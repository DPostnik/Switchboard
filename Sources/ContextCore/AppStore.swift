import Foundation
import CSQLite
import AgentContract

/// App-owned metadata, readable snapshots and portable work. Engines retain native execution state and credentials.
public actor AppStore {
    private let file: URL
    /// Bumped on every transcript write or delete so readers can skip re-decoding unchanged transcripts.
    private var transcriptRevisions: [String: Int] = [:]
    public init(file: URL) { self.file = file }
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
    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ClientFailure(L10n.text("Не удалось открыть хранилище", "Could not open storage"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw ClientFailure(L10n.text("Не удалось подготовить хранилище", "Could not prepare storage"))
        }
        try migrateIdentities(db)
        return try operation(db)
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

    /// All old IDs become app IDs without renaming. Existing job JSON references
    /// therefore remain valid throughout the SQLite transaction, including a crash.
    private func migrateIdentities(_ db: OpaquePointer) throws {
        guard let data = try bytes(db: db, key: "app") else { return }
        let existing = try JSONDecoder().decode(SavedState.self, from: data)
        if existing.identityVersion == 2 { _ = try ConversationIdentity.migrated(existing); return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ConversationIdentity.invalidStorage }
        do {
            // Re-read after acquiring the write lock; another process may have migrated.
            guard let current = try bytes(db: db, key: "app") else { throw ConversationIdentity.invalidStorage }
            let source = try JSONDecoder().decode(SavedState.self, from: current)
            let migrated = try ConversationIdentity.migrated(source)
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
                for (key, record) in summaries { try put(db: db, key: key, bytes: JSONEncoder().encode(record)) }
                try put(db: db, key: "app", bytes: JSONEncoder().encode(migrated))
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ConversationIdentity.invalidStorage }
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
    public func load() throws -> SavedState {
        try withDatabase { db in
            var s: OpaquePointer?; defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key='app'", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка чтения", "Could not read data")) }
            if sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) {
                return try ConversationIdentity.migrated(JSONDecoder().decode(SavedState.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))))
            }
            return SavedState()
        }
    }
    public func save(_ state: SavedState) throws {
        try put(key: "app", bytes: JSONEncoder().encode(ConversationIdentity.migrated(state)))
    }
    public func saveDeletingChat(_ state: SavedState, threadID: String) throws {
        let bytes = try JSONEncoder().encode(ConversationIdentity.migrated(state))
        try withDatabase { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось начать удаление чата", "Could not begin deleting the chat"))
            }
            do {
                try put(db: db, key: "app", bytes: bytes)
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, "DELETE FROM state WHERE key=? OR key=? OR key=? OR key=?", -1, &statement, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось удалить метрики чата", "Could not delete chat metrics"))
                }
                let key = "usage:" + threadID
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                _ = ("timing:" + threadID).withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
                _ = ("archiveSummary:" + threadID).withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
                _ = ("transcript:" + threadID).withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
                guard sqlite3_step(statement) == SQLITE_DONE,
                      sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось сохранить удаление чата", "Could not save the chat deletion"))
                }
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
        try withDatabase { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось сохранить архив", "Could not save archive"))
            }
            do {
                try put(db: db, key: "app", bytes: JSONEncoder().encode(ConversationIdentity.migrated(state)))
                for summary in summaries { try put(db: db, key: "archiveSummary:" + summary.threadID, bytes: JSONEncoder().encode(summary)) }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось сохранить архив", "Could not save archive"))
                }
            } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
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
    public func loadTimings(threadID: String) throws -> [String: ResponseTiming] {
        try withDatabase { db in
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Ошибка чтения времени ответов", "Could not read response timing"))
            }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = ("timing:" + threadID).withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return [:] }
            return try JSONDecoder().decode([String: ResponseTiming].self,
                from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
    }

    /// A late backfill must not overwrite a newer captured revision.
    public func saveTranscript(_ snapshot: AgentTranscriptSnapshot) throws {
        guard snapshot.version == AgentTranscriptSnapshot.schemaVersion else { throw ConversationIdentity.invalidStorage }
        try withDatabase { db in
            guard let data = try bytes(db: db, key: "app"),
                  let chat = try JSONDecoder().decode(SavedState.self, from: data).chats.first(where: { $0.id == snapshot.conversation.value }),
                  chat.nativeSession == snapshot.source else { throw ConversationIdentity.invalidStorage }
            if let data = try bytes(db: db, key: "transcript:" + snapshot.conversation.value) {
                let previous = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: data)
                guard previous.version == AgentTranscriptSnapshot.schemaVersion, previous.source == snapshot.source else {
                    throw ConversationIdentity.invalidStorage
                }
                if previous.capturedAt > snapshot.capturedAt { return }
            }
            try put(db: db, key: "transcript:" + snapshot.conversation.value, bytes: JSONEncoder().encode(snapshot))
            transcriptRevisions[snapshot.conversation.value, default: 0] += 1
        }
    }
    public func loadTranscript(conversationID: String) throws -> AgentTranscriptSnapshot? {
        try withDatabase { db in
            guard let data = try bytes(db: db, key: "transcript:" + conversationID) else { return nil }
            let snapshot = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: data)
            guard snapshot.version == AgentTranscriptSnapshot.schemaVersion, snapshot.conversation.value == conversationID,
                  let app = try bytes(db: db, key: "app"),
                  try JSONDecoder().decode(SavedState.self, from: app).chats.first(where: { $0.id == conversationID })?.nativeSession == snapshot.source else {
                throw ConversationIdentity.invalidStorage
            }
            return snapshot
        }
    }
    /// Undecoded transcript blobs for the chat search index, which checks identity itself; one database open per batch.
    public func transcriptBlobs(conversationIDs: [String]) throws -> [String: Data] {
        try withDatabase { db in
            var result: [String: Data] = [:]
            for id in conversationIDs { result[id] = try bytes(db: db, key: "transcript:" + id) }
            return result
        }
    }
    public func recordTranscriptItem(_ item: TranscriptItem, conversationID: String, source: AgentSessionReference) throws {
        let previous = try loadTranscript(conversationID: conversationID)
        var items = previous.map(LocalHistory.items) ?? []
        TranscriptItem.merge(item, into: &items)
        try saveTranscript(LocalHistory.snapshot(conversation: ConversationID(conversationID), source: source, items: items))
    }
    private func put(key: String, bytes: Data) throws {
        try withDatabase { db in try put(db: db, key: key, bytes: bytes) }
    }
    private func put(db: OpaquePointer, key: String, bytes: Data) throws {
        if key == "app", let oldBytes = try self.bytes(db: db, key: key) {
            let old = try ConversationIdentity.migrated(JSONDecoder().decode(SavedState.self, from: oldBytes))
            let new = try ConversationIdentity.migrated(JSONDecoder().decode(SavedState.self, from: bytes))
            let previous = Dictionary(uniqueKeysWithValues: old.chats.map { ($0.id, $0.nativeSession) })
            for chat in new.chats where previous.keys.contains(chat.id) {
                guard previous[chat.id] == chat.nativeSession else { throw ConversationIdentity.invalidStorage }
            }
        }
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка сохранения", "Could not save data")) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(s, 1, $0, -1, transient) }
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ClientFailure(L10n.text("Не удалось сохранить состояние", "Could not save state")) }
    }
}
