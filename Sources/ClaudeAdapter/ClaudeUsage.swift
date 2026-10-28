import Foundation
import ContextCore
import AgentContract

/// Token accounting for one Claude session, decoded from the CLI's stream-json usage blocks.
///
/// Each API call reports `input_tokens` (uncached), `cache_creation_input_tokens` and
/// `cache_read_input_tokens`; their sum plus `output_tokens` is what the next call carries,
/// so the latest main-thread call is the context occupancy. The window is only reported by
/// the terminal `result` (`modelUsage[model].contextWindow`) and is retained across turns.
/// `result.usage` covers only that turn; `modelUsage` accumulates across `--resume`, so only
/// its window is read.
/// Subagent calls (`parent_tool_use_id`) run in their own context and are not counted.
struct ClaudeUsageMeter: Sendable, Equatable {
    /// Cumulative counters from completed turns. Cached input is a subset of input.
    private(set) var base: TokenCounters
    private(set) var window: Int?
    private(set) var last: Int?
    var model: String?
    /// The main-thread call whose `message_delta` is pending; deltas carry no message id.
    var current: String?
    /// When the latest main-thread call started; each call refreshes the prompt cache.
    private(set) var lastRequestAt: Date?
    /// Cache lifetime from the latest call that wrote cache; reads alone keep the previous value.
    private(set) var cacheTTL: TimeInterval?
    private var messages: [String: TokenCounters] = [:]
    private var latest: String?

    init(base: TokenCounters?, window: Int?, last: Int?) {
        self.base = base ?? .zero; self.window = window; self.last = last
    }

    static func counters(_ usage: JSONValue) -> TokenCounters? {
        guard let uncached = usage["input_tokens"].int else { return nil }
        let created = usage["cache_creation_input_tokens"].int ?? 0, read = usage["cache_read_input_tokens"].int ?? 0
        let output = usage["output_tokens"].int ?? 0
        guard uncached >= 0, created >= 0, read >= 0, output >= 0 else { return nil }
        return .init(input: uncached + created + read, cached: read, output: output)
    }

    /// Lifetime of the cache a call wrote: `cache_creation` splits it into 1 h and 5 min entries.
    static func cacheTTL(_ usage: JSONValue) -> TimeInterval? {
        let created = usage["cache_creation"]
        if (created["ephemeral_1h_input_tokens"].int ?? 0) > 0 { return 3600 }
        if (created["ephemeral_5m_input_tokens"].int ?? 0) > 0 { return 300 }
        return nil
    }

    /// Usage blocks repeat (start, per-block assistant events, final delta); fields only grow.
    mutating func observe(message: String, usage: JSONValue, at date: Date = Date()) -> Bool {
        // A final delta may omit input fields; the merge keeps the input from the start event.
        guard let value = Self.counters(usage) ?? usage["output_tokens"].int.flatMap({ $0 >= 0 ? TokenCounters(input: 0, cached: 0, output: $0) : nil })
        else { return false }
        let previous = messages[message]
        let merged = TokenCounters(input: max(previous?.input ?? 0, value.input), cached: max(previous?.cached ?? 0, value.cached),
                                   output: max(previous?.output ?? 0, value.output))
        if previous == nil { latest = message; lastRequestAt = date }
        if let ttl = Self.cacheTTL(usage) { cacheTTL = ttl }
        messages[message] = merged
        if latest == message { last = merged.input + merged.output }
        return merged != previous
    }

    /// The running turn, summed over observed main-thread calls.
    var turn: TokenCounters { messages.values.reduce(.zero, Self.add) }
    var total: TokenCounters { Self.add(base, turn) }

    /// Adopts the turn summary when it covers every observed call; it may include calls the
    /// stream did not surface (compaction, retries). Fewer reported tokens keep the observed sum.
    mutating func complete(result: JSONValue) {
        let observed = turn
        let reported = Self.counters(result["usage"]).flatMap { $0.subtracting(observed) == nil ? nil : $0 }
        base = Self.add(base, reported ?? observed)
        if let window = Self.window(result["modelUsage"], model: model) { self.window = window }
        messages.removeAll(); latest = nil; current = nil
    }

    /// Folds an unfinished turn into the base so later turns stay cumulative.
    mutating func abandon() {
        base = total; messages.removeAll(); latest = nil; current = nil
    }

    static func window(_ models: JSONValue, model: String?) -> Int? {
        let entries = models.object.compactMapValues { $0["contextWindow"].int.flatMap { $0 > 0 ? $0 : nil } }
        if let model, let exact = entries[model] { return exact }
        if entries.count == 1 { return entries.values.first }
        // Several models (e.g. a helper model) without a recognizable main one: the main
        // conversation model is the one that consumed the most input.
        return models.object.filter { entries[$0.key] != nil }
            .max { ($0.value["inputTokens"].int ?? 0) + ($0.value["cacheReadInputTokens"].int ?? 0) < ($1.value["inputTokens"].int ?? 0) + ($1.value["cacheReadInputTokens"].int ?? 0) }
            .flatMap { entries[$0.key] }
    }

    func snapshot(at date: Date = Date()) -> UsageSnapshot {
        let total = total
        return UsageSnapshot(last: last, window: window, input: total.input, cached: total.cached, output: total.output, measuredAt: date,
                             lastRequestAt: lastRequestAt, cacheTTL: cacheTTL)
    }

    private static func add(_ lhs: TokenCounters, _ rhs: TokenCounters) -> TokenCounters {
        .init(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached, output: lhs.output + rhs.output)
    }
}
