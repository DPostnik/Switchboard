import Foundation
import Testing
import SQLite3
import AgentContract
@testable import ContextCore

private func auditDatabase(_ file: URL, sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else { throw ClientFailure("Fixture database open failed") }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ClientFailure("Fixture SQL failed") }
}

@Test func capabilityLedgerMigratesOldRowsAndKeepsLegacyWritersCompatible() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ledger.sqlite")
    let oldColumns = "date, chat, run, project, role, agent, tool, capability, target, decision, turn, audit"
    let oldValues = "\(Date().timeIntervalSince1970), 'chat', NULL, NULL, 'developer', 'codex', 'commandExecution', 'shell', 'echo old', 'asked', 'turn', 0"
    try auditDatabase(file, sql: """
        CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL NOT NULL, chat TEXT, run TEXT, project TEXT,
            role TEXT NOT NULL, agent TEXT NOT NULL, tool TEXT NOT NULL, capability TEXT NOT NULL, target TEXT, decision TEXT NOT NULL, turn TEXT, audit INTEGER NOT NULL);
        INSERT INTO decisions (\(oldColumns)) VALUES (\(oldValues));
        """)
    let ledger = CapabilityLedger(file: file)
    let before = try await ledger.recent(days: 1)
    #expect(before.count == 1 && before[0].target == "echo old")
    #expect(before[0].requestID == nil && before[0].source == nil && before[0].stage == nil && before[0].outcome == nil && before[0].reason == nil)
    let record = AgentCapabilityRecord(tool: "mcpElicitation", capability: .other, decision: .answered, turn: "turn",
        requestID: "interaction-1", source: "mcpServer/elicitation/request", stage: .responded, outcome: .unknown, ruleID: "rule-fixture",
        reason: "backslash")
    await ledger.record(.init(chatID: "chat", runID: nil, projectID: nil, roleID: "developer", agent: "codex", record: record, audit: false))
    await ledger.flush()
    // Old versions omit the new nullable columns and still write successfully.
    try auditDatabase(file, sql: "INSERT INTO decisions (\(oldColumns)) VALUES (\(oldValues));")
    let rows = try await CapabilityLedger(file: file).recent(days: 1)
    let migrated = try #require(rows.first { $0.requestID == "interaction-1" })
    #expect(rows.count == 3)
    #expect(migrated.source == record.source && migrated.stage == .responded && migrated.outcome == .unknown && migrated.ruleID == "rule-fixture" && migrated.reason == "backslash")
    #expect(await ledger.lastError == nil)
    #expect(try await ledger.interruptions(days: 1) == 0)
}

@Test func capabilityLedgerCountsOnlyDistinctPresentedInterruptions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = CapabilityLedger(file: root.appendingPathComponent("ledger.sqlite"))
    func write(stage: AgentCapabilityRecord.Stage?, id: String? = "one", chat: String = "chat", agent: String = "codex",
               audit: Bool = false, date: Date = Date()) async {
        await ledger.record(.init(date: date, chatID: chat, runID: nil, projectID: nil, roleID: "developer", agent: agent,
            record: .init(tool: "interaction", capability: .other, decision: .asked, requestID: id,
                          source: "mcpServer/elicitation/request", stage: stage), audit: audit))
    }
    await write(stage: .requested)
    await write(stage: .presented)
    await write(stage: .presented) // Duplicate UI delivery does not add an interruption.
    await write(stage: .responded)
    await write(stage: .resolved)
    await write(stage: nil, id: nil) // Legacy asked rows cannot establish presentation.
    await write(stage: .presented, id: "audit", audit: true) // A real prompt still interrupts in audit mode.
    await write(stage: .presented, id: "old", date: Date().addingTimeInterval(-8 * 86_400))
    await write(stage: .presented, id: nil)
    await write(stage: .presented, chat: "another-chat")
    await write(stage: .presented, agent: "claude")
    #expect(try await ledger.interruptions(days: 7) == 4)
    #expect(try await ledger.interruptions(days: 14) == 5)
}

@Test func capabilityAuditDecodesLegacyJSONWithoutLifecycleMetadata() throws {
    let data = Data(#"{"tool":"Bash","capability":"shell","decision":"used"}"#.utf8)
    let record = try JSONDecoder().decode(AgentCapabilityRecord.self, from: data)
    #expect(record.stage == nil && record.outcome == nil && record.requestID == nil && record.source == nil && record.ruleID == nil)
    #expect(record.reason == nil)
    let withReason = AgentCapabilityRecord(tool: "Bash", capability: .shell, decision: .asked, reason: "substitution")
    let decoded = try JSONDecoder().decode(AgentCapabilityRecord.self, from: JSONEncoder().encode(withReason))
    #expect(decoded.reason == "substitution" && decoded == withReason)
}

/// A ledger written by the build before `reason` (lifecycle columns present, no `reason`) gains the column on open;
/// old rows read back with no reason and new rows round-trip it.
@Test func capabilityLedgerAddsReasonColumnToLifecycleSchema() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ledger.sqlite")
    let columns = "date, chat, run, project, role, agent, tool, capability, target, decision, turn, audit, request_id, source, stage, outcome, rule_id"
    try auditDatabase(file, sql: """
        CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL NOT NULL, chat TEXT, run TEXT, project TEXT,
            role TEXT NOT NULL, agent TEXT NOT NULL, tool TEXT NOT NULL, capability TEXT NOT NULL, target TEXT, decision TEXT NOT NULL, turn TEXT,
            audit INTEGER NOT NULL, request_id TEXT, source TEXT, stage TEXT, outcome TEXT, rule_id TEXT);
        INSERT INTO decisions (\(columns)) VALUES (\(Date().timeIntervalSince1970), 'chat', NULL, NULL, 'developer', 'claude', 'Bash', 'shell',
            'echo old', 'asked', 'turn', 0, 'old-request', 'can_use_tool', 'requested', NULL, NULL);
        """)
    let ledger = CapabilityLedger(file: file)
    let old = try #require(try await ledger.recent(days: 1).first)
    #expect(old.requestID == "old-request" && old.reason == nil)
    for reason in ["cliAskedSandboxed", "denyList"] {
        await ledger.record(.init(chatID: "chat", runID: nil, projectID: nil, roleID: "developer", agent: "claude",
            record: .init(tool: "Bash", capability: .shell, target: reason, decision: .allowed, reason: reason), audit: false))
    }
    await ledger.flush()
    // The previous build's writer omits `reason` and still inserts.
    try auditDatabase(file, sql: "INSERT INTO decisions (\(columns)) VALUES (\(Date().timeIntervalSince1970), 'chat', NULL, NULL, 'developer', 'claude', 'Bash', 'shell', 'echo legacy', 'asked', 'turn', 0, NULL, NULL, NULL, NULL, NULL);")
    let rows = try await CapabilityLedger(file: file).recent(days: 1)
    #expect(rows.count == 4)
    let reasons = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.target.map { ($0, row.reason ?? "-") } })
    #expect(reasons == ["echo old": "-", "cliAskedSandboxed": "cliAskedSandboxed", "denyList": "denyList", "echo legacy": "-"])
    #expect(await ledger.lastError == nil)
}
