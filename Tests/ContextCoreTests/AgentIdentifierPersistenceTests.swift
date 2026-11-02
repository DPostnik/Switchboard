import Foundation
import Testing
@testable import ContextCore

// Stage B: persisted agent identifiers are open strings. Values written before the change decode unchanged,
// and a value from a newer build (another agent) survives a load and save instead of failing or turning into Codex.

private func storedJob(engine: String) -> String {
    """
    {"id":"7D1B4E0C-6A51-4F44-9C3B-2B1D7E5F0A11","name":"Digest","prompt":"Read, never send.","engine":"\(engine)",
     "projectID":"0B6B9C55-7A9E-4C1F-8E52-3F1A2B3C4D5E","model":"m","effort":"medium","route":"direct",
     "schedule":{"rule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","timeZone":"Europe/Warsaw"},"enabled":true,"sourceDisabled":false}
    """
}

private func storedLedger(engine: String) -> Data {
    Data("""
    {"version":1,"jobs":[\(storedJob(engine: engine))],
     "runs":[{"id":"5C2A0A63-1F0E-4C55-9F3E-6D7A8B9C0D1E","jobID":"7D1B4E0C-6A51-4F44-9C3B-2B1D7E5F0A11","engine":"\(engine)",
              "name":"Digest","started":0,"status":"completed","output":""}]}
    """.utf8)
}

@Test(arguments: ["codex", "claude"])
func storedJobEnginesDecodeUnchanged(engine: String) throws {
    let ledger = try JSONDecoder().decode(JobLedger.self, from: storedLedger(engine: engine))
    let expected: JobEngine = engine == "codex" ? .codex : .claude
    #expect(ledger.jobs.first?.engine == expected && ledger.runs.first?.engine == expected)
    // Encoding writes the same plain string under the same key.
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any]
    let job = (object?["jobs"] as? [[String: Any]])?.first, run = (object?["runs"] as? [[String: Any]])?.first
    #expect(job?["engine"] as? String == engine && run?["engine"] as? String == engine)
}

@Test func unknownJobEngineSurvivesAndNeverRunsAsCodex() throws {
    let ledger = try JSONDecoder().decode(JobLedger.self, from: storedLedger(engine: "gemini"))
    let engine = try #require(ledger.jobs.first?.engine)
    #expect(engine.rawValue == "gemini" && engine != .codex && engine != .claude && !JobEngine.known.contains(engine))
    #expect(engine.title == "gemini" && engine.agentID == AgentID(rawValue: "gemini"))
    let again = try JSONDecoder().decode(JobLedger.self, from: JSONEncoder().encode(ledger))
    #expect(again.jobs.first?.engine.rawValue == "gemini" && again.runs.first?.engine.rawValue == "gemini")
    // The legacy values keep their agent identities.
    #expect(JobEngine.codex.agentID == .codex && JobEngine.claude.agentID == .claudeCode)
}

@Test func storedLedgerLoadsThroughTheJobStoreUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("scheduled-jobs.json")
    try storedLedger(engine: "claude").write(to: file)
    let ledger = try await JobStore(file: file).load()
    #expect(ledger.jobs.map(\.engine) == [.claude] && ledger.runs.map(\.engine) == [.claude])
    #expect(ledger.jobs.first?.name == "Digest" && ledger.jobs.first?.enabled == true)
}

@Test func agentRequestsCannotCreateJobsOnUnknownEngines() throws {
    let project = ScheduleProject(id: UUID(), path: "/tmp")
    let schedule = JobSchedule(rule: "FREQ=DAILY;BYHOUR=8;BYMINUTE=0", timeZone: "Europe/Warsaw")
    for engine in JobEngine.known {
        let input = ScheduleCreate(name: "Digest", prompt: "Read.", engine: engine, projectID: project.id, schedule: schedule, model: "m", effort: "medium")
        #expect(try ScheduleControl.created(input, project: project).engine == engine)
    }
    let unknown = ScheduleCreate(name: "Digest", prompt: "Read.", engine: JobEngine(rawValue: "gemini"), projectID: project.id,
                                 schedule: schedule, model: "m", effort: "medium")
    #expect(throws: (any Error).self) { try ScheduleControl.created(unknown, project: project) }
}

@Test func storedChatsKeepTheirConnectionIdentity() throws {
    // Chats store `AgentConnectionID` as agent + UUID; an unregistered agent decodes as itself.
    let codex = Chat(session: AgentSessionReference(connection: .originalCodex, nativeID: "thread-1"), projectID: UUID(), title: "A", model: "m")
    let other = AgentConnectionID(agent: AgentID(rawValue: "gemini"), id: UUID())
    let gemini = Chat(session: AgentSessionReference(connection: other, nativeID: "session-1"), projectID: UUID(), title: "B", model: "m")
    let decoded = try JSONDecoder().decode([Chat].self, from: JSONEncoder().encode([codex, gemini]))
    #expect(decoded.map(\.nativeSession) == [codex.nativeSession, gemini.nativeSession])
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(codex)) as? [String: Any]
    let connection = (object?["nativeSession"] as? [String: Any])?["connection"] as? [String: Any]
    #expect(connection?["agent"] as? String == "codex" && connection?["id"] as? String == AgentConnectionID.originalCodex.id.uuidString)
}
