import Foundation
import AgentContract
import ContextCore

/// Projects native collaboration items into the shared sub-agent panel. Parent turn completion
/// does not end children: background agents can outlive it.
struct CodexSubagentTracker {
    static let stepLimit = 150, textLimit = 2000, resultLimit = 800, agentLimit = 24
    private var finalHistory = Set<String>()
    private var seenSteps: [String: Set<String>] = [:]
    private var seenTools: [String: Set<String>] = [:]
    private var lists: [String: [AgentSubagent]] = [:]

    static func interruptTarget(_ response: JSONValue, child: String) throws -> String? {
        let thread = response["thread"]
        guard thread["id"].string == child, case .array = thread["turns"] else {
            throw ClientFailure(L10n.text("Не удалось проверить состояние подагента.", "Could not verify the sub-agent state."))
        }
        return thread["turns"].array.last(where: { $0["status"].string == "inProgress" })?["id"].string
    }

    static func displayName(_ path: String) -> String {
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        return String(leaf.replacingOccurrences(of: "_", with: " ").prefix(80))
    }

    func historyIDs(parent: String) -> [String] {
        (lists[parent] ?? []).filter { $0.status == .running || !finalHistory.contains($0.id) }.map(\.id)
    }

    func runningIDs(parent: String) -> [String] {
        (lists[parent] ?? []).filter { $0.status == .running }.map(\.id)
    }

    mutating func stopped(_ id: String, parent: String, now: Date = Date()) -> AgentEvent? {
        guard let index = lists[parent]?.firstIndex(where: { $0.id == id }) else { return nil }
        lists[parent]![index].status = .stopped
        lists[parent]![index].endedAt = now
        lists[parent]![index].pendingTools = []; lists[parent]![index].activity = nil
        return .init(session: .init(connection: .originalCodex, nativeID: parent), payload: .subagents(lists[parent]!))
    }

    mutating func reset() -> [AgentEvent] {
        defer { lists.removeAll(); finalHistory.removeAll(); seenTools.removeAll(); seenSteps.removeAll() }
        return lists.keys.map { .init(session: .init(connection: .originalCodex, nativeID: $0), payload: .subagents([])) }
    }

    mutating func history(_ response: JSONValue, child: String) -> [AgentEvent] {
        let thread = response["thread"]
        guard thread["id"].string == child else { return [] }
        var events: [AgentEvent] = []
        for turn in thread["turns"].array.suffix(2) {
            for item in turn["items"].array.suffix(150) {
                let method = item["status"].string == "inProgress" ? "item/started" : "item/completed"
                let raw: JSONValue = .object(["method": .string(method), "params": .object([
                    "threadId": .string(child), "turnId": turn["id"], "item": item
                ])])
                if let event = childStep(raw, now: Date()) { events.append(event) }
            }
        }
        guard let parent = lists.keys.first(where: { lists[$0]?.contains(where: { $0.id == child }) == true }),
              let index = lists[parent]?.firstIndex(where: { $0.id == child }) else { return events }
        let before = lists[parent]![index]
        var agent = before
        if let role = thread["agentRole"].string ?? thread["model"].string { agent.type = role }
        if let date = thread["createdAt"].int { agent.startedAt = Date(timeIntervalSince1970: Double(date)) }
        if agent.prompt.isEmpty {
            let firstItems = thread["turns"].array.first?["items"].array ?? []
            let input = firstItems.first(where: { $0["type"].string == "userMessage" })?["content"].array ?? []
            agent.prompt = String(input.compactMap { $0["text"].string }.joined(separator: "\n").prefix(8000))
        }
        if let last = thread["turns"].array.last {
            switch last["status"].string {
            case "completed": agent.status = .completed
            case "failed": agent.status = .failed
            case "interrupted": agent.status = .stopped
            default: break
            }
            if agent.status != .running {
                agent.pendingTools = []; agent.activity = nil
                if agent.endedAt == nil { agent.endedAt = Date() }
                if let report = last["items"].array.last(where: { $0["type"].string == "agentMessage" })?["text"].string {
                    agent.report = String(report.prefix(8000))
                }
                finalHistory.insert(child)
            }
        }
        if agent != before {
            lists[parent]![index] = agent
            events.append(.init(session: .init(connection: .originalCodex, nativeID: parent), payload: .subagents(lists[parent]!)))
        }
        return events
    }

    /// Child transcript notifications retain the child's threadId. Publish their visible content
    /// under the observed parent, never as messages in the parent's main transcript.
    private mutating func childStep(_ raw: JSONValue, now: Date) -> AgentEvent? {
        let p = raw["params"]
        guard let child = p["threadId"].string,
              let parent = lists.keys.sorted().first(where: { lists[$0]?.contains(where: { $0.id == child }) == true }),
              var agents = lists[parent], let index = agents.firstIndex(where: { $0.id == child }) else { return nil }
        var agent = agents[index]
        let method = raw["method"].string ?? ""
        let prefix = (p["turnId"].string ?? "") + ":"
        func put(_ id: String, _ kind: AgentSubagent.Step.Kind, _ text: String, error: Bool = false, append: Bool = false) {
            guard !text.isEmpty || kind == .result else { return }
            let key = prefix + id
            if let existing = agent.steps.firstIndex(where: { $0.id == key }) {
                agent.steps[existing].text = String((append ? agent.steps[existing].text + text : text).prefix(kind == .result ? Self.resultLimit : Self.textLimit))
                agent.steps[existing].isError = error
            } else if seenSteps[child, default: []].insert(key).inserted {
                agent.steps.append(.init(id: key, kind: kind, text: String(text.prefix(kind == .result ? Self.resultLimit : Self.textLimit)), isError: error))
            }
        }
        switch method {
        case "item/agentMessage/delta":
            guard let id = p["itemId"].string else { return nil }
            put(id, .text, p["delta"].string ?? "", append: true)
        case "item/commandExecution/outputDelta":
            guard let id = p["itemId"].string else { return nil }
            put(id + ":result", .result, p["delta"].string ?? "", append: true)
        case "item/started", "item/completed":
            let item = p["item"]
            guard let decoded = CodexDecoding.transcriptItem(item), decoded.kind != "user" else { return nil }
            let tool = decoded.kind == "activity"
            let call = decoded.toolCall
            let detail = call?.inputSummary
            let line = [call?.title ?? decoded.text, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            put(decoded.id, tool ? .tool : .text, tool ? line : decoded.text)
            if tool {
                if method == "item/started", !agent.pendingTools.contains(where: { $0.id == decoded.id }) {
                    let name = item["tool"].string ?? item["type"].string ?? decoded.text
                    let args = item["arguments"]
                    let milliseconds = args["timeout_ms"].int ?? args["timeout"].int
                    agent.pendingTools.append(.init(id: decoded.id, name: name, timeout: milliseconds.flatMap { $0 > 0 ? Double($0) / 1000 : nil }))
                    if seenTools[child, default: []].insert(prefix + decoded.id).inserted {
                        agent.toolUses = (agent.toolUses ?? 0) + 1
                    }
                }
                if method == "item/completed" {
                    if seenTools[child, default: []].insert(prefix + decoded.id).inserted { agent.toolUses = (agent.toolUses ?? 0) + 1 }
                    agent.pendingTools.removeAll { $0.id == decoded.id }
                    if let result = CodexDecoding.commandResult(item) {
                        put(result.id, .result, result.text, error: result.failed == true || (result.exitCode ?? 0) != 0)
                    } else {
                        let parts = item["result"]["content"].array + item["contentItems"].array
                        let text = item["error"]["message"].string ?? parts.compactMap { $0["text"].string }.joined(separator: "\n")
                        put(decoded.id + ":result", .result, text, error: item["status"].string == "failed" || item["success"].bool == false)
                    }
                }
                agent.activity = agent.pendingTools.last?.name
            }
        case "thread/tokenUsage/updated":
            if let tokens = p["tokenUsage"]["total"]["totalTokens"].int { agent.tokens = tokens }
        case "turn/started":
            agent.status = .running; agent.endedAt = nil; agent.pendingTools = []; agent.activity = nil
            finalHistory.remove(child)
        case "turn/completed":
            switch p["turn"]["status"].string {
            case "completed": agent.status = .completed
            case "failed": agent.status = .failed
            case "interrupted": agent.status = .stopped
            default: return nil
            }
            agent.pendingTools = []; agent.activity = nil
            if agent.endedAt == nil { agent.endedAt = now }
            agent.report = agent.steps.last(where: { $0.kind == .text })?.text
        default: return nil
        }
        if agent.steps.count > Self.stepLimit {
            let dropped = agent.steps.count - Self.stepLimit
            agent.steps.removeFirst(dropped); agent.droppedSteps += dropped
        }
        guard agent != agents[index] else { return nil }
        agent.lastActivityAt = now
        agents[index] = agent; lists[parent] = agents
        return .init(session: .init(connection: .originalCodex, nativeID: parent), payload: .subagents(agents))
    }

    mutating func receive(_ raw: JSONValue, now: Date = Date()) -> AgentEvent? {
        if let event = childStep(raw, now: now) { return event }
        if raw["method"].string == "turn/started", let parent = raw["params"]["threadId"].string, let before = lists[parent] {
            lists[parent]?.removeAll { $0.status != .running }
            if lists[parent] != before { return .init(session: .init(connection: .originalCodex, nativeID: parent), payload: .subagents(lists[parent] ?? [])) }
        }
        let method = raw["method"].string, p = raw["params"], item = p["item"]
        guard method == "item/started" || method == "item/completed",
              let parent = p["threadId"].string, !parent.isEmpty,
              ["collabAgentToolCall", "subAgentActivity"].contains(item["type"].string ?? "") else { return nil }
        if item["type"].string == "subAgentActivity" {
            guard let id = item["agentThreadId"].string, !id.isEmpty, id != parent,
                  let kind = item["kind"].string, ["started", "interacted", "interrupted", "completed"].contains(kind) else { return nil }
            var agents = lists[parent] ?? []
            if !agents.contains(where: { $0.id == id }) {
                agents.append(.init(id: id, title: Self.displayName(item["agentPath"].string ?? id), type: nil, prompt: "", background: true, depth: 1, startedAt: now))
            }
            let index = agents.firstIndex(where: { $0.id == id })!
            if let path = item["agentPath"].string { agents[index].title = Self.displayName(path) }
            agents[index].status = kind == "completed" ? .completed : kind == "interrupted" ? .stopped : .running
            agents[index].endedAt = agents[index].status == .running ? nil : (agents[index].endedAt ?? now)
            if agents[index].status == .running { finalHistory.remove(id) }
            else { agents[index].pendingTools = []; agents[index].activity = nil }
            agents[index].lastActivityAt = now
            lists[parent] = agents
            return .init(session: .init(connection: .originalCodex, nativeID: parent), payload: .subagents(agents))
        }
        let states = item["agentsStates"].object
        let ids = Set(item["receiverThreadIds"].array.compactMap(\.string)).union(states.keys)
        var agents = lists[parent] ?? []
        let before = agents
        for id in ids.sorted() where !id.isEmpty && id != parent {
            let state = states[id] ?? .null
            let status: AgentSubagent.Status
            switch state["status"].string {
            case "completed": status = .completed
            case "errored": status = .failed
            case "shutdown", "notFound", "interrupted": status = .stopped
            case "pendingInit", "running": status = .running
            default:
                // A tool completing means delivery succeeded, not that its recipient finished.
                if item["tool"].string == "closeAgent", method == "item/completed", item["status"].string == "completed" { status = .stopped }
                else if let existing = agents.first(where: { $0.id == id }) { status = existing.status }
                else { status = .running }
            }
            if !agents.contains(where: { $0.id == id }) {
                let prompt = item["prompt"].string ?? ""
                agents.append(.init(id: id, title: String((prompt.isEmpty ? id : prompt).prefix(200)),
                                    type: item["model"].string, prompt: String(prompt.prefix(8000)), background: true,
                                    depth: 1, startedAt: now))
            }
            guard let index = agents.firstIndex(where: { $0.id == id }) else { continue }
            if let prompt = item["prompt"].string, agents[index].prompt.isEmpty {
                agents[index].prompt = String(prompt.prefix(8000))
            }
            if let model = item["model"].string { agents[index].type = model }
            agents[index].status = status
            agents[index].endedAt = status == .running ? nil : (agents[index].endedAt ?? now)
            if status == .running { finalHistory.remove(id) }
            else { agents[index].pendingTools = []; agents[index].activity = nil }
            agents[index].lastActivityAt = now
            if let message = state["message"].string, !message.isEmpty {
                agents[index].report = String(message.prefix(8000))
            }
        }
        // Bound completed history while preserving every running child.
        if agents.count > Self.agentLimit {
            var excess = agents.count - Self.agentLimit
            agents.removeAll { agent in
                guard excess > 0, agent.status != .running else { return false }
                excess -= 1; return true
            }
        }
        guard agents != before else { return nil }
        lists[parent] = agents
        return .init(session: .init(connection: .originalCodex, nativeID: parent), payload: .subagents(agents))
    }
}
