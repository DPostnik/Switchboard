import Foundation

/// A tool call as structured data, shaped after ACP's `tool_call` (research note "ACP and Zed", step 2, 2026-11-02):
/// what kind of action it is, how far it got, a title, the files it touches and what it produced. Adapters map their
/// native calls into this; the transcript draws it without parsing text. It rides on the call's `TranscriptItem`
/// (`toolCall`); a later item with the same id replaces the earlier one, as ACP v2 updates by id.
///
/// Stored with the transcript, so decoding is lenient: an unknown kind reads as `.other`, an unknown status as
/// `.completed`, and a content entry of an unknown type is skipped instead of failing the whole history.
public struct AgentToolCall: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case read, edit, delete, move, search, execute, think, fetch, switchMode, other
    }
    /// ACP's pending, in progress, completed and failed, plus the app's own approval and stop states.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending, inProgress, completed, failed, awaitingApproval, rejected, cancelled
        /// The call will not change any more.
        public var isFinal: Bool { [.completed, .failed, .rejected, .cancelled].contains(self) }
    }
    public struct Location: Codable, Sendable, Equatable, Hashable {
        public var path: String
        /// 1-based line, when the call names one.
        public var line: Int?
        public init(path: String, line: Int? = nil) { self.path = path; self.line = line }
    }
    /// A file change: `oldText` nil for a new file, `newText` empty for a deleted one. One change may come as several
    /// entries for the same path (one per hunk), each carrying only the lines around its change.
    public struct Diff: Codable, Sendable, Equatable {
        public var path: String
        public var oldText: String?
        public var newText: String
        /// 1-based line in the new file where `newText` starts, when known.
        public var line: Int?
        public init(path: String, oldText: String?, newText: String, line: Int? = nil) {
            self.path = path; self.oldText = oldText; self.newText = newText; self.line = line
        }
    }
    public struct Terminal: Codable, Sendable, Equatable {
        public var command: String?
        public var output: String
        public var exitCode: Int?
        public init(command: String?, output: String = "", exitCode: Int? = nil) {
            self.command = command; self.output = output; self.exitCode = exitCode
        }
    }
    public enum Content: Sendable, Equatable {
        case text(String)
        case diff(Diff)
        case terminal(Terminal)
    }

    public var id: String
    public var kind: Kind
    public var status: Status
    public var title: String
    public var locations: [Location]
    public var content: [Content]
    /// A short neutral summary of the call's input (one line), for calls whose title does not say everything.
    public var inputSummary: String?

    public init(id: String, kind: Kind, status: Status, title: String, locations: [Location] = [], content: [Content] = [],
                inputSummary: String? = nil) {
        self.id = id; self.kind = kind; self.status = status; self.title = title
        self.locations = locations; self.content = content; self.inputSummary = inputSummary
    }

    public var diffs: [Diff] { content.compactMap { if case .diff(let diff) = $0 { diff } else { nil } } }
    public var terminal: Terminal? { content.lazy.compactMap { if case .terminal(let terminal) = $0 { terminal } else { nil } }.first }

    private enum CodingKeys: String, CodingKey { case id, kind, status, title, locations, content, inputSummary }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = (try? container.decode(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .other
        status = (try? container.decode(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .completed
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        locations = (try? container.decode([LenientEntry<Location>].self, forKey: .locations))?.compactMap(\.value) ?? []
        content = (try? container.decode([LenientEntry<Content>].self, forKey: .content))?.compactMap(\.value) ?? []
        inputSummary = try? container.decodeIfPresent(String.self, forKey: .inputSummary)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encode(title, forKey: .title)
        if !locations.isEmpty { try container.encode(locations, forKey: .locations) }
        if !content.isEmpty { try container.encode(content, forKey: .content) }
        try container.encodeIfPresent(inputSummary, forKey: .inputSummary)
    }
}

extension AgentToolCall.Content: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, diff, terminal }
    private struct UnknownType: Error {}
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "diff": self = .diff(try container.decode(AgentToolCall.Diff.self, forKey: .diff))
        case "terminal": self = .terminal(try container.decode(AgentToolCall.Terminal.self, forKey: .terminal))
        default: throw UnknownType()
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try container.encode("text", forKey: .type); try container.encode(text, forKey: .text)
        case .diff(let diff): try container.encode("diff", forKey: .type); try container.encode(diff, forKey: .diff)
        case .terminal(let terminal): try container.encode("terminal", forKey: .type); try container.encode(terminal, forKey: .terminal)
        }
    }
}

/// Decodes one array element, or nil when it does not decode, so one unreadable entry never loses the rest.
private struct LenientEntry<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// The agent's plan for the current work, shaped after ACP's `plan` update: every update carries the whole list and
/// replaces the previous one. Shown in the transcript as one checklist item per turn (`TranscriptItem.plan`).
public struct AgentPlan: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable, CaseIterable { case pending, inProgress, completed }
        public enum Priority: String, Codable, Sendable, CaseIterable { case high, medium, low }
        public var content: String
        public var status: Status
        public var priority: Priority
        public init(content: String, status: Status, priority: Priority = .medium) {
            self.content = content; self.status = status; self.priority = priority
        }
        private enum CodingKeys: String, CodingKey { case content, status, priority }
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decode(String.self, forKey: .content)
            status = (try? container.decode(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .pending
            priority = (try? container.decode(String.self, forKey: .priority)).flatMap(Priority.init(rawValue:)) ?? .medium
        }
    }
    public var entries: [Entry]
    /// The agent's note about the plan, when it gives one.
    public var explanation: String?
    public init(entries: [Entry], explanation: String? = nil) { self.entries = entries; self.explanation = explanation }

    /// Transcript item kind of a plan checklist.
    public static let itemKind = "plan"
    /// One plan item per turn: a later update of the turn's plan replaces it in place.
    public static func itemID(turn: String) -> String { "plan:" + turn }

    /// Plain-text checklist, one entry per line ("[x] done", "[~] in progress", "[ ] pending"), so readers that know
    /// only text (search, summaries, older builds) still see the plan.
    public var checklist: String {
        var lines = entries.map { entry -> String in
            let mark = switch entry.status { case .completed: "[x]"; case .inProgress: "[~]"; case .pending: "[ ]" }
            return mark + " " + entry.content
        }
        if let explanation, !explanation.isEmpty { lines.insert(explanation, at: 0) }
        return lines.joined(separator: "\n")
    }

    /// The turn's plan as a transcript item.
    public func transcriptItem(turn: String, agentName: String? = nil) -> TranscriptItem {
        var item = TranscriptItem(id: Self.itemID(turn: turn), kind: Self.itemKind, text: checklist)
        item.turnID = turn; item.agentName = agentName; item.plan = self; item.showsCopyControl = false
        return item
    }
}

/// One session setting the agent exposes, shaped after ACP's config options (`session/set_config_option`), which
/// replaced separate model and mode calls. A boolean option's `current` is "true" or "false".
public struct AgentConfigOption: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable { case mode, model, modelConfig, thoughtLevel, other }
    public struct Value: Sendable, Equatable, Hashable {
        public var id: String
        public var name: String
        public var description: String?
        public init(id: String, name: String, description: String? = nil) { self.id = id; self.name = name; self.description = description }
    }
    public enum Kind: Sendable, Equatable {
        case select([Value])
        case boolean
    }
    public var id: String
    public var name: String
    public var category: Category
    public var kind: Kind
    public var current: String
    public init(id: String, name: String, category: Category, kind: Kind, current: String) {
        self.id = id; self.name = name; self.category = category; self.kind = kind; self.current = current
    }
}

/// A command the agent offers (ACP `available_commands_update`), such as a slash command. Typed by the user as
/// "/name"; `inputHint` describes the expected argument.
public struct AgentCommand: Sendable, Equatable, Hashable {
    public var name: String
    public var description: String
    public var inputHint: String?
    public init(name: String, description: String = "", inputHint: String? = nil) {
        self.name = name; self.description = description
        self.inputHint = inputHint.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Why a turn ended, after ACP's `StopReason`, plus the app's usage-limit and failure cases.
public enum AgentStopReason: String, Sendable, Equatable, CaseIterable {
    case endTurn, maxTokens, maxTurnRequests, refusal, cancelled, usageLimit, failed

    /// The reason implied by an outcome when the engine names none.
    public static func implied(by outcome: AgentExecutionOutcome, usageLimit: Bool = false) -> Self? {
        if usageLimit { return .usageLimit }
        switch outcome {
        case .completed: return .endTurn
        case .cancelled: return .cancelled
        case .failed, .blocked: return .failed
        case .uncertain: return nil
        }
    }
}
