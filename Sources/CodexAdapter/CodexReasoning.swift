import Foundation
import AgentContract
import ContextCore

/// Live text of Codex reasoning items. Codex 0.160.0 starts a `reasoning` item with empty `summary` and `content`,
/// streams `item/reasoning/summaryTextDelta` (`itemId`, `delta`, `summaryIndex`) and `item/reasoning/textDelta`
/// (`itemId`, `delta`, `contentIndex`), then `item/completed` carries the final parts, which `CodexDecoding` turns into
/// the thinking item. Streamed text is published as that same item at most every `interval`; the completed item
/// always replaces it. Codex reports no reasoning duration, so these items carry none.
struct CodexReasoningStream {
    static let interval: TimeInterval = 0.25
    private struct Entry {
        var thread: String
        var summary: [Int: String] = [:]
        var content: [Int: String] = [:]
        var lastPublished = Date.distantPast
    }
    private var entries: [String: Entry] = [:]

    mutating func receive(_ raw: JSONValue, at now: Date) -> CodexEvent? {
        let method = raw["method"].string ?? "", p = raw["params"]
        switch method {
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let thread = p["threadId"].string, !thread.isEmpty, let id = p["itemId"].string,
                  let delta = p["delta"].string, !delta.isEmpty else { return nil }
            var entry = entries[id] ?? Entry(thread: thread)
            guard entry.thread == thread else { return nil }
            if method == "item/reasoning/summaryTextDelta" { entry.summary[p["summaryIndex"].int ?? 0, default: ""] += delta }
            else { entry.content[p["contentIndex"].int ?? 0, default: ""] += delta }
            let due = now.timeIntervalSince(entry.lastPublished) >= Self.interval
            if due { entry.lastPublished = now }
            entries[id] = entry
            guard due else { return nil }
            let text = CodexDecoding.reasoningText(summary: entry.summary.sorted { $0.key < $1.key }.map(\.value),
                                                   content: entry.content.sorted { $0.key < $1.key }.map(\.value))
            guard !text.isEmpty else { return nil }
            var item = TranscriptItem(id: id, kind: ActivityDetail.thinkingKind, text: text)
            item.turnID = p["turnId"].string
            return CodexEvent(session: .init(connection: .originalCodex, nativeID: thread), payload: .item(item))
        case "item/completed":
            if let id = p["item"]["id"].string { entries[id] = nil }
        case "turn/completed":
            if let thread = p["threadId"].string { entries = entries.filter { $0.value.thread != thread } }
        case "client/disconnected":
            entries.removeAll()
        default: break
        }
        return nil
    }
}
