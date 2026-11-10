import Foundation

/// Block-level Markdown for chat answers. Parsing yields data only: no HTML is
/// interpreted except the `<details>` disclosure wrapper, and nothing is fetched.
/// Streaming prefixes stay readable: an unclosed fence is still a code block.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(MarkdownListItem)
    case code(MarkdownCode)
    case quote(String)
    case callout(MarkdownCallout)
    case table(MarkdownTable)
    case rule
    case image(alt: String, source: String)
    case details(summary: String, body: String)
    case footnote(label: String, text: String)
    /// YAML front matter at the very start of a document, as ordered key/value pairs.
    case properties([MarkdownProperty])
}

public struct MarkdownProperty: Equatable, Sendable {
    public var name: String
    public var values: [String]
    public init(name: String, values: [String]) { self.name = name; self.values = values }
}

public struct MarkdownListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable { case bullet, ordered(Int) }
    public var depth: Int
    public var marker: Marker
    public var checked: Bool?
    public var text: String
    public init(depth: Int, marker: Marker, checked: Bool? = nil, text: String) {
        self.depth = depth; self.marker = marker; self.checked = checked; self.text = text
    }
}

public struct MarkdownCode: Equatable, Sendable {
    public var language: String?
    public var text: String
    public var closed: Bool
    public init(language: String?, text: String, closed: Bool = true) {
        self.language = language; self.text = text; self.closed = closed
    }

    public var lineCount: Int { text.isEmpty ? 0 : text.components(separatedBy: "\n").count }
    public var isShell: Bool { ["sh", "bash", "zsh", "shell", "console", "terminal", "fish"].contains(language?.lowercased() ?? "") }
    public var isDiff: Bool { ["diff", "patch"].contains(language?.lowercased() ?? "") }

    /// Box drawing or an ASCII grid: wrapped lines would break the picture, so such blocks are not wrapped.
    public var isDrawing: Bool {
        guard !isDiff else { return false }
        return text.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
            || text.range(of: #"(?m)^\s*\+[-=+]{3,}\+\s*$"#, options: .regularExpression) != nil
    }

    /// The table a whole block draws with characters (`┌─┬─┐`, `+---+`, psql output); Markdown source stays code.
    public var drawnTable: MarkdownTable? {
        guard closed, !isDiff, !["markdown", "md"].contains(language?.lowercased() ?? "") else { return nil }
        return MarkdownTable.drawn(text)
    }

    /// Text placed on the pasteboard. Shell transcripts copy only their commands,
    /// without prompts or printed output; other code is copied verbatim.
    public var copyText: String {
        guard isShell else { return text }
        let lines = text.components(separatedBy: "\n")
        let prompted = lines.compactMap { line -> String? in
            for prompt in ["$ ", "% ", "# ", "❯ ", "> "] where line.hasPrefix(prompt) { return String(line.dropFirst(prompt.count)) }
            return nil
        }
        // Only `$`/`%`/`❯` reliably mark prompts; `#` and `>` alone are comments or continuations.
        let hasPrompts = lines.contains { $0.hasPrefix("$ ") || $0.hasPrefix("% ") || $0.hasPrefix("❯ ") }
        return hasPrompts ? prompted.joined(separator: "\n") : text
    }
}

public struct MarkdownCallout: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case note, tip, important, warning, caution }
    public var kind: Kind
    public var title: String?
    public var body: String
    public init(kind: Kind, title: String? = nil, body: String) { self.kind = kind; self.title = title; self.body = body }
}

/// A block together with the source lines it came from.
public struct MarkdownNode: Equatable, Sendable {
    public var block: MarkdownBlock
    public var lines: Range<Int>
}

public enum MarkdownBlocks {
    public static func parse(_ source: String) -> [MarkdownBlock] { nodes(source).map(\.block) }

    public static func nodes(_ source: String) -> [MarkdownNode] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownNode] = []
        var index = 0
        var listIndents: [Int] = []
        if let (properties, end) = frontMatter(lines) {
            result.append(MarkdownNode(block: .properties(properties), lines: 0..<end))
            index = end
        }
        while index < lines.count {
            let line = lines[index]
            let start = index
            func add(_ block: MarkdownBlock) { result.append(MarkdownNode(block: block, lines: start..<index)) }
            if isBlank(line) {
                index += 1
                // A blank line ends a list unless the next line continues it.
                if index < lines.count, listMarker(lines[index]) == nil, indentation(lines[index]) < 2 { listIndents = [] }
                continue
            }
            // HTML comments are notes for editors, not content.
            if trimLeading(line).hasPrefix("<!--") {
                while index < lines.count, !lines[index].contains("-->") { index += 1 }
                index = min(lines.count, index + 1)
                continue
            }
            if let fence = fenceOpening(line) {
                index += 1
                var body: [String] = []
                var closed = false
                while index < lines.count {
                    let current = lines[index]
                    if isFenceClose(current, fence: fence) { closed = true; index += 1; break }
                    body.append(removeIndent(current, upTo: fence.indent))
                    index += 1
                }
                add(.code(MarkdownCode(language: fence.language, text: body.joined(separator: "\n"), closed: closed)))
                continue
            }
            if let heading = atxHeading(line) {
                index += 1; listIndents = []
                add(.heading(level: heading.0, text: heading.1)); continue
            }
            if isRule(line) {
                index += 1; listIndents = []
                add(.rule); continue
            }
            if let (table, end) = MarkdownTable.parse(lines, at: index) {
                index = end; listIndents = []
                add(.table(table)); continue
            }
            if let image = standaloneImage(line) {
                index += 1
                add(.image(alt: image.0, source: image.1)); continue
            }
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<details") {
                index += 1
                var summary = "", body: [String] = [], depth = 1
                let opening = line.trimmingCharacters(in: .whitespaces)
                if let inline = summaryText(opening) { summary = inline }
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    let lowered = current.lowercased()
                    if lowered.hasPrefix("<details") { depth += 1 }
                    if lowered.hasPrefix("</details>") { depth -= 1; if depth == 0 { index += 1; break } }
                    if summary.isEmpty, body.allSatisfy(isBlank), let text = summaryText(current) { summary = text }
                    else { body.append(lines[index]) }
                    index += 1
                }
                add(.details(summary: summary, body: body.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                continue
            }
            if let footnote = footnoteDefinition(line) {
                index += 1
                var text = footnote.1
                while index < lines.count, !isBlank(lines[index]), indentation(lines[index]) >= 2 {
                    text += "\n" + lines[index].trimmingCharacters(in: .whitespaces); index += 1
                }
                add(.footnote(label: footnote.0, text: text)); continue
            }
            if quoteBody(line) != nil {
                var body: [String] = []
                while index < lines.count, let text = quoteBody(lines[index]) { body.append(text); index += 1 }
                listIndents = []
                if let first = body.first, let kind = calloutKind(first) {
                    let title = first.drop(while: { $0 != "]" }).dropFirst().trimmingCharacters(in: .whitespaces)
                    add(.callout(MarkdownCallout(kind: kind.0, title: title.isEmpty ? nil : title,
                                                 body: body.dropFirst().joined(separator: "\n"))))
                } else {
                    add(.quote(body.joined(separator: "\n")))
                }
                continue
            }
            if let marker = listMarker(line) {
                let indent = indentation(line)
                while let last = listIndents.last, last > indent { listIndents.removeLast() }
                if listIndents.last != indent { listIndents.append(indent) }
                var item = MarkdownListItem(depth: listIndents.count - 1, marker: marker.marker, text: marker.text)
                if let checkbox = item.text.range(of: #"^\[[ xX]\](\s+|$)"#, options: .regularExpression) {
                    item.checked = item.text[item.text.index(after: item.text.startIndex)] != " "
                    item.text = String(item.text[checkbox.upperBound...])
                }
                index += 1
                // Continuation: indented lines, lazy lines, or indented paragraphs after one blank line.
                while index < lines.count {
                    let next = lines[index]
                    if isBlank(next) {
                        guard index + 1 < lines.count, !isBlank(lines[index + 1]),
                              indentation(lines[index + 1]) >= marker.contentIndent,
                              listMarker(lines[index + 1]) == nil, fenceOpening(lines[index + 1]) == nil else { break }
                        item.text += "\n\n" + lines[index + 1].trimmingCharacters(in: .whitespaces)
                        index += 2; continue
                    }
                    if listMarker(next) != nil || fenceOpening(next) != nil || startsBlock(next) { break }
                    if indentation(next) < marker.contentIndent, MarkdownTable.parse(lines, at: index) != nil { break }
                    item.text += "\n" + next.trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                add(.listItem(item)); continue
            }
            listIndents = []
            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if isBlank(next) || startsBlock(next) || listMarker(next) != nil || fenceOpening(next) != nil
                    || MarkdownTable.parse(lines, at: index) != nil { break }
                // Setext headings: a paragraph underlined with === or ---.
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if indentation(next) < 4, !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                    index += 1
                    add(.heading(level: trimmed.first == "=" ? 1 : 2, text: paragraph.map(trimLeading).joined(separator: " ")))
                    paragraph = []
                    break
                }
                paragraph.append(next); index += 1
            }
            if !paragraph.isEmpty { add(.paragraph(paragraph.map(trimLeading).joined(separator: "\n"))) }
        }
        return result
    }

    /// Markdown source of the section a heading opens: up to the next heading of the same or higher level.
    public static func section(of nodes: [MarkdownNode], at index: Int, source: String) -> String {
        section(of: nodes, at: index, lines: lines(source))
    }

    public static func lines(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Same as `section(of:at:source:)` with the source already split, for documents with many headings.
    public static func section(of nodes: [MarkdownNode], at index: Int, lines: [String]) -> String {
        guard nodes.indices.contains(index), case .heading(let level, _) = nodes[index].block else { return "" }
        var end = nodes.count
        for next in nodes.indices where next > index {
            if case .heading(let other, _) = nodes[next].block, other <= level { end = next; break }
        }
        let range = nodes[index].lines.lowerBound..<(end < nodes.count ? nodes[end].lines.lowerBound : lines.count)
        return lines[range].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `---` front matter with `key: value` lines; lists (`- item` or `[a, b]`) become several values.
    private static func frontMatter(_ lines: [String]) -> ([MarkdownProperty], Int)? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", lines.count > 2 else { return nil }
        guard let close = lines.indices.dropFirst().prefix(300).first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }), close > 1 else { return nil }
        var properties: [MarkdownProperty] = []
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), !properties.isEmpty, line.first == " " || line.first == "-" {
                properties[properties.count - 1].values.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":"), indentation(line) == 0 else {
                // Continuation of a folded value.
                if !properties.isEmpty, indentation(line) > 0 {
                    let last = properties.count - 1
                    if properties[last].values.isEmpty { properties[last].values = [trimmed] }
                    else { properties[last].values[properties[last].values.count - 1] += " " + trimmed }
                    continue
                }
                return nil // Not YAML: leave the dashes to the normal parser.
            }
            let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") || name.count < 40 else { return nil }
            var values: [String] = []
            if value.hasPrefix("["), value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
                values = value.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
            } else if !value.isEmpty, value != "|", value != ">", value != "|-", value != ">-" {
                values = [unquote(value)]
            }
            properties.append(MarkdownProperty(name: name, values: values))
        }
        return properties.isEmpty ? nil : (properties, close + 1)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: Line classification

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func indentation(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func trimLeading(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func removeIndent(_ line: String, upTo count: Int) -> String {
        var removed = 0
        return String(line.drop(while: { character in
            guard character == " ", removed < count else { return false }
            removed += 1; return true
        }))
    }

    private static func startsBlock(_ line: String) -> Bool {
        atxHeading(line) != nil || isRule(line) || quoteBody(line) != nil || standaloneImage(line) != nil
            || line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<details") || footnoteDefinition(line) != nil
    }

    private struct Fence { let character: Character; let count: Int; let indent: Int; let language: String? }

    private static func fenceOpening(_ line: String) -> Fence? {
        let indent = indentation(line)
        let trimmed = trimLeading(line)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "{" }).first.map(String.init)
        return Fence(character: first, count: count, indent: indent, language: language?.isEmpty == false ? language : nil)
    }

    private static func isFenceClose(_ line: String, fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix(while: { $0 == fence.character }).count
        return count >= fence.count && trimmed.dropFirst(count).isEmpty
    }

    private static func atxHeading(_ line: String) -> (Int, String)? {
        guard indentation(line) < 4 else { return nil }
        let trimmed = trimLeading(line)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes.
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indentation(line) < 4 else { return false }
        let characters = line.filter { $0 != " " && $0 != "\t" }
        guard let first = characters.first, "-*_".contains(first), characters.count >= 3 else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func quoteBody(_ line: String) -> String? {
        guard indentation(line) <= 3 else { return nil }
        let trimmed = trimLeading(line)
        guard trimmed.first == ">" else { return nil }
        var body = trimmed.dropFirst()
        if body.first == " " || body.first == "\t" { body = body.dropFirst() }
        return String(body)
    }

    private static func calloutKind(_ line: String) -> (MarkdownCallout.Kind, String)? {
        guard let match = line.range(of: #"^\[![A-Za-z]+\]"#, options: .regularExpression) else { return nil }
        let name = line[match].dropFirst(2).dropLast().lowercased()
        return MarkdownCallout.Kind(rawValue: name).map { ($0, name) }
    }

    private struct ListMarker { let marker: MarkdownListItem.Marker; let text: String; let contentIndent: Int }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(line)
        let trimmed = trimLeading(line)
        guard !isRule(line) else { return nil }
        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            return ListMarker(marker: .bullet, text: rest.trimmingCharacters(in: .whitespaces), contentIndent: indent + 2)
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return ListMarker(marker: .ordered(number), text: after.trimmingCharacters(in: .whitespaces),
                          contentIndent: indent + digits.count + 2)
    }

    private static func standaloneImage(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let altEnd = trimmed.range(of: "]("), !trimmed[altEnd.upperBound...].contains("](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        var target = String(trimmed[altEnd.upperBound..<trimmed.index(before: trimmed.endIndex)]).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), let close = target.firstIndex(of: ">") {
            target = String(target[target.index(after: target.startIndex)..<close])
        } else if let space = target.firstIndex(of: " ") {
            target = String(target[..<space]) // Drop an optional "title".
        }
        return target.isEmpty ? nil : (alt, target)
    }

    private static func summaryText(_ line: String) -> String? {
        guard let open = line.range(of: "<summary>", options: .caseInsensitive),
              let close = line.range(of: "</summary>", options: .caseInsensitive), open.upperBound <= close.lowerBound else { return nil }
        return line[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    private static func footnoteDefinition(_ line: String) -> (String, String)? {
        guard let match = line.range(of: #"^\[\^[^\]\s]+\]:"#, options: .regularExpression) else { return nil }
        let label = String(line[match].dropFirst(2).dropLast(2))
        return (label, line[match.upperBound...].trimmingCharacters(in: .whitespaces))
    }
}
