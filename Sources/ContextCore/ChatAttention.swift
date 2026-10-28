import Foundation

/// Why a chat waits for the user, most urgent first. A running chat waits for nobody.
public enum ChatAttention: Int, Comparable, Sendable {
    case needsApproval = 0, needsAnswer, failed, finishedUnread

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func of(approval: Bool, question: Bool, running: Bool, unread: Bool, failed: Bool) -> Self? {
        if approval { return .needsApproval }
        if question { return .needsAnswer }
        if running || !unread { return nil }
        return failed ? .failed : .finishedUnread
    }

    public var title: String {
        switch self {
        case .needsApproval: L10n.text("Нужно одобрение", "Needs approval")
        case .needsAnswer: L10n.text("Нужен ответ", "Needs an answer")
        case .failed: L10n.text("Ошибка", "Failed")
        case .finishedUnread: L10n.text("Готово", "Done")
        }
    }
}

/// A short line about a finished turn for lists and notifications, taken from the answer itself:
/// its last question when it asks one, otherwise its first sentences. No model call.
public enum TurnRecap {
    public static let limit = 200

    public static func make(_ answer: String) -> String? {
        let lines = plainLines(answer)
        guard !lines.isEmpty else { return nil }
        if let question = lines.last(where: { $0.hasSuffix("?") }), question.count <= limit { return question }
        var recap = ""
        // At most two sentences; one is enough once it is long.
        for (index, sentence) in sentences(lines.joined(separator: " ")).enumerated() {
            recap += (recap.isEmpty ? "" : " ") + sentence
            if index == 1 || recap.count >= 80 { break }
        }
        return recap.count > limit ? String(recap.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : recap
    }

    /// Lines without code blocks, tables and Markdown markup.
    static func plainLines(_ text: String) -> [String] {
        var result: [String] = [], fenced = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || trimmed.hasPrefix("|") || trimmed.hasPrefix("<") { continue }
            var line = trimmed.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^((#{1,6}|[-*+]|\d+[.)]|>)\s+|\[[ xX]\]\s+)*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, line.contains(where: \.isLetter) { result.append(line) }
        }
        return result
    }

    private static func sentences(_ text: String) -> [String] {
        // Split only where punctuation is followed by a space, so "2.1.292" stays whole;
        // a part starting in lower case ("e.g. this") belongs to the previous one.
        var result: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"(?<=[.!?…])\s+"#)
        var start = text.startIndex
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.map(Optional.some) + [nil] {
            let end = match.flatMap { Range($0.range, in: text)?.lowerBound } ?? text.endIndex
            let part = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
            if let match, let range = Range(match.range, in: text) { start = range.upperBound } else { start = text.endIndex }
            guard !part.isEmpty else { continue }
            if let last = result.last, part.first?.isLowercase == true { result[result.count - 1] = last + " " + part }
            else { result.append(part) }
        }
        return result
    }
}
