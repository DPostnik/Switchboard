import Foundation
import CSQLite
import AgentContract
import os

/// App-owned metadata, readable snapshots and portable work. Engines retain native execution state and credentials.
///
/// One SQLite connection lives for the actor's lifetime (WAL, busy timeout, one-time identity migration).
/// The decoded `app` state and the four most recently used transcripts are cached; `PRAGMA data_version`
/// detects commits by other connections and drops the caches. Items recorded by `recordTranscriptItem`
/// are merged in memory and written about a second later, but a chat that keeps recording is written at most once
/// every `flushInterval` (10 s): a long turn no longer rewrites its whole blob every second. Up to ~10 s of items can
/// be lost on a crash; the turn-end history refresh restores them from the agent. `flushTranscript(conversationID:)`
/// and `flushTranscripts()` write at once (chat switch, archive, deactivation, sleep, quit).
public actor AppStore {
    private let file: URL
    private static let log = Logger(subsystem: "local.daniil.switchboard", category: "app-store")
    private static let transcriptCacheLimit = 4
    /// Wait after the first item recorded into a clean chat.
    private let flushDelay: Duration
    /// Minimum time between two scheduled writes of one chat while it keeps recording (a cap, not reset per item).
    private let flushInterval: Duration

    /// Closes the handle when released, so dropping the property (or the actor) closes the database.
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer
        init(_ db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close(db) }
    }
    private var connection: Connection?
    /// `PRAGMA data_version` observed when the caches were last known to match the file.
    private var dataVersion: Int64?

    private struct CachedApp { var bytes: Data?; var state: SavedState? }
    private var app: CachedApp?

    private struct TranscriptEntry {
        var snapshot: AgentTranscriptSnapshot
        /// Merged item list kept while items are recorded; `snapshotStale` marks a snapshot older than it.
        var items: [TranscriptItem]?
        var snapshotStale = false
        /// True while the snapshot (after materializing) has not been written.
        var dirty = false
        var capturedAt: Date
    }
    /// Small record next to each transcript blob; lets identical writes and late backfills be skipped without decoding the blob.
    private struct TranscriptStamp: Codable, Equatable {
        var revision: String
        var completeness: AgentTranscriptSnapshot.Completeness
        var capturedAt: Date
        /// True when no activity in the blob still carries a body (`ActivityRetention`); nil on stamps written before the rule.
        var reduced: Bool?
        init(_ snapshot: AgentTranscriptSnapshot) {
            revision = snapshot.revision; completeness = snapshot.completeness; capturedAt = snapshot.capturedAt
            reduced = ActivityRetention.isReduced(snapshot)
        }
        func matches(_ snapshot: AgentTranscriptSnapshot) -> Bool {
            revision == snapshot.revision && completeness == snapshot.completeness
        }
    }
    private var transcripts: [String: TranscriptEntry] = [:]
    /// Least recently used first.
    private var transcriptOrder: [String] = []
    private var stamps: [String: TranscriptStamp] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    /// When each chat's transcript was last written; the next scheduled flush waits until `flushInterval` after it.
    private var lastFlush: [String: ContinuousClock.Instant] = [:]
    /// Bumped on every transcript write or delete so readers can skip re-decoding unchanged transcripts.
    private var transcriptRevisions: [String: Int] = [:]
    /// Number of transcript blobs written to the file; exposed for tests.
    var transcriptWriteCount = 0

    public init(file: URL) { self.init(file: file, flushDelay: .seconds(1), flushInterval: .seconds(10)) }
    /// Tests shorten the delays.
    init(file: URL, flushDelay: Duration, flushInterval: Duration) {
        self.file = file; self.flushDelay = flushDelay; self.flushInterval = flushInterval
    }
    deinit { for task in flushTasks.values { task.cancel() } }
    public func transcriptRevision(conversationID: String) -> Int { transcriptRevisions[conversationID, default: 0] }
    public func loadRoutines() throws -> [PortableRoutine] {
        try withDatabase { db in
            guard let data = try bytes(db: db, key: "portableRoutines:v1") else { return [] }
            let routines = try JSONDecoder().decode([PortableRoutine].self, from: data)
            guard Set(routines.map(\.id)).count == routines.count else { throw ConversationIdentity.invalidStorage }
            for routine in routines { try routine.validate() }
            return routines
        }
    }
    public func saveRoutine(_ routine: PortableRoutine) throws -> [PortableRoutine] {
        try routine.validate()
        var routines = try loadRoutines()
        routines.removeAll { $0.id == routine.id }; routines.append(routine)
        try put(key: "portableRoutines:v1", bytes: JSONEncoder().encode(routines))
        return routines
    }
    public func removeRoutine(_ id: UUID) throws -> [PortableRoutine] {
        let routines = try loadRoutines().filter { $0.id != id }
        try put(key: "portableRoutines:v1", bytes: JSONEncoder().encode(routines))
        return routines
    }
    public func saveHandoff(_ handoff: ContextHandoff) throws {
        _ = try handoff.prompt()
        try put(key: "handoff:" + handoff.id.uuidString, bytes: JSONEncoder().encode(handoff))
    }
    public func loadHandoff(_ id: UUID) throws -> ContextHandoff? {
        try withDatabase { db in
            guard let data = try bytes(db: db, key: "handoff:" + id.uuidString) else { return nil }
            let handoff = try JSONDecoder().decode(ContextHandoff.self, from: data)
            guard handoff.id == id else { throw ConversationIdentity.invalidStorage }
            _ = try handoff.prompt()
            return handoff
        }
    }

    // MARK: Connection

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let db = try openIfNeeded()
        try validateCaches(db)
        do { return try operation(db) } catch {
            if Self.needsReopen(sqlite3_errcode(db)) { closeConnection() }
            throw error
        }
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let connection { return connection.db }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw ClientFailure(L10n.text("Не удалось открыть хранилище", "Could not open storage"))
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            // WAL keeps readers off the write lock and avoids rewriting the rollback journal for every blob.
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось подготовить хранилище", "Could not prepare storage"))
            }
            app = nil; stamps = [:]; dropCleanTranscripts()
            try migrateIdentities(db)
            dataVersion = try Self.dataVersion(db)
        } catch { sqlite3_close(db); throw error }
        connection = Connection(db)
        return db
    }

    private func closeConnection() {
        connection = nil; dataVersion = nil; app = nil; stamps = [:]
        dropCleanTranscripts()
    }

    private static func needsReopen(_ code: Int32) -> Bool {
        [SQLITE_MISUSE, SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN].contains(code & 0xff)
    }

    /// Commits by any other connection (another store instance or process) invalidate everything cached from the file.
    private func validateCaches(_ db: OpaquePointer) throws {
        let version = try Self.dataVersion(db)
        guard version != dataVersion else { return }
        dataVersion = version
        app = nil; stamps = [:]
        dropCleanTranscripts()
    }

    private static func dataVersion(_ db: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw ClientFailure(L10n.text("Ошибка чтения", "Could not read data"))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func bytes(db: OpaquePointer, key: String) throws -> Data? {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw ConversationIdentity.invalidStorage }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let data = sqlite3_column_blob(statement, 0) else { throw ConversationIdentity.invalidStorage }
        return Data(bytes: data, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func transaction(_ db: OpaquePointer, failure: ClientFailure, _ body: () throws -> Void) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure }
        do {
            try body()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure }
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }

    // MARK: App state

    /// All old IDs become app IDs without renaming. Existing job JSON references
    /// therefore remain valid throughout the SQLite transaction, including a crash.
    /// Runs once per connection and seeds the state cache.
    private func migrateIdentities(_ db: OpaquePointer) throws {
        guard let data = try bytes(db: db, key: "app") else { app = CachedApp(bytes: nil, state: nil); return }
        let existing = try JSONDecoder().decode(SavedState.self, from: data)
        if existing.identityVersion == 2 { app = CachedApp(bytes: data, state: try ConversationIdentity.migrated(existing)); return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ConversationIdentity.invalidStorage }
        do {
            // Re-read after acquiring the write lock; another process may have migrated.
            guard let current = try bytes(db: db, key: "app") else { throw ConversationIdentity.invalidStorage }
            let source = try JSONDecoder().decode(SavedState.self, from: current)
            let migrated = try ConversationIdentity.migrated(source)
            var stored = current
            if source.identityVersion != 2 {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT key,value FROM state WHERE key LIKE 'archiveSummary:%'", -1, &statement, nil) == SQLITE_OK else { throw ConversationIdentity.invalidStorage }
                var summaries: [(String, ArchiveSummaryRecord)] = []
                defer { sqlite3_finalize(statement) }
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    guard let key = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { throw ConversationIdentity.invalidStorage }
                    var record = try JSONDecoder().decode(ArchiveSummaryRecord.self,
                        from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
                    let storageKey = String(cString: key)
                    guard storageKey == "archiveSummary:" + record.threadID else { throw ConversationIdentity.invalidStorage }
                    if record.status == .generating { record.status = .uncertain }
                    else if record.status == .queued || record.status == .reading { record.status = .stale }
                    summaries.append((storageKey, record))
                    result = sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else { throw ConversationIdentity.invalidStorage }
                for (key, record) in summaries { try putRaw(db, key: key, bytes: JSONEncoder().encode(record)) }
                // Migration keeps every chat's session (legacy chats gain their own ID), so the identity check is tautological here.
                stored = try JSONEncoder().encode(migrated)
                try putRaw(db, key: "app", bytes: stored)
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ConversationIdentity.invalidStorage }
            app = CachedApp(bytes: stored, state: migrated)
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }

    private func cachedApp(_ db: OpaquePointer) throws -> CachedApp {
        if let app { return app }
        let loaded: CachedApp
        if let data = try bytes(db: db, key: "app") {
            loaded = CachedApp(bytes: data, state: try ConversationIdentity.migrated(JSONDecoder().decode(SavedState.self, from: data)))
        } else { loaded = CachedApp(bytes: nil, state: nil) }
        app = loaded
        return loaded
    }

    /// Identity check against the cached old state, then the write. Callers update the cache after their commit.
    private func putApp(_ db: OpaquePointer, bytes: Data, state: SavedState) throws {
        if let old = try cachedApp(db).state {
            let previous = Dictionary(uniqueKeysWithValues: old.chats.map { ($0.id, $0.nativeSession) })
            for chat in state.chats where previous.keys.contains(chat.id) {
                guard previous[chat.id] == chat.nativeSession else { throw ConversationIdentity.invalidStorage }
            }
        }
        try putRaw(db, key: "app", bytes: bytes)
    }

    private func checkIdentity(_ db: OpaquePointer, conversationID: String, source: AgentSessionReference) throws {
        guard try cachedApp(db).state?.chats.first(where: { $0.id == conversationID })?.nativeSession == source else {
            throw ConversationIdentity.invalidStorage
        }
    }

    public func load() throws -> SavedState {
        try withDatabase { db in try cachedApp(db).state ?? SavedState() }
    }
    public func save(_ state: SavedState) throws {
        let migrated = try ConversationIdentity.migrated(state)
        let bytes = try JSONEncoder().encode(migrated)
        try withDatabase { db in
            if try cachedApp(db).bytes == bytes { return }
            try putApp(db, bytes: bytes, state: migrated)
            app = CachedApp(bytes: bytes, state: migrated)
        }
    }
    public func saveDeletingChat(_ state: SavedState, threadID: String) throws {
        let migrated = try ConversationIdentity.migrated(state)
        let bytes = try JSONEncoder().encode(migrated)
        try withDatabase { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось начать удаление чата", "Could not begin deleting the chat"))
            }
            do {
                try putApp(db, bytes: bytes, state: migrated)
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, "DELETE FROM state WHERE key=? OR key=? OR key=? OR key=? OR key=? OR key=?", -1, &statement, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось удалить метрики чата", "Could not delete chat metrics"))
                }
                let key = "usage:" + threadID
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                _ = ("timing:" + threadID).withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
                _ = ("archiveSummary:" + threadID).withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
                _ = ("transcript:" + threadID).withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
                _ = ("transcript-revision:" + threadID).withCString { sqlite3_bind_text(statement, 5, $0, -1, transient) }
                _ = ("turnChanges:" + threadID).withCString { sqlite3_bind_text(statement, 6, $0, -1, transient) }
                guard sqlite3_step(statement) == SQLITE_DONE,
                      sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось сохранить удаление чата", "Could not save the chat deletion"))
                }
                app = CachedApp(bytes: bytes, state: migrated)
                // Pending items of a deleted chat are dropped with it.
                dropTranscript(threadID)
                transcriptRevisions[threadID, default: 0] += 1
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }
    public func saveUsage(threadID: String, snapshot: UsageSnapshot) throws {
        try put(key: "usage:" + threadID, bytes: JSONEncoder().encode(snapshot))
    }

    public func loadArchiveSummaries() throws -> [String: ArchiveSummaryRecord] {
        try withDatabase { db in
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key LIKE 'archiveSummary:%'", -1, &statement, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось прочитать итоги", "Could not read summaries"))
            }
            var result: [String: ArchiveSummaryRecord] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
                let value = try JSONDecoder().decode(ArchiveSummaryRecord.self,
                    from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
                result[value.threadID] = value
            }
            return result
        }
    }

    public func saveArchiveSummary(_ record: ArchiveSummaryRecord) throws {
        try put(key: "archiveSummary:" + record.threadID, bytes: JSONEncoder().encode(record))
    }

    /// The archive flag and durable pending work must commit together.
    public func saveArchivingChat(_ state: SavedState, summary: ArchiveSummaryRecord?) throws {
        try saveArchivingChats(state, summaries: summary.map { [$0] } ?? [])
    }
    public func saveArchivingChats(_ state: SavedState, summaries: [ArchiveSummaryRecord]) throws {
        let migrated = try ConversationIdentity.migrated(state)
        let bytes = try JSONEncoder().encode(migrated)
        try withDatabase { db in
            let failure = ClientFailure(L10n.text("Не удалось сохранить архив", "Could not save archive"))
            try transaction(db, failure: failure) {
                try putApp(db, bytes: bytes, state: migrated)
                for summary in summaries { try putRaw(db, key: "archiveSummary:" + summary.threadID, bytes: JSONEncoder().encode(summary)) }
            }
            app = CachedApp(bytes: bytes, state: migrated)
            // An archived chat records nothing more: its pending items are written now, not at the next interval.
            for chat in migrated.chats where chat.isArchived && transcripts[chat.id]?.dirty == true {
                do { try flushEntry(db, chat.id); cancelFlush(chat.id) }
                catch { Self.log.error("Transcript flush failed for \(chat.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
    public func loadUsage() throws -> [String: UsageSnapshot] {
        try withDatabase { db in
            var s: OpaquePointer?; defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT key,value FROM state WHERE key LIKE 'usage:%'", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка чтения метрик", "Could not read metrics")) }
            var values: [String: UsageSnapshot] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let key = sqlite3_column_text(s, 0), let bytes = sqlite3_column_blob(s, 1) {
                    let id = String(cString: key).dropFirst(6)
                    values[String(id)] = try JSONDecoder().decode(UsageSnapshot.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 1))))
                }
            }
            return values
        }
    }
    public func saveTiming(threadID: String, turnID: String, timing: ResponseTiming) throws {
        var timings = try loadTimings(threadID: threadID)
        timings[turnID] = timing
        try put(key: "timing:" + threadID, bytes: JSONEncoder().encode(timings))
    }
    /// Timings with each turn's checkpoint changes attached; a turn with changes but no timing gets none.
    public func loadTimings(threadID: String) throws -> [String: ResponseTiming] {
        try withDatabase { db in
            guard let data = try bytes(db: db, key: "timing:" + threadID) else { return [:] }
            var timings = try JSONDecoder().decode([String: ResponseTiming].self, from: data)
            for (turn, changes) in try turnChanges(db, threadID) where timings[turn] != nil { timings[turn]?.changes = changes }
            return timings
        }
    }
    /// Kept apart from timings: the checkpoint finishes after the turn, and a late token update rewrites the timing.
    public func saveTurnChanges(threadID: String, turnID: String, changes: TurnChanges) throws {
        try withDatabase { db in
            var all = try turnChanges(db, threadID)
            all[turnID] = changes
            try putRaw(db, key: "turnChanges:" + threadID, bytes: JSONEncoder().encode(all))
        }
    }
    private func turnChanges(_ db: OpaquePointer, _ threadID: String) throws -> [String: TurnChanges] {
        guard let data = try bytes(db: db, key: "turnChanges:" + threadID) else { return [:] }
        return (try? JSONDecoder().decode([String: TurnChanges].self, from: data)) ?? [:]
    }

    // MARK: Transcripts

    /// A late backfill must not overwrite a newer captured revision. Identical content (same revision and
    /// completeness as the stored stamp) is not rewritten; a full snapshot replaces pending recorded items.
    /// An archived chat whose stored transcript was reduced stays reduced: a history refresh (opening the archived
    /// chat) brings the engine's full bodies back, and they are reduced again before the write.
    public func saveTranscript(_ snapshot: AgentTranscriptSnapshot) throws {
        guard snapshot.version == AgentTranscriptSnapshot.schemaVersion else { throw ConversationIdentity.invalidStorage }
        let id = snapshot.conversation.value
        try withDatabase { db in
            try checkIdentity(db, conversationID: id, source: snapshot.source)
            if let entry = transcripts[id] {
                guard entry.snapshot.source == snapshot.source else { throw ConversationIdentity.invalidStorage }
                if entry.capturedAt > snapshot.capturedAt { return }
            } else if let stamp = try storedStamp(db, id) {
                // The stored blob passed the same identity check when it was written, so its source matches.
                if stamp.capturedAt > snapshot.capturedAt { return }
            } else if let previous = try transcriptEntry(db, id) {
                guard previous.snapshot.source == snapshot.source else { throw ConversationIdentity.invalidStorage }
                if previous.capturedAt > snapshot.capturedAt { return }
            }
            var snapshot = try carryingCompactions(db, snapshot)
            if try storedStamp(db, id)?.reduced == true, try isArchived(db, id) { snapshot = try ActivityRetention.reduce(snapshot) }
            _ = try writeTranscript(db, snapshot)
            cancelFlush(id)
            try insertEntry(db, id, TranscriptEntry(snapshot: snapshot, capturedAt: snapshot.capturedAt))
            transcriptRevisions[id, default: 0] += 1
        }
    }
    public func loadTranscript(conversationID: String) throws -> AgentTranscriptSnapshot? {
        try withDatabase { db in
            guard let entry = try transcriptEntry(db, conversationID) else { return nil }
            try checkIdentity(db, conversationID: conversationID, source: entry.snapshot.source)
            return try materialized(conversationID)
        }
    }
    /// Undecoded transcript blobs for the chat search index, which checks identity itself; pending items are written first.
    public func transcriptBlobs(conversationIDs: [String]) throws -> [String: Data] {
        try withDatabase { db in
            for id in conversationIDs where transcripts[id]?.dirty == true { try flushEntry(db, id); cancelFlush(id) }
            var result: [String: Data] = [:]
            for id in conversationIDs { result[id] = try bytes(db: db, key: "transcript:" + id) }
            return result
        }
    }
    /// Merges the item into the cached transcript and schedules its write (one pending flush per chat, see `scheduleFlush`).
    /// An item identical to the one already merged changes nothing: no revision, no write.
    public func recordTranscriptItem(_ item: TranscriptItem, conversationID: String, source: AgentSessionReference) throws {
        try withDatabase { db in
            try checkIdentity(db, conversationID: conversationID, source: source)
            var entry = try transcriptEntry(db, conversationID)
                ?? TranscriptEntry(snapshot: try LocalHistory.snapshot(conversation: ConversationID(conversationID), source: source, items: []),
                                   capturedAt: .distantPast)
            guard entry.snapshot.source == source else { throw ConversationIdentity.invalidStorage }
            let now = Date()
            if entry.capturedAt > now { return }
            var items = entry.items ?? LocalHistory.items(entry.snapshot)
            let capped = ActivityRetention.cap(item)
            // Cheap check before any re-encode: engines repeat finished items, which would only re-hash the same snapshot.
            if let index = items.firstIndex(where: { $0.id == capped.id }) {
                var merged = [items[index]]
                TranscriptItem.merge(capped, into: &merged)
                if merged == [items[index]] { return }
            }
            TranscriptItem.merge(capped, into: &items)
            entry.items = items; entry.snapshotStale = true; entry.dirty = true; entry.capturedAt = now
            try insertEntry(db, conversationID, entry)
            transcriptRevisions[conversationID, default: 0] += 1
            scheduleFlush(conversationID)
        }
    }
    /// Writes the chat's pending recorded items now (a chat switch); nothing when none are pending.
    public func flushTranscript(conversationID id: String) async {
        guard transcripts[id]?.dirty == true else { return }
        cancelFlush(id)
        do { try withDatabase { db in try flushEntry(db, id) } }
        catch { Self.log.error("Transcript flush failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }
    /// Writes every pending recorded item now. Failures are logged; the items stay pending for the next flush.
    public func flushTranscripts() async {
        let dirty = transcripts.filter { $0.value.dirty }.map(\.key)
        for id in dirty {
            cancelFlush(id)
            do { try withDatabase { db in try flushEntry(db, id) } }
            catch { Self.log.error("Transcript flush failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The first item into a clean chat is written after `flushDelay`; while the chat keeps recording, the next write
    /// waits until `flushInterval` after the previous one, so a streaming turn costs one blob rewrite per interval.
    private func scheduleFlush(_ id: String) {
        guard flushTasks[id] == nil else { return }
        var delay = flushDelay
        if let last = lastFlush[id] { delay = max(delay, flushInterval - (ContinuousClock.now - last)) }
        flushTasks[id] = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushScheduled(id)
        }
    }
    private func flushScheduled(_ id: String) {
        flushTasks[id] = nil
        guard transcripts[id]?.dirty == true else { return }
        do { try withDatabase { db in try flushEntry(db, id) } }
        catch { Self.log.error("Transcript flush failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }
    private func cancelFlush(_ id: String) {
        flushTasks[id]?.cancel(); flushTasks[id] = nil
    }

    /// A history refresh replaces the stored transcript, but Codex history returns compaction items without the sizes
    /// recorded live; they are kept from the stored items. The stored blob is read only when such an item lacks them.
    private func carryingCompactions(_ db: OpaquePointer, _ snapshot: AgentTranscriptSnapshot) throws -> AgentTranscriptSnapshot {
        guard snapshot.items.contains(where: { $0.presentation?.kind == "compaction" && $0.presentation?.compaction == nil }),
              let previous = try transcriptEntry(db, snapshot.conversation.value) else { return snapshot }
        var items = LocalHistory.items(snapshot)
        guard ContextCompaction.carry(from: previous.items ?? LocalHistory.items(previous.snapshot), into: &items) else { return snapshot }
        return try LocalHistory.snapshot(conversation: snapshot.conversation, source: snapshot.source, items: items,
                                         completeness: snapshot.completeness, capturedAt: snapshot.capturedAt)
    }
    /// Cached entry, or the decoded blob inserted into the cache; nil when no transcript is stored.
    private func transcriptEntry(_ db: OpaquePointer, _ id: String) throws -> TranscriptEntry? {
        if let entry = transcripts[id] { touch(id); return entry }
        guard let data = try bytes(db: db, key: "transcript:" + id) else { return nil }
        let snapshot = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: data)
        guard snapshot.version == AgentTranscriptSnapshot.schemaVersion, snapshot.conversation.value == id else {
            throw ConversationIdentity.invalidStorage
        }
        let entry = TranscriptEntry(snapshot: snapshot, capturedAt: snapshot.capturedAt)
        try insertEntry(db, id, entry)
        return entry
    }
    private func materialized(_ id: String) throws -> AgentTranscriptSnapshot {
        guard var entry = transcripts[id] else { throw ConversationIdentity.invalidStorage }
        if entry.snapshotStale, let items = entry.items {
            entry.snapshot = try LocalHistory.snapshot(conversation: ConversationID(id), source: entry.snapshot.source,
                                                       items: items, capturedAt: entry.capturedAt)
            entry.snapshotStale = false
            transcripts[id] = entry
        }
        return entry.snapshot
    }
    private func flushEntry(_ db: OpaquePointer, _ id: String) throws {
        guard transcripts[id]?.dirty == true else { return }
        let perfSpan = Perf.span("store.flush", id: id); var blobBytes: Int?; defer { perfSpan.end(blobBytes.map { "\($0) bytes" } ?? "unchanged") }
        let snapshot = try materialized(id)
        blobBytes = try writeTranscript(db, snapshot)
        transcripts[id]?.dirty = false
        lastFlush[id] = .now
    }
    /// Blob and stamp commit together. Returns the blob size, or nil when the stored content already matches.
    @discardableResult
    private func writeTranscript(_ db: OpaquePointer, _ snapshot: AgentTranscriptSnapshot) throws -> Int? {
        let id = snapshot.conversation.value
        let stamp = TranscriptStamp(snapshot)
        if let stored = try storedStamp(db, id), stored.matches(snapshot) {
            // Keep the capturedAt rule exact: a newer capture of the same content still wins over a later backfill.
            // A stamp from before the retention rule learns whether the content is reduced.
            if snapshot.capturedAt > stored.capturedAt || stored.reduced != stamp.reduced {
                try putRaw(db, key: "transcript-revision:" + id, bytes: JSONEncoder().encode(stamp))
                stamps[id] = stamp
            }
            return nil
        }
        let bytes = try JSONEncoder().encode(snapshot)
        let stampBytes = try JSONEncoder().encode(stamp)
        try transaction(db, failure: ClientFailure(L10n.text("Не удалось сохранить историю чата", "Could not save the chat history"))) {
            try putRaw(db, key: "transcript:" + id, bytes: bytes)
            try putRaw(db, key: "transcript-revision:" + id, bytes: stampBytes)
        }
        stamps[id] = stamp
        transcriptWriteCount += 1
        return bytes.count
    }
    private func isArchived(_ db: OpaquePointer, _ id: String) throws -> Bool {
        try cachedApp(db).state?.chats.first { $0.id == id }?.isArchived == true
    }

    // MARK: Retention

    /// Rewrites an archived chat's stored transcript with its tool bodies reduced to headline and metadata
    /// (`ActivityRetention.reduce`). Returns the blob size before and after, or nil when nothing is stored or the stored
    /// stamp already says the blob is reduced (the cheap check the launch cleanup relies on). A blob without bodies
    /// only gets its stamp updated, so the next pass skips the decode.
    public func reduceTranscript(conversationID id: String) throws -> (before: Int, after: Int)? {
        try withDatabase { db in
            if try storedStamp(db, id)?.reduced == true { return nil }
            guard let entry = try transcriptEntry(db, id) else { return nil }
            try checkIdentity(db, conversationID: id, source: entry.snapshot.source)
            if entry.dirty { try flushEntry(db, id); cancelFlush(id) }
            let snapshot = try materialized(id)
            let before = try bytes(db: db, key: "transcript:" + id)?.count ?? 0
            let reduced = try ActivityRetention.reduce(snapshot)
            // Same revision: no bodies to drop; the stamp alone was refreshed.
            guard let after = try writeTranscript(db, reduced) else { return nil }
            try insertEntry(db, id, TranscriptEntry(snapshot: reduced, capturedAt: reduced.capturedAt))
            transcriptRevisions[id, default: 0] += 1
            return (before, after)
        }
    }

    /// Share of the file held by free pages (`PRAGMA freelist_count` over `PRAGMA page_count`).
    public func freeSpaceFraction() throws -> Double {
        try withDatabase { db in
            let free = try Self.pragma(db, "freelist_count"), pages = try Self.pragma(db, "page_count")
            return pages > 0 ? Double(free) / Double(pages) : 0
        }
    }

    /// `VACUUM` when more than `threshold` of the file is free, then truncates the write-ahead log. The caller decides
    /// when the app is idle; the work runs on this actor, off the main actor. Returns true when the file was rebuilt.
    public func vacuumIfFragmented(threshold: Double = 0.25) throws -> Bool {
        guard try freeSpaceFraction() > threshold else { return false }
        try withDatabase { db in
            guard sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось сжать хранилище", "Could not compact storage"))
            }
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        }
        return true
    }

    private static func pragma(_ db: OpaquePointer, _ name: String) throws -> Int64 {
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA " + name, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw ClientFailure(L10n.text("Ошибка чтения", "Could not read data"))
        }
        return sqlite3_column_int64(statement, 0)
    }
    private func storedStamp(_ db: OpaquePointer, _ id: String) throws -> TranscriptStamp? {
        if let stamp = stamps[id] { return stamp }
        guard let data = try bytes(db: db, key: "transcript-revision:" + id),
              let stamp = try? JSONDecoder().decode(TranscriptStamp.self, from: data) else { return nil }
        stamps[id] = stamp
        return stamp
    }
    private func touch(_ id: String) {
        transcriptOrder.removeAll { $0 == id }; transcriptOrder.append(id)
    }
    /// Inserts as most recently used; evicts the least recently used entries beyond the limit, writing pending items first.
    private func insertEntry(_ db: OpaquePointer, _ id: String, _ entry: TranscriptEntry) throws {
        transcripts[id] = entry; touch(id)
        while transcripts.count > Self.transcriptCacheLimit, let victim = transcriptOrder.first, victim != id {
            try flushEntry(db, victim)
            cancelFlush(victim)
            transcripts[victim] = nil; transcriptOrder.removeFirst()
        }
    }
    private func dropTranscript(_ id: String) {
        cancelFlush(id)
        transcripts[id] = nil; stamps[id] = nil; lastFlush[id] = nil
        transcriptOrder.removeAll { $0 == id }
    }
    /// Memory pressure: drops every cached transcript except `kept` (the open chat); entries with pending items stay
    /// until their write. A dropped transcript is re-read from the file on demand.
    public func releaseCachedTranscripts(keeping kept: String?) {
        for (id, entry) in transcripts where id != kept && !entry.dirty { transcripts[id] = nil }
        transcriptOrder.removeAll { transcripts[$0] == nil }
    }
    /// Test seam: transcripts held in the cache.
    var cachedTranscriptCount: Int { transcripts.count }
    /// Pending items survive a cache reset; everything else is re-read from the file on demand.
    private func dropCleanTranscripts() {
        for (id, entry) in transcripts where !entry.dirty { transcripts[id] = nil }
        transcriptOrder.removeAll { transcripts[$0] == nil }
    }

    // MARK: Rows

    private func put(key: String, bytes: Data) throws {
        try withDatabase { db in try putRaw(db, key: key, bytes: bytes) }
    }
    private func putRaw(_ db: OpaquePointer, key: String, bytes: Data) throws {
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка сохранения", "Could not save data")) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(s, 1, $0, -1, transient) }
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ClientFailure(L10n.text("Не удалось сохранить состояние", "Could not save state")) }
    }
}
