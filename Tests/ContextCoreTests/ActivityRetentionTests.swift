import Foundation
import Testing
import CSQLite
import AgentContract
@testable import ContextCore
@testable import ClaudeAdapter
import ContextTranscript
@testable import ContextDesk

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func fileSize(_ url: URL) throws -> Int {
    try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
}

private func storedIsReduced(_ store: AppStore, _ id: String) async throws -> Bool {
    ActivityRetention.isReduced(try #require(try await store.loadTranscript(conversationID: id)))
}

/// Pages of the database as another connection sees them (the main file plus checkpointed WAL content).
private func pageCount(_ file: URL) throws -> Int {
    var handle: OpaquePointer?
    #expect(sqlite3_open(file.path, &handle) == SQLITE_OK)
    let db = try #require(handle)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
    #expect(sqlite3_prepare_v2(db, "PRAGMA page_count", -1, &statement, nil) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
    return Int(sqlite3_column_int64(statement, 0))
}

@Test func activityBodiesAreCappedAsHeadMarkerAndTail() {
    let body = (0..<2500).map { "line \($0) Привет" }.joined(separator: "\n")
    let item = TranscriptItem(id: "t1:result", kind: "activity", text: body)
    let capped = ActivityRetention.cap(item)
    let head = ActivityRetention.prefix(body, bytes: ActivityRetention.headBytes), tail = ActivityRetention.suffix(body, bytes: ActivityRetention.tailBytes)
    let omitted = body.utf8.count - head.utf8.count - tail.utf8.count
    #expect(capped.fullLength == body.utf8.count && capped.reduced == nil)
    #expect(capped.text == head + "\n" + ActivityRetention.marker(omitted: omitted) + "\n" + tail)
    #expect(body.hasPrefix(head) && body.hasSuffix(tail) && omitted > 0)
    #expect(head.utf8.count <= ActivityRetention.headBytes && head.utf8.count > ActivityRetention.headBytes - 4)
    #expect(tail.utf8.count <= ActivityRetention.tailBytes && tail.utf8.count > ActivityRetention.tailBytes - 4)
    #expect(capped.text.contains("\(omitted)"))
    // Idempotent; other kinds and short bodies pass through.
    #expect(ActivityRetention.cap(capped) == capped)
    #expect(ActivityRetention.cap(TranscriptItem(id: "a", kind: "assistant", text: body)).fullLength == nil)
    #expect(ActivityRetention.cap(TranscriptItem(id: "s", kind: "activity", text: "short")) == TranscriptItem(id: "s", kind: "activity", text: "short"))
    // A Claude call keeps its JSON structure: only the long value is cut, so the headline survives.
    let content = String(repeating: "x", count: 40_000)
    let call = TranscriptItem(id: "w1", kind: "activity", text: "Write\n" + JSONValue.object(["content": .string(content), "file_path": .string("/a/b.swift")]).display)
    let cappedCall = ActivityRetention.cap(call)
    #expect(cappedCall.fullLength == call.text.utf8.count && cappedCall.text.utf8.count <= ActivityRetention.capBytes)
    #expect(TranscriptScrollView.activityHeadline(cappedCall.text) == "Write · /a/b.swift")
    #expect(cappedCall.text.contains("\"file_path\" : \"\\/a\\/b.swift\""))
    // A plain cut that broke the JSON still yields the headline while the field is within the head.
    let notes = String(repeating: "y", count: 30_000)
    let broken = ActivityRetention.cappedText("Read\n" + JSONValue.object(["file_path": .string("/a/b.swift"), "notes": .string(notes)]).display,
                                              head: ActivityRetention.headBytes, tail: ActivityRetention.tailBytes)
    #expect(TranscriptScrollView.activityHeadline(broken) == "Read · /a/b.swift")
    #expect(ActivityRetention.headline("Grep\n{\"pattern\" : \"needle\", \"glob\" : \"*.swift\"}") == "Grep · needle")
}

private let resultBody = (0..<3000).map { "out \($0)" }.joined(separator: "\n") + "\nfatal: nope\nExit code 1"
private let sampleItems = [
    TranscriptItem(id: "u", kind: "user", text: "Run it"),
    TranscriptItem(id: "a", kind: "assistant", text: "Running", phase: "commentary"),
    TranscriptItem(id: "b1", kind: "activity", text: "Bash\n{\n  \"command\" : \"make test\",\n  \"timeout\" : 5\n}"),
    TranscriptItem(id: "b1:result", kind: "activity", text: resultBody),
    TranscriptItem(id: "c", kind: "activity", text: "ls -la\nsecond line"),
    TranscriptItem(id: "f", kind: "assistant", text: "Done", phase: "final_answer")
]

@Test func archiveReductionKeepsMessagesHeadlinesCountsAndWritesTheMetadataLine() throws {
    let items = sampleItems
    let reduced = ActivityRetention.reduce(items)
    #expect(reduced.map(\.id) == items.map(\.id))
    #expect(reduced[0] == items[0] && reduced[1] == items[1] && reduced[5] == items[5])
    #expect(reduced[2].text == "Bash · make test\n#activity tool=Bash target=\"make test\" input=\(items[2].text.utf8.count) output=\(resultBody.utf8.count)")
    #expect(reduced[3].text == TranscriptScrollView.activityHeadline(resultBody) + "\n#activity tool=Bash output=\(resultBody.utf8.count) exit=1 error=\"fatal: nope | Exit code 1\"")
    #expect(reduced[4].text == "ls -la second line\n#activity size=\(items[4].text.utf8.count)")
    #expect(reduced.allSatisfy { entry in entry.kind != "activity" || (entry.reduced == true && entry.fullLength == items.first { $0.id == entry.id }?.text.utf8.count) })
    // The headline of a reduced body is its stored first line, never the metadata.
    #expect(TranscriptScrollView.activityHeadline(reduced[2].text) == "Bash · make test")
    #expect(TranscriptScrollView.activityHeadline(reduced[3].text) == TranscriptScrollView.activityHeadline(resultBody))
    #expect(TranscriptScrollView.activityHeadline(reduced[4].text) == "ls -la second line")
    #expect(ActivityRetention.isReduced(reduced) && !ActivityRetention.isReduced(items))
    #expect(ActivityRetention.reduce(reduced) == reduced)
    // A capped body reports its original size; a clean result carries no error.
    let capped = ActivityRetention.cap(TranscriptItem(id: "x:result", kind: "activity", text: String(repeating: "z", count: 50_000)))
    #expect(ActivityRetention.reduce([capped])[0].text == String(repeating: "z", count: 119) + "…\n#activity output=50000")
    #expect(ActivityRetention.reduce([TranscriptItem(id: "q:result", kind: "activity", text: "ok\nall good")])[0].text == "ok all good\n#activity output=11")
    #expect(ActivityRetention.quoted("a \"b\"\n\\c") == "\"a \\\"b\\\"\\n\\\\c\"")
    // Turns: a call and its result pair up across turn records; timing and completeness stay.
    let turns = [AgentHistoryTurn(id: "t1", items: Array(items[0..<3]), startedAt: nil, completedAt: Date(timeIntervalSince1970: 5), duration: 2, isComplete: true),
                 AgentHistoryTurn(id: "t2", items: Array(items[3...]), startedAt: nil, completedAt: nil, duration: nil)]
    let reducedTurns = ActivityRetention.reduce(turns)
    #expect(reducedTurns.map(\.items.count) == [3, 3] && reducedTurns.flatMap(\.items) == reduced)
    #expect(reducedTurns[0].timing(fallback: nil)?.durationSeconds == 2 && reducedTurns[0].isComplete && !reducedTurns[1].isComplete)
    // Snapshots keep their capture time and completeness.
    let source = AgentSessionReference(connection: .appClaude, nativeID: "native")
    let snapshot = try LocalHistory.snapshot(conversation: ConversationID("chat"), source: source, items: items, completeness: .complete, capturedAt: Date(timeIntervalSince1970: 9))
    let reducedSnapshot = try ActivityRetention.reduce(snapshot)
    #expect(LocalHistory.items(reducedSnapshot).map(\.text) == reduced.map(\.text))
    #expect(reducedSnapshot.capturedAt == snapshot.capturedAt && reducedSnapshot.completeness == .complete)
    #expect(ActivityRetention.isReduced(reducedSnapshot) && !ActivityRetention.isReduced(snapshot))
    #expect(try ActivityRetention.reduce(reducedSnapshot) == reducedSnapshot)
}

@Test func claudeSummarySourceStillWorksOnReducedTurns() throws {
    let turn = AgentHistoryTurn(id: "t", items: sampleItems, startedAt: nil, completedAt: Date(timeIntervalSince1970: 100), duration: nil, isComplete: true)
    let turns = ActivityRetention.reduce([turn])
    let source = try ClaudeGenerationRunner.summarySource(turns: turns)
    #expect(source.fragments.map(\.kind) == ["userMessage", "agentMessage", "toolActivity", "toolActivity", "toolActivity", "agentMessage"])
    #expect(source.fragments[2].text == turns[0].items[2].text && source.fragments[2].text.contains("#activity tool=Bash target=\"make test\""))
    #expect(source.fragments[0].text == "Run it" && source.fragments[5].text == "Done")
    #expect(!source.omittedDetails && source.turnDates["t"] == 100)
    #expect(source.digest != (try ClaudeGenerationRunner.summarySource(turns: [turn])).digest)
}

@Test func storeReducesArchivedTranscriptsOnceAndKeepsThemReduced() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("metadata.sqlite"), store = AppStore(file: file)
    let project = Project(path: "/fixture")
    var chat = Chat(id: "archived", projectID: project.id, title: "Archived", model: "model"); chat.archived = true
    var state = SavedState(); state.projects = [project]; state.chats = [chat]
    try await store.save(state)
    let source = try #require(chat.nativeSession)
    let body = String(repeating: "y", count: 30_000)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Hi"), TranscriptItem(id: "b", kind: "activity", text: "Bash\n{\"command\" : \"ls\"}"),
                 TranscriptItem(id: "b:result", kind: "activity", text: body)]
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: source, items: items, capturedAt: Date(timeIntervalSince1970: 10)))
    // Bodies are capped on the way in, whichever path stores them.
    let stored = LocalHistory.items(try #require(try await store.loadTranscript(conversationID: chat.id)))
    #expect(stored[2].fullLength == 30_000 && stored[2].text.utf8.count <= ActivityRetention.capBytes + 64)
    try await store.recordTranscriptItem(TranscriptItem(id: "r:result", kind: "activity", text: body + body), conversationID: chat.id, source: source)
    let recorded = try #require(try await store.loadTranscript(conversationID: chat.id))
    #expect(LocalHistory.items(recorded).last?.fullLength == 60_000)
    let sizes = try #require(try await store.reduceTranscript(conversationID: chat.id))
    #expect(sizes.after < sizes.before / 4)
    let reduced = LocalHistory.items(try #require(try await store.loadTranscript(conversationID: chat.id)))
    #expect(reduced.map(\.id) == ["u", "b", "b:result", "r:result"] && reduced[0].text == "Hi")
    #expect(reduced[1].text == "Bash · ls\n#activity tool=Bash target=\"ls\" input=\(items[1].text.utf8.count) output=30000")
    #expect(reduced[2].fullLength == 30_000 && reduced[3].fullLength == 60_000)
    // Idempotent and cheap: the stamp says reduced, so nothing is decoded or written, also by a fresh instance.
    let writes = await store.transcriptWriteCount
    #expect(try await store.reduceTranscript(conversationID: chat.id) == nil)
    #expect(try await AppStore(file: file).reduceTranscript(conversationID: chat.id) == nil)
    #expect(await store.transcriptWriteCount == writes)
    // A later history refresh of the archived chat brings the engine's full bodies back; they are reduced before the write.
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: source,
        items: items + [TranscriptItem(id: "f", kind: "assistant", text: "Done")], capturedAt: Date().addingTimeInterval(60)))
    let refreshed = try #require(try await AppStore(file: file).loadTranscript(conversationID: chat.id))
    #expect(ActivityRetention.isReduced(refreshed) && refreshed.items.map(\.id) == ["u", "b", "b:result", "f"])
    // A transcript without tool bodies only gets its stamp marked; nothing is stored for an unknown chat.
    var plain = Chat(id: "plain", projectID: project.id, title: "Plain", model: "model"); plain.archived = true
    state.chats.append(plain); try await store.save(state)
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(plain.id), source: try #require(plain.nativeSession),
        items: [TranscriptItem(id: "u", kind: "user", text: "Only text")]))
    #expect(try await store.reduceTranscript(conversationID: plain.id) == nil)
    #expect(try await store.reduceTranscript(conversationID: "missing") == nil)
}

@Test func storeVacuumsOnlyWhenMoreThanAQuarterOfTheFileIsFree() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("metadata.sqlite"), store = AppStore(file: file)
    let chat = Chat(id: "chat", projectID: UUID(), title: "Title", model: "model")
    var state = SavedState(); state.chats = [chat]
    try await store.save(state)
    #expect(try await store.freeSpaceFraction() < 0.25)
    #expect(try await store.vacuumIfFragmented() == false)
    // A large transcript and then its deletion leave most of the file free (an assistant body is never capped).
    let big = TranscriptItem(id: "a", kind: "assistant", text: String(repeating: "q", count: 6_000_000))
    try await store.saveTranscript(LocalHistory.snapshot(conversation: chat.conversationID, source: try #require(chat.nativeSession), items: [big]))
    state.chats = []
    try await store.saveDeletingChat(state, threadID: chat.id)
    #expect(try await store.freeSpaceFraction() > 0.25)
    let before = try fileSize(file), pagesBefore = try pageCount(file)
    #expect(try await store.vacuumIfFragmented())
    #expect(try await store.freeSpaceFraction() < 0.25)
    let after = try fileSize(file), pagesAfter = try pageCount(file)
    #expect(after <= before && pagesAfter < pagesBefore / 4)
    #expect(try await store.vacuumIfFragmented() == false)
    // The store keeps working on the rebuilt file.
    #expect(try await store.load().chats.isEmpty)
}

@Test @MainActor func launchCleanupReducesArchivedChatsOnceAndSkipsActiveOnes() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let model = DeskModel(store: store, summaryResources: nil)
    let project = Project(path: "/fixture")
    func chat(_ id: String, archived: Bool) -> Chat {
        var chat = Chat(id: id, projectID: project.id, title: id, model: "model"); chat.archived = archived; return chat
    }
    let archived = chat("archived", archived: true), busy = chat("busy", archived: true), active = chat("active", archived: false)
    let claude = Chat(session: .init(connection: .appClaude, nativeID: UUID().uuidString), projectID: project.id, title: "Claude", model: "model")
    model.state.projects = [project]; model.state.chats = [archived, busy, active, claude]
    model.state.chats[3].archived = true
    try await store.save(model.state)
    let body = String(repeating: "b", count: 20_000)
    for chat in model.state.chats {
        try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: try #require(chat.nativeSession), items: [
            TranscriptItem(id: "u", kind: "user", text: "Hi"), TranscriptItem(id: "t", kind: "activity", text: "Read\n{\"file_path\" : \"/x\"}"),
            TranscriptItem(id: "t:result", kind: "activity", text: body)]))
    }
    await model.receive(.init(session: try #require(busy.nativeSession), payload: .started(turn: "turn")))
    #expect(model.isBusy(threadID: busy.id))
    let first = await model.cleanUpArchivedActivity()
    #expect(first.chats == 2 && first.bytesAfter < first.bytesBefore / 2)
    for id in [archived.id, claude.id] { #expect(try await storedIsReduced(store, id)) }
    for id in [busy.id, active.id] { #expect(try await storedIsReduced(store, id) == false) }
    // The second pass finds nothing to do and writes nothing.
    let writes = await store.transcriptWriteCount
    #expect(await model.cleanUpArchivedActivity() == DeskModel.ActivityReduction())
    #expect(await store.transcriptWriteCount == writes)
    // Archiving a chat reduces it at once; restoring it keeps the reduction.
    model.state.chats[2].archived = true
    let archivedNow = await model.reduceArchivedActivity(active.id)
    #expect(archivedNow.chats == 1)
    #expect(try await storedIsReduced(store, active.id))
    model.state.chats[2].archived = false
    #expect(try await storedIsReduced(store, active.id))
    #expect(await model.reduceArchivedActivity(active.id) == DeskModel.ActivityReduction())
    // The Claude session file is reduced while Claude is connected, unless a summary is queued or being generated;
    // a chat without any summary record is reduced too.
    #expect(model.activityReductionTargets(claude.id).session == nil)
    model.claudeConnected = true
    #expect(model.activityReductionTargets(claude.id).session == claude.nativeSession)
    var record = ArchiveSummaryRecord(threadID: claude.id, projectID: project.id); record.status = .queued
    model.archiveSummaries[claude.id] = record
    #expect(model.activityReductionTargets(claude.id).session == nil)
    record.status = .generating; model.archiveSummaries[claude.id] = record
    #expect(model.activityReductionTargets(claude.id).session == nil)
    for settled in [ArchiveSummaryStatus.ready, .failed, .uncertain, .stale] {
        record.status = settled; model.archiveSummaries[claude.id] = record
        #expect(model.activityReductionTargets(claude.id).session == claude.nativeSession)
    }
    #expect(model.activityReductionTargets(busy.id) == (false, nil))
    // A chat whose Claude history is marked reduced keeps its file unread; leaving the archive clears the mark.
    model.state.chats[3].historyReduced = true
    #expect(model.activityReductionTargets(claude.id).session == nil)
    model.state.chats[3].historyReduced = nil
    #expect(model.activityReductionTargets(claude.id).session == claude.nativeSession)
    // The launch task ends with VACUUM only while no chat is busy; the reduced bodies left most of this small file free.
    model.activityCleanupLaunchDelay = .zero
    model.startActivityCleanup()
    await model.activityCleanupTask?.value
    #expect(try await store.freeSpaceFraction() > 0.25)
    let idle = DeskModel(store: store, summaryResources: nil)
    idle.state = model.state
    await idle.vacuumStoreIfIdle()
    #expect(try await store.freeSpaceFraction() < 0.25)
    await model.shutdown()
}

@Test @MainActor func launchCleanupWaitsWhileAChatRunsAndPersistsTheHistoryMarksOnce() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let model = DeskModel(store: store, summaryResources: nil)
    let project = Project(path: "/fixture")
    var archived = Chat(id: "archived", projectID: project.id, title: "Archived", model: "model"); archived.archived = true
    let live = Chat(id: "live", projectID: project.id, title: "Live", model: "model")
    model.state.projects = [project]; model.state.chats = [archived, live]
    try await store.save(model.state)
    try await store.saveTranscript(LocalHistory.snapshot(conversation: archived.conversationID, source: try #require(archived.nativeSession), items: [
        TranscriptItem(id: "u", kind: "user", text: "Hi"), TranscriptItem(id: "t", kind: "activity", text: "Read\n{\"file_path\" : \"/x\"}"),
        TranscriptItem(id: "t:result", kind: "activity", text: String(repeating: "b", count: 20_000))]))
    model.activityCleanupBusyPause = .milliseconds(400)
    // Another chat runs a turn: the pass slows down (one pause per chat) instead of competing with it for the store
    // and adapter actors, but it does not wait for a full stop.
    await model.receive(.init(session: try #require(live.nativeSession), payload: .started(turn: "turn")))
    #expect(model.isBusy(threadID: live.id))
    let started = ContinuousClock.now
    let pass = Task { await model.cleanUpArchivedActivity() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await storedIsReduced(store, archived.id) == false)
    let result = await pass.value
    #expect(ContinuousClock.now - started >= .milliseconds(400))
    #expect(model.isBusy(threadID: live.id))
    #expect(result.chats == 1 && result.historiesMarked == 0)
    #expect(try await storedIsReduced(store, archived.id))
    // Idle chats: no pause at all.
    model.state.chats[1].archived = true
    try await store.saveTranscript(LocalHistory.snapshot(conversation: live.conversationID, source: try #require(live.nativeSession), items: [
        TranscriptItem(id: "t", kind: "activity", text: "Read\n{\"file_path\" : \"/y\"}"), TranscriptItem(id: "t:result", kind: "activity", text: String(repeating: "c", count: 20_000))]))
    let idle = DeskModel(store: store, summaryResources: nil)
    idle.state = model.state
    idle.activityCleanupBusyPause = .seconds(30)
    let quick = ContinuousClock.now
    #expect(await idle.cleanUpArchivedActivity().chats == 1)
    #expect(ContinuousClock.now - quick < .seconds(5))
    // A Codex chat never gets a history mark: its thread store is not the app's to rewrite.
    #expect(model.state.chats[0].historyReduced == nil)
    await model.shutdown()
}
