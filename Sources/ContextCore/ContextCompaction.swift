import Foundation
import AgentContract

/// Text of the transcript's compaction divider and the carry of sizes the engine's history does not return.
extension ContextCompaction {
    /// One-line caption: "Context compacted: 120k → 30k · automatic"; without the size after, "Context compacted · was 120k".
    public func caption(language: AppLanguage = L10n.language) -> String {
        var text = L10n.text("Контекст сжат", "Context compacted", language: language)
        if let before, let after {
            text += ": " + Self.tokens(before, language: language) + " → " + Self.tokens(after, language: language)
        } else if let before {
            text += L10n.text(" · было ", " · was ", language: language) + Self.tokens(before, language: language)
        }
        if let trigger = triggerName(language: language) { text += " · " + trigger }
        return text
    }

    /// Exact numbers behind the caption, one per line; nil when nothing is known.
    public func detail(language: AppLanguage = L10n.language) -> String? {
        func number(_ value: Int) -> String { value.formatted(.number.locale(language.locale)) }
        var lines: [String] = []
        if let before { lines.append(L10n.text("Токенов до сжатия: ", "Tokens before: ", language: language) + number(before)) }
        if let after { lines.append(L10n.text("Токенов после: ", "Tokens after: ", language: language) + number(after)) }
        if let trigger = triggerName(language: language) { lines.append(L10n.text("Запуск: ", "Trigger: ", language: language) + trigger) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func triggerName(language: AppLanguage) -> String? {
        switch trigger {
        case "auto": L10n.text("автоматически", "automatic", language: language)
        case "manual": L10n.text("вручную", "manual", language: language)
        default: nil
        }
    }

    /// Short token count: 950, 9.5k, 120k, 1.2M, 12M (decimal comma in Russian).
    public static func tokens(_ value: Int, language: AppLanguage = L10n.language) -> String {
        func short(_ scaled: Double, _ unit: String) -> String {
            let digits = scaled < 9.95 ? 0...1 : 0...0
            return scaled.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(language.locale)) + unit
        }
        if value < 1_000 { return "\(value)" }
        // 999,500 would round to "1000k"; it reads as 1M.
        if value < 999_500 { return short(Double(value) / 1_000, "k") }
        return short(Double(value) / 1_000_000, "M")
    }

    /// Codex returns a history compaction item with its id only; the sizes were recorded from the live events. Copies
    /// them from `previous` onto items that lack them: by item id, else by position among the same turn's compactions.
    /// Returns whether anything changed.
    @discardableResult
    public static func carry(from previous: [TranscriptItem], into items: inout [TranscriptItem]) -> Bool {
        guard items.contains(where: { $0.kind == "compaction" && $0.compaction == nil }) else { return false }
        var byID: [String: ContextCompaction] = [:], byTurn: [String: [ContextCompaction?]] = [:]
        for item in previous where item.kind == "compaction" {
            if let value = item.compaction { byID[item.id] = value }
            if let turn = item.turnID { byTurn[turn, default: []].append(item.compaction) }
        }
        guard !byID.isEmpty else { return false }
        var seen: [String: Int] = [:], changed = false
        for index in items.indices where items[index].kind == "compaction" {
            var positional: ContextCompaction?
            if let turn = items[index].turnID {
                let ordinal = seen[turn, default: 0]; seen[turn] = ordinal + 1
                if let list = byTurn[turn], ordinal < list.count { positional = list[ordinal] }
            }
            guard items[index].compaction == nil, let value = byID[items[index].id] ?? positional else { continue }
            items[index].compaction = value; changed = true
        }
        return changed
    }
}
