import Foundation
import Testing
import AgentContract
import ContextCore
@_spi(NativeProtocol) import CodexAdapter

private func commandFixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, os, pathlib, sys
    root = pathlib.Path(os.environ['CODEX_HOME'])
    calls = []
    chrome_enabled = False
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method, p = m.get('method'), m.get('params', {})
        result = {}
        if method == 'test/calls': result = calls
        else:
            calls.append({'method': method, 'params': p})
            if method == 'initialize': result = {'userAgent': 'fixture'}
            if method == 'thread/start': result = {'thread': {'id': (root/'session-id').read_text() if (root/'session-id').exists() else 'native-session'}}
            if method == 'thread/resume' and (root/'lose-resume').exists():
                with (root/'resume-dispatches').open('a') as capture: capture.write('sent\n')
                sys.exit(0)
            if method in ('thread/start', 'thread/resume'):
                chrome_enabled = p.get('config', {}).get('mcp_servers.switchboard_user_chrome', {}).get('enabled', False)
            if method == 'mcpServerStatus/list':
                result = {'data': ([{'name': 'switchboard_user_chrome', 'tools': {'status': {'name': 'status'}}}]
                                   if chrome_enabled and not (root/'missing-chrome-tools').exists() else []), 'nextCursor': None}
            if method == 'turn/start': result = {'turn': {'id': 'native-turn'}}
            if method == 'account/read': result = {'account': {'planType': 'fixture-plan'}}
            if method == 'account/login/start':
                result = {'authUrl': (root/'url').read_text() if (root/'url').exists() else 'https://auth.openai.com/login'}
            if method == 'model/list': result = {'data': [
                {'model': 'fixture-model', 'displayName': 'Fixture', 'isDefault': True,
                 'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': 'low'}]},
                {'displayName': 'Missing identifier'}]}
            if method == 'thread/read':
                result = {'thread': {'id': p['threadId'], 'turns': []}}
                if (root/'history').exists(): result = json.loads((root/'history').read_text())
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return (root, executable)
}

@Test func typedCommandsPreserveNativeRoutingAndPermissionPayloads() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection(), client: CodexClient
    client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root)
    let session = try await client.createSession(projectPath: "/workspace", access: .standard,
                                                 model: "fixture-model", route: .direct)
    #expect(session == AgentSessionReference(connection: .originalCodex, nativeID: "native-session"))
    try await client.resume(session, projectPath: "/workspace", access: .standard, route: .direct)
    #expect(try await client.send("literal $() and `data`", to: session, projectPath: "/workspace", access: .standard,
                                 model: "fixture-model", effort: "low") == "native-turn")
    _ = try await client.send("full", to: session, projectPath: "/workspace", access: .fullAccess, model: "", effort: "")
    try await client.interrupt(session, turn: "native-turn")
    try await client.rename(session, title: "Проверка / Check")
    try await client.setArchived(true, session: session)
    try await client.setArchived(false, session: session)
    try await client.delete(session)
    let calls = try await wire.request("test/calls").array
    let starts = calls.filter { $0["method"].string == "turn/start" }
    #expect(starts.count == 2)
    #expect(starts[0]["params"]["threadId"].string == session.nativeID)
    #expect(starts[0]["params"]["input"].array.first?["text"].string == "literal $() and `data`")
    #expect(starts[0]["params"]["sandboxPolicy"]["networkAccess"].bool == false)
    #expect(starts[0]["params"]["sandboxPolicy"]["writableRoots"] == .array([.string("/workspace")]))
    #expect(starts[0]["params"]["approvalPolicy"].string == "on-request")
    #expect(starts[1]["params"]["sandboxPolicy"]["type"].string == "dangerFullAccess")
    #expect(starts[1]["params"]["approvalPolicy"].string == "never")
    #expect(starts[1]["params"]["model"] == .null && starts[1]["params"]["effort"] == .null)
    #expect(calls.first { $0["method"].string == "thread/start" }?["params"]["modelProvider"].string == "openai")
    for method in ["thread/start", "thread/resume"] {
        #expect(calls.first { $0["method"].string == method }?["params"]["developerInstructions"].string == AgentAutonomy.instructions())
    }
    #expect(calls.first { $0["method"].string == "turn/interrupt" }?["params"]["turnId"].string == "native-turn")
    #expect(calls.suffix(3).compactMap { $0["method"].string } == ["thread/archive", "thread/unarchive", "thread/delete"])
    await client.stop()
}

@Test func typedCommandsRejectForeignSessionsBeforeAnyDispatch() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection(), client: CodexClient
    client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root)
    for session in [AgentSessionReference(connection: AgentConnectionID(agent: .codex, id: UUID()), nativeID: "same"),
                    AgentSessionReference(connection: AgentConnectionID(agent: .claudeCode, id: UUID()), nativeID: "same"),
                    AgentSessionReference(connection: .originalCodex, nativeID: "")] {
        await #expect(throws: ClientFailure.self) { try await client.resume(session, projectPath: "/tmp", access: .standard, route: .direct) }
        await #expect(throws: ClientFailure.self) { try await client.send("x", to: session, projectPath: "/tmp", access: .standard, model: "", effort: "") }
        await #expect(throws: ClientFailure.self) { try await client.interrupt(session, turn: "t") }
        await #expect(throws: ClientFailure.self) { try await client.rename(session, title: "x") }
        await #expect(throws: ClientFailure.self) { try await client.setArchived(true, session: session) }
        await #expect(throws: ClientFailure.self) { try await client.delete(session) }
        await #expect(throws: ClientFailure.self) { try await client.history(session) }
        await #expect(throws: ClientFailure.self) { try await client.summarySource(session) }
    }
    #expect(try await wire.request("test/calls").array.compactMap { $0["method"].string } == ["initialize"])
    await client.stop()
}

@Test func typedDiscoveryAndHistoryRejectMalformedIdentityWithoutFallback() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = CodexClient()
    try await client.start(executable: executable, home: root)
    let account = try await client.account()
    #expect(account.authenticated && account.plan == "fixture-plan")
    let models = try await client.models()
    #expect(models == [CodexModel(id: "fixture-model", displayName: "Fixture", isDefault: true, defaultEffort: "low", efforts: ["low"])])
    #expect(try await client.signInURL().host == "auth.openai.com")
    for url in ["https://auth.openai.com.evil.test/login", "http://auth.openai.com/login", "file:///tmp/login"] {
        try Data(url.utf8).write(to: root.appendingPathComponent("url"))
        await #expect(throws: ClientFailure.self) { try await client.signInURL() }
    }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "expected")
    #expect(try await client.history(session).isEmpty)
    for raw in [#"{"thread":{"id":"other","turns":[]}}"#,
                #"{"thread":{"id":"expected"}}"#] {
        try Data(raw.utf8).write(to: root.appendingPathComponent("history"))
        await #expect(throws: ClientFailure.self) { try await client.history(session) }
        await #expect(throws: ClientFailure.self) { try await client.summarySource(session) }
    }
    await client.stop()
}

@Test func browserBindingSurvivesReconnectAndDisableOverridesPersistedConfig() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources")
    let scripts = resources.appendingPathComponent("BrowserRuntime")
    let browserRoot = root.appendingPathComponent("browser")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
    try Data().write(to: scripts.appendingPathComponent("server.py"))
    try Data().write(to: browserRoot.appendingPathComponent("runtime.json"))
    let wire = CodexConnection()
    let first = CodexClient(transport: wire)
    try await first.start(executable: executable, home: root, browserResources: resources, browserRoot: browserRoot)
    let session = try await first.createSession(projectPath: root.path, access: .standard, model: "", route: .direct)
    let calls = try await wire.request("test/calls").array
    let config = try #require(calls.first { $0["method"].string == "thread/start" })["params"]["config"]
    let args = config["mcp_servers.switchboard_browser"]["args"].array
    #expect(args.contains(.string("--environment")))
    #expect(config["mcp_servers.switchboard_browser"]["required"].bool == true)
    await first.stop()
    // New client object, same saved native session: resolve from disk.
    let resumedWire = CodexConnection(), resumed: CodexClient
    resumed = CodexClient(transport: resumedWire)
    try await resumed.start(executable: executable, home: root, browserResources: resources, browserRoot: browserRoot)
    try await resumed.resume(session, projectPath: root.path, access: .standard, route: .direct)
    let resumeCalls = try await resumedWire.request("test/calls").array
    #expect(resumeCalls.first { $0["method"].string == "thread/resume" }?["params"]["config"] == config)
    await resumed.stop()
    // Disabled setting must explicitly override configuration saved by Codex.
    let disabledWire = CodexConnection(), disabled: CodexClient
    disabled = CodexClient(transport: disabledWire)
    try await disabled.start(executable: executable, home: root)
    try await disabled.resume(session, projectPath: root.path, access: .standard, route: .direct)
    let disabledCalls = try await disabledWire.request("test/calls").array
    #expect(disabledCalls.first { $0["method"].string == "thread/resume" }?["params"]["config"]["mcp_servers.switchboard_browser"]["enabled"].bool == false)
    await disabled.stop()
}

@Test func codexProfileSelectionUsesSameDirectoryAndLostConfigurationIsNotRetried() async throws {
    let (rawRoot, executable) = try commandFixture()
    let root = rawRoot.resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources"), browserRoot = root.appendingPathComponent("browser")
    let scripts = resources.appendingPathComponent("BrowserRuntime")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
    try Data().write(to: scripts.appendingPathComponent("server.py"))
    try Data("print('{\"running\":false}')\n".utf8).write(to: scripts.appendingPathComponent("chrome_host.py"))
    try Data().write(to: browserRoot.appendingPathComponent("runtime.json"))
    let wire = CodexConnection(), client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root, browserResources: resources, browserRoot: browserRoot)
    let first = try await client.createSession(projectPath: root.path, access: .standard, model: "", route: .direct)
    let store = BrowserProfileStore(root: browserRoot)
    let initial = try store.ownedGrant(session: first)
    try store.rename(session: first, name: "Work")
    try store.release(session: first, verifyClosed: { _ in })
    try Data("second-session".utf8).write(to: root.appendingPathComponent("session-id"))
    let second = try await client.createSession(projectPath: root.path, access: .standard, model: "", route: .direct,
                                               browserProfile: .init(id: initial.environment))
    let reused = try store.ownedGrant(session: second)
    #expect(reused.environment == initial.environment && reused.generation != initial.generation)
    let calls = try await wire.request("test/calls").array.filter { $0["method"].string == "thread/start" }
    let args = calls.map { $0["params"]["config"]["mcp_servers.switchboard_browser"]["args"].array }
    #expect(args.count == 2)
    #expect(args.allSatisfy { $0.contains(.string(initial.environment.uuidString.lowercased())) })
    #expect(args[1].contains(.string(reused.generation.uuidString.lowercased())))
    await #expect(throws: BrowserProfileError.released) { try await client.resume(first, projectPath: root.path, access: .standard, route: .direct) }
    try store.select(nil, session: second, project: root.path, verifyClosed: { _ in })
    try Data().write(to: root.appendingPathComponent("lose-resume"))
    await #expect(throws: (any Error).self) { try await client.resume(second, projectPath: root.path, access: .standard, route: .direct) }
    await #expect(throws: BrowserProfileError.uncertain) { try await client.resume(second, projectPath: root.path, access: .standard, route: .direct) }
    #expect(try String(contentsOf: root.appendingPathComponent("resume-dispatches"), encoding: .utf8) == "sent\n")
    await client.stop()
}

@Test func diagnosticsMCPBindsProjectWithoutBrowserAndDisablesBeforeRoleDowngrade() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("resources")
    let runtime = resources.appendingPathComponent("ChatDirectoryRuntime")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    try Data().write(to: runtime.appendingPathComponent("server.py"))
    let wire = CodexConnection()
    let client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root, diagnosticsResources: resources)
    let allowed = AgentPermissionProfile.workspace()
    let session = try await client.createSession(projectPath: "/workspace-one", permissions: allowed, model: "", route: .direct)
    var calls = try await wire.request("test/calls").array
    let initial = try #require(calls.first { $0["method"].string == "thread/start" })["params"]["config"]
    #expect(initial["mcp_servers.switchboard_browser"]["enabled"].bool == false)
    #expect(initial["mcp_servers.switchboard_diagnostics"]["enabled"].bool == true)
    #expect(initial["mcp_servers.switchboard_diagnostics"]["args"].array.contains(.string("/workspace-one")))
    var denied = allowed
    denied.shell = .off
    _ = try await client.send("reader turn", to: session, projectPath: "/workspace-one", permissions: denied, model: "", effort: "")
    calls = try await wire.request("test/calls").array
    let lastTwo = Array(calls.suffix(2))
    #expect(lastTwo.map { $0["method"].string } == ["thread/resume", "turn/start"])
    let disabled = lastTwo[0]["params"]["config"]["mcp_servers.switchboard_diagnostics"]
    #expect(disabled["enabled"].bool == false)
    #expect(disabled["command"].string == "/usr/bin/false")
    #expect(disabled["args"].array.isEmpty)
    _ = try await client.send("new project", to: session, projectPath: "/workspace-two", permissions: allowed, model: "", effort: "")
    calls = try await wire.request("test/calls").array
    let rebound = Array(calls.suffix(2))
    #expect(rebound.map { $0["method"].string } == ["thread/resume", "turn/start"])
    #expect(rebound[0]["params"]["config"]["mcp_servers.switchboard_diagnostics"]["args"].array.contains(.string("/workspace-two")))
    _ = try await client.send("same scope", to: session, projectPath: "/workspace-two", permissions: allowed, model: "", effort: "")
    let finalCalls = try await wire.request("test/calls").array
    #expect(finalCalls.count == calls.count + 1)
    #expect(finalCalls.last?["method"].string == "turn/start")
    await client.stop()
}

@Test func userChromePermissionRevocationOverridesSavedThreadBeforeSend() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("UserChromeRuntime/server.py")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: script)
    let grant = AgentUserChromeGrant(chatID: "app-chat", profileID: UUID().uuidString,
                                     stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    let wire = CodexConnection()
    // Use a dedicated transport so the fixture captures the exact thread configuration.
    let captured = CodexClient(transport: wire)
    try await captured.start(executable: executable, home: root, diagnosticsResources: root, browserRoot: root, userChromeEnabled: true)
    var profile = AgentRoleCatalog.preset(AgentRoleID.fullOperator).profile
    let session = try await captured.createSession(projectPath: root.path, permissions: profile, model: "", route: .direct, userChromeGrant: grant)
    profile.browser = .app
    _ = try await captured.send("continue", to: session, projectPath: root.path, permissions: profile, model: "", effort: "")
    let calls = try await wire.request("test/calls").array
    let start = try #require(calls.first { $0["method"].string == "thread/start" })
    let resume = try #require(calls.first { $0["method"].string == "thread/resume" })
    #expect(start["params"]["config"]["mcp_servers.switchboard_user_chrome"]["enabled"] == .bool(true))
    #expect(resume["params"]["config"]["mcp_servers.switchboard_user_chrome"]["enabled"] == .bool(false))
    #expect(!resume["params"]["developerInstructions"].string!.contains("tools control the user's regular"))
    #expect(calls.firstIndex(of: resume)! < calls.firstIndex { $0["method"].string == "turn/start" }!)
    await captured.stop()
}


@Test func userChromeGrantRotationAndColdResumeRequireDiscoveredTools() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("UserChromeRuntime/server.py")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: script)
    let grant = AgentUserChromeGrant(chatID: "app-chat", profileID: UUID().uuidString,
                                     stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    var profile = AgentRoleCatalog.preset("operator").profile
    profile.browser = .appAndUserChrome
    let wire = CodexConnection(), client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root, diagnosticsResources: root, userChromeEnabled: true)
    let session = try await client.createSession(projectPath: root.path, permissions: profile, model: "", route: .direct, userChromeGrant: grant)
    let rotated = AgentUserChromeGrant(chatID: grant.chatID, profileID: grant.profileID, stateDirectory: root,
                                       capabilityFile: root.appendingPathComponent("rotated-grant"))
    _ = try await client.send("rotated grant", to: session, projectPath: root.path, permissions: profile,
                              model: "", effort: "", userChromeGrant: rotated)
    let calls = try await wire.request("test/calls").array
    #expect(calls.suffix(3).map { $0["method"].string } == ["thread/resume", "mcpServerStatus/list", "turn/start"])
    #expect(calls.first { $0["method"].string == "thread/start" }?["params"]["config"]["mcp_servers.switchboard_user_chrome"]["enabled"] == .bool(true))
    await client.stop()
    let cold = CodexClient(transport: wire)
    try await cold.start(executable: executable, home: root, diagnosticsResources: root, userChromeEnabled: true)
    try Data().write(to: root.appendingPathComponent("missing-chrome-tools"))
    await #expect(throws: ClientFailure.self) {
        try await cold.resume(session, projectPath: root.path, permissions: profile, route: .direct, userChromeGrant: grant)
    }
    let coldCalls = try await wire.request("test/calls").array
    #expect(coldCalls.last?["method"].string == "mcpServerStatus/list")
    #expect(!coldCalls.contains { $0["method"].string == "turn/start" })
    await cold.stop()
}
