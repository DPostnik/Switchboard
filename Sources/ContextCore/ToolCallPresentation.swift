import Foundation
import AgentContract

/// Shared pieces of the structured tool calls (stage C, 2026-11-02): the titles both adapters give their calls, input
/// summaries, unified-diff hunks as ACP diff entries, the line diff the transcript draws, and model settings as config
/// options. Pure functions; the adapters decide what their native calls mean.
public enum ToolCallText {
    /// The last path component, or the path itself when it has none.
    public static func name(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
    public static func read(_ path: String) -> String { L10n.text("Чтение \(name(path))", "Read \(name(path))") }
    public static func edit(_ path: String) -> String { L10n.text("Изменение \(name(path))", "Edit \(name(path))") }
    public static func create(_ path: String) -> String { L10n.text("Создание \(name(path))", "Create \(name(path))") }
    public static func delete(_ path: String) -> String { L10n.text("Удаление \(name(path))", "Delete \(name(path))") }
    public static func move(_ path: String, to target: String) -> String {
        L10n.text("Перенос \(name(path)) → \(name(target))", "Move \(name(path)) → \(name(target))")
    }
    public static func files(_ count: Int) -> String { L10n.text("Изменение файлов: \(count)", "Edit \(count) files") }
    public static func search(_ pattern: String) -> String { L10n.text("Поиск «\(pattern)»", "Search “\(pattern)”") }
    public static func webSearch(_ query: String) -> String { L10n.text("Поиск в интернете: \(query)", "Web search: \(query)") }
    public static func fetch(_ url: String) -> String { L10n.text("Загрузка \(url)", "Fetch \(url)") }
    public static var plan: String { L10n.text("Обновление плана", "Update plan") }

    /// A one-line compact JSON summary of a call's input, at most `limit` characters; nil for an empty input.
    public static func inputSummary(_ input: JSONValue, limit: Int = 200) -> String? {
        if case .object(let object) = input, object.isEmpty { return nil }
        if input == .null { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input) else { return nil }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

extension AgentToolCall.Diff {
    /// The hunks of a unified diff for one file as diff entries: each carries its old and new side (context lines on
    /// both) and the new file's start line. Nil when the text has no hunk header.
    public static func hunks(unifiedDiff text: String, path: String) -> [Self]? {
        var result: [Self] = [], old: [String] = [], new: [String] = [], line: Int?, open = false
        func close() {
            if open { result.append(Self(path: path, oldText: old.joined(separator: "\n"), newText: new.joined(separator: "\n"), line: line)) }
            old = []; new = []; open = false
        }
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            if raw.hasPrefix("@@") {
                close(); open = true
                // "@@ -12,3 +14,5 @@": the new side starts at line 14.
                line = raw.range(of: #"\+(\d+)"#, options: .regularExpression).flatMap { Int(raw[$0].dropFirst()) }
                continue
            }
            guard open else { continue }
            if raw.hasPrefix("+") { new.append(String(raw.dropFirst())) }
            else if raw.hasPrefix("-") { old.append(String(raw.dropFirst())) }
            else if raw.hasPrefix(" ") { old.append(String(raw.dropFirst())); new.append(String(raw.dropFirst())) }
            else if raw.hasPrefix("\\") { continue } // "\ No newline at end of file"
            else if raw.isEmpty, index < lines.count - 1 { old.append(""); new.append("") }
        }
        close()
        return result.isEmpty ? nil : result
    }
}

/// The line diff the transcript draws for a diff entry.
public enum ToolCallDiffLines {
    public enum Sign: Sendable, Equatable { case context, added, removed }
    public struct Line: Sendable, Equatable {
        public var sign: Sign
        public var text: String
        public init(_ sign: Sign, _ text: String) { self.sign = sign; self.text = text }
    }
    /// Above this many lines on a side the sides are not matched: every old line shows as removed, every new one as added.
    public static let matchLimit = 600

    /// Old and new side as context, removed and added lines (longest common subsequence of lines). A new file is all
    /// added lines; a deleted one all removed lines.
    public static func lines(old: String?, new: String) -> [Line] {
        let before = old.map(split) ?? [], after = split(new)
        guard !before.isEmpty else { return after.map { Line(.added, $0) } }
        guard !after.isEmpty else { return before.map { Line(.removed, $0) } }
        guard before.count <= matchLimit, after.count <= matchLimit else {
            return before.map { Line(.removed, $0) } + after.map { Line(.added, $0) }
        }
        let n = before.count, m = after.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = before[i] == after[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Line] = [], i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, before[i] == after[j] { result.append(Line(.context, before[i])); i += 1; j += 1 }
            // Removed lines come before the added lines that replace them.
            else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] { result.append(Line(.removed, before[i])); i += 1 }
            else { result.append(Line(.added, after[j])); j += 1 }
        }
        return result
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

extension AgentConfigOption {
    /// Model and reasoning effort as config options, from a model list (the current values are kept even when the
    /// list does not name them).
    public static func modelAndEffort(models: [AgentModelInfo], model: String, effort: String?) -> [Self] {
        var modelValues = models.map { Value(id: $0.id, name: $0.displayName) }
        if !model.isEmpty, !modelValues.contains(where: { $0.id == model }) { modelValues.insert(Value(id: model, name: model), at: 0) }
        var options = [Self(id: "model", name: L10n.text("Модель", "Model"), category: .model, kind: .select(modelValues), current: model)]
        let efforts = models.first { $0.id == model }?.efforts ?? []
        let current = effort ?? models.first { $0.id == model }?.defaultEffort ?? ""
        var effortValues = efforts.map { Value(id: $0, name: effortName($0)) }
        if !current.isEmpty, !effortValues.contains(where: { $0.id == current }) { effortValues.append(Value(id: current, name: effortName(current))) }
        if !effortValues.isEmpty {
            options.append(Self(id: "effort", name: L10n.text("Усилие", "Effort"), category: .thoughtLevel, kind: .select(effortValues), current: current))
        }
        return options
    }

    public static func effortName(_ value: String) -> String {
        switch value {
        case "none": L10n.text("Без рассуждения", "None")
        case "minimal": L10n.text("Минимальное", "Minimal")
        case "low": L10n.text("Низкое", "Low")
        case "medium": L10n.text("Среднее", "Medium")
        case "high": L10n.text("Высокое", "High")
        case "xhigh": L10n.text("Повышенное", "Extra high")
        case "max": L10n.text("Максимальное", "Maximum")
        default: value
        }
    }
}
