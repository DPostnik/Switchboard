import Foundation
import ContextCore

/// Native payload decoding stays private to the Codex integration.
enum CodexDecoding {
    static func accountLimits(response: JSONValue, date: Date = Date()) -> AccountLimits {
        let buckets: [LimitBucket]
        let mapped = response["rateLimitsByLimitId"].object
        if mapped.isEmpty {
            let legacy = response["rateLimits"]
            buckets = legacy.object.isEmpty ? [] : [limitBucket(id: legacy["limitId"].string ?? "codex", value: legacy)]
        } else {
            buckets = mapped.keys.sorted().compactMap { id in
                guard let value = mapped[id], !value.object.isEmpty else { return nil }
                return limitBucket(id: id, value: value)
            }
        }
        return AccountLimits(buckets: buckets, ordinaryUsageAllowed: response["ordinaryUsageAllowed"].bool, fetchedAt: date)
    }
    static func limitBucket(id: String, value: JSONValue) -> LimitBucket {
        let name = value["limitName"].string ?? (id == "codex" ? "Codex" : id)
        let windows: [LimitWindow] = ["primary", "secondary"].compactMap { key in
            guard case .object = value[key] else { return nil }
            return limitWindow(id: key, value: value[key])
        }
        return LimitBucket(id: id, name: name, windows: windows)
    }
    static func limitWindow(id: String, value: JSONValue) -> LimitWindow {
        let remainingPercent = value["usedPercent"].int.map { 100 - min(100, max(0, $0)) }
        let durationMinutes = value["windowDurationMins"].int.flatMap { $0 > 0 ? $0 : nil }
        let resetsAt = value["resetsAt"].int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil }
        return LimitWindow(id: id, remainingPercent: remainingPercent, durationMinutes: durationMinutes, resetsAt: resetsAt)
    }
    /// Codex 0.160.0 `TurnError.codexErrorInfo` is the unit variant "usageLimitExceeded" when the account's plan
    /// limit stopped the turn. The error carries no reset time (only prose in `message`); the account limits supply it.
    /// "rateLimitExceeded" is short-term throttling, not an exhausted plan, and is not treated as one.
    static func usageLimitStop(turn: JSONValue) -> AgentUsageLimitStop? {
        guard turn["status"].string != "interrupted", turn["error"]["codexErrorInfo"].string == "usageLimitExceeded" else { return nil }
        return AgentUsageLimitStop(resetsAt: nil)
    }
    /// Why a turn ended: a usage limit, an interrupt, a context window too small for the turn
    /// (`codexErrorInfo` "contextWindowExceeded", as ACP max tokens), any other error as a failure, else the end of the turn.
    static func stopReason(turn: JSONValue, status: AgentExecutionOutcome, usageLimit: Bool) -> AgentStopReason? {
        if usageLimit { return .usageLimit }
        if status == .cancelled { return .cancelled }
        if turn["error"]["codexErrorInfo"].string == "contextWindowExceeded" { return .maxTokens }
        return AgentStopReason.implied(by: status)
    }
    static func tokenCounters(_ raw: JSONValue) -> TokenCounters? {
        guard let input = raw["inputTokens"].int, let cached = raw["cachedInputTokens"].int,
              let output = raw["outputTokens"].int, input >= 0, cached >= 0, cached <= input,
              output >= 0, !input.addingReportingOverflow(output).overflow else { return nil }
        return TokenCounters(input: input, cached: cached, output: output)
    }

    // Codex 0.155.0-alpha.16.4: startedAt/completedAt are Unix seconds; durationMs is milliseconds.
    static func responseTiming(_ turn: JSONValue, fallback: ResponseTiming? = nil) -> ResponseTiming? {
        guard let completedAt = turn["completedAt"].int.map({ Date(timeIntervalSince1970: Double($0)) }) ?? fallback?.completedAt else { return nil }
        let startedAt = turn["startedAt"].int.map { Date(timeIntervalSince1970: Double($0)) } ?? fallback?.startedAt
        let duration = turn["durationMs"].int.flatMap { $0 >= 0 ? Double($0) / 1_000 : nil }
        return ResponseTiming(startedAt: startedAt, completedAt: completedAt,
                    durationSeconds: duration ?? fallback?.durationSeconds, tokens: fallback?.tokens, changes: fallback?.changes)
    }

    /// A native item as a transcript item; calls also carry their structured form (`CodexToolCalls`).
    static func transcriptItem(_ raw: JSONValue) -> TranscriptItem? {
        guard var item = plainItem(raw) else { return nil }
        if item.kind == "activity" { item.toolCall = CodexToolCalls.toolCall(raw) }
        return item
    }

    private static func plainItem(_ raw: JSONValue) -> TranscriptItem? {
        guard let id = raw["id"].string, let type = raw["type"].string else { return nil }
        switch type {
        case "userMessage":
            return TranscriptItem(id: id, kind: "user", text: raw["content"].array.compactMap { $0["text"].string }.joined(separator: "\n"))
        case "agentMessage": return TranscriptItem(id: id, kind: "assistant", text: raw["text"].string ?? "", phase: raw["phase"].string)
        case "contextCompaction": return TranscriptItem(id: id, kind: "compaction", text: L10n.text("Контекст разговора сжат", "Conversation context compacted"), phase: "completed")
        case "commandExecution":
            var item = TranscriptItem(id: id, kind: "activity", text: raw["command"].string ?? L10n.text("Выполнение команды", "Running command"))
            item.tool = ActivityDetail.codexCommandTool
            return item
        case "reasoning":
            let text = reasoningText(summary: raw["summary"].array.compactMap(\.string), content: raw["content"].array.compactMap(\.string))
            return text.isEmpty ? nil : TranscriptItem(id: id, kind: ActivityDetail.thinkingKind, text: text)
        case "fileChange": return TranscriptItem(id: id, kind: "activity", text: L10n.text("Изменение файлов · \(raw["status"].string ?? "")", "File changes · \(raw["status"].string ?? "")"))
        case "mcpToolCall": return TranscriptItem(id: id, kind: "activity", text: raw["tool"].string ?? L10n.text("Вызов инструмента", "Calling tool"))
        case "dynamicToolCall": return TranscriptItem(id: id, kind: "activity", text: raw["tool"].string ?? L10n.text("Вызов инструмента", "Calling tool"))
        case "webSearch":
            let query = raw["query"].string ?? raw["action"]["query"].string ?? raw["action"]["url"].string ?? ""
            return TranscriptItem(id: id, kind: "activity", text: L10n.text("Поиск в интернете · \(query)", "Web search · \(query)"))
        case "imageView":
            return TranscriptItem(id: id, kind: "activity", text: L10n.text("Просмотр изображения · \(raw["path"].string ?? "")", "View image · \(raw["path"].string ?? "")"))
        default: return nil
        }
    }

    /// A native item as transcript items: `transcriptItem` plus, for a finished command, its result item.
    static func transcriptItems(_ raw: JSONValue) -> [TranscriptItem] {
        guard let item = transcriptItem(raw) else { return [] }
        return [item] + (commandResult(raw).map { [$0] } ?? [])
    }

    /// Codex 0.160.0 `ThreadItem` "commandExecution" once finished (`status` "completed", "failed" or "declined"): its
    /// `aggregatedOutput` (stdout and stderr), `exitCode` and `durationMs` as the result item `<id>:result`, paired with
    /// the call item like a Claude tool result. Nil while it runs or when its status is unknown.
    static func commandResult(_ raw: JSONValue) -> TranscriptItem? {
        guard raw["type"].string == "commandExecution", let id = raw["id"].string else { return nil }
        let status = raw["status"].string
        var item = TranscriptItem(id: ActivityDetail.resultID(of: id), kind: "activity", text: raw["aggregatedOutput"].string ?? "")
        switch status {
        case "declined":
            if item.text.isEmpty { item.text = L10n.text("Команда отклонена", "Command declined") }
            item.failed = true
        case "completed", "failed":
            if let code = raw["exitCode"].int { item.exitCode = code } else if status == "failed" { item.failed = true }
        default: return nil
        }
        item.seconds = raw["durationMs"].int.flatMap { $0 >= 0 ? Double($0) / 1_000 : nil }
        return item
    }

    /// Reasoning as shown: the summary parts, or the raw reasoning parts when there is no summary; blank parts dropped.
    static func reasoningText(summary: [String], content: [String]) -> String {
        func joined(_ parts: [String]) -> String {
            parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let text = joined(summary)
        return text.isEmpty ? joined(content) : text
    }

    static func usageSnapshot(event: JSONValue, date: Date = Date()) -> UsageSnapshot {
        let usage = event["tokenUsage"]
        let last = usage["last"]["totalTokens"].int; let window = usage["modelContextWindow"].int
        let input = usage["total"]["inputTokens"].int; let cached = usage["total"]["cachedInputTokens"].int
        let output = usage["total"]["outputTokens"].int
        return UsageSnapshot(last: last, window: window, input: input, cached: cached, output: output, measuredAt: date)
    }

    /// Bound each model input, retaining every user/assistant text segment. Tool details are explicitly limited.
    static func summarySource(thread: JSONValue) throws -> SummarySource {
        var turnDates: [String: Double] = [:]
        guard case .array(let turns) = thread["turns"] else {
            throw ClientFailure(L10n.text("История чата недоступна", "Conversation history is unavailable"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SummarySource.hash(try encoder.encode(thread["turns"]))
        var fragments: [SummarySource.Fragment] = [], seen: Set<String> = []
        var omittedDetails = false
        for turn in turns {
            guard let turnID = turn["id"].string, turn["status"].string != "inProgress",
                  case .array(let items) = turn["items"] else {
                throw ClientFailure(L10n.text("История содержит незавершённый или неполный запрос", "History contains an active or incomplete turn"))
            }
            if case .number(let date) = turn["completedAt"], date.isFinite { turnDates[turnID] = date }
            for item in items {
                guard let itemID = item["id"].string, let kind = item["type"].string else {
                    throw ClientFailure(L10n.text("Неполный элемент истории", "Incomplete history item"))
                }
                // Reasoning is not needed to infer the user's repeated activities.
                if kind == "reasoning" { continue }
                let text: String
                if kind == "agentMessage" { text = item["text"].string ?? "" }
                else if kind == "userMessage" {
                    text = item["content"].array.map { content in
                        if let text = content["text"].string { return text }
                        omittedDetails = true
                        return "[Non-text input: \(content["type"].string ?? "unknown")]"
                    }.joined(separator: "\n")
                } else {
                    let raw = String(decoding: try encoder.encode(item), as: UTF8.self)
                    text = String(raw.prefix(3000))
                    if raw.count > 3000 { omittedDetails = true }
                }
                let characters = Array(text)
                for offset in stride(from: 0, to: max(1, characters.count), by: 6000) {
                    let reference = "\(turnID)/\(itemID)/\(offset / 6000)"
                    guard seen.insert(reference).inserted else {
                        throw ClientFailure(L10n.text("Повторяющийся идентификатор в истории", "Duplicate history identifier"))
                    }
                    fragments.append(SummarySource.Fragment(reference: reference, kind: kind,
                        text: String(characters[offset..<min(offset + 6000, characters.count)])))
                }
            }
        }
        return try SummarySource(digest: digest, fragments: fragments, turnDates: turnDates, omittedDetails: omittedDetails)
    }
}
