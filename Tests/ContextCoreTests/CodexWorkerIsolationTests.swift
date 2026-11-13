import Foundation
import Darwin
import Testing
import AgentContract
import ContextCore
@testable import CodexAdapter

private actor WorkerEventLog {
    var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
    func wait(after index: Int = 0, _ matches: @Sendable (AgentEvent) -> Bool) async throws -> AgentEvent {
        for _ in 0..<500 {
            if let event = events.dropFirst(index).first(where: matches) { return event }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClientFailure("Worker fixture event was not received")
    }
}

/// Separate OS processes, real wire approvals and a worker-only reset/exit. No provider inference.
private func workerFixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("UserChromeRuntime"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("UserChromeRuntime/server.py"))
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json,os,pathlib,sys,time
    root=pathlib.Path(os.environ['CODEX_HOME']); loaded=set(); chrome=False; mode=''
    home=root
    \#(fixtureWriteHelpers)
    def send(value): pause(); print(json.dumps(value),flush=True)
    def emit(method,params): send({'method':method,'params':params})
    for line in sys.stdin:
        m=json.loads(line)
        if 'method' not in m:
            append('answers',str(m.get('id'))+'\n')
            continue
        if 'id' not in m:continue
        method=m['method'];p=m.get('params',{});r={};tid=p.get('threadId','')
        if method=='initialize':r={'userAgent':'codex/0.160.0 fixture'}
        if method=='thread/start':
            chrome=p.get('config',{}).get('mcp_servers.switchboard_user_chrome',{}).get('enabled',False)
            tid='chrome' if chrome else 'ordinary';loaded.add(tid);r={'thread':{'id':tid}}
            if chrome:emit('account/updated',{})
        if method=='thread/resume':
            if (root/'require-rollout').exists() and not (root/('rollout-'+tid)).exists():
                send({'id':m['id'],'error':{'code':-32600,'message':'no rollout found for thread id '+tid}});continue
            loaded.add(tid);r={'thread':{'id':tid}}
        if method=='thread/unsubscribe':loaded.discard(tid);r={'status':'unsubscribed'}
        if method=='mcpServerStatus/list':r={'data':[{'name':'switchboard_user_chrome','tools':{'status':{'name':'status'}}}]}
        if method=='thread/loaded/list':r={'data':list(loaded)}
        if method=='turn/start':
            (root/('rollout-'+tid)).touch()
            mode=p.get('input',[{}])[0].get('text','');r={'turn':{'id':'turn-'+tid}}
            emit('turn/started',{'threadId':tid,'turn':r['turn']})
            if mode=='children':
                loaded.add('child')
                emit('item/completed',{'threadId':tid,'turnId':'turn-'+tid,'item':{'id':'spawn','type':'subAgentActivity','agentThreadId':'child','agentPath':'/root/child','kind':'started'}})
                emit('turn/completed',{'threadId':tid,'turn':{'id':'turn-'+tid,'status':'completed'}})
            else:send({'id':'approval-'+tid,'method':'item/commandExecution/requestApproval','params':{'threadId':tid,'turnId':'turn-'+tid,'command':'echo fixture'}})
        if method=='thread/read':
            if tid=='chrome' and mode in ('reset','crash'):
                if mode=='crash':sys.exit(0)
                emit('account/updated',{})
            r={'thread':{'id':tid,'turns':[{'id':'child-turn','status':'inProgress','items':[]}] if tid=='child' else []}}
        if method=='turn/interrupt' and tid not in loaded:
            send({'id':m['id'],'error':{'code':-32600,'message':'wrong worker'}});continue
        # Recorded before the answer: a test that got the answer to a request sees its line.
        append('calls.jsonl',json.dumps({'method':method,'thread':tid,'pid':os.getpid(),'args':sys.argv[1:],'params':p})+'\n')
        send({'id':m['id'],'result':r})
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return (root, executable)
}

@Test func roleChangeResumesSameSessionInNewProcessWithCurrentTrust() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration())
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root))
    let developer = AgentRoleCatalog.preset(AgentRoleID.developer).profile
    let reader = AgentRoleCatalog.preset(AgentRoleID.reader).profile
    let session = try await app.createSession(projectPath: root.path, permissions: developer, model: "", route: .direct)
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: developer, model: "", effort: "")
    _ = try await log.wait { if case .completed = $0.payload { return $0.session == session }; return false }
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: reader, model: "", effort: "")
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: developer, model: "", effort: "")
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let turns = calls.filter { $0["method"].string == "turn/start" }
    #expect(turns.count == 3)
    #expect(Set(turns.compactMap { $0["pid"].int }).count == 3)
    #expect(turns.allSatisfy { $0["thread"].string == session.nativeID })
    #expect(calls.filter { $0["method"].string == "thread/start" }.count == 1)
    let key = String(decoding: try JSONEncoder().encode(root.resolvingSymlinksInPath().path), as: UTF8.self)
        .replacingOccurrences(of: "\\/", with: "/")
    for (turn, trust) in zip(turns, ["trusted", "untrusted", "trusted"]) {
        #expect(turn["args"].array.contains(.string("projects={\(key)={trust_level=\"\(trust)\"}}")))
    }
    #expect(turns[1]["params"]["sandboxPolicy"]["type"].string == "readOnly")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.toml").path))
    await app.stop()
}

@Test func appliedSettingsProposalReplacesTheWorkerAtTheNextSend() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration())
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root))
    var state = SavedState()
    var project = Project(path: root.path); project.accessPresets = []
    state.projects = [project]
    func rights() -> AgentPermissionProfile { AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: state.projects[0]) }
    let session = try await app.createSession(projectPath: root.path, permissions: rights(), model: "", route: .direct)
    func send() async throws {
        let marker = await log.events.count
        _ = try await app.send("children", to: session, projectPath: root.path, permissions: rights(), model: "", effort: "")
        _ = try await log.wait(after: marker) { if case .completed = $0.payload { return $0.session == session }; return false }
    }
    try await send()
    try await send()
    // The user applies a proposal from the request card: a folder for this project.
    let notes = root.appendingPathComponent("notes")
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    var change = SettingsProposal.Change(project: root.path); change.addFolders = [.init(path: notes.path, writable: true)]
    let applied = state.apply(SettingsProposalReview(id: "p.json", proposal: .init(chat: session.nativeID, changes: [change]), state: state))
    #expect(applied)
    try await send()
    // Negative: re-reading the same proposal changes nothing; the worker stays.
    let appliedAgain = state.apply(SettingsProposalReview(id: "p.json", proposal: .init(changes: [change]), state: state))
    #expect(!appliedAgain)
    try await send()
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let pids = calls.filter { $0["method"].string == "turn/start" }.compactMap { $0["pid"].int }
    #expect(pids.count == 4)
    // Same rights share a worker; the grant moves the same thread to a new process, which then keeps it.
    #expect(pids[0] == pids[1] && pids[2] != pids[1] && pids[3] == pids[2])
    #expect(calls.filter { $0["method"].string == "thread/start" }.count == 1)
    let last = try #require(calls.last { $0["method"].string == "turn/start" })
    #expect(last["thread"].string == session.nativeID && last["params"]["sandboxPolicy"]["writableRoots"].array.contains { $0.string?.hasSuffix("/notes") == true })
    await app.stop()
}

/// A granted Keychain item is part of the worker scope (the profile's command sandbox): applying it moves the thread to a new
/// worker at the next send; an unchanged list keeps the worker.
@Test func appliedKeychainItemReplacesTheWorkerOnceAndAnUnchangedListKeepsIt() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration())
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root))
    var state = SavedState()
    var project = Project(path: root.path); project.accessPresets = []
    state.projects = [project]
    func rights() -> AgentPermissionProfile { AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: state.projects[0]) }
    let session = try await app.createSession(projectPath: root.path, permissions: rights(), model: "", route: .direct)
    func send() async throws {
        let marker = await log.events.count
        _ = try await app.send("children", to: session, projectPath: root.path, permissions: rights(), model: "", effort: "")
        _ = try await log.wait(after: marker) { if case .completed = $0.payload { return $0.session == session }; return false }
    }
    try await send()
    var change = SettingsProposal.Change(project: root.path); change.addKeychainItems = [.init(service: "fixture-api")]
    let applied = state.apply(SettingsProposalReview(id: "k.json", proposal: .init(changes: [change]), state: state))
    #expect(applied && rights().commandSandbox?.keychainItems == [.init(service: "fixture-api")])
    try await send()
    let appliedAgain = state.apply(SettingsProposalReview(id: "k.json", proposal: .init(changes: [change]), state: state))
    #expect(!appliedAgain)
    try await send()
    let pids = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        .filter { $0["method"].string == "turn/start" }.compactMap { $0["pid"].int }
    #expect(pids.count == 3 && pids[1] != pids[0] && pids[2] == pids[1])
    await app.stop()
}

/// The Codex worker under the boundary gets the same settings proposal inbox as Claude: a writable grant and the variable.
@Test func codexBoundaryInputCarriesTheSettingsProposalInbox() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    let project = Project(path: root.appendingPathComponent("project").path)
    let profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)
    let input = CodexIntegration.boundaryInput(project: project.path, permissions: profile, home: root.appendingPathComponent("codex-home"),
                                               executable: root.appendingPathComponent("codex"), resources: nil, workflowDirectories: [], inbox: inbox)
    #expect(input.extraWrites == [inbox.path] && FileManager.default.fileExists(atPath: inbox.path))
    // The inbox, mediated pgrep and the command inventory, as for Claude; no settings file and no extra reads.
    #expect(input.extraReads.isEmpty && !input.settingsFile && input.mediateProcessList && input.commandInventory)
    // Negative: the native path's file roots stay the project's own (invariant 6).
    let native = try #require(profile.codexTurnParameters(projectPath: project.path)["sandboxPolicy"])
    #expect(!native["writableRoots"].array.contains(.string(inbox.path)))
    #expect(!native["writableRoots"].array.contains(.string(SettingsProposalInbox.directory.path)))
    // Negative: no folder, no grant.
    let bare = CodexIntegration.boundaryInput(project: project.path, permissions: profile, home: root.appendingPathComponent("codex-home"),
                                              executable: root.appendingPathComponent("codex"), resources: nil, workflowDirectories: [], inbox: nil)
    #expect(bare.extraWrites.isEmpty)
}

/// A Codex worker serves one chat for its whole life (`bindChromeWorker`), so its folder names that chat: the thread ID when
/// it starts for an existing thread, an app token for a new thread (mapped once the thread ID is known).
@Test func codexWorkerFolderIsTheThreadOrAnAppToken() throws {
    let thread = "019a2b3c-4d5e-7f00-8a9b-0c1d2e3f4a5b"
    #expect(CodexIntegration.inboxFolderName(for: AgentSessionReference(connection: .originalCodex, nativeID: thread)) == thread)
    let token = CodexIntegration.inboxFolderName(for: nil)
    #expect(token.hasPrefix("codex-") && SettingsProposalInbox.isFolderName(token) && token != CodexIntegration.inboxFolderName(for: nil))
    // Negative: a thread ID the app would not use as a folder name gets a token instead.
    let unsafe = CodexIntegration.inboxFolderName(for: AgentSessionReference(connection: .originalCodex, nativeID: "../x"))
    #expect(unsafe.hasPrefix("codex-") && !unsafe.contains("/"))
}

/// A Codex chat that falls back to the native sandbox for a reason the user can act on shows the notice once; a
/// role-defined fallback (Operator) shows none. The helper is injected as unverified; the fallback keeps the native
/// sandbox (invariant 9).
@Test(arguments: [AgentRoleID.developer, AgentRoleID.fullOperator])
func codexFallbackShowsTheNoticeOncePerChatAndNeverForRoleDefinedReasons(role: String) async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration(boundaryHelper: { .failure(.missing("/fixture/nono")) }))
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root))
    var project = Project(path: root.path); project.accessPresets = []
    let rights = AgentRoleCatalog.preset(role).profile(for: project)
    let session = try await app.createSession(projectPath: root.path, permissions: rights, model: "", route: .direct)
    for _ in 1...2 {
        let marker = await log.events.count
        _ = try await app.send("children", to: session, projectPath: root.path, permissions: rights, model: "", effort: "")
        _ = try await log.wait(after: marker) { if case .completed = $0.payload { return $0.session == session }; return false }
    }
    func notices() async -> [String] {
        await log.events.compactMap { event -> String? in
            if case .diagnostic(let text) = event.payload, event.session == session { return text }; return nil
        }
    }
    let expected = CodexBoundaryNotices.text(.helper(.missing("/fixture/nono")))
    // Developer: once over two turns. Operator (unrestricted, role-defined): only logged.
    #expect(await notices() == (role == AgentRoleID.developer ? [expected] : []))
    // A scope change replaces the worker. Reader has the same actionable reason: after Developer it is not repeated,
    // after Operator it is shown once (the negative: the Operator silence was the role, not a missing channel).
    let reader = AgentRoleCatalog.preset(AgentRoleID.reader).profile(for: project)
    let marker = await log.events.count
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: reader, model: "", effort: "")
    _ = try await log.wait(after: marker) { if case .completed = $0.payload { return $0.session == session }; return false }
    #expect(await notices() == [expected])
    await app.stop()
}

@Test(arguments: ["reset", "crash"])
func dedicatedWorkerResetDoesNotClearOtherChatApproval(mode: String) async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let integration = CodexIntegration()
    let app = AgentClient(integration: integration)
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root, resources: root, userChromeEnabled: true))
    var permissions = AgentPermissionProfile.workspace()
    permissions.browser = .appAndUserChrome
    let ordinary = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct)
    _ = try await app.send("approval", to: ordinary, projectPath: root.path, permissions: permissions, model: "", effort: "")
    let pending = try await log.wait { if case .interaction = $0.payload { return $0.session == ordinary }; return false }
    guard case .interaction(let approval) = pending.payload else { return }
    let marker = await log.events.count
    let grant = AgentUserChromeGrant(chatID: "chrome", profileID: UUID().uuidString, stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    let chrome = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct, userChromeGrant: grant)
    _ = try await app.send(mode, to: chrome, projectPath: root.path, permissions: permissions, model: "", effort: "", userChromeGrant: grant)
    let workerPending = try await log.wait { if case .interaction = $0.payload { return $0.session == chrome }; return false }
    guard case .interaction(let workerApproval) = workerPending.payload else { return }
    _ = try? await app.history(chrome)
    _ = try await log.wait { if case .resolved(let id) = $0.payload { return id == workerApproval.id }; return false }
    if mode == "crash" {
        let ended = try await log.wait { if case .completed = $0.payload { return $0.session == chrome }; return false }
        if case .completed(let value) = ended.payload { #expect(value.status == .uncertain) }
    }
    let events = await log.events
    #expect(!events.dropFirst(marker).contains { if case .interactionsReset = $0.payload { return true }; if case .disconnected = $0.payload { return true }; return false })
    #expect(!events.dropFirst(marker).contains { if case .resolved(let id) = $0.payload { return id == approval.id }; return false })
    try await app.answer(approval.id, session: ordinary, response: .deny)
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    #expect(calls.filter { $0["method"].string == "turn/start" && $0["thread"].string == "chrome" }.count == 1)
    await app.stop()
}

@Test func dedicatedWorkerKeepsRunningChildrenAfterParentCompletion() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let integration = CodexIntegration()
    let app = AgentClient(integration: integration)
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    let descriptor = try await app.start(.init(executable: executable, home: root, resources: root, userChromeEnabled: true))
    var permissions = AgentPermissionProfile.workspace(); permissions.browser = .appAndUserChrome
    let grant = AgentUserChromeGrant(chatID: "chrome", profileID: UUID().uuidString, stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    let session = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct, userChromeGrant: grant)
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: permissions, model: "", effort: "", userChromeGrant: grant)
    _ = try await log.wait { if case .completed = $0.payload { return $0.session == session }; return false }
    try await integration.stopTasks("child", session: session, context: descriptor.context).value()
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let parent = try #require(calls.first { $0["method"].string == "turn/start" })
    let stop = try #require(calls.first { $0["method"].string == "turn/interrupt" })
    #expect(stop["pid"] == parent["pid"])
    #expect(stop["thread"].string == "child")
    await app.stop()
}

@Test func dedicatedWorkerScopeReplacementClearsItsBackgroundChildren() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration())
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root, resources: root, userChromeEnabled: true))
    var permissions = AgentPermissionProfile.workspace(); permissions.browser = .appAndUserChrome
    let grant = AgentUserChromeGrant(chatID: "chrome", profileID: UUID().uuidString, stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    let session = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct, userChromeGrant: grant)
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: permissions, model: "", effort: "", userChromeGrant: grant)
    _ = try await log.wait { if case .completed = $0.payload { return $0.session == session }; return false }
    permissions.browser = .app
    _ = try await app.send("revoked", to: session, projectPath: root.path, permissions: permissions, model: "", effort: "")
    _ = try await log.wait { if case .subagents(let values) = $0.payload { return $0.session == session && values.isEmpty }; return false }
    await app.stop()
}

@Test(arguments: ["approval", "children"])
func explicitSignOutStopsDedicatedWorkerWithoutAccountNotification(mode: String) async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let integration = CodexIntegration()
    let app = AgentClient(integration: integration)
    let log = WorkerEventLog()
    let observer = Task { for await event in app.events { await log.append(event) } }
    defer { observer.cancel() }
    _ = try await app.start(.init(executable: executable, home: root, resources: root, userChromeEnabled: true))
    var permissions = AgentPermissionProfile.workspace(); permissions.browser = .appAndUserChrome
    let grant = AgentUserChromeGrant(chatID: "chrome", profileID: UUID().uuidString, stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    let session = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct, userChromeGrant: grant)
    _ = try await app.send(mode, to: session, projectPath: root.path, permissions: permissions, model: "", effort: "", userChromeGrant: grant)
    let approvalID: UUID?
    if mode == "approval" {
        let event = try await log.wait { if case .interaction = $0.payload { return $0.session == session }; return false }
        guard case .interaction(let approval) = event.payload else { return }
        approvalID = approval.id
    } else {
        _ = try await log.wait { if case .subagents(let values) = $0.payload { return $0.session == session && values.contains { $0.status == .running } }; return false }
        _ = try await log.wait { if case .completed = $0.payload { return $0.session == session }; return false }
        approvalID = nil
    }
    let marker = await log.events.count
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let pid = Int32(try #require(calls.first { $0["method"].string == "turn/start" }?["pid"].int))
    _ = try await integration.authenticate(.signOut).value()
    if let approvalID {
        _ = try await log.wait(after: marker) { if case .resolved(let id) = $0.payload { return id == approvalID }; return false }
    }
    _ = try await log.wait(after: marker) { if case .subagents(let values) = $0.payload { return $0.session == session && values.isEmpty }; return false }
    for _ in 0..<500 {
        if Darwin.kill(pid, 0) != 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Darwin.kill(pid, 0) != 0)
    await app.stop()
}

@Test func chatReferenceScopeReplacesOnlyItsWorker() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AgentClient(integration: CodexIntegration())
    _ = try await app.start(.init(executable: executable, home: root))
    let permissions = AgentPermissionProfile.unrestricted
    let session = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct)
    let arguments = ["/app/server.py", "--chat", "caller", "--root", "/app/data", "--references", "/app/references.json"]
    for scope in [nil, arguments, arguments, nil] as [[String]?] {
        _ = try await app.send("children", to: session, projectPath: root.path, permissions: permissions, model: "", effort: "", chatDirectory: scope)
    }
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let turns = calls.filter { $0["method"].string == "turn/start" }
    #expect(turns.count == 4)
    #expect(turns[0]["pid"] != turns[1]["pid"])
    #expect(turns[1]["pid"] == turns[2]["pid"])
    #expect(turns[2]["pid"] != turns[3]["pid"])
    let resumes = calls.filter { $0["method"].string == "thread/resume" }
    #expect(resumes.count == 2)
    #expect(resumes[0]["params"]["config"]["mcp_servers.switchboard_chats"]["args"].array == (["-I"] + arguments).map(JSONValue.string))
    #expect(resumes[1]["params"]["config"]["mcp_servers.switchboard_chats"]["enabled"] == .bool(false))
    await app.stop()
}

@Test func firstTurnKeepsPreparedChatDirectoryWorkerWithoutResumingEmptyThread() async throws {
    let (root, executable) = try workerFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("require-rollout"))
    let app = AgentClient(integration: CodexIntegration())
    _ = try await app.start(.init(executable: executable, home: root))
    let scope = ["/app/server.py", "--chat", "reserved", "--diagnostics-project", root.path]
    let session = try await app.createSession(projectPath: root.path, permissions: .unrestricted,
                                              model: "", route: .direct, chatDirectory: scope)
    _ = try await app.send("children", to: session, projectPath: root.path, permissions: .unrestricted,
                           model: "", effort: "", chatDirectory: scope)
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let start = try #require(calls.first { $0["method"].string == "thread/start" })
    let turn = try #require(calls.first { $0["method"].string == "turn/start" })
    #expect(start["pid"] == turn["pid"])
    #expect(!calls.contains { ["thread/resume", "thread/unsubscribe"].contains($0["method"].string ?? "") })
    await app.stop()
}
