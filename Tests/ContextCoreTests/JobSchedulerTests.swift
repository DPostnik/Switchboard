import ClaudeAdapter
@_spi(NativeProtocol) import CodexAdapter
import Foundation
import Darwin
import AppKit
import SwiftUI
import Testing
@testable import ContextCore
@testable import ContextDesk

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func jobFixture() -> ManagedJob {
    var job = ManagedJob(); job.name = "Morning · Утро"; job.prompt = "Review today's work"; job.projectID = UUID()
    job.schedule = JobSchedule(rule: "FREQ=HOURLY;INTERVAL=1", timeZone: "Europe/Warsaw"); job.enabled = true
    return job
}
@Test func schedulerCalendarZonesDSTAndUnsupportedRules() throws {
    let daily = JobSchedule(rule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=30;BYSECOND=0", timeZone: "Europe/Warsaw")
    #expect(try daily.next(after: instant("2026-03-28T10:00:00Z")) == instant("2026-03-29T07:30:00Z"))
    #expect(try daily.next(after: instant("2026-10-24T10:00:00Z")) == instant("2026-10-25T08:30:00Z"))
    let weekday = JobSchedule(rule: "FREQ=WEEKLY;BYHOUR=9;BYMINUTE=0;BYDAY=MO,TU,WE,TH,FR", timeZone: "Europe/Warsaw")
    #expect(try weekday.next(after: instant("2026-09-25T08:00:00Z")) == instant("2026-09-28T07:00:00Z"))
    let many = JobSchedule(rule: "RRULE:FREQ=DAILY;BYHOUR=8,9,10;BYMINUTE=0,30", timeZone: "UTC")
    #expect(try many.next(after: instant("2026-09-27T08:30:00Z")) == instant("2026-09-27T09:00:00Z"))
    for rule in ["FREQ=MONTHLY", "FREQ=HOURLY;BYMINUTE=30", "FREQ=MINUTELY;INTERVAL=0", "FREQ=HOURLY;COUNT=2", "FREQ=DAILY;BYHOUR=24;BYMINUTE=0", "FREQ=WEEKLY;BYHOUR=9;BYMINUTE=0", "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;FREQ=DAILY"] {
        #expect(throws: (any Error).self) { try JobSchedule(rule: rule).next(after: Date()) }
    }
    #expect(throws: (any Error).self) { try JobSchedule(timeZone: "invalid").next(after: Date()) }
}
@Test func schedulerClaimsPersistBeforeDispatchAndCollapseMissedRuns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let now = instant("2026-09-27T08:00:00Z"), job = jobFixture()
    _ = try await store.save(job, now: now)
    #expect(try await store.claim(job.id, manual: false, now: now) == nil)
    let (_, run) = try #require(await store.claim(job.id, manual: false, now: now.addingTimeInterval(86400)))
    let disk = try JSONDecoder().decode(JobLedger.self, from: Data(contentsOf: file))
    #expect(disk.runs.first?.id == run.id)
    #expect(disk.jobs.first?.nextRun == now.addingTimeInterval(90000))
    #expect(try await store.claim(job.id, manual: true) == nil)
    _ = try await store.finish(run.id, status: .completed)
    #expect(try await store.claim(job.id, manual: false, now: now.addingTimeInterval(86401)) == nil)
    let second = try #require(await store.claim(job.id, manual: true))
    _ = try await store.attach(second.1.id, thread: "test-thread", turn: "turn")
    await store.release()
    let restored = try await JobStore(file: file).load()
    #expect(restored.runs.first?.status == .uncertain)
    #expect(restored.runs.first?.threadID == "test-thread")
    #expect(restored.jobs.first?.enabled == true)
    #expect(restored.jobs.first?.nextRun == now.addingTimeInterval(90000))
}
@Test func schedulerOwnershipOneShotAndManualFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: root.appendingPathComponent("jobs.json"))
    _ = try await store.load()
    let other = JobStore(file: file)
    await #expect(throws: (any Error).self) { try await other.load() }
    var job = jobFixture(); let now = Date()
    job.schedule.once = now.addingTimeInterval(60)
    _ = try await store.save(job, now: now)
    let claimed = try #require(await store.claim(job.id, manual: false, now: now.addingTimeInterval(70)))
    #expect(try await store.load().jobs.first?.enabled == false)
    _ = try await store.finish(claimed.1.id, status: .blocked, output: "denied")
    #expect(try await store.load().runs.first?.status == .blocked)
    var imported = jobFixture(); imported.source = "codex:external"
    await #expect(throws: (any Error).self) { try await store.save(imported) }
    imported.sourceDisabled = true
    _ = try await store.save(imported)
    let manual = try #require(await store.claim(imported.id, manual: true, now: now))
    #expect(try await store.load().jobs.first { $0.id == imported.id }?.nextRun != nil)
    _ = try await store.finish(manual.1.id, status: .failed)
    #expect(try await store.load().jobs.first { $0.id == imported.id }?.enabled == true)
    await store.release()
}

@Test(arguments: [JobRunStatus.completed, .failed, .interrupted, .uncertain, .blocked], [false, true])
func schedulerRunOutcomesPreserveRecurringSchedule(status: JobRunStatus, manual: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: file)
    var job = jobFixture()
    job.schedule = JobSchedule(rule: "FREQ=DAILY;BYHOUR=10;BYMINUTE=15", timeZone: "Europe/Warsaw")
    let due = instant("2026-09-29T08:15:00Z")
    _ = try await store.save(job, now: due.addingTimeInterval(-60))
    let (_, run) = try #require(await store.claim(job.id, manual: manual, now: due.addingTimeInterval(manual ? -30 : 0)))
    let scheduled = try #require(await store.load().jobs.first)
    let next = try #require(scheduled.nextRun)
    #expect(next == (manual ? due : instant("2026-09-30T08:15:00Z")))
    let finished = try await store.finish(run.id, status: status, output: "Recorded result")
    #expect(finished.jobs.first == scheduled)
    #expect(finished.runs.first?.status == status)
    #expect(finished.runs.first?.output == "Recorded result")
    #expect(finished.runs.first?.finished != nil)
    await store.release()
    let reopened = JobStore(file: file)
    #expect(try await reopened.load().jobs.first == scheduled)
    #expect(try await reopened.claim(job.id, manual: false, now: next.addingTimeInterval(-1)) == nil)
    let (_, subsequent) = try #require(await reopened.claim(job.id, manual: false, now: next))
    #expect(subsequent.id != run.id)
    #expect(try await reopened.claim(job.id, manual: false, now: next) == nil)
    #expect(try await reopened.load().runs.first { $0.id == run.id }?.status == status)
    await reopened.release()
}

@Test(arguments: [JobRunStatus.starting, .running])
func schedulerRecoveryPreservesNextOccurrenceWithoutReplaying(activeStatus: JobRunStatus) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: file)
    let job = jobFixture(), now = instant("2026-09-29T08:00:00Z")
    _ = try await store.save(job, now: now)
    let due = now.addingTimeInterval(3600)
    let (_, run) = try #require(await store.claim(job.id, manual: false, now: due))
    if activeStatus == .running { _ = try await store.attach(run.id, thread: "recovered-thread", turn: "recovered-turn") }
    let scheduled = try #require(await store.load().jobs.first)
    let next = try #require(scheduled.nextRun)
    await store.release()
    let reopened = JobStore(file: file)
    let recovered = try await reopened.load()
    #expect(recovered.jobs.first == scheduled)
    #expect(recovered.runs.count == 1)
    #expect(recovered.runs.first?.id == run.id)
    #expect(recovered.runs.first?.status == .uncertain)
    #expect(recovered.runs.first?.finished != nil)
    // Delayed completion cannot replace the uncertain receipt or change the schedule.
    #expect(try await reopened.finish(run.id, status: .failed).jobs.first == scheduled)
    #expect(try await reopened.claim(job.id, manual: false, now: due) == nil)
    await reopened.release()
    #expect(try await reopened.load().runs.first?.finished == recovered.runs.first?.finished)
    let (_, subsequent) = try #require(await reopened.claim(job.id, manual: false, now: next))
    #expect(subsequent.id != run.id)
    #expect(try await reopened.load().runs.first { $0.id == run.id }?.status == .uncertain)
    await reopened.release()
}

@Test func schedulerExplicitPauseSurvivesManualFailureAndRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: file)
    let now = instant("2026-09-29T08:00:00Z")
    var job = jobFixture()
    _ = try await store.save(job, now: now)
    job.enabled = false
    let paused = try #require(await store.save(job, now: now).jobs.first)
    #expect(paused.nextRun == nil)
    let (_, manual) = try #require(await store.claim(job.id, manual: true, now: now))
    #expect(try await store.finish(manual.id, status: .failed).jobs.first == paused)
    let (_, unfinished) = try #require(await store.claim(job.id, manual: true, now: now))
    await store.release()
    let reopened = JobStore(file: file)
    let recovered = try await reopened.load()
    #expect(recovered.jobs.first == paused)
    #expect(recovered.runs.first { $0.id == unfinished.id }?.status == .uncertain)
    #expect(try await reopened.claim(job.id, manual: false, now: now.addingTimeInterval(86400)) == nil)
    await reopened.release()
}
@Test func schedulerPersistenceFailureCannotClaim() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let job = jobFixture(); _ = try await store.save(job)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await store.claim(job.id, manual: true) }
    #expect(try await store.load().runs.isEmpty)
    await store.release()
}
@Test func schedulerClaudeImportPreservesPromptWithoutInventingSchedule() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("sample")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = folder.appendingPathComponent("SKILL.md")
    let data = Data("---\nname: sample\ndescription: Example\n---\nHello $HOME `date`\nПривет\n".utf8)
    try data.write(to: file)
    let job = try #require(ScheduledJobs.readClaude(directory: root).first)
    #expect(job.prompt == "Hello $HOME `date`\nПривет\n")
    #expect(job.rawRule.isEmpty && job.model.isEmpty && job.paths.isEmpty)
    #expect(job.engine == .claude)
    #expect(try Data(contentsOf: file) == data)
}

@Test @MainActor func scheduledCodexRoutesRespectPermissionsAndPreserveSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json
    requests = []
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']
        result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='thread/start': result={'thread':{'id':'scheduled-thread'}}
        if method=='turn/start': result={'turn':{'id':'scheduled-turn'}}
        if method=='test/requests': result=requests
        else: requests.append(m)
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection(); try await connection.start(executable: executable, home: root)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    let project = Project(path: root.path); model.state.projects = [project]; model.projectID = project.id
    model.chatID = "visible-chat"; model.draft = "Keep my draft"; model.connected = true; model.authenticated = true
    model.schedulerReady = true
    var job = jobFixture(); job.projectID = project.id; job.model = "selected-model"; job.effort = "low"
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.chatID == "visible-chat" && model.draft == "Keep my draft")
    let requests = try await connection.request("test/requests").array
    let start = try #require(requests.first { $0["method"].string == "thread/start" })
    let turn = try #require(requests.first { $0["method"].string == "turn/start" })
    #expect(start["params"]["modelProvider"].string == "openai")
    #expect(start["params"]["approvalPolicy"].string == "on-request")
    #expect(turn["params"]["sandboxPolicy"]["type"].string == "workspaceWrite")
    #expect(turn["params"]["model"].string == "selected-model")
    let conversation = try #require(model.state.chats.first { $0.nativeSession?.nativeID == "scheduled-thread" })
    #expect(model.jobLedger.runs.first?.threadID == conversation.id)
    #expect(conversation.id != "scheduled-thread")
    await model.launchJob(job.id)
    #expect(model.jobLedger.runs.count == 1)
    model.finishActiveTurn(threadID: conversation.id, turnID: "scheduled-turn", status: .completed, hasError: false)
    for _ in 0..<100 { if model.jobLedger.runs.first?.status == .completed { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.jobLedger.runs.first?.status == .completed)
    await model.stopScheduler(); await connection.stop()
}

@Test func claudeAdapterUsesPinnedProtocolAndDeniesNewPermissions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,json
    if '--version' in sys.argv:
        print('2.1.292 (Claude Code)'); sys.exit(0)
    assert '--permission-mode' in sys.argv and sys.argv[sys.argv.index('--permission-mode')+1]=='dontAsk'
    assert '--dangerously-skip-permissions' not in sys.argv
    assert '--no-session-persistence' in sys.argv
    assert '--append-system-prompt' in sys.argv
    assert len(sys.argv[sys.argv.index('--append-system-prompt')+1]) > 100
    text=sys.stdin.read()
    print(json.dumps({'type':'result','is_error':False,'result':text,'permission_denials':[{'tool_name':'Bash'}]}))
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let (status, text) = try await ClaudeJobRunner().run(prompt: "Привет `date` $HOME", model: "test-model", cwd: root, executable: executable)
    #expect(status == .blocked)
    #expect(text == "Привет `date` $HOME")
}

@Test func schedulerSerializesConcurrentClaimsAndCapsRunningWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let job = jobFixture(); _ = try await store.save(job)
    let count = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<10 { group.addTask { try await store.claim(job.id, manual: true) == nil ? 0 : 1 } }
        var count = 0; for try await n in group { count += n }; return count
    }
    #expect(count == 1)
    for _ in 0..<2 { let other = jobFixture(); _ = try await store.save(other); #expect(try await store.claim(other.id, manual: true) != nil) }
    let fourth = jobFixture(); _ = try await store.save(fourth)
    #expect(try await store.claim(fourth.id, manual: true) == nil)
    await store.release()
}

@Test @MainActor func scheduledCodexUnconfirmedSendKeepsScheduleWithoutRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,json
    starts=0
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='thread/start': result={'thread':{'id':'uncertain-thread-'+str(starts)}}
        if method=='turn/start':
            starts+=1
            # A malformed acknowledgement leaves delivery unconfirmed.
            result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='test/count': result={'starts':starts}
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection(); try await connection.start(executable: executable, home: root)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    let project = Project(path: root.path); model.state.projects = [project]; model.connected = true; model.authenticated = true; model.schedulerReady = true
    var job = jobFixture(); job.projectID = project.id
    #expect(await model.saveJob(job))
    let control = root.appendingPathComponent("schedule-control")
    let due = try #require(model.jobLedger.jobs.first?.nextRun)
    await model.tickJobs(now: due, controlDirectory: control)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .uncertain)
    #expect(model.jobLedger.jobs.first?.enabled == true)
    let first = try #require(model.jobLedger.runs.first?.id)
    let next = try #require(model.jobLedger.jobs.first?.nextRun)
    #expect(next == due.addingTimeInterval(3600))
    await model.tickJobs(now: due, controlDirectory: control)
    await model.tickJobs(now: next.addingTimeInterval(-1), controlDirectory: control)
    #expect(try await connection.request("test/count")["starts"].int == 1)
    await model.tickJobs(now: next, controlDirectory: control)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(try await connection.request("test/count")["starts"].int == 2)
    #expect(model.jobLedger.runs.count == 2)
    #expect(model.jobLedger.runs.first?.id != first)
    #expect(model.jobLedger.runs.first { $0.id == first }?.status == .uncertain)
    await model.stopScheduler(); await connection.stop()
}

// Opt-in rendering uses synthetic data and process-local language defaults, never the running app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_SCHEDULE_RENDER_DIR"] != nil))
@MainActor func schedulerEditorRenderProbe() throws {
    let language = ProcessInfo.processInfo.environment["SWITCHBOARD_SCHEDULE_RENDER_LANGUAGE"] ?? "ru"
    UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: language], forName: UserDefaults.argumentDomain)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = Project(path: "/tmp/example-project"); model.state.projects = [project]
    var job = jobFixture(); job.projectID = project.id; job.schedule = JobSchedule(); job.source = "claude:example"; job.enabled = false; job.engine = .claude
    let host = NSHostingView(rootView: JobEditor(model: model, job: job).environment(\.locale, L10n.locale).preferredColorScheme(.light).background(Color.white))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 640, height: 700)
    window.backgroundColor = .white
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHBOARD_SCHEDULE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent("schedule-editor-" + language + ".png"))
    #expect(L10n.language.rawValue == language)
    window.orderOut(nil)
}

@Test func claudeAdapterRejectsUnverifiedVersionBeforeSendingPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,pathlib
    if '--version' in sys.argv:
        print('0.0.0 (Claude Code)'); sys.exit(0)
    pathlib.Path('unexpected-send').write_text('sent')
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    await #expect(throws: (any Error).self) {
        try await ClaudeJobRunner().run(prompt: "Do not send", model: "", cwd: root, executable: executable)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-send").path))
}

@Test func schedulerReleaseUnlocksEvenWithDuplicatedDescriptor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json")
    let store = JobStore(file: file)
    _ = try await store.load()
    // dup models the shared open file description retained briefly by a forked child.
    let suffix = "/" + root.lastPathComponent + "/jobs.json.lock"
    var duplicate: Int32 = -1
    for fd: Int32 in 0..<1024 {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBytes { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        if result == 0 && String(cString: path).hasSuffix(suffix) {
            duplicate = dup(fd); break
        }
    }
    defer { if duplicate >= 0 { close(duplicate) } }
    #expect(duplicate >= 0)
    await store.release()
    let replacement = JobStore(file: file)
    _ = try await replacement.load()
    await replacement.release()
}

private actor HangingExecutorFixture: AgentScheduledExecutor {
    var stops = 0, executions = 0
    func descriptor() -> AgentResult<AgentDescriptor> {
        .success(.init(context: .init(connection: .init(agent: .claudeCode, id: UUID()), accountRevision: UUID()),
            identityMode: .externalCLI, capabilities: [.scheduledExecution], permissions: .externalPolicyOnly, routes: [.externalConfiguration]))
    }
    func execute(_ request: AgentExecutionRequest, willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentScheduledResult> {
        executions += 1
        try? await willStart()
        while stops == 0 && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        return .success(.finished(.cancelled, output: "stopped"))
    }
    func stop() { stops += 1 }
}

@Test @MainActor func watchdogStopsOverdueRunsOnceAndNeverReplays() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let fixture = HangingExecutorFixture()
    model.jobExecutorFactories[.claude] = { _, _, _, _ in fixture }
    let project = Project(path: root.path); model.state.projects = [project]; model.schedulerReady = true
    var job = ManagedJob(); job.name = "Hangs"; job.prompt = "work"; job.projectID = project.id; job.engine = .claude
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for _ in 0..<200 where model.jobLedger.runs.first?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
    let run = try #require(model.jobLedger.runs.first)
    // Within the deadline nothing happens.
    await model.watchScheduler(now: run.started.addingTimeInterval(JobRun.deadline - 60))
    let stopsBefore = await fixture.stops
    #expect(model.jobLedger.runs.first?.status == .running && stopsBefore == 0)
    // Past it, the run is recorded as uncertain with the watchdog's reason, the executor is stopped once.
    await model.watchScheduler(now: run.started.addingTimeInterval(JobRun.deadline + 60))
    for task in Array(model.jobTasks.values) { await task.value }
    let finished = try #require(model.jobLedger.runs.first)
    #expect(finished.status == .uncertain && finished.output.contains("3"))
    let (stops, executions) = (await fixture.stops, await fixture.executions)
    #expect(stops == 1 && executions == 1)
    #expect(model.attention.open.contains { $0.runID == run.id })
    // A later tick neither stops nor replays it.
    await model.watchScheduler(now: run.started.addingTimeInterval(JobRun.deadline + 600))
    let (laterStops, laterExecutions) = (await fixture.stops, await fixture.executions)
    #expect(laterStops == 1 && laterExecutions == 1 && model.jobLedger.runs.count == 1)
}

@Test @MainActor func watchdogRetriesASchedulerThatStoppedAfterAnError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json")
    let other = JobStore(file: file)
    _ = try await other.load() // Another owner holds the schedules.
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: JobStore(file: file))
    let now = Date()
    await model.watchScheduler(now: now)
    #expect(!model.schedulerReady)
    await other.release()
    // Retried no sooner than five minutes after the failed attempt.
    await model.watchScheduler(now: now.addingTimeInterval(60))
    #expect(!model.schedulerReady)
    await model.watchScheduler(now: now.addingTimeInterval(301))
    #expect(model.schedulerReady)
}
