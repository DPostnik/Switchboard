@testable import CodexAdapter
import AgentContract
import ContextCore
import Foundation
import Testing

@Test func userChromeHonorsRoleGlobalToggleAndScheduledIsolation() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let grant = AgentUserChromeGrant(chatID: "chat", profileID: UUID().uuidString,
                                     stateDirectory: missing, capabilityFile: missing.appendingPathComponent("grant"))
    for browser in [AgentPermissionProfile.Browser.off, .app, .appAndUserChrome] {
        var profile = AgentRoleCatalog.preset("operator").profile
        profile.browser = browser
        for enabled in [false, true] {
            for scheduled in [false, true] {
                for authority in [nil, grant] where !enabled || browser != .appAndUserChrome || scheduled || authority == nil {
                    let config = try UserChromeConfiguration.configuration(enabled: enabled, permissions: profile, scheduled: scheduled,
                                                                            resources: missing, grant: authority)
                    let server = config["mcp_servers.switchboard_user_chrome"]
                    #expect(server["enabled"] == .bool(false))
                    #expect(server["command"] == .string("/usr/bin/false"))
                }
            }
        }
    }
}

@Test func userChromeUsesBundledExtensionAdapterWithExplicitChatAndProfileAuthority() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("UserChromeRuntime/server.py")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: script)
    var profile = AgentRoleCatalog.preset("operator").profile
    profile.browser = .appAndUserChrome
    let grant = AgentUserChromeGrant(chatID: "chat-id", profileID: UUID().uuidString,
                                     stateDirectory: root, capabilityFile: root.appendingPathComponent("private-grant"))
    let config = try UserChromeConfiguration.configuration(enabled: true, permissions: profile, scheduled: false, resources: root, grant: grant)
    let server = config["mcp_servers.switchboard_user_chrome"]
    #expect(server["enabled"] == .bool(true))
    #expect(server["required"] == .bool(true))
    #expect(server["command"] == .string("/usr/bin/python3"))
    #expect(server["args"].array.map(\.string) == ["-I", script.path, "mcp", "--state-dir", root.path,
        "--chat-id", grant.chatID, "--profile-id", grant.profileID, "--capability-file", grant.capabilityFile.path])
    let invalid = AgentUserChromeGrant(chatID: "chat", profileID: grant.profileID, stateDirectory: root,
                                       capabilityFile: root.deletingLastPathComponent().appendingPathComponent("outside"))
    #expect(throws: (any Error).self) {
        try UserChromeConfiguration.configuration(enabled: true, permissions: profile, scheduled: false, resources: root, grant: invalid)
    }
}

/// Mirrors real Codex: resume on a loaded thread keeps its original MCP configuration,
/// and a thread's writer lock stays with the process that loaded it until that process unloads it.
@Test func userChromeRoleChangeUsesColdWorkerWithoutChangingOtherChatsOrAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("UserChromeRuntime"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("UserChromeRuntime/server.py"))
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json,os,pathlib,sys
    root=pathlib.Path(os.environ['CODEX_HOME']); loaded={}
    locks=root/'locks'; locks.mkdir(exist_ok=True)
    unload_now=any(a=='-c' and b=='thread_unload_delay_secs=0' for a,b in zip(sys.argv,sys.argv[1:]))
    def alive(pid):
        try: os.kill(pid,0); return True
        except OSError: return False
    def writer(tid):
        lock=locks/tid
        return int(lock.read_text()) if lock.exists() and alive(int(lock.read_text())) else None
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method'];p=m.get('params',{});result={}
        tid=p.get('threadId','session')
        enabled=p.get('config',{}).get('mcp_servers.switchboard_user_chrome',{}).get('enabled',False)
        if method in ('thread/start','thread/resume') and writer(tid) not in (None,os.getpid()):
            with (root/'calls.jsonl').open('a') as f: f.write(json.dumps({'method':method+':conflict','pid':os.getpid()})+'\n')
            print(json.dumps({'id':m['id'],'error':{'code':-32600,'message':'thread '+tid+' already has an active writer'}}),flush=True)
            continue
        if method=='initialize': result={'userAgent':'codex/0.160.0 fixture'}
        if method=='thread/start': loaded[tid]=enabled;(locks/tid).write_text(str(os.getpid()));result={'thread':{'id':tid}}
        if method=='thread/resume' and tid not in loaded: loaded[tid]=enabled;(locks/tid).write_text(str(os.getpid()))
        if method=='thread/unsubscribe':
            result={'status':'unsubscribed' if tid in loaded else 'notLoaded'}
            if tid in loaded and unload_now: del loaded[tid];(locks/tid).unlink()
        if method=='thread/loaded/list': result={'data':list(loaded)}
        if method=='mcpServerStatus/list':
            result={'data':[{'name':'switchboard_user_chrome','tools':({'status':{'name':'status'}} if loaded.get(tid) else {})}]}
        if method=='turn/start':result={'turn':{'id':'turn'}}
        if method=='thread/read':result={'thread':{'id':tid,'turns':[]}}
        with (root/'calls.jsonl').open('a') as f:
            f.write(json.dumps({'method':method,'pid':os.getpid(),'enabled':loaded.get(tid,False)})+'\n')
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let integration = CodexIntegration()
    let app = AgentClient(integration: integration)
    let descriptor = try await app.start(.init(executable: executable, home: root, resources: root, userChromeEnabled: true))
    var permissions = AgentRoleCatalog.preset("operator").profile
    permissions.browser = .app
    let session = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct)
    let grant = AgentUserChromeGrant(chatID: "app-chat", profileID: UUID().uuidString,
                                     stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    permissions.browser = .appAndUserChrome
    try await app.resume(session, projectPath: root.path, permissions: permissions, route: .direct, userChromeGrant: grant)
    #expect(try await app.descriptor().context == descriptor.context)
    _ = try await app.send("Chrome permitted", to: session, projectPath: root.path, permissions: permissions,
                            model: "", effort: "", userChromeGrant: grant)
    _ = try await app.history(session)
    permissions.browser = .app
    _ = try await app.send("Chrome revoked", to: session, projectPath: root.path, permissions: permissions, model: "", effort: "")
    #expect(try await app.descriptor().context == descriptor.context)
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    let creation = try #require(calls.first { $0["method"].string == "thread/start" })
    let turns = calls.filter { $0["method"].string == "turn/start" }
    #expect(turns.count == 2)
    #expect(turns[0]["pid"] != creation["pid"])
    #expect(turns[0]["enabled"] == .bool(true))
    #expect(turns[1]["pid"] != turns[0]["pid"])
    #expect(turns[1]["enabled"] == .bool(false))
    #expect(calls.first { $0["method"].string == "thread/read" }?["pid"] == turns[0]["pid"])
    #expect(!calls.contains { $0["method"].string?.hasSuffix(":conflict") == true })
    let releases = calls.filter { $0["method"].string == "thread/unsubscribe" }.map { $0["pid"] }
    #expect(releases == [creation["pid"], turns[0]["pid"]])
    await app.stop()
}

/// A subagent's thread completes inside the parent's turn on the same Chrome worker. Stopping the worker
/// then aborted the parent turn and sent the next request to a process without the thread ("thread not found").
@Test func userChromeWorkerSurvivesSubagentTurnCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("UserChromeRuntime"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("UserChromeRuntime/server.py"))
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json,os,pathlib,sys
    root=pathlib.Path(os.environ['CODEX_HOME']); loaded=set()
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method'];p=m.get('params',{});result={}
        tid=p.get('threadId','session')
        if method=='initialize': result={'userAgent':'codex/0.160.0 fixture'}
        if method in ('thread/start','thread/resume'): loaded.add(tid);result={'thread':{'id':tid}}
        if method=='thread/unsubscribe': result={'status':'unsubscribed' if tid in loaded else 'notLoaded'};loaded.discard(tid)
        if method=='thread/loaded/list': result={'data':list(loaded)}
        if method=='mcpServerStatus/list': result={'data':[{'name':'switchboard_user_chrome','tools':{'status':{'name':'status'}}}]}
        if method=='turn/start':
            print(json.dumps({'method':'turn/completed','params':{'threadId':'child','turn':{'id':'child-turn','status':'completed'}}}),flush=True)
            result={'turn':{'id':'turn'}}
        if method in ('thread/read','turn/interrupt') and tid not in loaded:
            with (root/'calls.jsonl').open('a') as f: f.write(json.dumps({'method':method+':missing','pid':os.getpid()})+'\n')
            print(json.dumps({'id':m['id'],'error':{'code':-32600,'message':'thread not found: '+tid}}),flush=True)
            continue
        if method=='thread/read': result={'thread':{'id':tid,'turns':[]}}
        with (root/'calls.jsonl').open('a') as f: f.write(json.dumps({'method':method,'pid':os.getpid()})+'\n')
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let app = AgentClient(integration: CodexIntegration())
    _ = try await app.start(.init(executable: executable, home: root, resources: root, userChromeEnabled: true))
    var permissions = AgentRoleCatalog.preset("operator").profile
    permissions.browser = .appAndUserChrome
    let grant = AgentUserChromeGrant(chatID: "app-chat", profileID: UUID().uuidString,
                                     stateDirectory: root, capabilityFile: root.appendingPathComponent("grant"))
    let session = try await app.createSession(projectPath: root.path, permissions: permissions, model: "", route: .direct, userChromeGrant: grant)
    _ = try await app.send("Spawn a subagent", to: session, projectPath: root.path, permissions: permissions,
                            model: "", effort: "", userChromeGrant: grant)
    try await Task.sleep(for: .milliseconds(300))
    _ = try await app.history(session)
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    let turn = try #require(calls.first { $0["method"].string == "turn/start" })
    #expect(calls.first { $0["method"].string == "thread/read" }?["pid"] == turn["pid"])
    #expect(!calls.contains { $0["method"].string?.hasSuffix(":missing") == true })
    await app.stop()
}
