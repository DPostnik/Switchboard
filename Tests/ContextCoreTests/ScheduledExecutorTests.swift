import Foundation
import Testing
import ClaudeAdapter
@_spi(NativeProtocol) import CodexAdapter
@testable import ContextCore
@testable import ContextDesk

private func claudeFixture(_ root: URL, body: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("claude.py")
    try Data(("""
    #!\(fixturePython)
    import sys,json,pathlib,time
    if '--version' in sys.argv:
        print('2.1.292 (Claude Code)'); sys.exit(0)
    pathlib.Path('sent').write_text(sys.stdin.read())

    """ + body).utf8).write(to: file)
    try installFixtureExecutable(at: file)
    return file
}
private func makeRequest(_ runner: any AgentScheduledExecutor, root: URL) async throws -> AgentExecutionRequest {
    let descriptor = try await runner.descriptor().value()
    return AgentExecutionRequest(conversation: ConversationID(), kind: .scheduled, prompt: "test", projectPath: root.path,
        permissions: .externalPolicyDenyPrompts, model: .init(context: descriptor.context, model: ""), route: .externalConfiguration)
}

@Test func claudeScheduledContractRejectsReplayAndPersistsBeforeDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "assert pathlib.Path('claimed').exists()\nprint(json.dumps({'type':'result','is_error':False,'result':'done'}))")
    let runner = ClaudeJobRunner(executable: executable)
    let request = try await makeRequest(runner, root: root)
    let result = try await runner.execute(request) { try Data().write(to: root.appendingPathComponent("claimed")) }.value()
    guard case .finished(.completed, let output) = result else { Issue.record("Expected completion"); return }
    #expect(output == "done")
    guard case .rejected(.unknownRequest) = await runner.execute(request, willStart: {}) else { Issue.record("Replay accepted"); return }
}

@Test func claudeScheduledContractDistinguishesPreflightAndUncertainDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "print('malformed result')")
    let runner = ClaudeJobRunner(executable: executable)
    let request = try await makeRequest(runner, root: root)
    guard case .success(.finished(.cancelled, _)) = await runner.execute(request, willStart: { throw CancellationError() }) else {
        Issue.record("Expected pre-dispatch cancellation"); return
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    let other = ClaudeJobRunner(executable: executable)
    let otherRequest = try await makeRequest(other, root: root)
    guard case .failed(let failure) = await other.execute(otherRequest, willStart: {}) else { Issue.record("Malformed output accepted"); return }
    #expect(failure.delivery == .uncertain)
    let failedWrite = ClaudeJobRunner(executable: executable)
    let failedWriteRequest = try await makeRequest(failedWrite, root: root)
    guard case .failed(let persistence) = await failedWrite.execute(failedWriteRequest, willStart: { throw CocoaError(.fileWriteNoPermission) }) else {
        Issue.record("Expected persistence failure"); return
    }
    #expect(persistence.delivery == .notSent)
}

@Test func claudeScheduledRestrictionsRequireExplicitConsentAndFullAccess() async throws {
    let runner = ClaudeJobRunner()
    let descriptor = try await runner.descriptor().value()
    var project = Project(path: "/fixture")
    var job = ManagedJob(); job.engine = .claude
    for full in [false, true] {
        project.accessMode = full ? .fullAccess : .standard
        for consent in [nil, false, true] as [Bool?] {
            job.acceptsExternalPolicy = consent
            let request = job.executionRequest(runID: UUID(), project: project, descriptor: descriptor)
            #expect(descriptor.validate(request) == (full && consent == true ? nil : .unsupportedPermissions))
        }
    }
    job.route = RequestRoute(rawValue: "unavailable-plugin")
    #expect(descriptor.validate(job.executionRequest(runID: UUID(), project: project, descriptor: descriptor)) == .routeUnavailable)
    let legacy = try JSONDecoder().decode(ManagedJob.self, from: JSONEncoder().encode(ManagedJob()))
    #expect(legacy.acceptsExternalPolicy == nil)
}

@Test func claudeScheduledCancellationAfterSendIsUncertain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "time.sleep(20)")
    let runner = ClaudeJobRunner(executable: executable)
    let request = try await makeRequest(runner, root: root)
    let task = Task { await runner.execute(request, willStart: {}) }
    for _ in 0..<1500 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    await runner.stop()
    guard case .success(.finished(.uncertain, _)) = await task.value else { Issue.record("Dispatched cancellation must remain uncertain"); return }
}

@Test @MainActor func scheduledClaudeUnsupportedProjectIsBlockedWithoutDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "raise Exception('must not dispatch')")
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    model.jobExecutorFactories[.claude] = { _, _, _, _ in ClaudeJobRunner(executable: executable) }
    let project = Project(path: root.path); model.state.projects = [project]; model.schedulerReady = true
    var job = ManagedJob(); job.name = "test"; job.prompt = "test"; job.engine = .claude; job.projectID = project.id; job.enabled = true
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .blocked)
    #expect(model.jobLedger.jobs.first?.enabled == true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    await model.stopScheduler()
}

@Test(arguments: [JobEngine.codex, .claude])
@MainActor func scheduledExecutorsShareCompletionAndUncertainRecovery(engine: JobEngine) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let native = root.appendingPathComponent("codex.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,json,pathlib
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='thread/start': result={'thread':{'id':'session-'+str(len(list(pathlib.Path('.').glob('sent-*'))))}}
        if method=='turn/start':
            ledger=json.loads(pathlib.Path('jobs.json').read_text())
            assert ledger['runs'][0]['status']=='running'
            assert 'browser_import_session' in m['params']['input'][0]['text']
            assert m['params']['input'][0]['text'].startswith('test')
            pathlib.Path('sent-'+str(len(list(pathlib.Path('.').glob('sent-*'))))).write_text('sent')
            result={} if pathlib.Path('malformed').exists() else {'turn':{'id':'turn'}}
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: native)
    // Codex fixture runs in app home; the protocol process uses that directory explicitly below.
    let claude = try claudeFixture(root, body: """
    assert json.loads(pathlib.Path('jobs.json').read_text())['runs'][0]['status']=='running'
    if pathlib.Path('wait').exists(): time.sleep(20)
    print('malformed' if pathlib.Path('malformed').exists() else json.dumps({'type':'result','is_error':False,'result':'saved output'}))
    """)
    // The native fixture must use the temporary root regardless of transport cwd.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    var script = try String(contentsOf: native, encoding: .utf8)
    script = script.replacingOccurrences(of: "import sys,json,pathlib", with: "import sys,json,pathlib,os\nos.chdir(" + String(decoding: try encoder.encode(root.path), as: UTF8.self) + ")")
    try Data(script.utf8).write(to: native)
    try installFixtureExecutable(at: native)
    let transport = CodexConnection(); let fixtureClient = CodexClient(transport: transport)
    try await fixtureClient.start(executable: native, home: root)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(connection: CodexIntegration(client: fixtureClient), store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    model.jobExecutorFactories[.claude] = { _, _, _, _ in ClaudeJobRunner(executable: claude) }
    var project = Project(path: root.path); project.accessMode = .fullAccess
    model.state.projects = [project]; model.schedulerReady = true; model.connected = true; model.authenticated = true
    model.chatID = "visible"; model.draft = "keep draft"
    var job = ManagedJob(); job.name = "test"; job.prompt = "test"; job.engine = engine; job.projectID = project.id
    if engine == .codex { job.browserSessionImport = try .init(profile: "Default", site: "linkedin.com") }
    job.acceptsExternalPolicy = true; job.enabled = true
    #expect(await model.saveJob(job))
    let next = try #require(model.jobLedger.jobs.first?.nextRun)
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    if engine == .codex {
        let run = try #require(model.jobLedger.runs.first)
        #expect(run.status == .running)
        #expect(model.jobExecutors[run.id] != nil)
        model.finishActiveTurn(threadID: run.threadID, turnID: "turn", status: .completed, hasError: false)
        for _ in 0..<100 {
            if model.jobLedger.runs.first?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    } else {
        #expect(model.jobLedger.runs.first?.output == "saved output")
        // Each Claude print run is linked to its own read-only sidebar record.
        let run = try #require(model.jobLedger.runs.first)
        let chat = try #require(model.state.chats.first)
        #expect(model.state.chats.count == 1 && chat.scheduledRecord == run.id && run.threadID == chat.id)
        #expect(chat.title == "test" && chat.projectID == project.id && chat.nativeSession?.connection == .appClaude)
        let saved = try #require(try await model.store.loadTranscript(conversationID: chat.id))
        #expect(LocalHistory.items(saved).map(\.kind) == ["user", "assistant"])
        #expect(LocalHistory.items(saved).map(\.text) == ["test", "saved output"])
        #expect(!model.isBusy(threadID: chat.id))
    }
    #expect(model.jobLedger.runs.first?.status == .completed)
    #expect(model.chatID == "visible" && model.draft == "keep draft")
    try Data().write(to: root.appendingPathComponent("malformed"))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .uncertain)
    #expect(model.jobLedger.jobs.first?.enabled == true)
    #expect(model.jobLedger.jobs.first?.nextRun == next)
    await model.tickJobs(now: next.addingTimeInterval(-1), controlDirectory: root.appendingPathComponent("schedule-control"))
    #expect(model.jobLedger.runs.count == 2)
    try FileManager.default.removeItem(at: root.appendingPathComponent("malformed"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("sent"))
    try Data().write(to: root.appendingPathComponent("wait"))
    await model.launchJob(job.id)
    if engine == .codex {
        for task in Array(model.jobTasks.values) { await task.value }
    } else {
        for _ in 0..<1500 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    }
    let active = try #require(model.jobLedger.runs.first)
    #expect(active.status == .running)
    await model.stopJob(active)
    if engine == .codex {
        model.finishActiveTurn(threadID: active.threadID, turnID: "turn", status: .cancelled, hasError: false)
        for _ in 0..<100 {
            if model.jobLedger.runs.first?.status == .interrupted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    } else {
        for task in Array(model.jobTasks.values) { await task.value }
    }
    #expect(model.jobLedger.runs.first?.status == (engine == .codex ? .interrupted : .uncertain))
    if engine == .claude {
        #expect(model.state.chats.count == 3 && model.state.chats.allSatisfy { !model.isBusy(threadID: $0.id) })
        #expect(model.jobLedger.runs.allSatisfy { run in model.state.chats.contains { $0.id == run.threadID && $0.scheduledRecord == run.id } })
    }
    #expect(model.jobLedger.jobs.first?.enabled == true)
    #expect(model.jobLedger.jobs.first?.nextRun == next)
    #expect(model.jobExecutors.isEmpty)
    await model.stopScheduler(); await transport.stop()
}

@Test func claudeScheduledBrowserLeasesFreshProfileAndReleasesAfterRun() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let browserRoot = root.appendingPathComponent("browser")
    try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: browserRoot.appendingPathComponent("runtime.json"))
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = try claudeFixture(root, body: #"""
    a=sys.argv
    assert '--strict-mcp-config' not in a
    assert a[a.index('--allowedTools')+1]=='mcp__switchboard_browser'
    import os
    assert os.environ.get('MCP_TIMEOUT')=='30000' and os.environ.get('MCP_TOOL_TIMEOUT')=='90000'
    server=json.loads(a[a.index('--mcp-config')+1])['mcpServers']['switchboard_browser']
    assert server['type']=='stdio' and server['command']=='/usr/bin/python3'
    args=server['args']; assert args[0].endswith('BrowserRuntime/server.py')
    env=args[args.index('--environment')+1]; lease=args[args.index('--profile-lease')+1]
    root=pathlib.Path(args[args.index('--root')+1])
    profile=json.loads((root/'profiles.json').read_text())['profiles'][env]
    assert profile['generation'].lower()==lease and profile['state']=='active' and profile['owner']
    assert json.loads((root/'environments'/env/'chrome-session-import.json').read_text())
    sent=pathlib.Path('sent').read_text()
    assert sent.startswith('test') and 'mcp__switchboard_browser__browser_import_session' in sent
    pathlib.Path('environment').write_text(env)
    print(json.dumps({'type':'result','is_error':False,'result':'done'}))
    """#)
    var job = ManagedJob(); job.engine = .claude; job.prompt = "test"
    job.browserSessionImport = try .init(profile: "Default", site: "linkedin.com")
    let runner = await AgentIntegrationFactory.claudeRunner(browserEnabled: true, job: job, resources: resources,
                                                            root: browserRoot, executable: executable)
    let request = try await makeRequest(runner, root: root)
    let result = try await runner.execute(request, willStart: {}).value()
    guard case .finished(.completed, let output) = result else { Issue.record("Expected completion: \(result)"); return }
    #expect(output == "done")
    let environment = try #require(UUID(uuidString: try String(contentsOf: root.appendingPathComponent("environment"), encoding: .utf8)))
    let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: browserRoot.appendingPathComponent("profiles.json"))) as? [String: Any]
    let profile = try #require((catalog?["profiles"] as? [String: Any])?[environment.uuidString.lowercased()] as? [String: Any])
    #expect(profile["state"] as? String == "available" && profile["owner"] == nil)

    // Required browser unavailable: blocked before any dispatch; no-policy jobs still run without MCP.
    try FileManager.default.removeItem(at: root.appendingPathComponent("sent"))
    let blocked = await AgentIntegrationFactory.claudeRunner(browserEnabled: false, job: job, resources: resources,
                                                             root: browserRoot, executable: executable)
    guard case .finished(.blocked, let reason) = try await blocked.execute(try await makeRequest(blocked, root: root), willStart: {}).value() else {
        Issue.record("Expected blocked run"); return
    }
    #expect(reason == ScheduledBrowserImport.unavailable.message)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    job.browserSessionImport = nil
    let plain = await AgentIntegrationFactory.claudeRunner(browserEnabled: false, job: job, resources: resources,
                                                           root: browserRoot, executable: executable)
    guard case .failed = await plain.execute(try await makeRequest(plain, root: root), willStart: {}) else {
        Issue.record("Fixture requires MCP arguments; a plain run must not receive them"); return
    }
}

@Test @MainActor func claudeScheduledRecordIsReadOnlyAndSurvivesRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: """
    if pathlib.Path('wait').exists(): time.sleep(20)
    print(json.dumps({'type':'result','is_error':True,'result':'denied','permission_denials':[{'tool_name':'Bash'}]}))
    """)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    model.jobExecutorFactories[.claude] = { _, _, _, _ in ClaudeJobRunner(executable: executable) }
    var project = Project(path: root.path); project.accessMode = .fullAccess
    model.state.projects = [project]; model.schedulerReady = true
    var job = ManagedJob(); job.name = "Morning"; job.prompt = "collect"; job.engine = .claude; job.projectID = project.id
    job.acceptsExternalPolicy = true; job.enabled = true
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    let run = try #require(model.jobLedger.runs.first)
    #expect(run.status == .blocked)
    let chat = try #require(model.state.chats.first { $0.scheduledRecord == run.id })
    #expect(run.threadID == chat.id && chat.title == "Morning" && chat.unreadCompletionID != nil)

    // Opening never contacts an engine (Claude is not connected here) and nothing is dispatched.
    try FileManager.default.removeItem(at: root.appendingPathComponent("sent"))
    await model.openChat(chat)
    #expect(model.error == nil && model.localHistoryNotice == nil)
    #expect(model.items.map(\.text) == ["collect", "denied", JobRunStatus.blocked.title])
    model.draft = "follow up"
    #expect(!model.canSend && !model.canGenerateSummary(chat.id))
    await model.send()
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    // A reply becomes a new chat whose context is the record's saved run, built without any model call.
    let handoff = try await model.scheduledRecordHandoff(chat, goal: "follow up")
    let prompt = try handoff.prompt()
    #expect(handoff.origin.conversation.value == chat.id && handoff.includeTranscript)
    #expect(prompt.contains("follow up") && prompt.contains("collect") && prompt.contains("denied") && prompt.contains("Morning"))
    // Sending from the record reaches the follow-up with the typed text. The engine is unreachable here,
    // so it fails visibly: the record is not written to, no chat appears and the draft is kept.
    model.claudeConnected = true; model.claudeAuthenticated = true
    #expect(model.canSend)
    await model.send()
    #expect(model.error != nil && model.state.chats.count == 1 && model.chatID == chat.id && model.draft == "follow up")
    model.claudeConnected = false; model.claudeAuthenticated = false
    #expect(model.items.map(\.text) == ["collect", "denied", JobRunStatus.blocked.title])
    model.error = nil
    // The phone is told the record is read-only instead of offering a composer that is then rejected.
    let remote = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first { $0.id == chat.id })
    #expect(remote.readOnly == true && remote.supportsPhotos == false && remote.settings == nil)

    // Stopping from the chat stops the job; archive and delete need no engine and keep the run history.
    try Data().write(to: root.appendingPathComponent("wait"))
    await model.launchJob(job.id)
    for _ in 0..<1500 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let active = try #require(model.jobLedger.runs.first)
    let live = try #require(model.state.chats.first { $0.scheduledRecord == active.id })
    #expect(active.status == .running && model.isBusy(threadID: live.id) && !model.canDeleteChat(live.id))
    await #expect(throws: ClientFailure.self) { _ = try await model.scheduledRecordHandoff(live, goal: "too early") }
    await model.openChat(live)
    await model.interrupt()
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .uncertain && !model.isBusy(threadID: live.id))
    #expect(await model.setChatArchived(live.id, archived: true, revealArchive: false))
    await model.deleteChat(chat.id)
    #expect(!model.state.chats.contains { $0.id == chat.id })
    #expect(model.jobLedger.runs.count == 2 && model.jobLedger.runs.last?.threadID == chat.id && model.jobLedger.runs.last?.output == "denied")
    #expect(model.error == nil)
    await model.stopScheduler()
}

@Test @MainActor func scheduledRunBlockersBecomeImportantMessages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: """
    prompt = pathlib.Path('sent').read_text()
    assert 'BLOCKER:' in prompt and prompt.startswith('collect')
    print(json.dumps({'type':'result','is_error':False,'result':'Report\\n- BLOCKER: Answer Q-1 to unlock applications.'}))
    """)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    model.jobExecutorFactories[.claude] = { _, _, _, _ in ClaudeJobRunner(executable: executable) }
    var project = Project(path: root.path); project.accessMode = .fullAccess
    model.state.projects = [project]; model.schedulerReady = true
    var job = ManagedJob(); job.name = "Morning"; job.prompt = "collect"; job.engine = .claude; job.projectID = project.id
    job.acceptsExternalPolicy = true
    #expect(await model.saveJob(job))
    for _ in 0..<2 {
        await model.launchJob(job.id)
        for task in Array(model.jobTasks.values) { await task.value }
    }
    #expect(model.jobLedger.runs.map(\.status) == [.completed, .completed])
    let item = try #require(model.attention.open.first)
    #expect(model.attention.open.count == 1 && item.kind == .blocker && item.occurrences == 2)
    #expect(item.text == "Answer Q-1 to unlock applications." && item.jobName == "Morning" && item.runID == model.jobLedger.runs.first?.id)
    #expect(model.state.chats.contains { $0.id == item.threadID })
    // Stored next to the job ledger, so the user's own file is never touched by tests.
    #expect(try await AttentionStore(file: root.appendingPathComponent("attention.json")).load().open.map(\.id) == [item.id])

    model.openAttention()
    #expect(model.showingAttention && !model.showingJobs)
    await model.resolveAttention(item.id)
    #expect(model.openAttentionCount == 0 && model.attention.resolved.map(\.id) == [item.id])
    model.newChat()
    #expect(!model.showingAttention)
}
