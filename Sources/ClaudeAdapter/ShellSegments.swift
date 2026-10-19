import Foundation

/// Splits a shell command line into the commands it runs, the way the shell sees them, for the role's command hook.
/// Text in single quotes and in heredocs with a quoted delimiter (`<<'EOF'`) is data; `$(...)` and backticks run even
/// inside double quotes and unquoted heredocs; the string after `sh -c` / `bash -c` is a command line too.
/// An unfinished construct (an unclosed quote) still reports what was parsed, so nothing is silently skipped.
enum ShellSegments {
    /// Words that run the rest of the line as a command.
    static let wrappers = ["env", "command", "exec", "nohup", "time", "nice", "builtin", "xargs"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "/bin/sh", "/bin/bash", "/bin/zsh"]
    static let maximumDepth = 8

    static func commands(_ text: String, depth: Int = 0) -> [String] {
        guard depth < maximumDepth else { return [] }
        var parser = Parser(chars: Array(text), depth: depth)
        parser.run()
        return parser.result
    }

    /// `bash -c 'cmd'` runs its argument as a command line.
    static func nested(_ segment: String, depth: Int) -> [String] {
        let words = segment.split(separator: " ", maxSplits: 2).map(String.init)
        guard words.count == 3, shells.contains(words[0]), words[1] == "-c" else { return [] }
        var argument = words[2].trimmingCharacters(in: .whitespaces)
        if let first = argument.first, first == "'" || first == "\"", argument.count >= 2, argument.last == first {
            argument = String(argument.dropFirst().dropLast())
        }
        return commands(argument, depth: depth + 1)
    }

    private struct Heredoc { let delimiter: String; let quoted: Bool; let stripTabs: Bool }

    private struct Parser {
        let chars: [Character]
        let depth: Int
        var result: [String] = []
        var current = ""
        var i = 0
        var pending: [Heredoc] = []

        init(chars: [Character], depth: Int) { self.chars = chars; self.depth = depth }

        mutating func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed); result += ShellSegments.nested(trimmed, depth: depth) }
            current = ""
        }
        /// Index of the `)` closing a `$(` whose content starts at `start`, skipping quoted text.
        func closingParen(from start: Int) -> Int? {
            var level = 1, j = start
            var quote: Character?
            while j < chars.count {
                let c = chars[j]
                if let q = quote {
                    if c == q { quote = nil } else if c == "\\" && q == "\"" { j += 1 }
                } else if c == "'" || c == "\"" { quote = c }
                else if c == "\\" { j += 1 }
                else if c == "(" { level += 1 }
                else if c == ")" { level -= 1; if level == 0 { return j } }
                j += 1
            }
            return nil
        }
        func closingBacktick(from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "`" { return j }
                j += 1
            }
            return nil
        }
        func slice(_ from: Int, _ to: Int) -> String {
            let a = max(0, min(from, chars.count)), b = max(a, min(to, chars.count))
            return String(chars[a..<b])
        }
        /// Commands substituted inside text the shell expands (double quotes, unquoted heredocs).
        mutating func substitutions(_ start: Int, _ end: Int) {
            var j = start
            while j < end {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "$", j + 1 < end, chars[j + 1] == "(" {
                    let close = closingParen(from: j + 2) ?? chars.count
                    result += ShellSegments.commands(slice(j + 2, close), depth: depth + 1); j = close + 1; continue
                }
                if chars[j] == "`" {
                    let close = closingBacktick(from: j + 1) ?? chars.count
                    result += ShellSegments.commands(slice(j + 1, close), depth: depth + 1); j = close + 1; continue
                }
                j += 1
            }
        }
        /// Skips heredoc bodies after the line that opened them; quoted delimiters make the body plain data.
        mutating func skipHeredocs() {
            for heredoc in pending {
                let start = i
                var closed = false
                while i < chars.count {
                    let end = chars[i...].firstIndex(of: "\n") ?? chars.count
                    var line = slice(i, end)
                    if heredoc.stripTabs { line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\t")) }
                    if line == heredoc.delimiter {
                        if !heredoc.quoted { substitutions(start, i) }
                        i = min(end + 1, chars.count); closed = true; break
                    }
                    i = end + 1
                }
                if !closed {
                    i = chars.count
                    if !heredoc.quoted { substitutions(start, chars.count) }
                }
            }
            pending.removeAll()
        }

        mutating func run() {
            while i < chars.count {
                let c = chars[i]
                switch c {
                case "\\":
                    current.append(c)
                    if i + 1 < chars.count { current.append(chars[i + 1]) }
                    i += 2
                case "'":
                    let close = chars[(i + 1)...].firstIndex(of: "'") ?? chars.count
                    current += slice(i, close + 1); i = close + 1
                case "\"":
                    var j = i + 1
                    while j < chars.count && chars[j] != "\"" { if chars[j] == "\\" { j += 1 }; j += 1 }
                    substitutions(i + 1, min(j, chars.count))
                    current += slice(i, j + 1); i = j + 1
                case "`":
                    let close = closingBacktick(from: i + 1) ?? chars.count
                    result += ShellSegments.commands(slice(i + 1, close), depth: depth + 1)
                    current += "_"; i = close + 1
                case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                    let close = closingParen(from: i + 2) ?? chars.count
                    result += ShellSegments.commands(slice(i + 2, close), depth: depth + 1)
                    current += "_"; i = close + 1
                case "<" where i + 1 < chars.count && chars[i + 1] == "<" && (i + 2 >= chars.count || chars[i + 2] != "<"):
                    var j = i + 2, strip = false
                    if j < chars.count && chars[j] == "-" { strip = true; j += 1 }
                    while j < chars.count && chars[j] == " " { j += 1 }
                    var word = ""
                    while j < chars.count && !" ;|&<>\n".contains(chars[j]) { word.append(chars[j]); j += 1 }
                    let quoted = word.contains("'") || word.contains("\"") || word.contains("\\")
                    let delimiter = word.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
                    if !delimiter.isEmpty { pending.append(Heredoc(delimiter: delimiter, quoted: quoted, stripTabs: strip)) }
                    current += slice(i, j); i = j
                case "\n":
                    flush(); i += 1
                    skipHeredocs()
                case "|", ";", "&", "(", ")":
                    flush(); i += 1
                default:
                    current.append(c); i += 1
                }
            }
            flush()
        }
    }
}
