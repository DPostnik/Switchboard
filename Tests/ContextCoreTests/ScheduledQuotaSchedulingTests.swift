import Foundation
import Testing
@_spi(NativeProtocol) @testable import CodexAdapter
@testable import ContextCore
@testable import ContextDesk

@MainActor private func quotaFixture(_ root: URL) async throws -> (DeskModel, CodexConnection, ManagedJob) {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,json,os,pathlib
    calls=pathlib.Path(os.environ['CODEX_HOME'])/'quota-calls.jsonl'
    turns=0
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='thread/start': result={'thread':{'id':'quota-session'}}
        if method=='thread/resume': result={'thread':{'id':'quota-session'}}
        if method=='turn/start':
            turns+=1
            result={'turn':{'id':'turn-'+str(turns)}}
        if method=='account/read': result={'account':{'type':'chatgpt','email':'fixture@example.com','planType':'plus'}}
        if method=='account/rateLimits/read': result={'rateLimits':{'limitId':'codex','primary':{'usedPercent':0}}}
        if method=='test/requests':
            result=[json.loads(x) for x in calls.read_text().splitlines()] if calls.exists() else []
        else:
            with calls.open('a') as log: log.write(json.dumps(m)+'\n')
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let transport = CodexConnection()
    let client = CodexClient(transport: transport)
    try await client.start(executable: executable, home: root)
    let model = DeskModel(connection: CodexIntegration(client: client),
        store: AppStore(file: root.appendingPathComponent("state.sqlite")),
        jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    model.scheduledQuota.closeBrowser = { _, _ in .notNeeded }
    let project = Project(path: root.path)
    model.state.projects = [project]; model.state.defaultRoute = .direct
    model.schedulerReady = true; model.connected = true; model.authenticated = true
    var job = ManagedJob(); job.name = "Quota fixture"; job.prompt = "Run one routine"
    job.projectID = project.id; job.model = "gpt-test"; job.enabled = true
    #expect(await model.saveJob(job))
    return (model, transport, job)
}

@MainActor private func quotaCache(_ model: DeskModel, account: String? = "account-a", remaining: Int? = 80) {
    let now = Date()
    model.scheduledQuota.cached[.originalCodex] = .init(accountID: account,
        limits: .init(buckets: [.init(id: "codex", name: "Codex", windows: [
            .init(id: "primary", remainingPercent: remaining, durationMinutes: 300, resetsAt: nil)])],
            ordinaryUsageAllowed: nil, fetchedAt: now),
        context: model.agentState(.originalCodex).descriptor?.context, fetchedAt: now)
}

private func quotaTurns(_ transport: CodexConnection) async throws -> [JSONValue] {
    try await transport.request("test/requests").array.filter { $0["method"].string == "turn/start" }
}

@MainActor private func quotaSuspend(_ model: DeskModel) async throws -> JobRun {
    let run = try #require(model.jobLedger.runs.first)
    let thread = try #require(run.threadID), turn = try #require(run.turnID)
    let completion = AgentTurnCompletion(id: turn, status: .failed, hasError: true, error: "quota",
        history: .init(id: turn, items: [], startedAt: nil, completedAt: nil, duration: nil), usageLimit: .init(resetsAt: nil))
    #expect(await model.suspendScheduledQuota(threadID: thread, completion: completion))
    model.finishActiveTurn(threadID: thread, turnID: turn, status: .failed, hasError: true)
    // This fixture has no browser profile. Await cleanup before checking admission.
    if let cleanup = model.scheduledQuota.cleanupTasks[thread] { await cleanup.value }
    return try #require(model.jobLedger.runs.first)
}

@Test @MainActor func scheduledQuotaStopWaitsAndResumesSameRunAndChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, transport, job) = try await quotaFixture(root)
    quotaCache(model)
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    let waiting = try await quotaSuspend(model)
    #expect(waiting.status == .waitingForQuota && waiting.finished == nil)
    #expect(model.jobExecutors[waiting.id] == nil)
    #expect(model.state.chats.count == 1)
    let thread = try #require(waiting.threadID)
    #expect(model.state.chats.first?.limitResume == nil)
    quotaCache(model)
    // Exercise the resume entry point; the connected adapter may reuse its session.
    model.loadedThreads.remove(thread)
    model.jobLedger = try await model.jobStore.updateQuotaWait(waiting.id, resetAt: nil, nextCheckAt: Date().addingTimeInterval(-1))
    await model.checkScheduledQuotaWait(waiting.id)
    let resumed = try #require(model.jobLedger.runs.first)
    #expect(resumed.id == waiting.id && resumed.threadID == thread && resumed.status == .running)
    #expect(resumed.turnID != waiting.turnID)
    #expect(model.state.chats.count == 1)
    let turns = try await quotaTurns(transport)
    #expect(turns.count == 2)
    let first = try #require(turns.first), last = try #require(turns.last)
    #expect(first["params"]["approvalPolicy"] != .null)
    #expect(last["params"]["approvalPolicy"] == first["params"]["approvalPolicy"])
    #expect(last["params"]["sandboxPolicy"] == first["params"]["sandboxPolicy"])
    let requests = try await transport.request("test/requests").array
    let resume = try #require(requests.last(where: { $0["method"].string == "thread/resume" || $0["method"].string == "thread/start" }))
    #expect(resume["params"]["config"]["mcp_servers.switchboard_user_chrome"]["enabled"] == .bool(false))
    #expect(turns.allSatisfy { $0["params"]["threadId"].string == "quota-session" })
    #expect(turns.last?["params"]["input"].array.first?["text"].string?.contains("browser") == true ||
            turns.last?["params"]["input"].array.first?["text"].string?.contains("браузер") == true)
    await model.stopScheduler(); await transport.stop()
}

@Test @MainActor func scheduledQuotaUnknownPreflightNeverDispatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, transport, job) = try await quotaFixture(root)
    quotaCache(model, account: nil, remaining: nil)
    await model.launchJob(job.id)
    let waiting = try #require(model.jobLedger.runs.first)
    #expect(waiting.status == .waitingForQuota && waiting.threadID == nil)
    #expect(model.jobTasks.isEmpty && model.state.chats.isEmpty)
    #expect(try await quotaTurns(transport).isEmpty)
    quotaCache(model, remaining: nil)
    model.jobLedger = try await model.jobStore.updateQuotaWait(waiting.id, resetAt: nil, nextCheckAt: Date().addingTimeInterval(-1))
    await model.checkScheduledQuotaWait(waiting.id)
    #expect(model.jobLedger.runs.first?.status == .waitingForQuota)
    #expect(try await quotaTurns(transport).isEmpty)
    await model.stopScheduler(); await transport.stop()
}

@Test(arguments: [false, true]) @MainActor func scheduledQuotaCancellationAndAccountSwapDoNotResume(accountSwap: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, transport, job) = try await quotaFixture(root)
    quotaCache(model)
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    let waiting = try await quotaSuspend(model)
    if accountSwap {
        quotaCache(model, account: "account-b")
        model.jobLedger = try await model.jobStore.updateQuotaWait(waiting.id, resetAt: nil, nextCheckAt: Date().addingTimeInterval(-1))
        await model.checkScheduledQuotaWait(waiting.id)
    } else {
        await model.cancelScheduledQuota(in: try #require(waiting.threadID))
        quotaCache(model)
        await model.checkScheduledQuotaWait(waiting.id, manual: true)
    }
    #expect(model.jobLedger.runs.first?.status == .interrupted)
    #expect(try await quotaTurns(transport).count == 1)
    await model.stopScheduler(); await transport.stop()
}

/// Admission evidence for executor tests that intentionally do not exercise account probing.
@MainActor func admitScheduledQuotaFixture(_ model: DeskModel, engine: JobEngine) {
    guard let agent = model.connection(for: engine) else { Issue.record("Missing fixture connection"); return }; let now = Date()
    model.scheduledQuota.cached[agent] = .init(accountID: "scheduled-executor-fixture", limits:
        .init(buckets: [.init(id: engine == .codex ? "codex" : "all", name: "Fixture", windows: [
            .init(id: "primary", remainingPercent: 80, durationMinutes: 300, resetsAt: nil)])],
            ordinaryUsageAllowed: nil, fetchedAt: now),
        context: model.agentState(agent).descriptor?.context, fetchedAt: now)
}
