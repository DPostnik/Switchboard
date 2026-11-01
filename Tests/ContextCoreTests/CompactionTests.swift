import AppKit
import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ContextTranscript
@testable import CodexAdapter

/// Codex 0.160.0 app-server shapes (`codex app-server generate-ts`): `ThreadItem` `{ "type": "contextCompaction", id }` and
/// `ThreadTokenUsageUpdatedNotification` `{ threadId, turnId, tokenUsage: { total, last, modelContextWindow } }`.
private func compactionEvent(_ method: String, id: String = "compact") throws -> AgentEvent {
    let raw: JSONValue = .object([
        "method": .string(method),
        "params": .object([
            "threadId": .string("thread"), "turnId": .string("turn"),
            "item": .object(["id": .string(id), "type": .string("contextCompaction")])
        ])
    ])
    return try #require(CodexEventDecoder.notification(raw))
}
private func usageEvent(context: Int) throws -> AgentEvent {
    func breakdown(_ total: Int) -> JSONValue {
        .object(["totalTokens": .number(Double(total)), "inputTokens": .number(Double(total - 100)), "cachedInputTokens": .number(0),
                 "cacheWriteInputTokens": .number(0), "outputTokens": .number(100), "reasoningOutputTokens": .number(0)])
    }
    let raw: JSONValue = .object(["method": .string("thread/tokenUsage/updated"), "params": .object([
        "threadId": .string("thread"), "turnId": .string("turn"),
        "tokenUsage": .object(["total": breakdown(2_000_000), "last": breakdown(context), "modelContextWindow": .number(258_400)])
    ])])
    return try #require(CodexEventDecoder.notification(raw))
}
private func item(_ event: AgentEvent) throws -> TranscriptItem {
    guard case .item(let item) = event.payload else { throw ClientFailure("Expected transcript item") }
    return item
}
private func storeFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("metadata.sqlite")
}

@Test @MainActor func compactionLifecycleIsADividerOutsideCollapsedTools() throws {
    let started = try item(compactionEvent("item/started"))
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
    #expect(storage.attribute(.compactionDivider, at: range.location, effectiveRange: nil) as? Bool == true)
    #expect(storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil)
    #expect(storage.attribute(.link, at: range.location, effectiveRange: nil) == nil)
    #expect(view.transcript.string.contains("Working"))

    let completed = try item(compactionEvent("item/completed"))
    #expect(completed.phase == "completed")
    TranscriptItem.merge(completed, into: &items)
    TranscriptItem.merge(completed, into: &items)
    #expect(items.filter { $0.id == "compact" }.count == 1)
    view.update(items: items, conversationID: "thread", followOutput: true, isWorking: true)
    // No sizes were reported: the divider says only that the context was compacted.
    let caption = L10n.text("Контекст сжат", "Context compacted")
    #expect(!view.transcript.string.contains(started.text))
    let line = (view.transcript.string as NSString).range(of: caption)
    #expect(line.location != NSNotFound)
    #expect(storage.attribute(.compactionDivider, at: line.location, effectiveRange: nil) as? Bool == false)
    #expect(storage.attribute(.toolTip, at: line.location, effectiveRange: nil) == nil)
    view.update(items: items, conversationID: "thread", followOutput: false, isWorking: false)
    #expect(view.transcript.string.contains(caption))
    view.update(items: [], conversationID: "other", followOutput: false, isWorking: true)
    #expect(!view.transcript.string.contains(caption))
}

@Test @MainActor func unfinishedCompactionDoesNotClaimSuccessAfterStop() throws {
    let started = try item(compactionEvent("item/started"))
    let view = TranscriptScrollView()
    view.update(items: [started], conversationID: "thread", followOutput: false, isWorking: false)
    #expect(!view.transcript.string.contains(started.text))
    #expect(view.transcript.string.contains(L10n.text(
        "Сжатие контекста: завершение не подтверждено", "Context compaction: completion unconfirmed")))
}

@Test @MainActor func dividerShowsSizesTriggerAndExactNumbersAndDrawsItsRules() throws {
    var compaction = TranscriptItem(id: "compact:b", kind: "compaction", text: "Conversation context compacted", phase: "completed")
    compaction.compaction = ContextCompaction(before: 966_625, after: 19_463, trigger: "auto")
    let items = [TranscriptItem(id: "user", kind: "user", text: "Question"), compaction,
                 TranscriptItem(id: "answer", kind: "assistant", text: "Continued")]
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
    view.update(items: items, conversationID: "chat", followOutput: false, isWorking: false)
    let caption = try #require(compaction.compaction).caption()
    #expect(caption == L10n.text("Контекст сжат: 967k → 19k · автоматически", "Context compacted: 967k → 19k · automatic"))
    let range = (view.transcript.string as NSString).range(of: caption)
    #expect(range.location != NSNotFound)
    let storage = try #require(view.transcript.textStorage)
    #expect(storage.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String == compaction.compaction?.detail())
    #expect((storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
    // The divider sits between the messages, in transcript order.
    let string = view.transcript.string as NSString
    #expect(string.range(of: "Question").location < range.location && range.location < string.range(of: "Continued").location)
    // Drawing goes through the layout manager's rules without failing.
    let bitmap = try #require(view.transcript.bitmapImageRepForCachingDisplay(in: view.transcript.bounds))
    view.transcript.cacheDisplay(in: view.transcript.bounds, to: bitmap)
}

@Test func compactionCaptionAndNumbersInBothLanguages() {
    #expect(ContextCompaction.tokens(950, language: .english) == "950")
    #expect(ContextCompaction.tokens(9_500, language: .english) == "9.5k")
    #expect(ContextCompaction.tokens(9_500, language: .russian) == "9,5k")
    #expect(ContextCompaction.tokens(10_000, language: .english) == "10k")
    #expect(ContextCompaction.tokens(120_000, language: .english) == "120k")
    #expect(ContextCompaction.tokens(966_625, language: .english) == "967k")
    #expect(ContextCompaction.tokens(999_600, language: .english) == "1M")
    #expect(ContextCompaction.tokens(1_260_000, language: .english) == "1.3M")
    #expect(ContextCompaction.tokens(1_260_000, language: .russian) == "1,3M")
    #expect(ContextCompaction.tokens(12_400_000, language: .english) == "12M")

    let both = ContextCompaction(before: 120_000, after: 30_000, trigger: "manual")
    #expect(both.caption(language: .english) == "Context compacted: 120k → 30k · manual")
    #expect(both.caption(language: .russian) == "Контекст сжат: 120k → 30k · вручную")
    let before = ContextCompaction(before: 120_000)
    #expect(before.caption(language: .english) == "Context compacted · was 120k")
    #expect(before.caption(language: .russian) == "Контекст сжат · было 120k")
    let auto = ContextCompaction(before: 120_000, trigger: "auto")
    #expect(auto.caption(language: .english) == "Context compacted · was 120k · automatic")
    #expect(auto.caption(language: .russian) == "Контекст сжат · было 120k · автоматически")
    // An unknown trigger value is data: it decodes and is not shown.
    #expect(ContextCompaction(before: 1_000, trigger: "scheduled").caption(language: .english) == "Context compacted · was 1k")
    #expect(ContextCompaction().caption(language: .english) == "Context compacted")
    #expect(ContextCompaction().detail(language: .english) == nil)

    let exact = ContextCompaction(before: 966_625, after: 19_463, trigger: "auto")
    #expect(exact.detail(language: .english) == "Tokens before: 966,625\nTokens after: 19,463\nTrigger: automatic")
    // Russian groups digits with a non-breaking space.
    let russian = exact.detail(language: .russian) ?? ""
    #expect(russian.hasPrefix("Токенов до сжатия: 966") && russian.contains("625\nТокенов после: 19"))
    #expect(russian.hasSuffix("463\nЗапуск: автоматически"))
}

@Test func codexCompactionTakesItsSizesFromTheThreadUsageAroundIt() throws {
    var meter = CodexCompactionMeter()
    #expect(meter.observe(try usageEvent(context: 230_000)).count == 1)
    let started = try item(#require(meter.observe(try compactionEvent("item/started")).first))
    #expect(started.compaction == ContextCompaction(before: 230_000))
    // A repeated report of the old size is not the size after.
    #expect(meter.observe(try usageEvent(context: 230_000)).count == 1)
    let completed = try item(#require(meter.observe(try compactionEvent("item/completed")).first))
    #expect(completed.phase == "completed" && completed.compaction == ContextCompaction(before: 230_000))
    // The first smaller report completes it; the item is published again with both sizes and no trigger (Codex has none).
    let events = meter.observe(try usageEvent(context: 31_500))
    #expect(events.count == 2)
    guard case .usage = events[0].payload else { Issue.record("usage first"); return }
    let sized = try item(events[1])
    #expect(sized.id == "compact" && sized.turnID == "turn" && sized.phase == "completed")
    #expect(sized.compaction == ContextCompaction(before: 230_000, after: 31_500))
    #expect(meter.observe(try usageEvent(context: 20_000)).count == 1)
    // A repeat of the completed item keeps the sizes; the next compaction starts from the latest report.
    #expect(try item(#require(meter.observe(try compactionEvent("item/completed")).first)).compaction == sized.compaction)
    #expect(try item(#require(meter.observe(try compactionEvent("item/completed", id: "second")).first)).compaction == ContextCompaction(before: 20_000))
    // Without any report before it, nothing is guessed.
    var fresh = CodexCompactionMeter()
    #expect(try item(#require(fresh.observe(try compactionEvent("item/completed")).first)).compaction == nil)
    #expect(fresh.observe(try usageEvent(context: 10_000)).count == 1)
}

@Test @MainActor func storedDividersSurviveReopeningAndLegacyItemsStillDecode() throws {
    // A transcript stored before the field existed, in the shape the app wrote (no `compaction` key).
    let legacy = Data(#"{"version":1,"conversation":{"value":"chat"},"source":{"connection":{"agent":"codex","id":"F0362513-6DDA-4E2A-9F74-807F29BCE001"},"nativeID":"chat"},"revision":"r","capturedAt":0,"completeness":"complete","items":[{"id":"c1","kind":"activity","text":"Conversation context compacted","presentation":{"id":"c1","kind":"compaction","text":"Conversation context compacted","phase":"completed","turnID":"t1","showsAuthor":true,"showsCopyControl":true}}]}"#.utf8)
    let snapshot = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: legacy)
    let restored = LocalHistory.items(snapshot)
    #expect(restored.first?.kind == "compaction" && restored.first?.compaction == nil)
    let view = TranscriptScrollView()
    view.update(items: restored, conversationID: "chat", followOutput: false, isWorking: false)
    #expect(view.transcript.string.contains(L10n.text("Контекст сжат", "Context compacted")))

    var sized = TranscriptItem(id: "c2", kind: "compaction", text: "Conversation context compacted", phase: "completed")
    sized.compaction = ContextCompaction(before: 120_000, after: 30_000, trigger: "auto")
    let source = AgentSessionReference(connection: .originalCodex, nativeID: "chat")
    let saved = try LocalHistory.snapshot(conversation: ConversationID("chat"), source: source, items: [sized])
    let reopened = LocalHistory.items(try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: JSONEncoder().encode(saved)))
    #expect(reopened == [sized])
}

@Test func historyRefreshKeepsTheCompactionSizesRecordedLive() async throws {
    let file = storeFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    let chat = Chat(id: "chat", projectID: UUID(), title: "Title", model: "model")
    var state = try await store.load(); state.chats.append(chat); try await store.save(state)
    let source = try #require(chat.nativeSession)
    var live = TranscriptItem(id: "live-id", kind: "compaction", text: "Conversation context compacted", phase: "completed")
    live.turnID = "t1"; live.compaction = ContextCompaction(before: 230_000, after: 31_500)
    var other = TranscriptItem(id: "other", kind: "compaction", text: "Conversation context compacted", phase: "completed")
    other.turnID = "t2"; other.compaction = ContextCompaction(before: 200_000, after: 25_000)
    try await store.recordTranscriptItem(live, conversationID: chat.id, source: source)
    try await store.recordTranscriptItem(other, conversationID: chat.id, source: source)
    // The engine's history returns the items without sizes: one with the same id, one under another id in the same turn.
    func plain(_ id: String, turn: String) -> AgentHistoryTurn {
        AgentHistoryTurn(id: turn, items: [TranscriptItem(id: "u-" + turn, kind: "user", text: "Go"),
                                           TranscriptItem(id: id, kind: "compaction", text: "Conversation context compacted", phase: "completed")],
                         startedAt: nil, completedAt: nil, duration: nil)
    }
    let turns = [plain("live-id", turn: "t1"), plain("history-id", turn: "t2")]
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: source, turns: turns,
                                                         capturedAt: Date().addingTimeInterval(60)))
    await store.flushTranscripts()
    let reopened = LocalHistory.items(try #require(try await AppStore(file: file).loadTranscript(conversationID: chat.id)))
    #expect(reopened.filter { $0.kind == "compaction" }.map(\.compaction) == [live.compaction, other.compaction])

    // The chat view applies the same rule to the list it shows.
    var shown = turns.flatMap { turn in turn.items.map { var item = $0; item.turnID = turn.id; return item } }
    #expect(ContextCompaction.carry(from: [live, other], into: &shown))
    #expect(shown.filter { $0.kind == "compaction" }.map(\.compaction) == [live.compaction, other.compaction])
    #expect(!ContextCompaction.carry(from: [live, other], into: &shown))
}

@Test func archivedTranscriptWithADividerStaysReducedAndKeepsIt() async throws {
    let file = storeFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    var chat = Chat(id: "archived", projectID: UUID(), title: "Archived", model: "model"); chat.archived = true
    var state = try await store.load(); state.chats.append(chat); try await store.save(state)
    let source = try #require(chat.nativeSession)
    var divider = TranscriptItem(id: "c", kind: "compaction", text: "Conversation context compacted", phase: "completed")
    divider.compaction = ContextCompaction(before: 966_625, after: 19_463, trigger: "auto")
    let body = String(repeating: "y", count: 30_000)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Hi"), TranscriptItem(id: "b", kind: "activity", text: body), divider]
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: source, items: items,
                                                         capturedAt: Date(timeIntervalSince1970: 10)))
    #expect(try await store.reduceTranscript(conversationID: chat.id) != nil)
    let reduced = try #require(try await store.loadTranscript(conversationID: chat.id))
    // The divider is not a tool body: it stays whole and does not keep the transcript looking unreduced.
    #expect(ActivityRetention.isReduced(reduced))
    #expect(LocalHistory.items(reduced).last == divider)
    #expect(try await store.reduceTranscript(conversationID: chat.id) == nil)
    // Opening the archived chat refreshes its history with full bodies; they are reduced again before the write.
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: source, items: items,
                                                         capturedAt: Date().addingTimeInterval(60)))
    let refreshed = try #require(try await AppStore(file: file).loadTranscript(conversationID: chat.id))
    #expect(ActivityRetention.isReduced(refreshed) && LocalHistory.items(refreshed).last == divider)
}

@Test @MainActor func refusalShowsAnAttentionBadgeOutsideCollapsedTools() throws {
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
    #expect(storage.attribute(.noticeBadge, at: range.location, effectiveRange: nil) != nil)
    #expect(storage.attribute(.noticeBadge, at: NSMaxRange(range), effectiveRange: nil) == nil)
    #expect(storage.attribute(.badgeTint, at: range.location, effectiveRange: nil) as? NSColor == DeskPalette.ns.attentionWash)
    #expect(view.transcript.string.contains("Safe answer"))
}
