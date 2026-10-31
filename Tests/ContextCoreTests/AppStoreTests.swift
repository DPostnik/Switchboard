import Foundation
import Testing
import CSQLite
import AgentContract
@testable import ContextCore

private func withRawDatabase<T>(_ file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    #expect(sqlite3_open(file.path, &handle) == SQLITE_OK)
    let db = try #require(handle)
    defer { sqlite3_close(db) }
    return try body(db)
}
private func rawText(_ db: OpaquePointer, _ sql: String) throws -> String? {
    var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
    #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
}
private func rawBlob(_ db: OpaquePointer, _ key: String) throws -> Data? {
    var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
    #expect(sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { return nil }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
}
private func temporaryStoreFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("metadata.sqlite")
}
private func savedChat(_ store: AppStore, id: String = "chat") async throws -> (Chat, AgentSessionReference) {
    let chat = Chat(id: id, projectID: UUID(), title: "Title", model: "model")
    var state = try await store.load(); state.chats.append(chat)
    try await store.save(state)
    return (chat, try #require(chat.nativeSession))
}

@Test func recordedItemsAreReadableBeforeTheFlushAndByAnotherInstanceAfterIt() async throws {
    let file = temporaryStoreFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    let (chat, source) = try await savedChat(store)
    try await store.recordTranscriptItem(TranscriptItem(id: "a", kind: "user", text: "Hello"), conversationID: chat.id, source: source)
    try await store.recordTranscriptItem(TranscriptItem(id: "b", kind: "assistant", text: "Answer"), conversationID: chat.id, source: source)
    // (b) The recording instance serves the merged items at once; the blob is not on disk yet.
    #expect(try await store.loadTranscript(conversationID: chat.id)?.items.map(\.text) == ["Hello", "Answer"])
    #expect(try withRawDatabase(file) { try rawBlob($0, "transcript:" + chat.id) } == nil)
    #expect(try await AppStore(file: file).loadTranscript(conversationID: chat.id) == nil)
    #expect(await store.transcriptWriteCount == 0)
    // (a) One write covers both items; a fresh instance reads the same snapshot.
    await store.flushTranscripts()
    #expect(await store.transcriptWriteCount == 1)
    let restored = try #require(try await AppStore(file: file).loadTranscript(conversationID: chat.id))
    #expect(restored.items.map(\.text) == ["Hello", "Answer"] && restored.completeness == .partial)
    #expect(try await store.loadTranscript(conversationID: chat.id) == restored)
    #expect(try withRawDatabase(file) { try rawBlob($0, "transcript-revision:" + chat.id) } != nil)
    // The scheduled flush writes without an explicit call (about 1 s; a loaded test run may delay the task).
    try await store.recordTranscriptItem(TranscriptItem(id: "c", kind: "assistant", text: "Later"), conversationID: chat.id, source: source)
    let deadline = Date().addingTimeInterval(15)
    while await store.transcriptWriteCount < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    #expect(await store.transcriptWriteCount == 2)
    #expect(try await AppStore(file: file).loadTranscript(conversationID: chat.id)?.items.map(\.text) == ["Hello", "Answer", "Later"])
}

@Test func identicalTranscriptSavesDoNotRewriteTheBlob() async throws {
    let file = temporaryStoreFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    let (chat, source) = try await savedChat(store)
    let items = [TranscriptItem(id: "a", kind: "user", text: "Hello"), TranscriptItem(id: "b", kind: "assistant", text: "Answer")]
    let first = try LocalHistory.snapshot(conversation: chat.conversationID, source: source, items: items, capturedAt: Date(timeIntervalSince1970: 100))
    try await store.saveTranscript(first)
    #expect(await store.transcriptWriteCount == 1)
    let blob = try #require(try withRawDatabase(file) { try rawBlob($0, "transcript:" + chat.id) })
    let identical = try LocalHistory.snapshot(conversation: chat.conversationID, source: source, items: items, capturedAt: Date(timeIntervalSince1970: 200))
    try await store.saveTranscript(identical)
    #expect(await store.transcriptWriteCount == 1)
    #expect(try withRawDatabase(file) { try rawBlob($0, "transcript:" + chat.id) } == blob)
    // A fresh instance without a cache skips the identical write too, without decoding the blob.
    let other = AppStore(file: file)
    try await other.saveTranscript(identical)
    #expect(await other.transcriptWriteCount == 0)
    // The later capture still protects against a backfill from between the two captures.
    let late = try LocalHistory.snapshot(conversation: chat.conversationID, source: source, items: [items[0]], capturedAt: Date(timeIntervalSince1970: 150))
    try await other.saveTranscript(late)
    #expect(await other.transcriptWriteCount == 0)
    #expect(try await other.loadTranscript(conversationID: chat.id)?.items.count == 2)
    // Same items with a different completeness is a real change.
    let complete = try LocalHistory.snapshot(conversation: chat.conversationID, source: source, items: items, completeness: .complete, capturedAt: Date(timeIntervalSince1970: 300))
    try await store.saveTranscript(complete)
    #expect(await store.transcriptWriteCount == 2)
    #expect(try withRawDatabase(file) { try rawBlob($0, "transcript:" + chat.id) } != blob)
    #expect(try await AppStore(file: file).loadTranscript(conversationID: chat.id)?.completeness == .complete)
}

@Test func storeUsesWriteAheadLoggingAndOneConnection() async throws {
    let file = temporaryStoreFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    _ = try await savedChat(store)
    #expect(try withRawDatabase(file) { try rawText($0, "PRAGMA journal_mode") } == "wal")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    // Repeated calls reuse the connection: the app state is served from the cache and identical saves are skipped.
    for _ in 0..<3 { _ = try await store.load() }
    try await store.save(try await store.load())
    #expect(try await store.load().chats.map(\.id) == ["chat"])
}

@Test func cachedStateFollowsCommitsFromOtherConnections() async throws {
    let file = temporaryStoreFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let first = AppStore(file: file), second = AppStore(file: file)
    let (chat, source) = try await savedChat(first)
    #expect(try await second.load().chats.map(\.id) == [chat.id])
    let (other, _) = try await savedChat(second, id: "other")
    #expect(try await first.load().chats.map(\.id) == [chat.id, other.id])
    // The identity check uses fresh state after the other instance deleted the chat.
    var state = try await second.load(); state.chats.removeAll { $0.id == chat.id }
    try await second.saveDeletingChat(state, threadID: chat.id)
    await #expect(throws: ClientFailure.self) {
        try await first.recordTranscriptItem(TranscriptItem(id: "a", kind: "user", text: "Gone"), conversationID: chat.id, source: source)
    }
    #expect(try await first.load().chats.map(\.id) == [other.id])
}

@Test func fullSnapshotsAndDeletionsSupersedePendingItems() async throws {
    let file = temporaryStoreFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    let (chat, source) = try await savedChat(store)
    try await store.recordTranscriptItem(TranscriptItem(id: "a", kind: "assistant", text: "Pending"), conversationID: chat.id, source: source)
    let revision = await store.transcriptRevision(conversationID: chat.id)
    let full = try LocalHistory.snapshot(conversation: chat.conversationID, source: source,
        items: [TranscriptItem(id: "u", kind: "user", text: "From history")], completeness: .complete, capturedAt: Date().addingTimeInterval(1))
    try await store.saveTranscript(full)
    #expect(await store.transcriptRevision(conversationID: chat.id) == revision + 1)
    #expect(try await store.loadTranscript(conversationID: chat.id) == full)
    await store.flushTranscripts()
    #expect(await store.transcriptWriteCount == 1)
    #expect(try await AppStore(file: file).loadTranscript(conversationID: chat.id) == full)
    // Items recorded for a chat that is then deleted never reach the file.
    let (second, secondSource) = try await savedChat(store, id: "second")
    try await store.recordTranscriptItem(TranscriptItem(id: "b", kind: "assistant", text: "Dropped"), conversationID: second.id, source: secondSource)
    var state = try await store.load(); state.chats.removeAll { $0.id == second.id }
    try await store.saveDeletingChat(state, threadID: second.id)
    await store.flushTranscripts()
    #expect(await store.transcriptWriteCount == 1)
    #expect(try await store.loadTranscript(conversationID: second.id) == nil)
    #expect(try withRawDatabase(file) { try rawBlob($0, "transcript:" + second.id) } == nil)
    // Blobs handed to the search index include pending items.
    let (third, thirdSource) = try await savedChat(store, id: "third")
    try await store.recordTranscriptItem(TranscriptItem(id: "c", kind: "assistant", text: "Indexed"), conversationID: third.id, source: thirdSource)
    let blobs = try await store.transcriptBlobs(conversationIDs: [third.id])
    let indexed = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: try #require(blobs[third.id]))
    #expect(indexed.items.map(\.text) == ["Indexed"])
    #expect(await store.transcriptWriteCount == 2)
}

@Test func transcriptCacheEvictsLeastRecentlyUsedEntriesAfterWritingPendingItems() async throws {
    let file = temporaryStoreFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = AppStore(file: file)
    var sources: [String: AgentSessionReference] = [:]
    for index in 0..<6 {
        let (chat, source) = try await savedChat(store, id: "chat-\(index)")
        sources[chat.id] = source
    }
    for (id, source) in sources.sorted(by: { $0.key < $1.key }) {
        try await store.recordTranscriptItem(TranscriptItem(id: "a", kind: "assistant", text: "Text " + id), conversationID: id, source: source)
    }
    // Two entries left the cache of four; their pending items were written on eviction.
    #expect(await store.transcriptWriteCount == 2)
    let reader = AppStore(file: file)
    #expect(try await reader.loadTranscript(conversationID: "chat-0")?.items.map(\.text) == ["Text chat-0"])
    #expect(try await reader.loadTranscript(conversationID: "chat-1")?.items.map(\.text) == ["Text chat-1"])
    #expect(try await reader.loadTranscript(conversationID: "chat-5") == nil)
    for id in sources.keys {
        #expect(try await store.loadTranscript(conversationID: id)?.items.map(\.text) == ["Text " + id])
    }
    await store.flushTranscripts()
    #expect(await store.transcriptWriteCount == 6)
    for id in sources.keys {
        #expect(try await AppStore(file: file).loadTranscript(conversationID: id)?.items.map(\.text) == ["Text " + id])
    }
}
