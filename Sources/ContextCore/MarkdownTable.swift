import Foundation

/// Pipe tables are recognized only after a matching delimiter row. Incomplete
/// streaming prefixes and ordinary prose remain text until that row arrives.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public enum Block: Equatable, Sendable {
        case text(String)
        case table(MarkdownTable)
    }
    public let rows: [[String]]
    public let alignments: [Alignment]
    public init(rows: [[String]], alignments: [Alignment]) { self.rows = rows; self.alignments = alignments }

    public static func blocks(in source: String) -> [Block] {
        let lines = source.components(separatedBy: "\n")
        var result: [Block] = [], pending: [String] = []
        var index = 0
        var fence: (character: Character, count: Int)?
        func flush() {
            if !pending.isEmpty { result.append(.text(pending.joined(separator: "\n"))); pending = [] }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "~" || first == "`" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let current = fence {
                        if first == current.character, count >= current.count,
                           trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (first, count) }
                    pending.append(line); index += 1; continue
                }
            }
            guard fence == nil, let (table, end) = parse(lines, at: index) else {
                pending.append(line); index += 1; continue
            }
            // Retain the newline before a table so the preceding text has its own paragraph.
            if !pending.isEmpty { pending.append("") }
            flush()
            result.append(.table(table))
            index = end
        }
        flush()
        return result
    }

    /// A table starting at `index` and the index of the first line after it.
    public static func parse(_ lines: [String], at index: Int) -> (MarkdownTable, Int)? {
        guard index + 1 < lines.count, let header = cells(lines[index]), let delimiters = cells(lines[index + 1]),
              header.count == delimiters.count,
              delimiters.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        let alignments: [Alignment] = delimiters.map {
            $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left
        }
        var rows = [header]
        var index = index + 2
        while index < lines.count, let row = cells(lines[index]),
              !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            rows.append(Array((row + Array(repeating: "", count: header.count)).prefix(header.count)))
            index += 1
        }
        return (MarkdownTable(rows: rows, alignments: alignments), index)
    }

    /// Default-aligned columns whose body cells are all numbers read better right-aligned.
    public var displayAlignments: [Alignment] {
        alignments.enumerated().map { column, alignment in
            guard alignment == .left, rows.count > 1 else { return alignment }
            let values = rows.dropFirst().map { $0[column].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let numeric = !values.isEmpty && values.allSatisfy {
                $0.range(of: #"^[-+−≈~]?[$€₽£]?\d[\d\s.,]*(%|[kKMB]|[$€₽£])?$"#, options: .regularExpression) != nil
            }
            return numeric ? .right : alignment
        }
    }

    /// Markdown pipe table with normalized cells.
    public var markdown: String {
        guard let header = rows.first else { return "" }
        let delimiter = alignments.map { alignment -> String in
            switch alignment { case .left: "---"; case .center: ":---:"; case .right: "---:" }
        }
        return ([header, delimiter] + rows.dropFirst()).map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
    }

    /// Tab-separated values for spreadsheets. Inline Markdown is reduced to its text.
    public var tabSeparated: String {
        rows.map { row in
            row.map { cell in
                var value = cell.replacingOccurrences(of: "\\|", with: "|")
                value = value.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                for mark in ["**", "__", "`", "~~"] { value = value.replacingOccurrences(of: mark, with: "") }
                return value.replacingOccurrences(of: "\t", with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    // MARK: Drawn tables

    /// A table drawn with characters that fills a whole code block: box drawing (`┌─┬─┐`, sqlite `.mode box`),
    /// ASCII grids (`+---+`, MySQL, sqlite `.mode table`), psql output and dash-ruled columns (sqlite `.mode column`).
    /// Diagrams, text around the grid and ragged rows return nil, so the block stays monospaced text.
    public static func drawn(_ text: String) -> MarkdownTable? {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            while let last = line.last, last.isWhitespace { line.removeLast() }
            return line
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        // psql prints a row count after the table.
        if let last = lines.last, last.range(of: #"^\s*\(\d+ rows?\)$"#, options: .regularExpression) != nil {
            lines.removeLast()
            while lines.last?.isEmpty == true { lines.removeLast() }
        }
        guard lines.count >= 3 else { return nil }
        let rows = grid(lines) ?? psql(lines) ?? ruled(lines)
        guard let rows, rows.count >= 2, let width = rows.first?.count, width >= 2,
              rows.allSatisfy({ $0.count == width }) else { return nil }
        let escaped = rows.map { $0.map { $0.replacingOccurrences(of: "|", with: "\\|") } }
        return MarkdownTable(rows: escaped, alignments: Array(repeating: .left, count: width))
    }

    private static let verticals: Set<Character> = ["│", "┃", "║", "|"]
    private static let rules: Set<Character> = Set("─━═-=+:┌┐└┘├┤┬┴┼╭╮╯╰┏┓┗┛┣┫┳┻╋╔╗╚╝╠╣╦╩╬╒╕╘╛╞╡╤╧╪╓╖╙╜╟╢╥╨╫┍┑┕┙┝┥┯┷┿┎┒┖┚┠┨┰┸╂")

    /// Bordered grid: every line is a rule or a row framed by vertical bars. Rows between two rules
    /// are one record whose wrapped lines join; without rules between them every line is a record.
    /// Rules are unbroken, so boxes standing side by side in a diagram do not pass for a table.
    private static func grid(_ lines: [String]) -> [[String]]? {
        var segments: [[[String]]] = [], current: [[String]] = [], ruleCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, let last = trimmed.last else { return nil }
            if trimmed.allSatisfy({ rules.contains($0) }), trimmed.contains(where: { "─━═-=".contains($0) }) {
                // ASCII rules are framed by corners; a bare dash line is not a grid.
                if first == "-" || first == "=" { return nil }
                ruleCount += 1
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            guard verticals.contains(first), verticals.contains(last), trimmed.count >= 2 else { return nil }
            current.append(trimmed.dropFirst().dropLast().split(separator: first == "|" ? "|" : first, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if !current.isEmpty { segments.append(current) }
        guard ruleCount >= 2, let header = segments.first else { return nil }
        let body = segments.dropFirst()
        if segments.count == 1 { return header }
        var rows = [merge(header)]
        if body.count == 1 { rows += body[body.startIndex] } else { rows += body.map(merge) }
        return rows
    }

    /// Joins the wrapped lines of one record cell by cell.
    private static func merge(_ lines: [[String]]) -> [String] {
        guard let width = lines.first?.count, lines.allSatisfy({ $0.count == width }) else { return lines.first ?? [] }
        return (0..<width).map { column in lines.map { $0[column] }.filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// psql aligned output: a header, a `----+----` rule and rows split by bars.
    private static func psql(_ lines: [String]) -> [[String]]? {
        guard lines[1].trimmingCharacters(in: .whitespaces).range(of: #"^-+(\+-+)+$"#, options: .regularExpression) != nil else { return nil }
        let rows = ([lines[0]] + lines.dropFirst(2)).map {
            $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return rows
    }

    /// Columns under a dash ruler (`--  -----`): each cell is the text under its run of dashes.
    private static func ruled(_ lines: [String]) -> [[String]]? {
        let ruler = Array(lines[1])
        guard ruler.allSatisfy({ $0 == "-" || $0 == " " }), ruler.first == "-" else { return nil }
        var spans: [Range<Int>] = [], start: Int?
        for (index, character) in ruler.enumerated() {
            if character == "-", start == nil { start = index }
            if character == " ", let begin = start { spans.append(begin..<index); start = nil }
        }
        if let start { spans.append(start..<ruler.count) }
        guard spans.count >= 2 else { return nil }
        // A cell reaches to the start of the next column, so values longer than the ruler stay whole.
        var rows: [[String]] = []
        for line in [lines[0]] + lines.dropFirst(2) {
            let characters = Array(line)
            var row: [String] = []
            for (index, span) in spans.enumerated() {
                let end = index + 1 < spans.count ? spans[index + 1].lowerBound : characters.count
                guard span.lowerBound <= characters.count else { row.append(""); continue }
                if span.lowerBound > 0, span.lowerBound < characters.count, characters[span.lowerBound - 1] != " " { return nil }
                row.append(String(characters[span.lowerBound..<max(span.lowerBound, min(end, characters.count))])
                    .trimmingCharacters(in: .whitespaces))
            }
            rows.append(row)
        }
        return rows
    }

    private static func cells(_ line: String) -> [String]? {
        guard !line.hasPrefix("    "), !line.hasPrefix("\t") else { return nil }
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = [], cell = "", index = 0, hasPipe = false
        var codeRun = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                cell.append(character); cell.append(characters[index + 1]); index += 2; continue
            }
            if character == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                if codeRun == count { codeRun = 0 }
                else if codeRun == 0,
                        String(characters[index...]).contains(String(repeating: "`", count: count)) { codeRun = count }
                cell += String(repeating: "`", count: count)
                continue
            }
            if character == "|", codeRun == 0 {
                cells.append(cell); cell = ""; hasPipe = true
            } else { cell.append(character) }
            index += 1
        }
        guard hasPipe else { return nil }
        cells.append(cell)
        if characters.first == "|" { cells.removeFirst() }
        if cells.last == "", characters.last == "|" { cells.removeLast() }
        return cells.isEmpty ? nil : cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
