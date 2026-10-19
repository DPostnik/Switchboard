@testable import CodexAdapter
import Foundation
import Testing
@testable import ContextCore

@Test func optimisticMessagesReconcileWithoutDuplicates() {
    var items = [TranscriptItem(id: "local-user:1", kind: "user", text: "Ещё", phase: "Отправляется…"),
                 TranscriptItem(id: "local-user:2", kind: "user", text: "Ещё", phase: "Отправляется…")]
    let first = TranscriptItem(id: "server-1", kind: "user", text: "Ещё")
    TranscriptItem.merge(first, into: &items)
    TranscriptItem.merge(first, into: &items)
    #expect(items.count == 2)
    #expect(items[1].id == "local-user:2")
    TranscriptItem.merge(TranscriptItem(id: "server-2", kind: "user", text: "Ещё"), into: &items)
    #expect(items.map(\.id) == ["server-1", "server-2"])
    #expect(items.allSatisfy { $0.phase == nil })
}

@Test func usageDoesNotDoubleCountCachedTokens() throws {
    let event = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"tokenUsage":{"last":{"totalTokens":250},"total":{"inputTokens":1000,"cachedInputTokens":700,"outputTokens":90,"reasoningOutputTokens":50},"modelContextWindow":1000}}"#.utf8))
    let usage = CodexDecoding.usageSnapshot(event: event)
    #expect(usage.contextFraction == 0.25)
    #expect(usage.uncached == 300)
    #expect(usage.output == 90)
    #expect(CodexDecoding.usageSnapshot(event: .object([:])).contextFraction == nil)
    #expect(CodexDecoding.usageSnapshot(event: .object([:])).input == nil)
}

@Test func databasePreservesProjectAndThreadIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = AppStore(file: directory.appendingPathComponent("state.sqlite"))
    var state = SavedState()
    var project = Project(path: "/tmp/example")
    project.accessMode = .fullAccess
    state.projects = [project]
    state.chats = [Chat(id: "thread-1", projectID: project.id, title: "Привет", model: "model")]
    try await database.save(state)
    let reopened = AppStore(file: directory.appendingPathComponent("state.sqlite"))
    let restored = try await reopened.load()
    #expect(restored.projects == state.projects)
    #expect(restored.chats == state.chats)
    state.chats[0].title = "Новое имя"
    try await reopened.save(state)
    #expect(try await database.load().chats[0].title == "Новое имя")
    let snapshot = UsageSnapshot(measuredAt: Date(timeIntervalSince1970: 10))
    try await database.saveUsage(threadID: "thread-1", snapshot: snapshot)
    #expect(try await reopened.loadUsage()["thread-1"] == snapshot)
}

@Test func accessModeMigrationAndProjectIsolation() throws {
    let legacy = Data(#"{"projects":[{"id":"00000000-0000-0000-0000-000000000001","name":"legacy","path":"/tmp/legacy"}],"chats":[],"model":""}"#.utf8)
    var state = try JSONDecoder().decode(SavedState.self, from: legacy)
    #expect((state.projects[0].accessMode ?? .standard) == .standard)
    state.projects[0].accessMode = .fullAccess
    state.projects.append(Project(path: "/tmp/another"))
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    #expect(restored.projects[0].accessMode == .fullAccess)
    #expect((restored.projects[1].accessMode ?? .standard) == .standard)
    let full = AgentRoleCatalog.preset(AccessMode.fullAccess.legacyRoleID).profile.codexTurnParameters(projectPath: "/tmp/legacy")
    #expect(full["approvalPolicy"]?.string == "never")
    #expect(full["sandboxPolicy"]?["type"].string == "dangerFullAccess")
    let standard = AgentRoleCatalog.preset(AccessMode.standard.legacyRoleID).profile.codexTurnParameters(projectPath: "/tmp/another")
    #expect(standard["approvalPolicy"]?.string == "on-request")
    #expect(standard["sandboxPolicy"]?["type"].string == "workspaceWrite")
    #expect(standard["sandboxPolicy"]?["writableRoots"].array == [.string("/tmp/another")])
}

@Test func schedulesReadMultilineTomlWithoutWriting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let job = root.appendingPathComponent("job")
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    let source = """
    version = 1
    id = "job"
    name = "Проверка"
    kind = "heartbeat"
    status = "ACTIVE"
    rrule = "FREQ=HOURLY;INTERVAL=2"
    """ + "\nprompt = \"\"\"\nПервая строка\nВторая строка\n\"\"\"\n"
    let file = job.appendingPathComponent("automation.toml")
    try Data(source.utf8).write(to: file)
    let result = ScheduledJobs.read(directory: root)
    #expect(result.count == 1)
    #expect(result[0].prompt == "Первая строка\nВторая строка\n")
    #expect(result[0].schedule == "Каждые 2 ч.")
    #expect(result[0].issue == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == source)
    try Data("malformed = [".utf8).write(to: file)
    #expect(ScheduledJobs.read(directory: root).first?.issue != nil)
    #expect(ScheduledJobs.readableSchedule("FREQ=HOURLY;BYMINUTE=30") == "FREQ=HOURLY;BYMINUTE=30")
}

@Test func compactionAppearsInTranscript() throws {
    let raw: JSONValue = .object(["id": .string("compaction-1"), "type": .string("contextCompaction")])
    #expect(CodexDecoding.transcriptItem(raw)?.kind == "compaction")
    #expect(CodexDecoding.transcriptItem(.object(["id": .string("unknown"), "type": .string("future")])) == nil)
}
