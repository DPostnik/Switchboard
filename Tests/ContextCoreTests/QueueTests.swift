@_spi(NativeProtocol) import CodexAdapter
import AgentContract
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test @MainActor func queueWaitsForCompletionAndPriorityWaitsForInterruption() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json
    requests = []
    turns = 0
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method = m['method']
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'turn/start':
            turns += 1
            result = {'turn': {'id': 'v' + str(turns)}}
        if method == 'test/requests': result = requests
        else: requests.append(m)
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: store, summaryExecutable: executable, summaryHome: folder)
    model.state.defaultRoute = .direct
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id; model.chatID = "t"
    model.state.chats = [Chat(id: "t", projectID: project.id, title: "Fixture", model: "")]
    model.connected = true; model.authenticated = true
    model.draft = "First"
    await model.send()
    model.draft = "Second"
    await model.send()
    model.draft = "Third"
    await model.send()
    #expect(model.items.map(\.text) == ["First"])
    #expect(model.visibleQueue.map(\.text) == ["Second", "Third"])
    var requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "turn/start" }.count == 1)
    #expect(!requests.contains { $0["method"].string == "turn/steer" })

    await model.sendQueuedMessageNow(try #require(model.visibleQueue.last?.id))
    requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "turn/interrupt" }.count == 1)
    #expect(requests.filter { $0["method"].string == "turn/start" }.count == 1)
    model.finishActiveTurn(threadID: "other", turnID: "v1", status: .completed, hasError: false)
    #expect(model.busy)
    model.finishActiveTurn(threadID: "t", turnID: "v1", status: .cancelled, hasError: false)
    for _ in 0..<100 {
        if model.busy && !model.sending { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.items.map(\.text) == ["First", "Third"])
    #expect(model.visibleQueue.map(\.text) == ["Second"])
    model.finishActiveTurn(threadID: "t", turnID: "v2", status: .completed, hasError: false)
    for _ in 0..<100 {
        if model.busy && !model.sending { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.items.map(\.text) == ["First", "Third", "Second"])
    #expect(model.visibleQueue.isEmpty)
    // Only the message that interrupted the turn tells the agent to finish the interrupted task; the transcript hides the note.
    requests = try await connection.request("test/requests").array
    let sent = requests.filter { $0["method"].string == "turn/start" }.map { $0["params"]["input"].array.compactMap { $0["text"].string }.joined() }
    #expect(sent.count == 3)
    #expect(sent[0] == "First" && sent[2] == "Second")
    #expect(sent[1].hasPrefix("Third\n\n[Switchboard: ") && InterruptedTurnNote.stripped(sent[1]) == "Third")
    #expect(TranscriptItem(id: "u", kind: "user", text: sent[1]).text == "Third")
    #expect(InterruptedTurnNote.stripped("Third [Switchboard: other]") == "Third [Switchboard: other]")
    model.draft = "Keep for later"
    await model.send()
    await model.interrupt()
    model.finishActiveTurn(threadID: "t", turnID: "v3", status: .cancelled, hasError: false)
    #expect(model.queuePaused)
    #expect(model.visibleQueue.map(\.text) == ["Keep for later"])
    try await store.save(model.state)
    let restored = try await store.load()
    #expect(restored.queuedMessages == model.state.queuedMessages)
    #expect(DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: store, summaryExecutable: executable, summaryHome: folder).queuePaused)
    await model.sendQueuedMessageNow(try #require(model.visibleQueue.first?.id))
    for _ in 0..<100 {
        if model.busy && !model.sending { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    // After a plain Stop the next message carries no note.
    requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "turn/start" }.last?["params"]["input"].array.compactMap { $0["text"].string }.joined() == "Keep for later")
    model.draft = "Wait after failure"
    await model.send()
    model.finishActiveTurn(threadID: "t", turnID: "v4", status: .failed, hasError: true)
    #expect(model.queuePaused)
    #expect(model.visibleQueue.map(\.text) == ["Wait after failure"])
    await connection.stop()
}

private func parallelChatFixture() throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json, threading
    requests, counts = [], {}
    lock = threading.Lock()
    def emit(m, result):
        with lock:
            print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method = m['method']
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'test/requests': result = list(requests)
        else: requests.append(m)
        if method == 'thread/start': result = {'thread': {'id': 'new-thread'}}
        if method in ['thread/archive', 'thread/unarchive']:
            if m['params']['threadId'] == 'failed-archive':
                with lock:
                    print(json.dumps({'id': m['id'], 'error': {'code': -32000, 'message': 'Archive rejected'}}), flush=True)
            else:
                threading.Timer(0.15, emit, args=(m, result)).start()
            continue
        if method == 'thread/delete':
            if m['params']['threadId'] == 'failed-delete':
                with lock:
                    print(json.dumps({'id': m['id'], 'error': {'code': -32000, 'message': 'Deletion rejected'}}), flush=True)
            else:
                threading.Timer(0.15, emit, args=(m, result)).start()
            continue
        if method == 'turn/start':
            thread = m['params']['threadId']
            counts[thread] = counts.get(thread, 0) + 1
            result = {'turn': {'id': thread + '-' + str(counts[thread])}}
            if m['params']['input'][0]['text'] == 'slow':
                threading.Timer(0.3, emit, args=(m, result)).start()
                continue
        emit(m, result)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return (folder, executable)
}

@Test @MainActor func parallelChatsKeepStopsQueuesAndNewProjectsIndependent() async throws {
    let (folder, executable) = try parallelChatFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: AppStore(file: folder.appendingPathComponent("state.sqlite")),
                          summaryExecutable: executable, summaryHome: folder)
    let a = Project(path: folder.appendingPathComponent("a").path)
    let b = Project(path: folder.appendingPathComponent("b").path)
    model.state.projects = [a, b]
    model.state.chats = [Chat(id: "a", projectID: a.id, title: "A", model: ""), Chat(id: "b", projectID: b.id, title: "B", model: "")]
    model.state.defaultRoute = .direct
    model.connected = true; model.authenticated = true
    model.projectID = a.id; model.chatID = "a"; model.draft = "slow"
    let first = Task { await model.send() }
    for _ in 0..<100 {
        if model.sending { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.sending)
    model.selectProject(b.id)
    model.chatID = "b"; model.draft = "B first"
    #expect(model.canSend)
    await model.send()
    #expect(model.isBusy(threadID: "a"))
    #expect(model.isBusy(threadID: "b"))
    await first.value
    model.draft = "B queued"; await model.send()
    model.selectProject(a.id); model.chatID = "a"
    model.draft = "A queued"; await model.send()
    await model.interrupt()
    model.selectProject(b.id); model.chatID = "b"
    model.finishActiveTurn(threadID: "a", turnID: "a-1", status: .cancelled, hasError: false)
    #expect(model.busy)
    #expect(!model.queuePaused)
    model.finishActiveTurn(threadID: "b", turnID: "b-1", status: .completed, hasError: false)
    for _ in 0..<100 {
        if model.busy && !model.sending { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.visibleQueue.isEmpty)
    #expect(model.queuedMessages.map(\.text) == ["A queued"])
    #expect(model.isBusy(threadID: "b"))
    let requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "turn/interrupt" }.map { $0["params"]["threadId"].string } == ["a"])
    #expect(requests.filter { $0["method"].string == "turn/start" }.map { $0["params"]["threadId"].string } == ["a", "b", "b"])

    // Clicking the same project leaves its existing chat and preserves a new draft.
    model.selectProject(b.id)
    #expect(model.chatID == nil)
    #expect(!model.busy)
    #expect(model.anyBusy)
    model.draft = "New conversation"
    model.selectProject(b.id)
    #expect(model.draft == "New conversation")
    #expect(model.canSend)
    await model.send()
    #expect(model.chatID == model.state.chats.last?.id)
    #expect(model.chatID != "new-thread")
    #expect(model.state.chats.last?.nativeSession?.nativeID == "new-thread")
    #expect(model.state.chats.last?.projectID == b.id)
    #expect(model.queuedMessages.map(\.text) == ["A queued"])
    let after = try await connection.request("test/requests").array
    #expect(after.filter { $0["method"].string == "thread/start" }.count == 1)
    #expect(after.last { $0["method"].string == "turn/start" }?["params"]["threadId"].string == "new-thread")
    await connection.stop()
}

@Test @MainActor func stopBeforeStartAcknowledgmentStaysWithOriginalChat() async throws {
    let (folder, executable) = try parallelChatFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: AppStore(file: folder.appendingPathComponent("state.sqlite")),
                          summaryExecutable: executable, summaryHome: folder)
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id
    model.state.chats = ["a", "b"].map { Chat(id: $0, projectID: project.id, title: $0, model: "") }
    model.state.defaultRoute = .direct; model.connected = true; model.authenticated = true
    model.chatID = "a"; model.draft = "slow"
    let first = Task { await model.send() }
    for _ in 0..<100 {
        if model.sending { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    await model.interrupt()
    model.chatID = "b"; model.draft = "B first"
    await model.send()
    await first.value
    let requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "turn/interrupt" }.map { $0["params"]["threadId"].string } == ["a"])
    model.finishActiveTurn(threadID: "a", turnID: "a-1", status: .cancelled, hasError: false)
    #expect(model.busy)
    #expect(model.isBusy(threadID: "b"))
    await connection.stop()
}

@Test @MainActor func deletionRemovesOnlyConfirmedIdleChatAndPersistsCleanup() async throws {
    let (folder, executable) = try parallelChatFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: store, summaryExecutable: executable, summaryHome: folder)
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id
    model.state.defaultRoute = .direct; model.connected = true; model.authenticated = true
    model.state.chats = ["a", "b", "failed-delete"].map { Chat(id: $0, projectID: project.id, title: $0, model: "") }
    model.chatID = "b"; model.draft = "Keep working"
    await model.send()
    #expect(!model.canDeleteChat("b"))
    await model.deleteChat("b")
    #expect(model.isBusy(threadID: "b"))
    model.state.queuedMessages = ["a", "b", "failed-delete"].map {
        QueuedMessage(id: "q-" + $0, threadID: $0, projectID: project.id, text: $0, model: "", effort: "")
    }
    let snapshot = UsageSnapshot()
    for id in ["a", "b"] {
        model.usage[id] = snapshot
        try await store.saveUsage(threadID: id, snapshot: snapshot)
    }
    try await store.save(model.state)
    model.chatID = "a"
    let deleting = Task { await model.deleteChat("a") }
    for _ in 0..<100 {
        if model.deletingChatIDs.contains("a") { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.deletingChatIDs.contains("a"))
    model.draft = "Cannot send during deletion"
    #expect(!model.canSend)
    model.resumeQueue()
    await model.sendQueuedMessageNow("q-a")
    await deleting.value
    #expect(model.chatID == nil)
    #expect(model.projectID == project.id)
    #expect(model.items.isEmpty)
    #expect(model.state.chats.map(\.id) == ["b", "failed-delete"])
    #expect(model.queuedMessages.map(\.threadID) == ["b", "failed-delete"])
    #expect(model.usage["a"] == nil)
    #expect(model.isBusy(threadID: "b"))
    let saved = try await store.load()
    #expect(saved.chats.map(\.id) == ["b", "failed-delete"])
    #expect(saved.queuedMessages?.map(\.threadID) == ["b", "failed-delete"])
    let usage = try await store.loadUsage()
    #expect(usage["a"] == nil)
    #expect(usage["b"] == snapshot)

    model.chatID = "failed-delete"
    await model.deleteChat("failed-delete")
    #expect(model.chatID == "failed-delete")
    #expect(model.state.chats.contains { $0.id == "failed-delete" })
    #expect(model.visibleQueue.map(\.id) == ["q-failed-delete"])
    #expect(model.queuePaused)
    #expect(model.error?.contains("Deletion rejected") == true)
    let requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "thread/delete" }.map { $0["params"]["threadId"].string } == ["a", "failed-delete"])
    #expect(requests.filter { $0["method"].string == "turn/start" }.map { $0["params"]["threadId"].string } == ["b"])
    await connection.stop()
}

@Test @MainActor func archiveAndRestorePreserveQueueAndRespectServerFailures() async throws {
    let (folder, executable) = try parallelChatFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: store, summaryExecutable: executable, summaryHome: folder)
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id
    model.state.defaultRoute = .direct; model.connected = true; model.authenticated = true
    model.state.chats = ["a", "b", "failed-archive"].map { Chat(id: $0, projectID: project.id, title: $0, model: "") }
    model.chatID = "b"; model.draft = "Working"
    await model.send()
    await model.setChatArchived("b", archived: true)
    #expect(!model.isArchived("b"))
    #expect(model.isBusy(threadID: "b"))
    model.chatID = "a"
    model.state.queuedMessages = [QueuedMessage(id: "q-a", threadID: "a", projectID: project.id, text: "Saved draft", model: "", effort: "")]
    let snapshot = UsageSnapshot()
    model.usage["a"] = snapshot
    try await store.saveUsage(threadID: "a", snapshot: snapshot)
    let archive = Task { await model.setChatArchived("a", archived: true) }
    for _ in 0..<100 {
        if model.archivingChatIDs.contains("a") { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.archivingChatIDs.contains("a"))
    model.draft = "Do not send"
    #expect(!model.canSend)
    #expect(!model.canDeleteChat("a"))
    await model.deleteChat("a")
    await archive.value
    // Restore is intentionally unavailable while the archive summary owns the thread.
    await model.summaryTask?.value
    #expect(model.selectedChatIsArchived)
    #expect(model.showingArchive && !model.archiveViewingChat)
    #expect(!model.chats.contains { $0.id == "a" })
    #expect(model.visibleQueue.map(\.id) == ["q-a"])
    #expect(model.queuePaused)
    #expect(try await store.load().chats.first { $0.id == "a" }?.isArchived == true)
    #expect(try await store.loadUsage()["a"] == snapshot)
    model.resumeQueue()
    await model.sendQueuedMessageNow("q-a")
    await model.send()
    #expect(model.visibleQueue.count == 1)
    #expect(!model.canSend)
    await model.setChatArchived("a", archived: false)
    #expect(!model.selectedChatIsArchived)
    #expect(model.queuePaused)
    #expect(model.visibleQueue.count == 1)
    #expect(model.canSend)
    #expect(try await store.load().chats.first { $0.id == "a" }?.isArchived == false)
    await model.setChatArchived("failed-archive", archived: true)
    #expect(!model.isArchived("failed-archive"))
    #expect(model.error?.contains("Archive rejected") == true)
    model.state.chats[2].archived = true
    await model.setChatArchived("failed-archive", archived: false)
    #expect(model.isArchived("failed-archive"))
    #expect(model.isBusy(threadID: "b"))
    let requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "thread/archive" }.map { $0["params"]["threadId"].string } == ["a", "failed-archive"])
    #expect(requests.filter { $0["method"].string == "thread/unarchive" }.map { $0["params"]["threadId"].string } == ["a", "failed-archive"])
    #expect(!requests.contains { $0["method"].string == "thread/delete" })
    #expect(requests.filter { $0["method"].string == "turn/start" }.count == 1)
    let legacy = Data(#"{"id":"legacy","projectID":"00000000-0000-0000-0000-000000000001","title":"Old","model":"","updated":0}"#.utf8)
    #expect(try JSONDecoder().decode(Chat.self, from: legacy).isArchived == false)
    await connection.stop()
}

@Test @MainActor func bulkArchiveSkipsBusyChatsAndReportsFailuresOnce() async throws {
    let (folder, executable) = try parallelChatFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: store, summaryExecutable: executable, summaryHome: folder)
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id
    model.state.defaultRoute = .direct; model.connected = true; model.authenticated = true
    model.state.chats = ["a", "b", "c", "failed-archive"].map { Chat(id: $0, projectID: project.id, title: $0, model: "") }
    model.chatID = "b"; model.draft = "Working"
    await model.send()
    model.chatID = "a"
    await model.archiveChats(["a", "b", "failed-archive", "c"])
    await model.summaryTask?.value
    #expect(model.isArchived("a") && model.isArchived("c"))
    #expect(!model.isArchived("b") && !model.isArchived("failed-archive"))
    #expect(model.isBusy(threadID: "b"))
    // The open chat was archived: the workspace stays in the project instead of jumping to the archive.
    #expect(model.chatID == nil && !model.showingArchive)
    #expect(model.error?.contains("2") == true)
    #expect(model.error?.contains("Archive rejected") == true)
    let saved = try await store.load().chats
    #expect(saved.filter(\.isArchived).map(\.id).sorted() == ["a", "c"])
    let requests = try await connection.request("test/requests").array
    #expect(requests.filter { $0["method"].string == "thread/archive" }.map { $0["params"]["threadId"].string } == ["a", "failed-archive", "c"])
    await connection.stop()
}
