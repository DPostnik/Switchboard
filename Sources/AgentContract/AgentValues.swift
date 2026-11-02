import Foundation

public struct ResponseTiming: Codable, Sendable, Equatable {
    public var startedAt: Date?
    public var completedAt: Date
    public var durationSeconds: Double?
    public var tokens: ResponseTokens?
    /// Files the turn changed in the project's git repository, from its start and end checkpoints.
    public var changes: TurnChanges?
    public init(startedAt: Date?, completedAt: Date, durationSeconds: Double? = nil, tokens: ResponseTokens? = nil, changes: TurnChanges? = nil) {
        self.startedAt = startedAt; self.completedAt = completedAt
        self.durationSeconds = durationSeconds; self.tokens = tokens; self.changes = changes
    }

    public static func apply(_ timing: Self?, to items: inout [TranscriptItem]) {
        guard let timing, let index = items.lastIndex(where: { $0.kind == "assistant" }) else { return }
        items[index].timing = timing
    }
}

/// A turn's working-tree checkpoints (commits under `refs/switchboard/checkpoints/` in the project's own repository)
/// and the size of the change between them. Counts are stored so the transcript never runs git to draw them.
public struct TurnChanges: Codable, Sendable, Equatable {
    /// Top level of the repository the checkpoints live in.
    public var repository: String
    public var start: String
    public var end: String
    public var files: Int
    public var added: Int
    public var removed: Int
    /// Another chat in the same project folder was running during the turn; its edits may be counted here.
    public var otherChats: Bool?
    public init(repository: String, start: String, end: String, files: Int, added: Int, removed: Int, otherChats: Bool? = nil) {
        self.repository = repository; self.start = start; self.end = end
        self.files = files; self.added = added; self.removed = removed; self.otherChats = otherChats
    }
}

/// Agent-facing note appended to a message sent with "Interrupt and send". Without it the agent read the new message
/// as a replacement and silently dropped the interrupted request. Transcripts show the message without the note.
public enum InterruptedTurnNote {
    public static let russian = "[Switchboard: пользователь прервал предыдущий ход, чтобы отправить это сообщение. Если сообщение не отменяет и не заменяет прерванную задачу, учти его и доведи ту задачу до конца. Фоновые задачи прерванного хода могли остановиться; перезапусти те, что ещё нужны.]"
    public static let english = "[Switchboard: the user interrupted the previous turn to send this message. Unless this message cancels or replaces the interrupted task, take it into account and finish that task. Background tasks of the interrupted turn may have stopped; restart the ones that are still needed.]"
    static let separator = "\n\n"
    public static func applying(_ note: String, to text: String) -> String { text + separator + note }
    public static func stripped(_ text: String) -> String {
        for note in [russian, english] where text.hasSuffix(separator + note) {
            return String(text.dropLast(separator.count + note.count))
        }
        return text
    }
}

public struct TranscriptItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var phase: String?
    public var turnID: String?
    public var showsAuthor = true
    public var showsCopyControl = true
    public var timing: ResponseTiming?
    public var agentName: String?
    /// UTF-8 size of a tool body before it was capped at record time or reduced after archiving; nil while intact.
    public var fullLength: Int?
    /// Set once the body was replaced by its headline and a metadata line after archiving; never undone.
    public var reduced: Bool?
    /// Context size around a `compaction` item, when known; nil on other kinds and on items stored before it existed.
    public var compaction: ContextCompaction?
    /// Native tool name when the text does not start with it: "commandExecution" on a Codex command's call item.
    public var tool: String?
    /// Exit status of a finished shell command, on its result item (`<call id>:result`).
    public var exitCode: Int?
    /// The call finished unsuccessfully without an exit status (tool error, declined or interrupted command); on its result item.
    public var failed: Bool?
    /// Seconds a thinking block or a command took, when the engine reported or the adapter measured it.
    public var seconds: Double?
    /// The structured call behind an activity item (`AgentToolCall`); nil on results, other kinds and items stored
    /// before it existed, which keep their text-only presentation.
    public var toolCall: AgentToolCall?
    /// The checklist of a `plan` item (`AgentPlan.itemKind`); nil on other kinds.
    public var plan: AgentPlan?
    public init(id: String, kind: String, text: String, phase: String? = nil, timing: ResponseTiming? = nil) {
        self.id = id; self.kind = kind; self.phase = phase; self.timing = timing
        self.text = kind == "user" ? InterruptedTurnNote.stripped(text) : text
    }
    public static func merge(_ item: Self, into items: inout [Self]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.timing = item.timing ?? items[index].timing
            updated.turnID = item.turnID ?? items[index].turnID
            items[index] = updated
        } else if item.kind == "user", let index = items.firstIndex(where: {
            $0.kind == "user" && $0.id.hasPrefix("local-user:") && $0.text == item.text
        }) {
            items[index] = item
        } else { items.append(item) }
    }
}

/// Context size in tokens before and after an engine compacted the conversation. Claude Code reports both and what
/// triggered it (`compact_boundary`); for Codex the adapter reads them from the thread's usage reports around the item.
public struct ContextCompaction: Codable, Sendable, Equatable {
    public var before: Int?
    public var after: Int?
    /// The engine's own value: "auto" or "manual" from Claude Code; kept as text so an unknown value still decodes.
    public var trigger: String?
    public init(before: Int? = nil, after: Int? = nil, trigger: String? = nil) {
        self.before = before; self.after = after; self.trigger = trigger
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var last: Int?
    public var window: Int?
    public var input: Int?
    public var cached: Int?
    public var output: Int?
    public var measuredAt: Date
    /// When the latest model request was made; each request refreshes the prompt cache.
    public var lastRequestAt: Date?
    /// Prompt cache lifetime in seconds, from the latest request that wrote cache.
    public var cacheTTL: TimeInterval?
    public init(last: Int? = nil, window: Int? = nil, input: Int? = nil, cached: Int? = nil,
                output: Int? = nil, measuredAt: Date = Date(), lastRequestAt: Date? = nil, cacheTTL: TimeInterval? = nil) {
        self.last = last; self.window = window; self.input = input
        self.cached = cached; self.output = output; self.measuredAt = measuredAt
        self.lastRequestAt = lastRequestAt; self.cacheTTL = cacheTTL
    }
    /// Prompt cache freshness at `now`; nil until a request with a known cache lifetime.
    public func cacheState(now: Date = Date()) -> PromptCacheState? {
        guard let lastRequestAt, let cacheTTL, cacheTTL > 0 else { return nil }
        let remaining = cacheTTL - now.timeIntervalSince(lastRequestAt)
        guard remaining > 0 else { return .cold }
        // The last fifth of the lifetime, at most five minutes: time to send now or start a new chat.
        return remaining <= min(300, cacheTTL / 5) ? .expiring(remaining: remaining) : .warm(remaining: remaining)
    }
    public var contextFraction: Double? {
        guard let last, let window, last >= 0, window > 0 else { return nil }
        return min(1, Double(last) / Double(window))
    }
    public var uncached: Int? {
        guard let input, let cached, input >= cached else { return nil }; return input - cached
    }
}

/// Whether the next request re-reads the conversation from the prompt cache or pays for it again.
public enum PromptCacheState: Sendable, Equatable {
    case warm(remaining: TimeInterval)
    case expiring(remaining: TimeInterval)
    case cold
    public var needsAttention: Bool { if case .warm = self { false } else { true } }
}

public struct TokenCounters: Codable, Sendable, Equatable {
    public var input: Int
    public var cached: Int
    public var output: Int
    public static let zero = Self(input: 0, cached: 0, output: 0)

    public init(input: Int, cached: Int, output: Int) {
        self.input = input; self.cached = cached; self.output = output
    }
    public func subtracting(_ previous: Self) -> Self? {
        guard input >= previous.input, cached >= previous.cached, output >= previous.output,
              cached - previous.cached <= input - previous.input else { return nil }
        return Self(input: input - previous.input, cached: cached - previous.cached, output: output - previous.output)
    }
}

public struct ResponseTokens: Codable, Sendable, Equatable {
    public var counts: TokenCounters
    public var isPartial: Bool
    public init(counts: TokenCounters, isPartial: Bool) { self.counts = counts; self.isPartial = isPartial }

}

public struct AccountLimits: Sendable {
    public let buckets: [LimitBucket]
    public let ordinaryUsageAllowed: Bool?
    public let fetchedAt: Date

    public init(buckets: [LimitBucket], ordinaryUsageAllowed: Bool?, fetchedAt: Date) {
        self.buckets = buckets; self.ordinaryUsageAllowed = ordinaryUsageAllowed; self.fetchedAt = fetchedAt
    }
}

public struct LimitBucket: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let windows: [LimitWindow]

    public init(id: String, name: String, windows: [LimitWindow]) {
        self.id = id; self.name = name; self.windows = windows
    }
}

public struct LimitWindow: Identifiable, Sendable {
    public let id: String
    public let remainingPercent: Int?
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(id: String, remainingPercent: Int?, durationMinutes: Int?, resetsAt: Date?) {
        self.id = id; self.remainingPercent = remainingPercent
        self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }

}
