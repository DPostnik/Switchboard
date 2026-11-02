import Foundation
import AgentContract

/// Shell commands and thinking in the activity history (AUD-007, 2026-11-01): which calls are commands, what they ran,
/// how they ended and how much of their output the transcript shows. Pure functions over `TranscriptItem`; the adapters
/// record the outcome fields (`exitCode`, `failed`, `seconds`, `tool`) in this neutral form (the Claude rules live in
/// `ClaudeAdapter`) and `ActivityRetention` keeps them through capping and archive reduction. Reading stays here because
/// stored transcripts of both agents keep their recorded shapes: a Codex `commandExecution` call, a Claude `Bash` call
/// with JSON input, and results from before the outcome fields existed.
public enum ActivityDetail {
    /// Item kind of Claude thinking and Codex reasoning text.
    public static let thinkingKind = "thinking"
    /// `tool` of a Codex `commandExecution` call item, whose text is the command line.
    public static let codexCommandTool = "commandExecution"
    /// Claude tools that run a shell command; the `command` field of their input is the command line.
    /// Kept for reading stored Claude transcripts.
    static let claudeShellTools = ["Bash", "PowerShell"]
    static let resultSuffix = ":result"
    /// The transcript shows at most the last `outputLineLimit` lines within `outputByteLimit` of a command's output.
    public static let outputLineLimit = 200
    public static let outputByteLimit = 32 * 1024

    public static func resultID(of callID: String) -> String { callID + resultSuffix }

    /// True for a Codex command, a Claude shell call ("Bash" and its JSON input) or such a call reduced after archiving.
    /// Only prefix checks: the transcript asks this for every activity on every grouping pass.
    public static func isShellCall(_ item: TranscriptItem) -> Bool {
        guard item.kind == "activity", !item.id.hasSuffix(resultSuffix) else { return false }
        if item.tool == codexCommandTool { return true }
        guard let newline = item.text.firstIndex(of: "\n") else { return false }
        let first = item.text[..<newline]
        if item.reduced == true {
            // "Bash · <command>" then "#activity tool=Bash …".
            let metadata = item.text[item.text.index(after: newline)...]
            return claudeShellTools.contains { tool in
                let field = ActivityRetention.metadataPrefix + " tool=" + tool
                return metadata == field || metadata.hasPrefix(field + " ")
            }
        }
        return claudeShellTools.contains { first == $0 }
    }

    /// The command line of a shell call: Codex keeps it as the text, a Claude call in its input's `command` field
    /// (read from a capped body too), a reduced call in its headline.
    public static func command(_ call: TranscriptItem) -> String {
        let lines = call.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if call.reduced == true {
            let headline = lines.first ?? ""
            for tool in claudeShellTools where headline.hasPrefix(tool + " · ") { return String(headline.dropFirst(tool.count + 3)) }
            return headline
        }
        if call.tool == codexCommandTool { return call.text }
        if let input = ActivityRetention.parsedCall(call.text)?.input, let command = input["command"] as? String { return command }
        if lines.count == 2, let command = ActivityRetention.scannedValue(in: lines[1], keys: ["command"]) { return command }
        return lines.count == 2 ? lines[1] : call.text
    }

    /// One line for a row: the first non-empty line, cut at `limit` characters; "…" marks anything left out.
    public static func oneLine(_ text: String, limit: Int = 160) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        if first.count > limit { return String(first.prefix(limit - 1)) + "…" }
        return lines.count > 1 ? first + " …" : first
    }

    // MARK: Outcome

    /// How a shell command ended, as the transcript badge shows it.
    public enum Outcome: Equatable, Sendable {
        case succeeded
        case exit(Int)
        /// Finished unsuccessfully without an exit status.
        case failed
    }

    /// The outcome recorded on a result item; for results recorded before the fields existed, a leading Claude
    /// "Exit code N" line or the `exit=` field of a reduced body. Nil while running or when unknown.
    public static func outcome(_ result: TranscriptItem?) -> Outcome? {
        guard let result else { return nil }
        if let code = result.exitCode { return code == 0 ? .succeeded : .exit(code) }
        if result.failed == true { return .failed }
        if result.reduced == true, let range = result.text.range(of: #"\sexit=(-?\d+)\b"#, options: .regularExpression),
           let code = Int(result.text[range].dropFirst(" exit=".count)) {
            return code == 0 ? .succeeded : .exit(code)
        }
        if let code = leadingExitCode(result.text) { return code == 0 ? .succeeded : .exit(code) }
        return nil
    }

    /// Claude's Bash result reports a non-zero exit as an error whose text starts with "Exit code N"
    /// (Claude Code 2.1.x; a clean run is not an error and names no code). Also read from stored results.
    public static func leadingExitCode(_ text: String) -> Int? {
        guard text.hasPrefix("Exit code ") else { return nil }
        let digits = text.dropFirst("Exit code ".count).prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    public static func label(_ outcome: Outcome) -> String {
        switch outcome {
        case .succeeded: L10n.text("код 0", "exit 0")
        case .exit(let code): L10n.text("код \(code)", "exit \(code)")
        case .failed: L10n.text("ошибка", "error")
        }
    }

    // MARK: Output

    public struct Output: Equatable, Sendable {
        /// The shown text: the last lines of the output within the limits.
        public var text: String
        /// Lines left out above the shown text (0 when it is complete).
        public var omittedLines: Int
        /// The stored body was already capped at record time (`ActivityRetention`); its middle is missing.
        public var capped: Bool
        /// The chat is archived: only the output's first line was kept.
        public var archived: Bool
    }

    /// The part of a result the transcript shows. Claude's leading "Exit code N" line is dropped (the badge shows it).
    public static func output(_ result: TranscriptItem, lineLimit: Int = outputLineLimit, byteLimit: Int = outputByteLimit) -> Output {
        if result.reduced == true {
            let headline = result.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return Output(text: headline, omittedLines: 0, capped: false, archived: true)
        }
        var text = result.text
        if leadingExitCode(text) != nil { text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? "" }
        while text.hasSuffix("\n") { text.removeLast() }
        var lines = text.components(separatedBy: "\n")
        var omitted = 0
        if lines.count > lineLimit { omitted = lines.count - lineLimit; lines = Array(lines.suffix(lineLimit)) }
        var shown = lines.joined(separator: "\n")
        if shown.utf8.count > byteLimit {
            let tail = ActivityRetention.suffix(shown, bytes: byteLimit)
            // Start at a whole line.
            let whole = tail.firstIndex(of: "\n").map { String(tail[tail.index(after: $0)...]) } ?? tail
            omitted += lines.count - whole.components(separatedBy: "\n").count
            shown = whole
        }
        return Output(text: shown, omittedLines: omitted, capped: result.fullLength != nil, archived: false)
    }

    // MARK: Thinking

    /// The thinking text to show: a reduced body keeps its first line only. Empty when there is nothing to show.
    public static func thinkingText(_ item: TranscriptItem) -> String {
        guard item.reduced == true else { return item.text }
        return item.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// "Thinking · 12s", or "Thinking" while the duration is unknown.
    public static func thinkingLabel(seconds: Double?) -> String {
        let title = L10n.text("Размышления", "Thinking")
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 1e7 else { return title }
        return title + " · " + ResponseTiming.duration(max(1, Int(seconds.rounded())))
    }
}
