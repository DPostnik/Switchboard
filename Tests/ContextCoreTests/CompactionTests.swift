import AppKit
import Foundation
import Testing
import ContextCore
import ContextTranscript
@testable import CodexAdapter

private func compactionEvent(_ method: String) throws -> TranscriptItem {
    let raw: JSONValue = .object([
        "method": .string(method),
        "params": .object([
            "threadId": .string("thread"), "turnId": .string("turn"),
            "item": .object(["id": .string("compact"), "type": .string("contextCompaction")])
        ])
    ])
    let event = try #require(CodexEventDecoder.notification(raw))
    #expect(event.session?.nativeID == "thread")
    guard case .item(let item) = event.payload else {
        throw ClientFailure("Expected transcript item")
    }
    return item
}

@Test @MainActor func compactionLifecycleStaysVisibleOutsideCollapsedTools() throws {
    let started = try compactionEvent("item/started")
    #expect(started.kind == "compaction")
    #expect(started.phase == "inProgress")
    #expect(started.turnID == "turn")
    #expect(started.text == L10n.text("Сжатие контекста…", "Compacting conversation…"))
    var items = [TranscriptItem(id: "user", kind: "user", text: "Question"),
                 TranscriptItem(id: "tool", kind: "activity", text: "Tool detail"),
                 TranscriptItem(id: "answer", kind: "assistant", text: "Working")]
    TranscriptItem.merge(started, into: &items)
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.update(items: items, conversationID: "thread", followOutput: true, isWorking: true)
    let range = (view.transcript.string as NSString).range(of: started.text)
    #expect(range.location != NSNotFound)
    let storage = try #require(view.transcript.textStorage)
    #expect(storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil)
    let badgeKey = NSAttributedString.Key("ContextDeskCompactionBadge")
    #expect(storage.attribute(badgeKey, at: range.location, effectiveRange: nil) != nil)
    #expect(storage.attribute(badgeKey, at: NSMaxRange(range), effectiveRange: nil) == nil)
    #expect(storage.attribute(.link, at: range.location, effectiveRange: nil) == nil)
    #expect(view.transcript.string.contains("Working"))

    let completed = try compactionEvent("item/completed")
    #expect(completed.phase == "completed")
    #expect(completed.text == L10n.text("Контекст разговора сжат", "Conversation context compacted"))
    TranscriptItem.merge(completed, into: &items)
    TranscriptItem.merge(completed, into: &items)
    #expect(items.filter { $0.id == "compact" }.count == 1)
    view.update(items: items, conversationID: "thread", followOutput: true, isWorking: true)
    #expect(!view.transcript.string.contains(started.text))
    #expect(view.transcript.string.contains(completed.text))
    view.update(items: items, conversationID: "thread", followOutput: false, isWorking: false)
    #expect(view.transcript.string.contains(completed.text))

    let restored = try JSONDecoder().decode([TranscriptItem].self, from: JSONEncoder().encode(items))
    #expect(restored == items)
    view.update(items: [], conversationID: "other", followOutput: false, isWorking: true)
    #expect(!view.transcript.string.contains(completed.text))
}

@Test @MainActor func unfinishedCompactionDoesNotClaimSuccessAfterStop() throws {
    let started = try compactionEvent("item/started")
    let view = TranscriptScrollView()
    view.update(items: [started], conversationID: "thread", followOutput: false, isWorking: false)
    #expect(!view.transcript.string.contains(started.text))
    #expect(view.transcript.string.contains(L10n.text(
        "Сжатие контекста: завершение не подтверждено", "Context compaction: completion unconfirmed")))
}

@Test @MainActor func refusalShowsAnOrangeBadgeOutsideCollapsedTools() throws {
    let notice = "A safety classifier stopped the response."
    let items = [TranscriptItem(id: "user", kind: "user", text: "Question"),
                 TranscriptItem(id: "tool", kind: "activity", text: "Tool detail"),
                 TranscriptItem(id: "refusal:m1", kind: "refusal", text: notice, phase: "cyber"),
                 TranscriptItem(id: "answer", kind: "assistant", text: "Safe answer")]
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.update(items: items, conversationID: "thread", followOutput: false, isWorking: false)
    let range = (view.transcript.string as NSString).range(of: notice)
    #expect(range.location != NSNotFound)
    let storage = try #require(view.transcript.textStorage)
    #expect(storage.attribute(NSAttributedString.Key("ContextDeskCompactionBadge"), at: range.location, effectiveRange: nil) != nil)
    #expect(storage.attribute(NSAttributedString.Key("ContextDeskBadgeTint"), at: range.location, effectiveRange: nil) as? NSColor == .systemOrange)
    #expect(view.transcript.string.contains("Safe answer"))
}
