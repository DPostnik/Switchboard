import Foundation
import AgentContract
import ContextCore

/// One running prompt turn of one session: turns `session/update` notifications into the current contract's events.
///
/// Mapping (until the shared model gets typed tool calls and plans, plan stage C): message chunks stream as `.delta` into
/// one assistant item per segment (a tool call or thought between chunks starts a new segment, a `messageId` names one);
/// thought chunks become a thinking item; a tool call is an `activity` item (title, kind, locations, raw input) whose
/// result item (`<call>:result`) carries the text, diff and terminal content once it completes or fails; the plan is one
/// `activity` item replaced on every update; `usage_update` is the context size; a completed compaction is a
/// `compaction` item. Other known updates return nil: the integration keeps what it needs and counts them.
struct ACPTurn {
    static let thinkingInterval: TimeInterval = 0.25
    let id: String
    let cwd: String
    let startedAt: Date
    /// Approval behavior of the turn's role: forward prompts to the user, or refuse every prompt.
    let attended: Bool
    private(set) var items: [TranscriptItem]
    var cancelRequested = false
    private var segment = 0
    private var message: (id: String, text: String)?
    private var thought: (id: String, text: String, started: Date, published: Date)?
    private var tools: [String: ACPToolState] = [:]
    private var usedRecorded = Set<String>()

    struct ACPToolState {
        var title: String
        var kind: String?
        var status: String?
        var locations: [ACPToolCallLocation] = []
        var rawInput: JSONValue?
        var content: [ACPToolCallContent] = []
        var rawOutput: JSONValue?
        var started: Date
    }

    init(id: String, cwd: String, prompt: TranscriptItem, attended: Bool, startedAt: Date = Date()) {
        self.id = id; self.cwd = cwd; self.attended = attended; self.startedAt = startedAt; items = [prompt]
    }

    static func userItem(turn: String, text: String) -> TranscriptItem { TranscriptItem(id: "user:" + turn, kind: "user", text: text) }
    static func callID(turn: String, tool: String) -> String { turn + ":tool:" + tool }

    private mutating func store(_ item: TranscriptItem) { TranscriptItem.merge(item, into: &items) }

    /// Payloads for one known update kind, or nil when the kind is not surfaced as an event.
    mutating func apply(_ kind: String, _ update: JSONValue, at now: Date = Date()) -> [AgentEvent.Payload]? {
        switch kind {
        case "agent_message_chunk":
            let text = Self.chunkText(update)
            guard !text.isEmpty else { return [] }
            var payloads = closeThought(at: now)
            let named = update["messageId"].string.map { id + ":assistant:" + $0 }
            if let current = message, named == nil || named == current.id {
                message = (current.id, current.text + text)
            } else {
                payloads += closeMessage()
                segment += 1
                message = (named ?? id + ":assistant:\(segment)", text)
                payloads.append(.status(turn: id, text: nil))
            }
            payloads.append(.delta(turn: id, item: message!.id, text: text))
            return payloads
        case "agent_thought_chunk":
            let text = Self.chunkText(update)
            guard !text.isEmpty else { return [] }
            var payloads = closeMessage()
            if let current = thought {
                thought = (current.id, current.text + text, current.started, current.published)
            } else {
                segment += 1
                thought = (id + ":thinking:\(segment)", text, now, .distantPast)
                payloads.append(.status(turn: id, text: L10n.text("Думает…", "Thinking…")))
            }
            if let current = thought, now.timeIntervalSince(current.published) >= Self.thinkingInterval {
                thought?.published = now
                let item = TranscriptItem(id: current.id, kind: ActivityDetail.thinkingKind, text: current.text)
                store(item); payloads.append(.item(item))
            }
            return payloads
        case "tool_call", "tool_call_update":
            guard let call = try? ACPCodec.decode(ACPToolCall.self, from: update) else { return [] }
            return closeMessage() + closeThought(at: now) + tool(call, at: now)
        case "plan":
            let entries = update["entries"].array.compactMap { try? ACPCodec.decode(ACPPlanEntry.self, from: $0) }
            let lines = entries.map { entry -> String in
                let mark = switch entry.status { case "completed": "[x]"; case "in_progress": "[~]"; default: "[ ]" }
                return mark + " " + entry.content
            }
            let item = TranscriptItem(id: id + ":plan", kind: "activity", text: ([L10n.text("План", "Plan")] + lines).joined(separator: "\n"))
            store(item)
            return [.item(item)]
        case "usage_update":
            guard let used = update["used"].int, let size = update["size"].int else { return [] }
            return [.usage(turn: id, total: nil, snapshot: UsageSnapshot(last: used, window: size, measuredAt: now))]
        case "compaction_update":
            guard let compaction = update["compactionId"].string else { return [] }
            switch update["status"].string {
            case "completed":
                var item = TranscriptItem(id: id + ":compaction:" + compaction, kind: "compaction",
                                          text: L10n.text("Контекст разговора сжат", "Conversation context compacted"), phase: "completed")
                item.compaction = ContextCompaction()
                store(item)
                return [.item(item), .status(turn: id, text: nil)]
            case "in_progress": return [.status(turn: id, text: L10n.text("Сжимает контекст…", "Compacting context…"))]
            default: return [.status(turn: id, text: nil)]
            }
        default: return nil
        }
    }

    /// A permission request names a tool call that may not have been announced yet.
    mutating func observe(permission call: ACPToolCall, at now: Date = Date()) -> [AgentEvent.Payload] {
        closeMessage() + closeThought(at: now) + tool(call, at: now)
    }

    func tool(_ id: String) -> ACPToolState? { tools[id] }

    private mutating func tool(_ call: ACPToolCall, at now: Date) -> [AgentEvent.Payload] {
        var state = tools[call.toolCallId] ?? ACPToolState(title: call.title ?? call.toolCallId, started: now)
        let wasFinished = ["completed", "failed"].contains(state.status ?? "")
        if let title = call.title, !title.isEmpty { state.title = title }
        if let kind = call.kind { state.kind = kind }
        if let status = call.status { state.status = status }
        if let locations = call.locations { state.locations = locations }
        if let input = call.rawInput { state.rawInput = input }
        if let content = call.content { state.content = content }
        if let output = call.rawOutput { state.rawOutput = output }
        tools[call.toolCallId] = state
        let callItem = TranscriptItem(id: Self.callID(turn: id, tool: call.toolCallId), kind: "activity", text: Self.callText(state))
        store(callItem)
        var payloads: [AgentEvent.Payload] = [.item(callItem)]
        if !wasFinished, state.status == "pending" || state.status == "in_progress" || state.status == nil {
            payloads.append(.status(turn: id, text: ActivityDetail.oneLine(state.title)))
        }
        if let status = state.status, ["completed", "failed"].contains(status) {
            var result = TranscriptItem(id: ActivityDetail.resultID(of: callItem.id), kind: "activity", text: Self.resultText(state))
            result.failed = status == "failed" ? true : nil
            result.seconds = max(0, now.timeIntervalSince(state.started))
            result = ActivityRetention.cap(result)
            store(result)
            payloads.append(.item(result))
            if !wasFinished { payloads.append(.status(turn: id, text: nil)) }
            if status == "completed", usedRecorded.insert(call.toolCallId).inserted {
                payloads.append(.capability(Self.capability(state, cwd: cwd, decision: .used, turn: id)))
            }
        }
        return payloads
    }

    /// Ends open text segments, for the end of the turn or before another kind of content.
    mutating func close(at now: Date = Date()) -> [AgentEvent.Payload] { closeMessage() + closeThought(at: now) }

    private mutating func closeMessage() -> [AgentEvent.Payload] {
        guard let current = message else { return [] }
        message = nil
        let item = TranscriptItem(id: current.id, kind: "assistant", text: current.text)
        store(item)
        return [.item(item)]
    }

    private mutating func closeThought(at now: Date) -> [AgentEvent.Payload] {
        guard let current = thought else { return [] }
        thought = nil
        var item = TranscriptItem(id: current.id, kind: ActivityDetail.thinkingKind, text: current.text)
        item.seconds = max(0, now.timeIntervalSince(current.started))
        store(item)
        return [.item(item)]
    }

    static func chunkText(_ update: JSONValue) -> String {
        (try? ACPCodec.decode(ACPContentBlock.self, from: update["content"]))?.display ?? ""
    }

    /// Title first (the transcript's headline), then kind, locations and the raw input as data.
    static func callText(_ state: ACPToolState) -> String {
        var lines = [state.title]
        if let kind = state.kind { lines.append(L10n.text("Вид: ", "Kind: ") + kind) }
        for location in state.locations { lines.append(location.path + (location.line.map { ":\($0)" } ?? "")) }
        if let input = state.rawInput, input != .null { lines.append(input.display) }
        return lines.joined(separator: "\n")
    }

    static func resultText(_ state: ACPToolState) -> String {
        var parts = state.content.map(\.display).filter { !$0.isEmpty }
        if parts.isEmpty, let output = state.rawOutput, output != .null { parts.append(output.display) }
        return parts.joined(separator: "\n\n")
    }

    static func capability(_ state: ACPToolState, cwd: String, decision: AgentCapabilityRecord.Decision, turn: String?) -> AgentCapabilityRecord {
        let target = state.locations.first?.path ?? ActivityDetail.oneLine(state.title, limit: 200)
        let capability: AgentCapabilityRecord.Capability
        switch state.kind {
        case "read", "search": capability = .read
        case "edit", "delete", "move": capability = state.locations.allSatisfy { isInside($0.path, cwd) } ? .writeInProject : .writeOutside
        case "execute": capability = .shell
        case "fetch": capability = .network
        default: capability = .other
        }
        return AgentCapabilityRecord(tool: state.kind ?? "other", capability: capability, target: target, decision: decision, turn: turn)
    }

    /// Lexical containment of an absolute path in the project; only used for ledger labels and to refuse prompts.
    static func isInside(_ path: String, _ root: String) -> Bool {
        let target = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
