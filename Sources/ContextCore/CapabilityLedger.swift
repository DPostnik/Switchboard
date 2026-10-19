import Foundation
import SQLite3
import AgentContract

/// One recorded capability use or permission decision, with the chat, run and role it happened under.
public struct CapabilityDecision: Codable, Hashable, Sendable {
    public var date: Date
    public var chatID: String?
    public var runID: UUID?
    public var projectID: UUID?
    public var roleID: String
    /// `codex` or `claude`.
    public var agent: String
    public var tool: String
    public var capability: AgentCapabilityRecord.Capability
    public var target: String?
    public var decision: AgentCapabilityRecord.Decision
    public var turn: String?
    public var audit: Bool
    public init(date: Date = Date(), chatID: String?, runID: UUID?, projectID: UUID?, roleID: String, agent: String,
                record: AgentCapabilityRecord, audit: Bool) {
        self.date = date; self.chatID = chatID; self.runID = runID; self.projectID = projectID; self.roleID = roleID; self.agent = agent
        self.tool = record.tool; self.capability = record.capability; self.target = record.target; self.decision = record.decision
        self.turn = record.turn; self.audit = audit
    }
}

/// A daily count kept for a year after the raw rows are gone.
public struct CapabilityDailyCount: Codable, Hashable, Sendable {
    public var day: String
    public var projectID: UUID?
    public var roleID: String
    public var agent: String
    public var capability: AgentCapabilityRecord.Capability
    public var decision: AgentCapabilityRecord.Decision
    public var count: Int
}

/// Phase 0 of the roles plan: every decision is a row, written in batches off the main actor, never blocking a decision.
/// Raw rows live 30 days (hard cap 500,000, oldest first); daily aggregates live one year.
public actor CapabilityLedger {
    public static let rawRetention: TimeInterval = 30 * 86_400
    public static let aggregateRetention: TimeInterval = 366 * 86_400
    public static let rawLimit = 500_000
    static let batchLimit = 200
    private let file: URL
    private var buffer: [CapabilityDecision] = []
    private var flushTask: Task<Void, Never>?
    private let flushDelay: Duration
    /// Write failures are reported once per failure streak, not per row.
    public private(set) var lastError: String?
    public init(file: URL, flushDelay: Duration = .seconds(1)) { self.file = file; self.flushDelay = flushDelay }

    public func record(_ decision: CapabilityDecision) {
        buffer.append(decision)
        if buffer.count >= Self.batchLimit { flushTask?.cancel(); flushTask = nil; flushNow(); return }
        guard flushTask == nil else { return }
        let delay = flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.flushScheduled()
        }
    }
    private func flushScheduled() { flushTask = nil; flushNow() }
    public func flush() { flushTask?.cancel(); flushTask = nil; flushNow() }
    private func flushNow() {
        guard !buffer.isEmpty else { return }
        let rows = buffer; buffer.removeAll()
        do { try withDatabase { db in try Self.insert(rows, db: db) }; lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    /// Start-up maintenance: drop raw rows past retention or beyond the cap, and aggregates past a year.
    public func sweep(now: Date = Date()) throws {
        flush()
        try withDatabase { db in
            try Self.exec(db, "DELETE FROM decisions WHERE date < \(now.timeIntervalSince1970 - Self.rawRetention)")
            try Self.exec(db, "DELETE FROM decisions WHERE id <= (SELECT id FROM decisions ORDER BY id DESC LIMIT 1 OFFSET \(Self.rawLimit))")
            try Self.exec(db, "DELETE FROM daily WHERE day < '\(Self.day(now.addingTimeInterval(-Self.aggregateRetention)))'")
        }
    }

    public func recent(days: Int, limit: Int = 2000) throws -> [CapabilityDecision] {
        flush()
        return try withDatabase { db in
            let since = Date().timeIntervalSince1970 - Double(days) * 86_400
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT date, chat, run, project, role, agent, tool, capability, target, decision, turn, audit FROM decisions WHERE date >= ? ORDER BY id DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw Self.failure }
            sqlite3_bind_double(statement, 1, since); sqlite3_bind_int(statement, 2, Int32(limit))
            var result: [CapabilityDecision] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let capability = AgentCapabilityRecord.Capability(rawValue: Self.text(statement, 7) ?? ""),
                      let decision = AgentCapabilityRecord.Decision(rawValue: Self.text(statement, 9) ?? "") else { continue }
                let record = AgentCapabilityRecord(tool: Self.text(statement, 6) ?? "", capability: capability, target: Self.text(statement, 8), decision: decision, turn: Self.text(statement, 10))
                result.append(CapabilityDecision(date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)), chatID: Self.text(statement, 1),
                    runID: Self.text(statement, 2).flatMap(UUID.init), projectID: Self.text(statement, 3).flatMap(UUID.init), roleID: Self.text(statement, 4) ?? "",
                    agent: Self.text(statement, 5) ?? "", record: record, audit: sqlite3_column_int(statement, 11) == 1))
            }
            return result
        }
    }

    public func daily(days: Int) throws -> [CapabilityDailyCount] {
        flush()
        return try withDatabase { db in
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT day, project, role, agent, capability, decision, count FROM daily WHERE day >= ? ORDER BY day DESC", -1, &statement, nil) == SQLITE_OK else { throw Self.failure }
            let since = Self.day(Date().addingTimeInterval(-Double(days) * 86_400))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = since.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            var result: [CapabilityDailyCount] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let capability = AgentCapabilityRecord.Capability(rawValue: Self.text(statement, 4) ?? ""),
                      let decision = AgentCapabilityRecord.Decision(rawValue: Self.text(statement, 5) ?? "") else { continue }
                result.append(.init(day: Self.text(statement, 0) ?? "", projectID: Self.text(statement, 1).flatMap(UUID.init), roleID: Self.text(statement, 2) ?? "",
                                    agent: Self.text(statement, 3) ?? "", capability: capability, decision: decision, count: Int(sqlite3_column_int64(statement, 6))))
            }
            return result
        }
    }

    public func count() throws -> Int {
        flush()
        return try withDatabase { db in
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM decisions", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw Self.failure }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - SQLite

    private static var failure: ClientFailure { ClientFailure(L10n.text("Не удалось записать журнал разрешений", "Could not write the permissions ledger")) }
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure }
    }
    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .iso8601); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw Self.failure }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        try Self.exec(db, """
            CREATE TABLE IF NOT EXISTS decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL NOT NULL, chat TEXT, run TEXT, project TEXT,
                role TEXT NOT NULL, agent TEXT NOT NULL, tool TEXT NOT NULL, capability TEXT NOT NULL, target TEXT, decision TEXT NOT NULL, turn TEXT, audit INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS decisions_date ON decisions(date);
            CREATE INDEX IF NOT EXISTS decisions_chat ON decisions(chat);
            CREATE TABLE IF NOT EXISTS daily (day TEXT NOT NULL, project TEXT NOT NULL, role TEXT NOT NULL, agent TEXT NOT NULL, capability TEXT NOT NULL,
                decision TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (day, project, role, agent, capability, decision));
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try operation(db)
    }
    private static func insert(_ rows: [CapabilityDecision], db: OpaquePointer) throws {
        try exec(db, "BEGIN IMMEDIATE")
        do {
            var insert: OpaquePointer?, upsert: OpaquePointer?
            defer { sqlite3_finalize(insert); sqlite3_finalize(upsert) }
            guard sqlite3_prepare_v2(db, "INSERT INTO decisions (date, chat, run, project, role, agent, tool, capability, target, decision, turn, audit) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", -1, &insert, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "INSERT INTO daily (day, project, role, agent, capability, decision, count) VALUES (?,?,?,?,?,?,1) ON CONFLICT(day, project, role, agent, capability, decision) DO UPDATE SET count = count + 1", -1, &upsert, nil) == SQLITE_OK else { throw failure }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
                if let value { _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) } } else { sqlite3_bind_null(statement, index) }
            }
            for row in rows {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                sqlite3_bind_double(insert, 1, row.date.timeIntervalSince1970)
                bind(insert, 2, row.chatID); bind(insert, 3, row.runID?.uuidString); bind(insert, 4, row.projectID?.uuidString)
                bind(insert, 5, row.roleID); bind(insert, 6, row.agent); bind(insert, 7, row.tool); bind(insert, 8, row.capability.rawValue)
                bind(insert, 9, row.target); bind(insert, 10, row.decision.rawValue); bind(insert, 11, row.turn)
                sqlite3_bind_int(insert, 12, row.audit ? 1 : 0)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure }
                sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                bind(upsert, 1, day(row.date)); bind(upsert, 2, row.projectID?.uuidString ?? ""); bind(upsert, 3, row.roleID)
                bind(upsert, 4, row.agent); bind(upsert, 5, row.capability.rawValue); bind(upsert, 6, row.decision.rawValue)
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw failure }
            }
            try exec(db, "COMMIT")
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
}
