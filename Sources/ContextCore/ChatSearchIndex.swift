import Foundation
import CSQLite
import AgentContract
import os

/// Local full-text index of chat dialogue (plan `docs/agent-chat-search-plan.md`): user and assistant text only,
/// no tool output. The app keeps it current from saved transcripts; the archive search and the chat-search MCP
/// tools read it. Owner-only file in the app folder; deleting it only costs a rebuild.
public actor ChatSearchIndex {
    public static let fileName = "chat-index.sqlite"
    /// Bump to rebuild every chat after a schema or extraction change.
    static let schemaVersion = "2"
    /// Longer messages (pasted logs) are cut; the start carries the meaning.
    public static let messageLimit = 20_000

    /// What the index stores about a chat besides its messages.
    public struct ChatInfo: Sendable, Equatable {
        public var id: String
        public var projectID: String
        public var project: String
        public var projectPath: String
        public var title: String
        public var agent: String
        public var archived: Bool
        public var updated: Date
        /// Overview and goals of the archive summary, when one is ready.
        public var summary: String
        public var session: AgentSessionReference?
        public init(id: String, projectID: String, project: String, projectPath: String, title: String, agent: String,
                    archived: Bool, updated: Date, summary: String = "", session: AgentSessionReference?) {
            self.id = id; self.projectID = projectID; self.project = project; self.projectPath = projectPath; self.title = title
            self.agent = agent; self.archived = archived; self.updated = updated; self.summary = summary; self.session = session
        }
    }

    public struct Hit: Sendable, Equatable {
        public var chatID: String
        public var snippet: String
    }

    /// Chats whose messages must be read again, chats with changed metadata only, and chats to drop.
    public struct Plan: Sendable, Equatable {
        public var content: [String] = []
        public var metadata: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { content.isEmpty && metadata.isEmpty && removed.isEmpty }
    }

    /// Owns one SQLite handle and closes it when released, so the actor needs no deinit of its own.
    private final class Connection {
        let db: OpaquePointer
        init(db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close(db) }
    }

    private let file: URL
    /// Opened on first use and kept for the actor's lifetime; dropped after a failed call so the next call reopens.
    private var connection: Connection?
    /// Searches run on their own read-only connection, so a query never waits behind `index()` (WAL lets it read
    /// the last commit while a write is in progress).
    private let reader: Reader
    /// The newest search per scope; an older one still running in that scope stops at its next progress check.
    private let generations = OSAllocatedUnfairLock(initialState: [String: UInt64]())
    public init(file: URL) { self.file = file; reader = Reader(file: file) }

    public func plan(_ chats: [ChatInfo]) throws -> Plan {
        try withDatabase { db in
            var stored: [String: (content: Double, updated: Double, info: ChatInfo)] = [:]
            try Self.query(db, "SELECT id, project_id, project, project_path, title, agent, archived, updated, summary, content_updated FROM chats") { row in
                let info = ChatInfo(id: row.text(0), projectID: row.text(1), project: row.text(2), projectPath: row.text(3), title: row.text(4),
                                    agent: row.text(5), archived: row.int(6) != 0, updated: Date(timeIntervalSince1970: row.double(7)),
                                    summary: row.text(8), session: nil)
                stored[info.id] = (row.double(9), row.double(7), info)
            }
            var plan = Plan()
            for chat in chats {
                guard let old = stored.removeValue(forKey: chat.id) else { plan.content.append(chat.id); continue }
                // Times are compared as the stored seconds: `Date(timeIntervalSince1970:)` does not round-trip about half of all values.
                let updated = chat.updated.timeIntervalSince1970
                var comparable = chat; comparable.session = nil; comparable.updated = old.info.updated
                if old.content != updated { plan.content.append(chat.id) }
                else if old.updated != updated || old.info != comparable { plan.metadata.append(chat.id) }
            }
            plan.removed = stored.keys.sorted()
            return plan
        }
    }

    /// Replaces the messages of each chat from its saved transcript blob. A missing or foreign blob indexes the title only.
    public func index(_ chats: [(info: ChatInfo, transcript: Data?)]) throws {
        let decoder = JSONDecoder()
        let prepared = chats.map { chat in (chat.info, Self.messages(chat.transcript, info: chat.info, decoder: decoder)) }
        try withDatabase { db in
            try Self.transaction(db) {
                for (info, messages) in prepared {
                    try Self.removeRows(db, id: info.id)
                    try Self.insertChat(db, info, messages: messages)
                }
            }
        }
    }

    public func updateMetadata(_ chats: [ChatInfo]) throws {
        try withDatabase { db in
            try Self.transaction(db) {
                for info in chats {
                    try Self.run(db, "UPDATE chats SET project_id=?, project=?, project_path=?, title=?, agent=?, archived=?, updated=?, summary=? WHERE id=?",
                                 [info.projectID, info.project, info.projectPath, info.title, info.agent, info.archived ? 1 : 0,
                                  info.updated.timeIntervalSince1970, info.summary, info.id])
                    try Self.deleteMessages(db, id: info.id, below: 0)
                    try Self.insertMessages(db, chatID: info.id, Self.headerRows(info))
                }
            }
        }
    }

    public func remove(_ ids: [String]) throws {
        try withDatabase { db in try Self.transaction(db) { for id in ids { try Self.removeRows(db, id: id) } } }
    }

    /// Best match per chat, best chats first. Every word must occur, each as a word prefix. When every word has at
    /// most two characters, the newest matching messages come first instead: ranking thousands of matches costs
    /// more than it tells. A search whose task is cancelled, or which a newer search in the same `scope` replaces,
    /// stops early and throws `CancellationError`.
    public nonisolated func search(_ text: String, limit: Int = 300, scope: String? = nil) async throws -> [Hit] {
        try await search(text, limit: limit, interrupt: interrupt(scope: scope))
    }

    /// A stop signal for a new search; it also fires once a later search in the same scope begins.
    nonisolated func interrupt(scope: String?) -> Interrupt {
        guard let scope else { return Interrupt { false } }
        let generation = generations.withLock { $0[scope, default: 0] += 1; return $0[scope]! }
        return Interrupt { [generations] in generations.withLock { $0[scope] } != generation }
    }

    nonisolated func search(_ text: String, limit: Int, interrupt: Interrupt) async throws -> [Hit] {
        guard let match = Self.matchQuery(text) else { return [] }
        let perfSpan = Perf.span("search.index", id: "\(text.count) chars"); defer { perfSpan.end() }
        let terms = Self.terms(text)
        return try await withTaskCancellationHandler {
            try await reader.search(match: match, recent: terms.allSatisfy { $0.count <= 2 }, terms: terms, limit: limit, interrupt: interrupt)
        } onCancel: { interrupt.cancel() }
    }

    /// Searchable words as `matchQuery` keeps them.
    static func terms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
    }

    /// Set once a search should stop; SQLite's progress handler reads it between virtual machine steps.
    final class Interrupt: Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)
        private let superseded: @Sendable () -> Bool
        init(superseded: @escaping @Sendable () -> Bool) { self.superseded = superseded }
        func cancel() { cancelled.withLock { $0 = true } }
        var isSet: Bool { cancelled.withLock { $0 } || superseded() }
    }

    /// Owns the read-only search connection. Opened on first use; a missing file means the index is not built yet.
    private actor Reader {
        let file: URL
        private var connection: Connection?
        init(file: URL) { self.file = file }

        func search(match: String, recent: Bool, terms: [String], limit: Int, interrupt: Interrupt) throws -> [Hit] {
            guard !interrupt.isSet, !Task.isCancelled else { throw CancellationError() }
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            let connection = try connection ?? open()
            let db = connection.db
            let context = Unmanaged.passUnretained(interrupt).toOpaque()
            sqlite3_progress_handler(db, 1000, { context in
                Unmanaged<Interrupt>.fromOpaque(context!).takeUnretainedValue().isSet ? 1 : 0
            }, context)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            do {
                return try withExtendedLifetime(interrupt) {
                    // Rank without snippets, keep the best row per chat, then read only those rows' text by rowid:
                    // FTS5's snippet() over every ranked row was most of the time.
                    var best: [(row: Int, chat: String)] = [], seen: Set<String> = []
                    let order = recent ? "rowid DESC" : "bm25(messages)"
                    try ChatSearchIndex.query(db, "SELECT rowid, chat_id FROM messages WHERE messages MATCH ? ORDER BY \(order) LIMIT 3000", [match]) { row in
                        guard best.count < limit else { return }
                        let id = row.text(1)
                        if seen.insert(id).inserted { best.append((row.int(0), id)) }
                    }
                    guard !best.isEmpty else { return [] }
                    var texts: [Int: String] = [:]
                    try ChatSearchIndex.query(db, "SELECT rowid, text FROM messages WHERE rowid IN (\(best.map { String($0.row) }.joined(separator: ",")))") { row in
                        texts[row.int(0)] = row.text(1)
                    }
                    if interrupt.isSet { throw CancellationError() }
                    return best.map { Hit(chatID: $0.chat, snippet: ChatSearchIndex.snippet(texts[$0.row] ?? "", terms: terms)) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if interrupt.isSet || sqlite3_errcode(db) == SQLITE_INTERRUPT { throw CancellationError() }
                self.connection = nil
                throw error
            }
        }

        private func open() throws -> Connection {
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                throw ChatSearchIndex.failure
            }
            let connection = Connection(db: db)
            sqlite3_busy_timeout(db, 5000)
            self.connection = connection
            return connection
        }
    }

    /// About `tokens` words of `text` around the first word that starts with a query term, with `…` where text was
    /// left out: the window FTS5's `snippet()` would choose for a single match. Line breaks become spaces.
    static func snippet(_ text: String, terms: [String], tokens: Int = 12) -> String {
        let scalars = text.unicodeScalars
        func isToken(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.isASCII {
                let value = scalar.value
                return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber, .privateUse, .nonspacingMark, .spacingMark: return true
            default: return false
            }
        }
        // The earliest occurrence of a term at the start of a word.
        var hit: String.Index?
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            let upper = hit ?? text.endIndex
            while from < upper, let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<upper) {
                if range.lowerBound == text.startIndex || !isToken(scalars[scalars.index(before: range.lowerBound)]) { hit = range.lowerBound; break }
                from = scalars.index(after: range.lowerBound)
            }
        }
        var start = hit ?? text.startIndex
        // Move to the start of a word if the text begins with separators.
        while start < text.endIndex, !isToken(scalars[start]) { start = scalars.index(after: start) }
        guard start < text.endIndex else { return text.replacingOccurrences(of: "\n", with: " ") }
        // Word starts before the hit (nearest first), one more than a window can use, so a cut is visible.
        var before: [String.Index] = []
        var cursor = start
        while before.count < tokens, cursor > text.startIndex {
            var index = scalars.index(before: cursor)
            while index > text.startIndex, !isToken(scalars[index]) { index = scalars.index(before: index) }
            guard isToken(scalars[index]) else { break }
            while index > text.startIndex, isToken(scalars[scalars.index(before: index)]) { index = scalars.index(before: index) }
            before.append(index); cursor = index
        }
        // Word ends from the hit on, again one more than needed.
        var ends: [String.Index] = []
        cursor = start
        while ends.count <= tokens, cursor < text.endIndex {
            while cursor < text.endIndex, !isToken(scalars[cursor]) { cursor = scalars.index(after: cursor) }
            guard cursor < text.endIndex else { break }
            while cursor < text.endIndex, isToken(scalars[cursor]) { cursor = scalars.index(after: cursor) }
            ends.append(cursor)
        }
        // FTS5 centres a single hit, then shifts the window back when the text ends sooner.
        let lead = min(before.count, max((tokens - 1) / 2, tokens - ends.count))
        let taken = min(tokens - lead, ends.count)
        let from = lead > 0 ? before[lead - 1] : start
        let to = ends[taken - 1]
        let cutBefore = before.count > lead, cutAfter = ends.count > taken
        let body = String(text[from..<to]).replacingOccurrences(of: "\n", with: " ")
        return (cutBefore ? "…" : "") + body + (cutAfter ? "…" : "")
    }

    /// Text columns of every row of `sql`; tests read query plans, pragmas and counts through it.
    func rows(_ sql: String) throws -> [[String]] {
        try withDatabase { db in
            var rows: [[String]] = []
            try Self.query(db, sql) { row in rows.append((0..<row.count).map(row.text)) }
            return rows
        }
    }

    /// FTS5 query for free text: each word becomes a quoted prefix term, all required. Nil when nothing is searchable.
    public static func matchQuery(_ text: String) -> String? {
        let words = terms(text)
        return words.isEmpty ? nil : words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: Extraction

    /// Only the fields the index needs; decoding skips presentation detail and tool output.
    private struct LightSnapshot: Decodable {
        struct Item: Decodable {
            struct Presentation: Decodable { let timing: ResponseTiming? }
            let kind: AgentTranscriptItem.Kind
            let text: String
            let presentation: Presentation?
        }
        let version: Int
        let conversation: ConversationID
        let source: AgentSessionReference
        let items: [Item]
    }

    struct Message: Equatable { var role: String; var text: String; var date: Date? }

    static func messages(_ data: Data?, info: ChatInfo, decoder: JSONDecoder) -> [Message] {
        guard let data, let snapshot = try? decoder.decode(LightSnapshot.self, from: data),
              snapshot.version == AgentTranscriptSnapshot.schemaVersion, snapshot.conversation.value == info.id,
              snapshot.source == info.session else { return [] }
        return snapshot.items.compactMap { item in
            guard item.kind == .user || item.kind == .assistant else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Message(role: item.kind.rawValue, text: text.count > messageLimit ? String(text.prefix(messageLimit)) : text,
                           date: item.presentation?.timing?.completedAt)
        }
    }

    // MARK: Storage

    /// One searchable row of `messages`; header rows carry negative positions.
    private struct MessageRow { var position: Int; var role: String; var date: Double?; var text: String }

    /// `chat_id` is unindexed in the FTS5 table, so deletes go through the rowids recorded in `message_rows`
    /// instead of scanning every message. Positions below `?` select the rows: 0 for the header only.
    static let deleteMessagesSQL = "DELETE FROM messages WHERE rowid IN (SELECT row FROM message_rows WHERE chat_id=? AND position<?)"
    private static let deleteRecordsSQL = "DELETE FROM message_rows WHERE chat_id=? AND position<?"

    private static func insertChat(_ db: OpaquePointer, _ info: ChatInfo, messages: [Message]) throws {
        let first = messages.first { $0.role == "user" }.map { String($0.text.prefix(300)) } ?? ""
        // 0 when no message carries a time; date filters then rely on the last activity alone.
        let started = messages.lazy.compactMap(\.date).first?.timeIntervalSince1970 ?? 0
        try run(db, """
            INSERT INTO chats (id, project_id, project, project_path, title, agent, archived, updated, summary, content_updated, started, message_count, first_request)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [info.id, info.projectID, info.project, info.projectPath, info.title, info.agent, info.archived ? 1 : 0,
                  info.updated.timeIntervalSince1970, info.summary, info.updated.timeIntervalSince1970, started, messages.count, first])
        let rows = messages.enumerated().map { position, message in
            MessageRow(position: position, role: message.role, date: message.date?.timeIntervalSince1970, text: message.text)
        }
        try insertMessages(db, chatID: info.id, headerRows(info) + rows)
    }

    /// Title and summary are searchable rows with negative positions, so a title match ranks with the text.
    private static func headerRows(_ info: ChatInfo) -> [MessageRow] {
        var rows = [MessageRow(position: -1, role: "title", date: nil, text: info.title)]
        if !info.summary.isEmpty { rows.append(MessageRow(position: -2, role: "summary", date: nil, text: info.summary)) }
        return rows
    }

    /// Every inserted message records its rowid, which later deletes look up by chat.
    private static func insertMessages(_ db: OpaquePointer, chatID: String, _ rows: [MessageRow]) throws {
        try prepare(db, "INSERT INTO messages (chat_id, position, role, date, text) VALUES (?,?,?,?,?)") { insert in
            try prepare(db, "INSERT INTO message_rows (chat_id, row, position) VALUES (?,?,?)") { record in
                for row in rows {
                    try step(insert, [chatID, row.position, row.role, row.date, row.text])
                    try step(record, [chatID, Int(sqlite3_last_insert_rowid(db)), row.position])
                }
            }
        }
    }

    private static func deleteMessages(_ db: OpaquePointer, id: String, below position: Int) throws {
        try run(db, deleteMessagesSQL, [id, position])
        try run(db, deleteRecordsSQL, [id, position])
    }

    private static func removeRows(_ db: OpaquePointer, id: String) throws {
        try deleteMessages(db, id: id, below: Int.max)
        try run(db, "DELETE FROM chats WHERE id=?", [id])
    }

    /// Runs `operation` on the actor's connection, opening it on the first call. A failed call drops the handle,
    /// so a broken connection is replaced on the next call instead of being reused.
    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let connection = try connection ?? open()
        do { return try operation(connection.db) }
        catch { self.connection = nil; throw error }
    }

    private func open() throws -> Connection {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw Self.failure }
        let connection = Connection(db: db)
        sqlite3_busy_timeout(db, 5000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Readers in other processes (the chat tools) keep working while this process writes.
        try Self.exec(db, "PRAGMA journal_mode=WAL")
        var version: String?
        if (try? Self.query(db, "SELECT value FROM meta WHERE key='schema'", [], { version = $0.text(0) })) == nil || version != Self.schemaVersion {
            try Self.exec(db, """
                DROP TABLE IF EXISTS message_rows; DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS chats; DROP TABLE IF EXISTS meta;
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE chats (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, project TEXT NOT NULL, project_path TEXT NOT NULL,
                    title TEXT NOT NULL, agent TEXT NOT NULL, archived INTEGER NOT NULL, updated REAL NOT NULL, summary TEXT NOT NULL,
                    content_updated REAL NOT NULL, started REAL NOT NULL, message_count INTEGER NOT NULL, first_request TEXT NOT NULL);
                CREATE VIRTUAL TABLE messages USING fts5(chat_id UNINDEXED, position UNINDEXED, role UNINDEXED, date UNINDEXED, text,
                    tokenize='unicode61 remove_diacritics 2');
                CREATE TABLE message_rows (chat_id TEXT NOT NULL, row INTEGER NOT NULL, position INTEGER NOT NULL);
                CREATE INDEX message_rows_chat ON message_rows (chat_id);
                INSERT INTO meta (key, value) VALUES ('schema', '\(Self.schemaVersion)');
                """)
        }
        self.connection = connection
        return connection
    }

    static let failure = ClientFailure(L10n.text("Не удалось открыть индекс поиска по чатам", "Could not open the chat search index"))

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure }
    }

    private static func transaction(_ db: OpaquePointer, _ body: () throws -> Void) throws {
        try exec(db, "BEGIN IMMEDIATE")
        do { try body(); try exec(db, "COMMIT") } catch { try? exec(db, "ROLLBACK"); throw error }
    }

    private struct Row {
        let statement: OpaquePointer
        var count: Int32 { sqlite3_column_count(statement) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure }
        try body(statement)
    }

    private static func bind(_ statement: OpaquePointer, _ values: [Any?]) {
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String: _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private static func step(_ statement: OpaquePointer, _ values: [Any?]) throws {
        bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure }
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [Any?]) throws {
        try prepare(db, sql) { try step($0, values) }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ values: [Any?] = [], _ each: (Row) -> Void) throws {
        try prepare(db, sql) { statement in
            bind(statement, values)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw failure }
                each(Row(statement: statement))
            }
        }
    }
}
