@_spi(NativeProtocol) @testable import CodexAdapter
import ContextCore
import AgentContract
import Foundation
import Testing

@Test func codexVersionGateUsesOnlyTheEngineProductToken() {
    for agent in ["context_desk/0.160.0 (Mac OS; arm64)", "context_desk/0.159.2 (Mac OS; arm64)", "context_desk/0.159.0 (Mac OS; arm64)", "codex/0.158.0-alpha.2.1 fixture"] {
        #expect(CodexProtocolCompatibility.accepts(userAgent: agent))
    }
    for agent in ["", "0.160.0", "/0.160.0", "codex/0.160.1 fixture", "codex/0.160.0-dev fixture", "codex/0.159.1 fixture", "codex/0.159.0-dev fixture",
                  "codex/999.0 client/0.159.0 fixture"] {
        #expect(!CodexProtocolCompatibility.accepts(userAgent: agent))
    }
}

/// Explicit opt-in: uses a temporary unauthenticated home and never sends a model turn.
@Test func installedCodexCompatibilityWithoutInference() async throws {
    guard ProcessInfo.processInfo.environment["SWITCHBOARD_CODEX_COMPATIBILITY_LIVE"] == "1" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let app = AgentClient(integration: CodexIntegration(client: CodexClient(transport: wire)))
    do {
        _ = try await app.start(.init(executable: Locations.codexExecutable(), home: root.appendingPathComponent("codex")))
        #expect(try await app.account().authenticated == false)
        try await app.registerWorkflows(at: root)
        await app.stop()

        // Exercise the real summary setup through the last pre-inference isolation checks.
        try await wire.start(executable: Locations.codexExecutable(), home: root.appendingPathComponent("codex"),
                             extraArguments: ArchiveSummaryRunner.isolationArguments)
        let config = try await wire.request("config/read", params: .object(["includeLayers": .bool(false)]))
        #expect(config["config"] != .null)
        let thread = try await wire.request("thread/start", params: .object([
            "ephemeral": .bool(true), "environments": .array([]), "runtimeWorkspaceRoots": .array([]),
            "selectedCapabilityRoots": .array([]), "dynamicTools": .array([]),
            "cwd": .string(root.path), "sandbox": .string("read-only"),
            "approvalPolicy": .string("untrusted"), "approvalsReviewer": .string("user"),
            "model": .string("gpt-6-astra"), "modelProvider": .string("openai"),
            "allowProviderModelFallback": .bool(false)
        ]))
        #expect(thread["thread"]["ephemeral"].bool == true)
        #expect(thread["thread"]["environments"] == .array([]))
        #expect(thread["sandbox"]["type"].string == "readOnly")
        #expect(thread["approvalPolicy"].string == "untrusted")
        #expect(thread["modelProvider"].string == "openai")
        #expect(thread["model"].string == "gpt-6-astra")
        let id = try #require(thread["thread"]["id"].string)
        let inventory = try await wire.request("mcpServerStatus/list", params: .object([
            "threadId": .string(id), "detail": .string("toolsAndAuthOnly")
        ]))
        #expect(inventory["data"] == .array([]))
        await wire.stop()
    } catch {
        await app.stop(); await wire.stop()
        throw error
    }
}

/// Real per-thread MCP startup and resume. Helper writes only its own launch identity.
@Test func installedCodexRoutesBrowserEnvironmentsWithoutInference() async throws {
    guard ProcessInfo.processInfo.environment["SWITCHBOARD_CODEX_COMPATIBILITY_LIVE"] == "1" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources")
    let scripts = resources.appendingPathComponent("BrowserRuntime")
    let browserRoot = root.appendingPathComponent("browser")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
    try Data().write(to: browserRoot.appendingPathComponent("runtime.json"))
    try Data(#"""
    import sys,json,pathlib,argparse
    p=argparse.ArgumentParser()
    p.add_argument('--root');p.add_argument('--environment');p.add_argument('--language');p.add_argument('--max-browsers');p.add_argument('--profile-lease')
    # The role's browser rights (BrowserLaunchPolicy.arguments) are always passed.
    p.add_argument('--import-scope');p.add_argument('--allow-eval',action='store_true');p.add_argument('--allow-upload',action='store_true')
    a=p.parse_args()
    with (pathlib.Path(a.root)/'launches.jsonl').open('a') as f: f.write(json.dumps({'environment':a.environment,'lease':a.profile_lease})+'\n')
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        r={'protocolVersion':m['params']['protocolVersion'],'capabilities':{'tools':{}},'serverInfo':{'name':'routing-fixture','version':'1'}} if m.get('method')=='initialize' else {'tools':[]}
        print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)
    """#.utf8).write(to: scripts.appendingPathComponent("server.py"))
    // This fixture has no Chrome; native profile selection still requires an idle check.
    try Data("print('{\"running\":false}')\n".utf8).write(to: scripts.appendingPathComponent("chrome_host.py"))
    // A deterministic local refusal persists a user turn without remote inference.
    let endpointScript = root.appendingPathComponent("endpoint.py")
    try Data(#"""
    import http.server,pathlib,sys
    root=pathlib.Path(sys.argv[1])
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length','0')))
            (root/'endpoint-called').write_text('local refusal')
            body=b'{"error":{"message":"Intentional local fixture refusal","type":"invalid_request_error"}}'
            self.send_response(400);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
        def log_message(self,*args): pass
    server=http.server.HTTPServer(('127.0.0.1',0),Handler)
    (root/'port').write_text(str(server.server_port))
    server.serve_forever()
    """#.utf8).write(to: endpointScript)
    let endpoint = Process(), endpointExited = DispatchSemaphore(value: 0)
    endpoint.terminationHandler = { _ in endpointExited.signal() }
    endpoint.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    endpoint.arguments = [endpointScript.path, root.path]
    endpoint.standardOutput = FileHandle.nullDevice; endpoint.standardError = FileHandle.nullDevice
    try endpoint.run()
    defer {
        if endpoint.isRunning { endpoint.terminate() }
        let exited = { endpointExited.wait(timeout: .now() + 5) == .success }()
        #expect(exited)
    }
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("port").path) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let port = try String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8)
    let overrides = ["model_providers.contextdesk_browser_fixture.name=\"Local fixture\"",
                     "model_providers.contextdesk_browser_fixture.wire_api=\"responses\"",
                     "model_providers.contextdesk_browser_fixture.stream_max_retries=0",
                     "model_providers.contextdesk_browser_fixture.base_url=\"http://127.0.0.1:\(port)/v1\"",
                     "model_providers.contextdesk_browser_fixture.requires_openai_auth=false", "model_providers.contextdesk_browser_fixture.supports_websockets=false",
                     "model_providers.contextdesk_browser_fixture.request_max_retries=0"].flatMap { ["-c", $0] }
    let wire = CodexConnection(), client: CodexClient
    client = CodexClient(transport: wire)
    do {
        let executable = try Locations.codexExecutable()
        let home = root.appendingPathComponent("codex")
        try await client.start(executable: executable, home: home, extraArguments: overrides, browserResources: resources, browserRoot: browserRoot)
        let first = try await client.createSession(projectPath: root.path, access: .standard, model: "", route: RequestRoute(rawValue: "browser_fixture"))
        let second = try await client.createSession(projectPath: root.path, access: .standard, model: "", route: RequestRoute(rawValue: "browser_fixture"))
        let a = try BrowserEnvironmentStore.environment(session: first.nativeID, root: browserRoot)
        let b = try BrowserEnvironmentStore.environment(session: second.nativeID, root: browserRoot)
        #expect(a != b)
        _ = try await client.send("Local browser routing fixture only", to: first, projectPath: root.path,
                                  access: .standard, model: "gpt-6-astra", effort: "low")
        var completed = false
        for _ in 0..<100 {
            let history: JSONValue
            do {
                history = try await wire.request("thread/read", params: .object([
                    "threadId": .string(first.nativeID), "includeTurns": .bool(true)]))
            } catch let error as ClientFailure where error.message.contains("rollout") && error.message.contains(" is empty") {
                // 0.160 can acknowledge turn/start before initial rollout flush.
                // Poll only this read; the local refusal turn is never resent.
                try await Task.sleep(for: .milliseconds(50)); continue
            }
            if history["thread"]["turns"].array.last?["status"].string == "failed" { completed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(completed)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("endpoint-called").path))
        await client.stop()
        try await client.start(executable: executable, home: home, extraArguments: overrides, browserResources: resources, browserRoot: browserRoot)
        try await client.resume(first, projectPath: root.path, access: .standard, route: RequestRoute(rawValue: "browser_fixture"))
        let profiles = BrowserProfileStore(root: browserRoot)
        try profiles.rename(session: first, name: "Live routing fixture")
        try profiles.release(session: first, verifyClosed: { _ in })
        let reused = try await client.createSession(projectPath: root.path, access: .standard, model: "", route: RequestRoute(rawValue: "browser_fixture"),
                                                    browserProfile: .init(id: a))
        #expect(try profiles.ownedGrant(session: reused).environment == a)
        let log = try String(contentsOf: browserRoot.appendingPathComponent("launches.jsonl"), encoding: .utf8)
        let identities = try log.split(separator: "\n").map { line in
            try JSONDecoder().decode([String: String].self, from: Data(line.utf8))["environment"]
        }
        #expect(identities == [a.uuidString.lowercased(), b.uuidString.lowercased(), a.uuidString.lowercased(), a.uuidString.lowercased()])
        let leases = try log.split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8))["lease"] }
        #expect(leases.count == 4 && leases[0] == leases[2] && leases[0] != leases[3])
        await client.stop()
        try await client.start(executable: executable, home: home, extraArguments: overrides)
        try await client.resume(first, projectPath: root.path, access: .standard, route: RequestRoute(rawValue: "browser_fixture"))
        _ = try await client.createSession(projectPath: root.path, access: .standard, model: "", route: RequestRoute(rawValue: "browser_fixture"))
        #expect(try String(contentsOf: browserRoot.appendingPathComponent("launches.jsonl"), encoding: .utf8) == log)
        await client.stop()
    } catch {
        await client.stop()
        throw error
    }
}
