import Foundation
import ContextCore

/// Collects the main turn's thinking from Claude's stream into one "thinking" item per message (`thinking:<message id>`).
/// Claude Code 2.1.x streams a block as `content_block_start` (`content_block.type` "thinking"), `content_block_delta`
/// events with `delta.type` "thinking_delta" (`delta.thinking`) and a `content_block_stop` with the same `index`; the
/// complete `assistant` message then repeats the block as `{"type":"thinking","thinking":…,"signature":…}`. With
/// thinking display omitted the text is empty and only the signature arrives: no item is produced then.
/// Streamed updates are published at most every `interval`; the block's stop and new text in the complete message
/// always publish. Durations are measured here, from the block's start to its stop.
struct ClaudeThinkingCapture {
    static let interval: TimeInterval = 0.25
    private struct Block { var message: String; var index: Int; var started: Date; var separated: Bool }
    let turn: String
    private var block: Block?
    private var lastPublished = Date.distantPast
    private(set) var items: [String: TranscriptItem] = [:]

    init(turn: String) { self.turn = turn }

    static func itemID(message: String) -> String { "thinking:" + message }

    mutating func start(message: String, index: Int, at now: Date) {
        // A second block of the same message continues its item after a blank line.
        let known = !(items[Self.itemID(message: message)]?.text.isEmpty ?? true)
        block = Block(message: message, index: index, started: now, separated: !known)
    }

    /// Appends streamed text; returns the item when an update is due.
    mutating func delta(_ text: String, index: Int, at now: Date) -> TranscriptItem? {
        guard var current = block, current.index == index, !text.isEmpty else { return nil }
        let id = Self.itemID(message: current.message)
        var item = items[id] ?? TranscriptItem(id: id, kind: ActivityDetail.thinkingKind, text: "")
        item.text += (current.separated ? "" : "\n\n") + text
        current.separated = true; block = current
        items[id] = item
        guard now.timeIntervalSince(lastPublished) >= Self.interval else { return nil }
        lastPublished = now
        return item
    }

    /// Ends the block and adds its duration; returns the item when the message has thinking text.
    mutating func stop(index: Int, at now: Date) -> TranscriptItem? {
        guard let current = block, current.index == index else { return nil }
        block = nil
        let id = Self.itemID(message: current.message)
        guard var item = items[id], !item.text.isEmpty else { return nil }
        item.seconds = (item.seconds ?? 0) + max(0, now.timeIntervalSince(current.started))
        items[id] = item; lastPublished = now
        return item
    }

    /// Thinking text of a complete message. The stream normally delivered it already; text it missed is appended.
    mutating func message(_ message: String, thinking: String) -> TranscriptItem? {
        guard !thinking.isEmpty else { return nil }
        let id = Self.itemID(message: message)
        var item = items[id] ?? TranscriptItem(id: id, kind: ActivityDetail.thinkingKind, text: "")
        guard !item.text.contains(thinking) else { return nil }
        item.text += (item.text.isEmpty ? "" : "\n\n") + thinking
        items[id] = item
        return item
    }
}
