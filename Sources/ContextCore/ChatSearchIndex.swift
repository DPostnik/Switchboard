import Foundation
import CSQLite
import AgentContract

/// Local full-text index of chat dialogue (plan `docs/agent-chat-search-plan.md`): user and assistant text only,
/// no tool output. The app keeps it current from saved transcripts; the archive search and the chat-search MCP
/// tools read it. Owner-only file in the app folder; deleting it only costs a rebuild.
public actor ChatSearchIndex {
    public static let fileName = "chat-index.sqlite"
    /// Bump to rebuild every chat after a schema or extraction change.
    static let schemaVersion = "1"
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

    private let file: URL
    public init(file: URL) { self.file = file }

    public func plan(_ chats: [ChatInfo]) throws -> Plan {
        try withDatabase { db in
            var stored: [String: (content: Double, info: ChatInfo)] = [:]
            try Self.query(db, "SELECT id, project_id, project, project_path, title, agent, archived, updated, summary, content_updated FROM chats") { row in
                let info = ChatInfo(id: row.text(0), projectID: row.text(1), project: row.text(2), projectPath: row.text(3), title: row.text(4),
                                    agent: row.text(5), archived: row.int(6) != 0, updated: Date(timeIntervalSince1970: row.double(7)),
                                    summary: row.text(8), session: nil)
                stored[info.id] = (row.double(9), info)
            }
            var plan = Plan()
            for chat in chats {
                guard let old = stored.removeValue(forKey: chat.id) else { plan.content.append(chat.id); continue }
                var comparable = chat; comparable.session = nil
                if old.content != chat.updated.timeIntervalSince1970 { plan.content.append(chat.id) }
                else if old.info != comparable { plan.metadata.append(chat.id) }
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
                    try Self.run(db, "DELETE FROM messages WHERE chat_id=? AND position<0", [info.id])
                    try Self.insertHeader(db, info)
                }
            }
        }
    }

    public func remove(_ ids: [String]) throws {
        try withDatabase { db in try Self.transaction(db) { for id in ids { try Self.removeRows(db, id: id) } } }
    }

    /// Best match per chat, best chats first. Every word must occur, each as a word prefix.
    public func search(_ text: String, limit: Int = 300) throws -> [Hit] {
        guard let match = Self.matchQuery(text) else { return [] }
        return try withDatabase { db in
            var hits: [Hit] = [], seen: Set<String> = []
            try Self.query(db, "SELECT chat_id, snippet(messages, 4, '', '', '…', 12) FROM messages WHERE messages MATCH ? ORDER BY bm25(messages) LIMIT 3000",
                           [match]) { row in
                let id = row.text(0)
                guard hits.count < limit, seen.insert(id).inserted else { return }
                hits.append(Hit(chatID: id, snippet: row.text(1).replacingOccurrences(of: "\n", with: " ")))
            }
            return hits
        }
    }

    /// FTS5 query for free text: each word becomes a quoted prefix term, all required. Nil when nothing is searchable.
    public static func matchQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
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

    private static func insertChat(_ db: OpaquePointer, _ info: ChatInfo, messages: [Message]) throws {
        let first = messages.first { $0.role == "user" }.map { String($0.text.prefix(300)) } ?? ""
        // 0 when no message carries a time; date filters then rely on the last activity alone.
        let started = messages.lazy.compactMap(\.date).first?.timeIntervalSince1970 ?? 0
        try run(db, """
            INSERT INTO chats (id, project_id, project, project_path, title, agent, archived, updated, summary, content_updated, started, message_count, first_request)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [info.id, info.projectID, info.project, info.projectPath, info.title, info.agent, info.archived ? 1 : 0,
                  info.updated.timeIntervalSince1970, info.summary, info.updated.timeIntervalSince1970, started, messages.count, first])
        try insertHeader(db, info)
        try prepare(db, "INSERT INTO messages (chat_id, position, role, date, text) VALUES (?,?,?,?,?)") { statement in
            for (position, message) in messages.enumerated() {
                try step(statement, [info.id, position, message.role, message.date?.timeIntervalSince1970, message.text])
            }
        }
    }

    /// Title and summary are searchable rows with negative positions, so a title match ranks with the text.
    private static func insertHeader(_ db: OpaquePointer, _ info: ChatInfo) throws {
        try run(db, "INSERT INTO messages (chat_id, position, role, date, text) VALUES (?,?,?,?,?)", [info.id, -1, "title", nil, info.title])
        if !info.summary.isEmpty {
            try run(db, "INSERT INTO messages (chat_id, position, role, date, text) VALUES (?,?,?,?,?)", [info.id, -2, "summary", nil, info.summary])
        }
    }

    private static func removeRows(_ db: OpaquePointer, id: String) throws {
        try run(db, "DELETE FROM messages WHERE chat_id=?", [id])
        try run(db, "DELETE FROM chats WHERE id=?", [id])
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw Self.failure }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var version: String?
        if (try? Self.query(db, "SELECT value FROM meta WHERE key='schema'", [], { version = $0.text(0) })) == nil || version != Self.schemaVersion {
            try Self.exec(db, """
                DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS chats; DROP TABLE IF EXISTS meta;
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE chats (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, project TEXT NOT NULL, project_path TEXT NOT NULL,
                    title TEXT NOT NULL, agent TEXT NOT NULL, archived INTEGER NOT NULL, updated REAL NOT NULL, summary TEXT NOT NULL,
                    content_updated REAL NOT NULL, started REAL NOT NULL, message_count INTEGER NOT NULL, first_request TEXT NOT NULL);
                CREATE VIRTUAL TABLE messages USING fts5(chat_id UNINDEXED, position UNINDEXED, role UNINDEXED, date UNINDEXED, text,
                    tokenize='unicode61 remove_diacritics 2');
                INSERT INTO meta (key, value) VALUES ('schema', '\(Self.schemaVersion)');
                """)
        }
        return try operation(db)
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
