@_spi(NativeProtocol) import CodexAdapter
import Foundation
import Testing
import AgentContract
import ContextCore
@testable import ContextDesk

@Test @MainActor func restartRequestsCoalesceAndCanBeCancelled() {
    let restart = AppRestartController()
    restart.enqueueRestart()
    restart.enqueueRestart()
    #expect(restart.requested)
    restart.cancel()
    #expect(!restart.requested)
    restart.terminating = true
    restart.enqueueRestart()
    #expect(!restart.requested)
}

@Test func restartHelperWaitsForOwnerAndPreservesLiteralPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("App ' quoted $(literal).app")
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["1"]
    try owner.run()
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", AppRestartController.helperScript.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch"),
                        "test-relaunch", String(owner.processIdentifier), marker.path]
    try helper.run()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    for _ in 0..<60 {
        if !helper.isRunning { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!helper.isRunning)
    if helper.isRunning { helper.terminate() }
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func restartHelperDoesNotReopenWhenOwnerStaysAlive() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    let script = AppRestartController.helperScript
        .replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch")
        .replacingOccurrences(of: "-ge 120", with: "-ge 2")
        .replacingOccurrences(of: "/bin/sleep 1", with: "/bin/sleep 0.01")
    helper.arguments = ["-c", script, "test-timeout", String(ProcessInfo.processInfo.processIdentifier), marker.path]
    try helper.run()
    for _ in 0..<50 {
        if !helper.isRunning { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!helper.isRunning)
    if helper.isRunning { helper.terminate() }
    else { #expect(helper.terminationStatus == 1) }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func restartContinuationMapsOnlyMatchingUnarchivedChats() {
    let project = UUID()
    let claude = Chat(session: .init(connection: .appClaude, nativeID: "claude-1"), projectID: project, title: "c", model: "")
    let codex = Chat(session: .init(connection: .originalCodex, nativeID: "thread-1"), projectID: project, title: "x", model: "")
    var archived = Chat(session: .init(connection: .appClaude, nativeID: "claude-2"), projectID: project, title: "a", model: "")
    archived.archived = true
    let chats = [claude, codex, archived]
    let info = RestartContinuation.requesterInfo(environment: ["CLAUDE_CODE_SESSION_ID": "claude-1", "CODEX_THREAD_ID": "", "PATH": "/bin"])
    #expect(info == [RestartContinuation.claudeSessionKey: "claude-1"])
    #expect(RestartContinuation.chatID(requestedBy: info, in: chats) == claude.id)
    #expect(RestartContinuation.chatID(requestedBy: [RestartContinuation.codexThreadKey: "thread-1"], in: chats) == codex.id)
    // A session ID never matches a chat of the other agent, an archived chat or an unknown session.
    #expect(RestartContinuation.chatID(requestedBy: [RestartContinuation.codexThreadKey: "claude-1"], in: chats) == nil)
    #expect(RestartContinuation.chatID(requestedBy: [RestartContinuation.claudeSessionKey: "claude-2"], in: chats) == nil)
    #expect(RestartContinuation.chatID(requestedBy: nil, in: chats) == nil)
    #expect(RestartContinuation.requesterInfo(environment: ["CLAUDE_CODE_SESSION_ID": String(repeating: "a", count: 129)]).isEmpty)
}

@Test func restartContinuationIsConsumedOnceAndExpires() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let now = Date()
    try RestartContinuation(chatIDs: ["a", "b"], requestedAt: now).save(to: url)
    #expect(RestartContinuation.take(from: url, now: now.addingTimeInterval(5)) == ["a", "b"])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(RestartContinuation.take(from: url, now: now).isEmpty)
    try RestartContinuation(chatIDs: ["a"], requestedAt: now).save(to: url)
    #expect(RestartContinuation.take(from: url, now: now.addingTimeInterval(RestartContinuation.maximumAge + 1)).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func restartCollectsSeveralRequestingChatsUntilCancelled() {
    let project = UUID()
    let first = Chat(session: .init(connection: .appClaude, nativeID: "claude-1"), projectID: project, title: "First", model: "")
    let second = Chat(id: "thread-2", projectID: project, title: "Second", model: "")
    let restart = AppRestartController()
    restart.record(requester: [RestartContinuation.claudeSessionKey: "claude-1"], chats: [first, second])
    restart.record(requester: [RestartContinuation.codexThreadKey: "thread-2"], chats: [first, second])
    restart.record(requester: [RestartContinuation.claudeSessionKey: "claude-1"], chats: [first, second])
    restart.record(requester: [RestartContinuation.codexThreadKey: "unknown"], chats: [first, second])
    restart.record(requester: nil, chats: [first, second])
    #expect(restart.requested)
    #expect(restart.continuationChatIDs == [first.id, second.id])
    #expect(restart.continuationTitles == [first.id: "First", second.id: "Second"])
    restart.cancel()
    #expect(restart.continuationChatIDs.isEmpty && restart.continuationTitles.isEmpty)
    restart.terminating = true
    restart.record(requester: [RestartContinuation.codexThreadKey: "thread-2"], chats: [first, second])
    #expect(restart.continuationChatIDs.isEmpty)
}

@Test @MainActor func restartContinuationIsDeliveredToEveryRequestingChat() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json, os, pathlib
    calls = pathlib.Path(os.environ['CODEX_HOME']) / 'calls.jsonl'
    turns = 0
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method = m['method']
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'turn/start':
            turns += 1
            result = {'turn': {'id': 'v' + str(turns)}}
        if method == 'test/requests':
            result = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        else:
            with calls.open('a') as log: log.write(json.dumps(m) + '\n')
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    let client = CodexClient(transport: connection)
    try await client.start(executable: executable, home: folder)
    let integration = CodexIntegration(client: client)
    defer { Task { await integration.disconnect() } }
    let model = DeskModel(connection: integration,
                          store: AppStore(file: folder.appendingPathComponent("state.sqlite")), summaryExecutable: executable, summaryHome: folder)
    model.state.defaultRoute = .direct
    let project = Project(path: folder.path)
    model.state.projects = [project]
    var archived = Chat(id: "c", projectID: project.id, title: "Archived", model: "")
    archived.archived = true
    model.state.chats = [Chat(id: "a", projectID: project.id, title: "A", model: ""),
                         Chat(id: "b", projectID: project.id, title: "B", model: ""), archived]
    model.connected = true; model.authenticated = true
    #expect(!model.hasDeliverableQueue)
    model.continueAfterRestart(["a", "b", "c", "missing"])
    #expect(Set(model.queuedMessages.map(\.threadID)) == ["a", "b"])
    #expect(model.queuedMessages.allSatisfy { $0.text == RestartContinuation.message })
    // Until the queued continuations are sent, a further restart must wait.
    #expect(model.hasDeliverableQueue)
    #expect(model.restartBlockers.contains(L10n.text("Сообщение в очереди: ", "Queued message: ") + "A"))
    #expect(model.restartBlockers.contains(L10n.text("Сообщение в очереди: ", "Queued message: ") + "B"))
    var started: [JSONValue] = []
    for _ in 0..<200 {
        started = try await connection.request("test/requests").array.filter { $0["method"].string == "turn/start" }
        if started.count == 2 && model.queuedMessages.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(started.count == 2)
    #expect(model.queuedMessages.isEmpty)
    #expect(!model.hasDeliverableQueue)
}
