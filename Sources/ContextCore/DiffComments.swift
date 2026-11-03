import Foundation

/// A comment on lines of a turn's diff, written into the chat draft for the agent; nothing is sent by itself.
public enum DiffComment {
    /// At most this many diff lines are quoted; the location still names the whole range.
    public static let quotedLineLimit = 40

    /// Changed or context lines of the selection; hunk headers and notes are not code.
    public static func codeLines(_ lines: ArraySlice<DiffLine>) -> [DiffLine] {
        lines.filter { $0.kind == .added || $0.kind == .removed || $0.kind == .context }
    }

    /// `path:12` or `path:12-15` in the new file; a selection of removed lines only names their old lines.
    public static func location(path: String, lines: [DiffLine]) -> String {
        let new = lines.filter { $0.kind != .removed }.compactMap(\.new)
        if let first = new.min(), let last = new.max() {
            return path + ":" + (first == last ? "\(first)" : "\(first)-\(last)")
        }
        let old = lines.compactMap(\.old)
        guard let first = old.min(), let last = old.max() else { return path }
        return path + ":" + (first == last ? "\(first)" : "\(first)-\(last)") + L10n.text(" (удалённые строки)", " (removed lines)")
    }

    /// The location, the quoted diff lines and the comment after the current draft.
    public static func draft(path: String, lines: [DiffLine], comment: String, appendingTo draft: String) -> String {
        let quoted = lines.prefix(quotedLineLimit).map { line in
            (line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text
        }
        var fence = "```"
        while quoted.contains(where: { $0.contains(fence) }) { fence += "`" }
        var block = "`" + location(path: path, lines: lines) + "`\n" + fence + "diff\n" + quoted.joined(separator: "\n")
        if lines.count > quotedLineLimit { block += "\n…" }
        block += "\n" + fence + "\n" + comment.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        let head = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (head.isEmpty ? "" : head + "\n\n") + block
    }

    /// The line to open in an editor for a diff line: its new line, or for a removed line the next surviving one.
    public static func editorLine(_ index: Int, in lines: [DiffLine]) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        if let new = lines[index].new { return new }
        return lines[index...].lazy.compactMap(\.new).first ?? lines[..<index].reversed().lazy.compactMap(\.new).first
    }

    /// A diff line as plain text for the pasteboard: its text without the `+`/`-` sign.
    public static func copyText(_ line: DiffLine) -> String { line.text }

    /// Lines as unified diff text for the pasteboard: changed and context lines with their sign, hunk headers and
    /// notes (`\ No newline at end of file`) as they are.
    public static func copyText(_ lines: ArraySlice<DiffLine>) -> String {
        lines.map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .hunk, .note: line.text
            }
        }
        .joined(separator: "\n")
    }
}

extension DiffLine {
    /// The hunk a line belongs to: its `@@` header through the line before the next header. Lines before the first
    /// header (mode or rename notes) belong to no hunk. Scans only the hunk, so it is meant for a click, not a render.
    public static func hunk(containing index: Int, in lines: [DiffLine]) -> ArraySlice<DiffLine>? {
        guard lines.indices.contains(index), let start = lines[...index].lastIndex(where: { $0.kind == .hunk }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.kind == .hunk } ?? lines.endIndex
        return lines[start..<end]
    }
}
