import Foundation
import AgentContract

/// Tool bodies are kept only while they are useful (performance fixes 2026-10-31, round 4). While a chat is active every
/// activity body is capped at `capBytes` (head, omitted-bytes marker, tail) when it is recorded; once the chat is archived
/// the body is reduced to its one-line headline plus a metadata line, which keeps later analysis (time per tool, audit of
/// targets, repeated failures, routine mining) possible without the bodies. Both steps are pure functions over
/// `TranscriptItem`; user and assistant text is never touched.
public enum ActivityRetention {
    public static let headBytes = 12 * 1024
    public static let tailBytes = 4 * 1024
    /// Bodies up to this UTF-8 size are stored as they are.
    public static let capBytes = headBytes + tailBytes
    /// First token of the metadata line; `headline` and `parsedCall` recognize reduced bodies by it.
    public static let metadataPrefix = "#activity"
    /// Input fields that name what a Claude tool call acts on, in order of preference.
    static let headlineKeys = ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "expression"]

    /// Kinds whose bodies are capped and reduced: tool calls and results, and thinking (`ActivityDetail.thinkingKind`).
    static func isActivity(_ kind: String) -> Bool { kind == "activity" || kind == "tool" || kind == ActivityDetail.thinkingKind }

    // MARK: Cap (record time)

    /// Caps an activity body: the first `headBytes`, a marker line and the last `tailBytes`, with the original size in
    /// `fullLength`. Other kinds, short bodies and already capped or reduced items pass through unchanged.
    public static func cap(_ item: TranscriptItem) -> TranscriptItem {
        guard isActivity(item.kind), item.fullLength == nil, item.reduced != true, item.text.utf8.count > capBytes else { return item }
        var copy = item
        copy.fullLength = item.text.utf8.count
        copy.text = cappedCall(item.text) ?? cappedText(item.text, head: headBytes, tail: tailBytes)
        return copy
    }

    static func marker(omitted: Int) -> String {
        L10n.text("… пропущено \(omitted) байт …", "… \(omitted) bytes omitted …")
    }

    /// Head, marker line and tail, cut on Unicode scalar boundaries.
    static func cappedText(_ text: String, head headLimit: Int, tail tailLimit: Int) -> String {
        let head = prefix(text, bytes: headLimit), tail = suffix(text, bytes: tailLimit)
        return head + "\n" + marker(omitted: text.utf8.count - head.utf8.count - tail.utf8.count) + "\n" + tail
    }

    /// A Claude call ("Name" then its JSON input) keeps its JSON structure: only long string values are cut, so the short
    /// telling fields (command, file_path, ...) and the headline survive. Nil when the text is not such a call or the
    /// result would still exceed the cap (several long values); the caller then cuts the plain text.
    static func cappedCall(_ text: String) -> String? {
        guard let call = parsedCall(text) else { return nil }
        var input = call.input, changed = false
        for (key, value) in input {
            guard let string = value as? String, string.utf8.count > headBytes else { continue }
            input[key] = cappedText(string, head: headBytes / 2, tail: tailBytes / 2); changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              data.count + call.name.utf8.count + 1 <= capBytes else { return nil }
        return call.name + "\n" + String(decoding: data, as: UTF8.self)
    }

    static func prefix(_ text: String, bytes: Int) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.startIndex, used = 0
        while end < scalars.endIndex {
            let width = scalars[end].utf8.count
            if used + width > bytes { break }
            used += width; scalars.formIndex(after: &end)
        }
        return String(scalars[..<end])
    }

    static func suffix(_ text: String, bytes: Int) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.endIndex, used = 0
        while start > scalars.startIndex {
            let previous = scalars.index(before: start)
            let width = scalars[previous].utf8.count
            if used + width > bytes { break }
            used += width; start = previous
        }
        return String(scalars[start...])
    }

    // MARK: Headline

    /// One readable line for an activity: a Claude call shows its tool name and most telling input field instead of raw
    /// JSON; a reduced body its stored headline; anything else its text joined into one line. Works on capped bodies,
    /// including a plain cut that broke the JSON, as long as the field is within the head.
    public static func headline(_ text: String, limit: Int = 120) -> String {
        var line = text
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1].hasPrefix(metadataPrefix) {
            line = parts[0]
        } else if parts.count == 2, !parts[0].contains(" ") {
            if let input = parsedObject(parts[1]) {
                let value = headlineKeys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
                line = value.map { parts[0] + " · " + $0 } ?? parts[0]
            } else if parts[1].drop(while: \.isWhitespace).first == "{", let value = scannedValue(in: parts[1]) {
                line = parts[0] + " · " + value
            }
        }
        line = line.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// A Claude tool call is recorded as its name on the first line and the JSON object of its input after it.
    static func parsedCall(_ text: String) -> (name: String, input: [String: Any])? {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].contains(" "), let input = parsedObject(parts[1]) else { return nil }
        return (parts[0], input)
    }

    private static func parsedObject(_ json: String) -> [String: Any]? {
        guard json.drop(while: \.isWhitespace).first == "{", let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !object.isEmpty else { return nil }
        return object
    }

    /// The first telling field of a JSON object whose end was cut off: `"key" : "value"` read up to the closing quote
    /// or the cut, unescaped.
    static func scannedValue(in json: String, keys: [String] = headlineKeys) -> String? {
        for key in keys {
            guard let range = json.range(of: "\"\(key)\"\\s*:\\s*\"", options: .regularExpression) else { continue }
            var value = "", escaped = false, closed = false
            for character in json[range.upperBound...] {
                if escaped { value.append(character == "n" ? "\n" : character == "t" ? "\t" : character); escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { closed = true; break }
                else { value.append(character) }
                if value.utf8.count > 400 { break }
            }
            if !value.isEmpty { return value }
            if !closed { return nil }
        }
        return nil
    }

    // MARK: Reduce (archive time)

    /// Reduces every activity body to its headline and a metadata line. User and assistant text, item ids, order and
    /// count are unchanged, so the transcript's "Actions · N" rows and the archive summary source keep working.
    /// Reduced items pass through, so the function is idempotent; `fullLength` keeps the size before capping.
    public static func reduce(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard !isReduced(items) else { return items }
        var names: [String: String] = [:], sizes: [String: Int] = [:]
        for item in items where isActivity(item.kind) {
            sizes[item.id] = item.fullLength ?? item.text.utf8.count
            if item.reduced != true, let call = parsedCall(item.text) { names[item.id] = call.name } else if let tool = item.tool { names[item.id] = tool }
        }
        return items.map { item in
            guard isActivity(item.kind), item.reduced != true else { return item }
            var copy = item
            copy.reduced = true
            copy.fullLength = sizes[item.id]
            copy.text = headline(item.text) + "\n" + metadata(item, names: names, sizes: sizes)
            return copy
        }
    }

    public static func reduce(_ turns: [AgentHistoryTurn]) -> [AgentHistoryTurn] {
        // Reduced across the whole history so a call and its result pair up even across turn records.
        var remaining = reduce(turns.flatMap(\.items))[...]
        return turns.map { turn in
            let items = Array(remaining.prefix(turn.items.count)); remaining = remaining.dropFirst(turn.items.count)
            return turn.replacingItems(items)
        }
    }

    public static func reduce(_ snapshot: AgentTranscriptSnapshot) throws -> AgentTranscriptSnapshot {
        guard !isReduced(snapshot) else { return snapshot }
        return try LocalHistory.snapshot(conversation: snapshot.conversation, source: snapshot.source, items: reduce(LocalHistory.items(snapshot)),
                                         completeness: snapshot.completeness, capturedAt: snapshot.capturedAt)
    }

    /// True when no activity still carries a body (also for histories without activities).
    public static func isReduced(_ items: [TranscriptItem]) -> Bool {
        !items.contains { isActivity($0.kind) && $0.reduced != true }
    }
    /// Kinds without a contract case (compaction dividers, refusal notices) are stored as `.activity`; their presentation
    /// names the real kind, so they do not keep a reduced transcript looking unreduced.
    public static func isReduced(_ snapshot: AgentTranscriptSnapshot) -> Bool {
        // Kinds without their own snapshot case (thinking, compaction, refusal) are stored as `.activity`; the presentation names them.
        !snapshot.items.contains { isActivity($0.presentation?.kind ?? $0.kind.rawValue) && $0.presentation?.reduced != true }
    }

    /// Metadata line of a reduced body (its second line): `#activity` followed by space-separated `key=value` fields in
    /// this order, each present only when known. Quoted values are JSON string literals.
    ///   kind=thinking    a thinking item (Claude thinking, Codex reasoning); its first line keeps the start of the text
    ///   tool=<name>      tool name: the first line of a Claude call, the `tool` field (Codex `commandExecution`), or
    ///                    that of the call paired with a result (`<id>:result`)
    ///   target=<"...">   the call's most telling input field (description, command, file_path, path, pattern, url,
    ///                    query, prompt or expression), at most 300 characters
    ///   input=<bytes>    UTF-8 size of the call body before capping; on a call line
    ///   output=<bytes>   UTF-8 size of the paired result body before capping; on the call line and on the result line
    ///   size=<bytes>     body size of an activity that is neither a Claude call nor a result (Codex commands, status
    ///                    notes, thinking)
    ///   exit=<code>      exit status of a result: the recorded `exitCode`, else one named near the end of the text
    ///                    ("Exit code 1", "exited with 2", "exit status: 3")
    ///   error=<"...">    last two non-empty lines of a failed result (exit status other than 0, `failed`, or an error
    ///                    marker at the start), each at most 200 characters, joined with " | "
    ///   seconds=<n.n>    duration of a thinking block or a command, when it was known
    static func metadata(_ item: TranscriptItem, names: [String: String], sizes: [String: Int]) -> String {
        var fields = [metadataPrefix]
        if item.kind == ActivityDetail.thinkingKind { fields.append("kind=" + item.kind) }
        let isResult = item.id.hasSuffix(":result")
        let callID = isResult ? String(item.id.dropLast(":result".count)) : item.id
        let call = isResult ? nil : parsedCall(item.text)
        if let name = call?.name ?? item.tool ?? names[callID] { fields.append("tool=" + name) }
        if let call {
            if let target = headlineKeys.lazy.compactMap({ call.input[$0] as? String }).first(where: { !$0.isEmpty }) {
                fields.append("target=" + quoted(String(target.prefix(300))))
            }
            fields.append("input=\(sizes[item.id] ?? 0)")
            if let output = sizes[item.id + ":result"] { fields.append("output=\(output)") }
        } else if isResult {
            fields.append("output=\(sizes[item.id] ?? 0)")
            let exit = item.exitCode ?? exitStatus(item.text)
            if let exit { fields.append("exit=\(exit)") }
            if exit.map({ $0 != 0 }) ?? (item.failed == true || looksFailed(item.text)) { fields.append("error=" + quoted(lastLines(item.text))) }
        } else {
            fields.append("size=\(sizes[item.id] ?? 0)")
            if item.tool != nil, let output = sizes[item.id + ":result"] { fields.append("output=\(output)") }
        }
        if let seconds = item.seconds, seconds.isFinite, seconds >= 0 { fields.append("seconds=" + String(format: "%.1f", seconds)) }
        return fields.joined(separator: " ")
    }

    static func exitStatus(_ text: String) -> Int? {
        let tail = suffix(text, bytes: 1024)
        guard let range = tail.range(of: #"(?i)\bexit(?:ed)?(?:\s+with)?(?:\s+(?:code|status))?\s*[:=]?\s*(\d{1,3})\b"#, options: .regularExpression),
              let digits = tail[range].range(of: #"\d{1,3}\b"#, options: [.regularExpression, .backwards]) else { return nil }
        return Int(tail[digits])
    }

    static func looksFailed(_ text: String) -> Bool {
        let head = prefix(text, bytes: 1024)
        return head.contains("<tool_use_error>") || head.drop(while: \.isWhitespace).lowercased().hasPrefix("error")
    }

    static func lastLines(_ text: String) -> String {
        suffix(text, bytes: 2048).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(2).map { String($0.prefix(200)) }.joined(separator: " | ")
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
