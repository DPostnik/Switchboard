import Foundation
import Testing
@testable import ClaudeAdapter
@testable import ContextCore
@testable import ContextDesk

private actor ClaudeEvents {
    var values: [AgentEvent] = []
    func append(_ event: AgentEvent) { values.append(event) }
    func completion() -> AgentExecutionOutcome? {
        for event in values { if case .completed(let result) = event.payload { return result.status } }
        return nil
    }
    func completionCount() -> Int {
        values.filter { if case .completed = $0.payload { return true }; return false }.count
    }
    func usage() -> [(turn: String?, total: TokenCounters?, snapshot: UsageSnapshot)] {
        values.compactMap { if case .usage(let turn, let total, let snapshot) = $0.payload { return (turn, total, snapshot) }; return nil }
    }
    func statuses() -> [String?] {
        values.compactMap { if case .status(_, let text) = $0.payload { return .some(text) }; return nil }
    }
    func subagents() -> [[AgentSubagent]] {
        values.compactMap { if case .subagents(let list) = $0.payload { return list }; return nil }
    }
    func background() -> [Int] {
        values.compactMap { if case .background(let tasks) = $0.payload { return tasks }; return nil }
    }
    func diagnostics() -> [String] {
        values.compactMap { if case .diagnostic(let text) = $0.payload { return text }; return nil }
    }
    func startedCount() -> Int {
        values.filter { if case .started = $0.payload { return true }; return false }.count
    }
    func interaction() -> AgentInteraction? {
        for event in values { if case .interaction(let request) = event.payload { return request } }
        return nil
    }
    func capabilities() -> [AgentCapabilityRecord] {
        values.compactMap { if case .capability(let record) = $0.payload { return record }; return nil }
    }
}
private func interactiveFixture(_ root: URL) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("claude.py")
    let script = #"""
    #!\#(fixturePython)
    import sys,os,json,pathlib,time,threading
    home=pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])
    if '--version' in sys.argv:
        print('2.1.292 (Claude Code)'); sys.exit(0)
    if sys.argv[1:3] == ['auth','status']:
        if (home/'auth-delay').exists(): time.sleep(float((home/'auth-delay').read_text()))
        if (home/'invalid-auth').exists(): print('{}'); sys.exit(1)
        print(json.dumps({'loggedIn':True,'apiProvider':'firstParty','authMethod':'oauth','email':(home/'account').read_text() if (home/'account').exists() else 'fixture'})); sys.exit(0)
    if sys.argv[1:3] == ['auth','logout']: sys.exit(0)
    if '--json-schema' in sys.argv:
        a=sys.argv
        assert a[a.index('--tools')+1]=='' and '--no-session-persistence' in a and '--safe-mode' in a and '--disable-slash-commands' in a
        assert a[a.index('--setting-sources')+1]=='' and '--strict-mcp-config' in a and a[a.index('--mcp-config')+1]=='{"mcpServers":{}}'
        assert not any(k in a for k in ['--resume','--session-id','--append-system-prompt','--input-format'])
        assert not any(k in os.environ for k in ['ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_BASE_URL','BASH_ENV','NODE_OPTIONS'])
        text=sys.stdin.read()
        with (home/'generated').open('a') as f: f.write(json.dumps({'args':a,'cwd':os.getcwd(),'input':text})+'\n')
        mode=(home/'generation-mode').read_text() if (home/'generation-mode').exists() else 'success'
        if mode=='hang': time.sleep(30); sys.exit(1)
        props=json.loads(a[a.index('--json-schema')+1])['properties']
        if 'title' in props: value={'title':'Fixture title'}
        elif 'overview' in props:
            refs=[f['reference'] for f in json.loads(text.split('\n',1)[1])]
            value={'overview':'Fixture overview','activities':[{'goal':'Say hello','actions':['Greeted'],'outcome':'Done','unfinished':[],
                'reusableSteps':[],'variableInputs':[],'evidence':['missing/ref' if mode=='invalid' else refs[0]]}]}
        else: value={k:'Fixture '+k for k in props}
        usage={'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':70,'output_tokens':5}
        if mode=='error':
            print(json.dumps({'type':'result','subtype':'error_during_execution','is_error':True,'result':'boom','usage':usage,'permission_denials':[]})); sys.exit(1)
        print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':json.dumps(value),'structured_output':value,'usage':usage,'permission_denials':[]})); sys.exit(0)
    browser='--mcp-config' in sys.argv and 'switchboard_browser' in sys.argv[sys.argv.index('--mcp-config')+1]
    full=sys.argv[sys.argv.index('--permission-mode')+1]=='bypassPermissions'
    editor='--restricted' in sys.argv and sys.argv[sys.argv.index('--tools')+1]=='Read,Glob,Grep,Write,Edit,AskUserQuestion'
    connectors='--strict-mcp-config' not in sys.argv
    assert ('--safe-mode' in sys.argv) == (not browser and not connectors) and '--setting-sources' in sys.argv
    # The editor and operator roles keep the old standard/full flags; scheduled operator turns run without connector approval rules.
    assert (not (full or editor)) or connectors == full
    assert not editor or '--settings' not in sys.argv
    assert '--append-system-prompt' in sys.argv
    assert len(sys.argv[sys.argv.index('--append-system-prompt')+1]) > 100
    assert sys.argv[sys.argv.index('--setting-sources')+1] == ''
    assert not any(k in os.environ for k in ['ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_BASE_URL','BASH_ENV','NODE_OPTIONS'])
    sid=sys.argv[sys.argv.index('--resume' if '--resume' in sys.argv else '--session-id')+1]
    def out(value): print(json.dumps(value),flush=True)
    def result(): out({'type':'result','session_id':sid,'is_error':False,
        'usage':{'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':70,'output_tokens':5},
        'modelUsage':{'claude-helper':{'contextWindow':5000,'inputTokens':1},'claude-test':{'contextWindow':1000,'inputTokens':10}}})
    out({'type':'system','subtype':'init','session_id':sid,'model':'claude-test'})
    with (home/'launches').open('a') as f: f.write(sid+'\n')
    def tasks(*ids): out({'type':'system','subtype':'background_tasks_changed','session_id':sid,'tasks':[{'task_id':i,'task_type':'local_agent'} for i in ids]})
    def woke():
        out({'type':'assistant','session_id':sid,'parent_tool_use_id':'call1','message':{'id':'sub-done','content':[{'type':'text','text':'sub-report'}]}})
        out({'type':'system','subtype':'task_notification','session_id':sid,'task_id':'b1','tool_use_id':'call1','status':'completed','summary':'sub-report','usage':{'total_tokens':120,'tool_uses':1}})
        tasks()
        out({'type':'system','subtype':'init','session_id':sid,'model':'claude-test'})
        out({'type':'assistant','session_id':sid,'message':{'id':'woke-'+sid,'content':[{'type':'text','text':'woke'}]}})
        result()
    for line in sys.stdin:
        value=json.loads(line)
        if value['type']=='control_request':
            with (home/'controls').open('a') as f: f.write(json.dumps({'request':value['request'],'pid':os.getpid()})+'\n')
            if value['request']['subtype']=='stop_task' and (home/'refuse-stop').exists():
                out({'type':'control_response','response':{'subtype':'error','request_id':value['request_id'],'error':'Task is busy'}}); continue
            out({'type':'control_response','response':{'subtype':'success','request_id':value['request_id'],'response':{}}})
            if value['request']['subtype']=='interrupt': result()
            if value['request']['subtype']=='stop_task':
                out({'type':'system','subtype':'task_notification','session_id':sid,'task_id':value['request']['task_id'],'status':'stopped','summary':'stopped'})
            if value['request']['subtype']=='initialize' and (home/'own-turn').exists():
                # A resumed CLI runs a turn of its own (a notification about the previous process's tasks) before it answers.
                (home/'own-turn').unlink()
                out({'type':'system','subtype':'task_notification','session_id':sid,'task_id':'old','status':'stopped','summary':'old task'})
                out({'type':'system','subtype':'init','session_id':sid,'model':'claude-test'})
                out({'type':'assistant','session_id':sid,'message':{'id':'own-'+sid,'content':[{'type':'text','text':'No response requested.'}]}})
                result()
                time.sleep(0.5) # The real answer waits for MCP servers to start.
                tasks()
        elif value['type']=='user':
            record=json.loads((home/'contextdesk-sessions'/(sid+'.json')).read_text())
            assert record['active'] and record['sent']
            with (home/'submitted').open('a') as f: f.write(json.dumps({'prompt':value['message']['content'],'args':sys.argv,'pid':os.getpid(),'env':{k:os.environ[k] for k in ['MCP_TIMEOUT','MCP_TOOL_TIMEOUT','CLAUDE_CODE_DISABLE_CLAUDE_MDS','CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES','MCP_CONNECTION_NONBLOCKING'] if k in os.environ}})+'\n')
            prompt=value['message']['content']
            if prompt=='broken': print('invalid-json',flush=True); continue
            if prompt=='notified':
                # A resumed CLI first answers a notification about the previous process's task, with the message still queued.
                def life(state): out({'type':'command_lifecycle','session_id':sid,'command_uuid':value['uuid'],'state':state,'uuid':'x-'+state})
                out({'type':'system','subtype':'task_notification','session_id':sid,'task_id':'old','status':'stopped','summary':'old task'})
                out({'type':'system','subtype':'init','session_id':sid,'model':'claude-test'})
                life('queued')
                out({'type':'assistant','session_id':sid,'message':{'id':'own-'+sid,'content':[{'type':'text','text':'No response requested.'}]}})
                result()
                life('started')
                out({'type':'system','subtype':'init','session_id':sid,'model':'claude-test'})
                out({'type':'assistant','session_id':sid,'message':{'id':'handled-'+sid,'content':[{'type':'text','text':'handled'}]}})
                life('completed')
                result()
                continue
            if prompt=='unknown': out({'type':'control_request','request_id':'unknown','request':{'subtype':'unexpected_action'}}); continue
            if prompt=='wait': continue
            if prompt.startswith('hook:'):
                out({'type':'control_request','request_id':'hook-'+prompt[5:],'request':{'subtype':'hook_callback','callback_id':'switchboard-bash','tool_use_id':'t-hook',
                     'input':{'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':prompt[5:]},'session_id':sid,'cwd':os.getcwd()}}})
                continue
            if prompt.startswith('background'):
                tasks('b1')
                out({'type':'system','subtype':'task_started','session_id':sid,'task_id':'b1','tool_use_id':'call1','description':'Check sources','subagent_type':'general-purpose','is_backgrounded':True,'task_type':'local_agent','prompt':'Look'})
                out({'type':'assistant','session_id':sid,'parent_tool_use_id':'call1','message':{'id':'sub-1','content':[{'type':'text','text':'sub-step'},{'type':'tool_use','id':'r1','name':'Read','input':{'file_path':'a.txt'}}]}})
                out({'type':'user','session_id':sid,'parent_tool_use_id':'call1','message':{'content':[{'type':'tool_result','tool_use_id':'r1','content':'contents'}]}})
                out({'type':'system','subtype':'task_progress','session_id':sid,'task_id':'b1','description':'Reading a.txt','usage':{'total_tokens':50,'tool_uses':1}})
                out({'type':'assistant','session_id':sid,'message':{'id':'launched-'+sid,'content':[{'type':'text','text':'launched'}]}})
                result()
                if prompt=='background': threading.Timer(0.3, woke).start()
                if prompt=='background-idle': threading.Timer(0.3, tasks).start()
                continue
            if prompt in ['approval','question','outside','connector']:
                name='AskUserQuestion' if prompt=='question' else 'mcp__claude_ai_Gmail__send_message' if prompt=='connector' else 'Write'
                args={'questions':[{'question':'Choose','options':[{'label':'Yes','description':'Go ahead','preview':'print(1)'},{'label':'No','description':' '}]}]} if prompt=='question' else {'file_path':'/outside-project/file' if prompt=='outside' else str(pathlib.Path.cwd()/'fixture.txt'),'content':'content'}
                out({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':name,'input':args}})
                continue
            usage={'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':70,'output_tokens':1}
            out({'type':'stream_event','session_id':sid,'event':{'type':'message_start','message':{'id':'answer-'+sid,'usage':usage}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':0,'content_block':{'type':'thinking','thinking':''}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':1,'content_block':{'type':'tool_use','id':'t1','name':'Grep','input':{}}}})
            out({'type':'stream_event','session_id':sid,'parent_tool_use_id':'task','event':{'type':'message_start','message':{'id':'sub-'+sid,'usage':{'input_tokens':9000,'output_tokens':1}}}})
            out({'type':'stream_event','session_id':sid,'parent_tool_use_id':'task','event':{'type':'content_block_start','index':0,'content_block':{'type':'tool_use','id':'t2','name':'Read','input':{}}}})
            out({'type':'tool_use_summary','session_id':sid,'summary':'Searched\n  the project ','preceding_tool_use_ids':['t1']})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':2,'content_block':{'type':'thinking','thinking':''}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':3,'content_block':{'type':'text','text':''}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'hello'}}})
            out({'type':'assistant','session_id':sid,'message':{'id':'answer-'+sid,'usage':usage,'content':[{'type':'text','text':'hello'}]}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'message_delta','usage':{'output_tokens':5}}})
            result()
        elif value['type']=='control_response':
            (home/'answer').write_text(json.dumps(value))
            result()
    """#
    try Data(script.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return executable
}
private func waitFor(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<1500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ClientFailure("Fixture timed out")
}
private func interactiveRequest(context: AgentContext, root: URL, session: AgentSessionReference? = nil, prompt: String = "hello", id: UUID = UUID(),
                                fullAccess: Bool = false, kind: AgentExecutionRequest.Kind = .interactive, model: String = "",
                                role: AgentPermissionProfile? = nil) -> AgentExecutionRequest {
    .init(id: id, conversation: ConversationID(), session: session, kind: kind, prompt: prompt, projectPath: root.path,
          permissions: role.map { .profile($0, root: root.path) } ?? (fullAccess ? .unrestricted(approval: .never) : .workspaceWrite(root: root.path, network: false, approval: .ask)),
          model: .init(context: context, model: model), route: .direct)
}

@Test func claudeEditorWritesInsideTheProjectWithoutAsking() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "approval")).value()
    try await waitFor { await events.completion() != nil }
    #expect(await events.interaction() == nil)
    let reply = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("answer")))["response"]["response"]
    #expect(reply["behavior"].string == "allow")
    #expect(await events.capabilities().map(\.decision) == [.allowed])
    let launch = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8)
    #expect(launch.contains("acceptEdits") && launch.contains("--restricted"))
    await adapter.disconnect()
}

@Test func claudeDeveloperRoleRegistersTheCommandHookAndAnswersByRole() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let developer = AgentRoleCatalog.preset(AgentRoleID.developer).profile
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, role: developer)).value()
    var expected: [(String, String?)] = [("sudo ls", "deny"), ("rm -rf ../build", "ask"), ("rm -rf build", nil), ("swift build", nil)]
    for (command, decision) in expected {
        let before = await events.completionCount()
        _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "hook:" + command, role: developer)).value()
        try await waitFor { await events.completionCount() == before + 1 }
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("answer")))["response"]
        #expect(reply["request_id"].string == "hook-" + command)
        #expect(reply["response"]["hookSpecificOutput"]["permissionDecision"].string == decision)
        if decision == nil { #expect(reply["response"] == .object([:])) }
    }
    expected.removeAll()
    let launch = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8)
    #expect(launch.contains("acceptEdits") && launch.contains("Grep,Write,Edit,Bash,WebFetch") && !launch.contains("--restricted"))
    let controls = try String(contentsOf: home.appendingPathComponent("controls"), encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    let initialize = try #require(controls.first { $0["request"]["subtype"].string == "initialize" })
    #expect(initialize["request"]["hooks"]["PreToolUse"].array.first?["matcher"].string == "Bash")
    #expect(initialize["request"]["hooks"]["PreToolUse"].array.first?["hookCallbackIds"].array == [.string("switchboard-bash")])
    let recorded = await events.capabilities().filter { $0.capability == .shell }
    #expect(recorded.map(\.decision) == [.hookDenied, .hookAsked] && recorded.first?.target == "sudo ls")
    // The editor role registers no hook at all.
    let editor = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: editor)).value()
    try await waitFor { await events.completionCount() == 5 }
    let later = try String(contentsOf: home.appendingPathComponent("controls"), encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }.filter { $0["request"]["subtype"].string == "initialize" }
    #expect(later.count == 2 && later.last?["request"]["hooks"] == .null)
    await adapter.disconnect()
}

@Test func claudeInteractiveKeepsProcessWarmAcrossTurnsUntilSettingsChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    func turn(_ model: String, expected: Int) async throws {
        _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, model: model)).value()
        try await waitFor { await events.completionCount() == expected }
    }
    try await turn("", expected: 1)
    try await turn("", expected: 2)
    try await turn("claude-other", expected: 3)
    let sent = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    try #require(sent.count == 3)
    // The second turn is written to the first process; a model change starts a resumed one.
    #expect(sent[0]["pid"] == sent[1]["pid"])
    #expect(sent[2]["pid"] != sent[1]["pid"])
    #expect(sent[2]["args"].array.contains(.string("--resume")))
    #expect(sent[2]["args"].array.contains(.string("claude-other")))
    // A warm process is idle, so the chat can still be summarized.
    _ = try await adapter.summarySource(session, context: descriptor.context).value()
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.count == 3 && history.allSatisfy { $0.items.map(\.kind) == ["user", "assistant"] })
    await adapter.disconnect()
}

@Test func claudeWarmProcessIsClosedAfterIdleTimeout() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(warmTimeout: .milliseconds(200)), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 1 }
    try await Task.sleep(for: .milliseconds(600))
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 2 }
    let sent = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    try #require(sent.count == 2)
    // The idle process was closed, so the next turn resumes native history in a new one.
    #expect(sent[0]["pid"] != sent[1]["pid"])
    #expect(sent[1]["args"].array.contains(.string("--resume")))
    #expect(await events.diagnostics().isEmpty)
    await adapter.disconnect()
}

@Test func claudeChatsLaunchTheirOwnBrowserProfileAndRestartAfterReassignment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let resources = root.appendingPathComponent("Resources"), browserRoot = root.appendingPathComponent("browser")
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("BrowserRuntime"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
    try Data("# fixture".utf8).write(to: resources.appendingPathComponent("BrowserRuntime/server.py"))
    let adapter = ClaudeIntegration(browserRoot: browserRoot), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    // The runtime is not installed yet: fail loudly instead of a silently browser-less chat.
    guard case .failed = await adapter.connect(.init(executable: binary, home: home, resources: resources, browserEnabled: true)) else {
        Issue.record("Missing browser runtime accepted"); return
    }
    try Data("{}".utf8).write(to: browserRoot.appendingPathComponent("runtime.json"))
    let descriptor = try await adapter.connect(.init(executable: binary, home: home, resources: resources, browserEnabled: true)).value()
    #expect(descriptor.capabilities.contains(.browserProfiles))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    let store = BrowserProfileStore(root: browserRoot)
    let first = try store.ownedGrant(session: session)
    #expect(try store.current(session: session)?.connection == .appClaude)

    func turn(_ index: Int) async throws -> [String: Any] {
        _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
        try await waitFor { await events.completionCount() == index }
        let lines = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
        return try #require(JSONSerialization.jsonObject(with: Data(lines[index - 1].utf8)) as? [String: Any])
    }
    func lease(_ record: [String: Any]) throws -> String {
        let args = try #require(record["args"] as? [String])
        let config = args[try #require(args.firstIndex(of: "--mcp-config")) + 1]
        let server = try #require(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let browser = try #require((server["mcpServers"] as? [String: Any])?["switchboard_browser"] as? [String: Any])
        let argv = try #require(browser["args"] as? [String])
        #expect(argv.first == resources.appendingPathComponent("BrowserRuntime/server.py").path)
        return argv[try #require(argv.firstIndex(of: "--profile-lease")) + 1]
    }
    let one = try await turn(1)
    let args = try #require(one["args"] as? [String])
    #expect(!args.contains("--safe-mode") && args.contains("--disable-slash-commands"))
    #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == "mcp__switchboard_browser")
    #expect(one["env"] as? [String: String] == ["MCP_TIMEOUT": "30000", "MCP_TOOL_TIMEOUT": "90000", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
                                                   "CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES": "1"])
    #expect(try lease(one) == first.generation.uuidString.lowercased())

    // Reopening keeps the chat's profile.
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    #expect(try store.ownedGrant(session: session) == first)
    #expect(try lease(await turn(2)) == first.generation.uuidString.lowercased())

    // A reassigned profile only reaches the agent through a new launch.
    try store.select(nil, session: session, project: root.path) { _ in }
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    let second = try store.ownedGrant(session: session)
    #expect(second.environment != first.environment)
    #expect(try lease(await turn(3)) == second.generation.uuidString.lowercased())
}

@Test func claudeSendDuringAnotherAccountCheckIsDelivered() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    // A background title/summary re-check is still probing the login when the user sends.
    try Data("1.5".utf8).write(to: home.appendingPathComponent("auth-delay"))
    let check = Task { await adapter.account() }
    try await Task.sleep(for: .milliseconds(300))
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == .completed)
    guard case .success(let account) = await check.value else { Issue.record("Account re-check failed"); return }
    #expect(account.authenticated)
}

@Test func claudeToolResultShowsTextInsteadOfBlockJSON() throws {
    let blocks = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"type":"text","text":"Clicked on element ref_644"},{"type":"image","source":{"data":"AAAA"}},{"type":"text","text":"\n\nTab Context:\n- Executed on tabId: 1"}]"#.utf8))
    let text = ClaudeIntegration.toolResultText(blocks)
    #expect(text.hasPrefix("Clicked on element ref_644\n"))
    #expect(text.hasSuffix("Tab Context:\n- Executed on tabId: 1"))
    #expect(!text.contains("\"type\"") && !text.contains("AAAA"))
    #expect(ClaudeIntegration.toolResultText(.string("done")) == "done")
}

@Test func claudeProgressSummaryIsOneBoundedLine() {
    #expect(ClaudeIntegration.progressSummary(" \n ") == nil)
    #expect(ClaudeIntegration.progressSummary(nil) == nil)
    #expect(ClaudeIntegration.progressSummary("Inspecting pipeline lock\n and open questions") == "Inspecting pipeline lock and open questions")
    let long = ClaudeIntegration.progressSummary(String(repeating: "a", count: 300))
    #expect(long?.count == 120 && long?.hasSuffix("…") == true)
}

@Test func claudeInteractivePersistsStreamsResumesAndRejectsReplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    #expect(descriptor.context.connection == .appClaude)
    #expect(descriptor.capabilities.contains(.usage))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    let request = interactiveRequest(context: descriptor.context, root: root, session: session)
    _ = try await adapter.submit(request).value()
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == .completed)
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.count == 1)
    #expect(history[0].items.map(\.kind) == ["user", "assistant"])
    #expect(history[0].items.last?.agentName == "Claude")
    #expect(!history[0].isComplete)
    #expect(await events.values.contains { if case .delta(_, _, "hello") = $0.payload { return true }; return false })
    // Thinking and tool starts are announced before any text; the CLI's progress summary then
    // replaces generic labels for the rest of the turn, and streamed text clears the line.
    #expect(await events.statuses() == [ClaudeIntegration.thinkingLabel, ClaudeIntegration.thinkingLabel,
        ClaudeIntegration.toolLabel("Grep", main: true), ClaudeIntegration.thinkingLabel,
        ClaudeIntegration.toolLabel("Read", main: false), "Searched the project", "Searched the project", nil])
    let first = await events.usage()
    #expect(first.first?.turn == nil && first.first?.total == .zero)
    // Subagent calls stay out of the main context; the window comes from the session model.
    #expect(first.allSatisfy { ($0.snapshot.last ?? 0) < 9000 })
    #expect(first.last?.snapshot == UsageSnapshot(last: 105, window: 1000, input: 100, cached: 70, output: 5, measuredAt: first.last!.snapshot.measuredAt))
    #expect(first.last?.snapshot.contextFraction == 0.105)
    guard case .rejected(.unknownRequest) = await adapter.submit(request) else { Issue.record("Replay accepted"); return }
    await adapter.disconnect()
    let next = try await adapter.connect(.init(executable: binary, home: home)).value()
    #expect(try await adapter.history(session, context: next.context).value().count == 1)
    _ = try await adapter.prepare(interactiveRequest(context: next.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: next.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 2 }
    // Totals persist with the adapter session record and stay cumulative after reconnecting.
    let resumed = await events.usage().dropFirst(first.count)
    #expect(resumed.first?.turn == nil && resumed.first?.total == TokenCounters(input: 100, cached: 70, output: 5))
    #expect(resumed.first?.snapshot.window == 1000)
    #expect(resumed.last?.total == TokenCounters(input: 200, cached: 140, output: 10))
    #expect(resumed.last?.snapshot.last == 105)
    let sent = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
    try #require(sent.count == 2)
    #expect(sent[1].contains("--resume"))
    await adapter.disconnect()
}

@Test(arguments: ["approval", "question", "outside"]) func claudeInteractivePermissionRoundTrip(_ prompt: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    // A role that still asks for project writes, so the fixture's in-project Write reaches the user.
    var asking = AgentPermissionProfile.workspace(); asking.projectWrites = .ask
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, role: asking)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: prompt, role: asking)).value()
    if prompt != "outside" {
        try await waitFor {
            let action = await events.interaction(), completion = await events.completion()
            return action != nil || completion != nil
        }
        let interaction = try #require(await events.interaction())
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("answer").path))
        if prompt == "question" {
            // Option descriptions and previews travel with the label; blank descriptions are dropped.
            guard case .questions(let fields) = interaction.kind else { Issue.record("Expected questions"); return }
            #expect(fields.map(\.options) == [[.init(label: "Yes", description: "Go ahead", preview: "print(1)"), .init(label: "No")]])
        }
        let response: AgentInteractionResponse = prompt == "question" ? .answers(["Choose": "Yes"]) : .allowOnce
        _ = try await adapter.answer(interaction.id, session: session, context: descriptor.context, response: response).value()
        guard case .rejected(.unknownRequest) = await adapter.answer(interaction.id, session: session, context: descriptor.context, response: response) else { Issue.record("Approval reused"); return }
    }
    try await waitFor { await events.completion() != nil }
    let reply = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("answer")))["response"]["response"]
    #expect(reply["behavior"].string == (prompt == "outside" ? "deny" : "allow"))
    if prompt == "question" { #expect(reply["updatedInput"]["answers"]["Choose"].string == "Yes") }
    await adapter.disconnect()
}

@Test func claudeFullAccessLoadsAccountConnectorsAndAsksBeforeTheirActions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, fullAccess: true)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "connector", fullAccess: true)).value()
    try await waitFor {
        let action = await events.interaction(), completion = await events.completion()
        return action != nil || completion != nil
    }
    let interaction = try #require(await events.interaction())
    #expect(interaction.reason == "mcp__claude_ai_Gmail__send_message")
    _ = try await adapter.answer(interaction.id, session: session, context: descriptor.context, response: .deny).value()
    try await waitFor { await events.completion() != nil }
    let reply = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("answer")))["response"]["response"]
    #expect(reply["behavior"].string == "deny")
    let record = try #require(JSONSerialization.jsonObject(with: Data(try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8)
        .split(separator: "\n")[0].utf8)) as? [String: Any])
    let args = try #require(record["args"] as? [String])
    #expect(!args.contains("--strict-mcp-config") && !args.contains("--safe-mode") && args.contains("--disable-slash-commands"))
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(args[try #require(args.firstIndex(of: "--settings")) + 1].utf8))
    let rules = settings["permissions"]["ask"].array.compactMap(\.string)
    #expect(rules.contains("mcp__claude_ai_*__*send*") && rules.contains("mcp__claude_ai_*__*trash*") && !rules.contains { $0.contains("search") })
    #expect(record["env"] as? [String: String] == ["MCP_TIMEOUT": "30000", "MCP_TOOL_TIMEOUT": "90000", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
                                                      "CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES": "1", "MCP_CONNECTION_NONBLOCKING": "false"])
    // The same chat in standard access launches without connectors; their requests fail closed.
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "connector")).value()
    try await waitFor { await events.completionCount() == 2 }
    let standard = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
    try #require(standard.count == 2)
    #expect(standard[1].contains("--strict-mcp-config") && standard[1].contains("--safe-mode"))
    let denied = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("answer")))["response"]["response"]
    #expect(denied["behavior"].string == "deny" && denied["message"].string == L10n.text("Неподдерживаемый запрос", "Unsupported request"))
    await adapter.disconnect()
}

@Test func claudeScheduledTurnRunsUnattendedAndItsChatContinuesWithApprovals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    #expect(descriptor.capabilities.contains(.scheduledExecution))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, fullAccess: true)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, fullAccess: true, kind: .scheduled)).value()
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == .completed)
    // A follow-up in the run's chat resumes the same session in a fresh CLI that holds connector actions for approval.
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, fullAccess: true)).value()
    try await waitFor { await events.completionCount() == 2 }
    let launches = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
    try #require(launches.count == 2)
    #expect(launches[0].contains("--session-id") && !launches[0].contains("--settings") && !launches[0].contains("--strict-mcp-config"))
    #expect(launches[1].contains("--resume") && launches[1].contains("--settings"))
    #expect(try await adapter.history(session, context: descriptor.context).value().count == 2)
    await adapter.disconnect()
}

@Test func claudeMessageDuringScheduledBackgroundTasksKeepsThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    func lines(_ name: String) throws -> [JSONValue] {
        try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, fullAccess: true)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "background-hang",
                                                    fullAccess: true, kind: .scheduled)).value()
    try await waitFor { await events.background() == [1] }
    // The user's message goes to the CLI still running the run's sub-agent, with connector approvals applied to it live.
    for count in [2, 3] {
        _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session, fullAccess: true)).value()
        _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, fullAccess: true)).value()
        try await waitFor { await events.completionCount() == count }
    }
    let submitted = try lines("submitted")
    #expect(submitted.count == 3 && Set(submitted.map { $0["pid"] }).count == 1)
    #expect(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count == 1)
    let applied = try lines("controls").filter { $0["request"]["subtype"].string == "apply_flag_settings" }
    #expect(applied.count == 1 && applied.first?["request"]["settings"] == ClaudeIntegration.approvalSettings(access: .fullAccess, scheduled: false))
    #expect(await events.subagents().last?.first?.status == .running)
    #expect(await events.diagnostics().isEmpty)
    await adapter.disconnect()
}

@Test @MainActor func claudeScheduledJobRunsAsAChatThatCanBeContinued() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    _ = try await adapter.connect(.init(executable: binary, home: home)).value()
    let model = DeskModel(claudeIntegration: adapter, store: AppStore(file: root.appendingPathComponent("store.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"), claudeHome: home,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let pump = Task { for await event in model.claudeConnection.events { await model.receiveClaude(event) } }
    defer { pump.cancel() }
    var project = Project(path: root.path); project.accessMode = .fullAccess
    model.state.projects = [project]; model.schedulerReady = true
    model.claudeConnected = true; model.claudeAuthenticated = true
    var job = ManagedJob(); job.name = "Morning"; job.prompt = "hello"; job.engine = .claude; job.projectID = project.id
    job.model = "claude-test"; job.effort = ""; job.enabled = true
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    for _ in 0..<1500 where !(model.jobLedger.runs.first?.status == .completed) { try await Task.sleep(for: .milliseconds(10)) }
    // The run is a regular Claude chat in the app's profile, not a read-only record.
    let run = try #require(model.jobLedger.runs.first)
    let chat = try #require(model.state.chats.first)
    #expect(run.threadID == chat.id && !chat.isScheduledRecord && chat.title == "Morning")
    #expect(chat.nativeSession?.connection == .appClaude && chat.accessMode == .fullAccess)
    await model.openChat(chat)
    #expect(model.items.map(\.kind) == ["user", "assistant"])
    model.draft = "hello"
    #expect(model.canSend)
    await model.send()
    for _ in 0..<1500 where !(!model.isBusy(threadID: chat.id) && model.items.filter { $0.kind == "user" }.count == 2) { try await Task.sleep(for: .milliseconds(10)) }
    let launches = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
    try #require(launches.count == 2)
    #expect(launches[0].contains("claude-test") && !launches[0].contains("--settings"))
    #expect(launches[1].contains("--resume") && launches[1].contains("--settings"))
    #expect(model.state.chats.count == 1 && model.error == nil)
    await model.stopScheduler()
    await model.shutdown()
}

@Test @MainActor func phoneStartsClaudeChatWithChosenModelWhileCodexIsOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    _ = try await adapter.connect(.init(executable: binary, home: home)).value()
    let model = DeskModel(claudeIntegration: adapter, store: AppStore(file: root.appendingPathComponent("store.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"), claudeHome: home,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let pump = Task { for await event in model.claudeConnection.events { await model.receiveClaude(event) } }
    defer { pump.cancel() }
    var project = Project(path: root.path)
    project.defaultChatAccessMode = .fullAccess // The phone may pick full access only up to the project's default role.
    model.state.projects = [project]; model.state.defaultConnection = .appClaude; model.state.claudeModel = "claude-sonnet-5-5"
    let ids = [project.id.uuidString]
    #expect(await model.remoteSnapshot(projects: Set(ids)).projects.first?.canCreateChat == false)
    model.claudeConnected = true; model.claudeAuthenticated = true
    let offered = try #require(await model.remoteSnapshot(projects: Set(ids)).projects.first)
    #expect(offered.canCreateChat == true && offered.settings?.canEdit == true)
    #expect(offered.settings?.options.model == "claude-sonnet-5-5")
    #expect(offered.newChatModels?.map(\.id) == ClaudeModel.catalog.filter { $0.isSupported() }.map(\.id))
    #expect(offered.newChatModels?.allSatisfy { $0.agent == RemoteModelOption.claudeAgent } == true)
    let unknown = RemoteCommand.newChat(owner: UUID().uuidString, device: UUID().uuidString, project: ids[0], text: "hello",
                                        options: RemoteChatOptions(model: "claude-unknown"))
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(unknown) }
    let command = RemoteCommand.newChat(owner: unknown.owner, device: unknown.device, project: ids[0], text: "hello",
                                        options: RemoteChatOptions(model: "claude-fable-5-1", access: .fullAccess))
    #expect(try await model.executeRemote(command) == "submitted")
    let chat = try #require(model.state.chats.first)
    #expect(chat.id == command.chat && chat.nativeSession?.connection == .appClaude)
    #expect(chat.model == "claude-fable-5-1" && chat.route == .direct && chat.accessMode == .fullAccess)
    #expect(model.chatID == nil && model.state.claudeModel == "claude-sonnet-5-5")
    let submitted = home.appendingPathComponent("submitted")
    for _ in 0..<1500 where (try? String(contentsOf: submitted, encoding: .utf8))?.contains("claude-fable-5-1") != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try String(contentsOf: submitted, encoding: .utf8).contains("claude-fable-5-1"))
    #expect(model.state.chats.count == 1)
    await model.shutdown()
}

@Test(arguments: ["broken", "unknown", "wait"]) func claudeInteractiveUncertainAndInterrupt(_ prompt: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    let handle = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: prompt)).value()
    if prompt == "wait" { _ = try await adapter.cancel(handle).value() }
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == (prompt == "wait" ? .cancelled : .uncertain))
    #expect(try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n").count == 1)
    await adapter.disconnect()
}

@Test func claudeInteractiveAccountChangeInvalidatesPreparedTurnAndLoginIsIsolated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home with space")
    let adapter = ClaudeIntegration()
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    guard case .openLocalSignIn(let script) = try await adapter.authenticate(.beginSignIn).value() else { Issue.record("No local sign-in"); return }
    let text = try String(contentsOf: script, encoding: .utf8)
    #expect(text.contains("auth login --claudeai"))
    #expect(text.contains("CLAUDE_CONFIG_DIR=" + home.path))
    #expect(text.contains("/usr/bin/env -i"))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    try Data("other-account".utf8).write(to: home.appendingPathComponent("account"))
    guard case .rejected(.staleContext) = await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)) else { Issue.record("Account change accepted"); return }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("submitted").path))
    await adapter.disconnect()
}

@Test @MainActor func chatSelectionAndDisconnectAreScopedToAgent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil)
    let project = Project(path: root.path)
    let codex = Chat(session: .init(connection: .originalCodex, nativeID: "same-native-id"), projectID: project.id, title: "Codex", model: "codex")
    let claude = Chat(session: .init(connection: .appClaude, nativeID: "same-native-id"), projectID: project.id, title: "Claude", model: "claude")
    model.state.projects = [project]; model.state.chats = [codex, claude]; model.projectID = project.id
    model.chatID = claude.id; model.claudeConnected = true; model.claudeAuthenticated = true; model.draft = "hello"
    #expect(model.currentAgent == .appClaude)
    #expect(model.canSend)
    #expect(model.supportsSummaries(claude.id))
    // Summaries run on the chat's own connection; Codex is disconnected here.
    #expect(model.canGenerateSummary(claude.id) && !model.canGenerateSummary(codex.id))
    #expect(model.generationRunner(for: claude.id) === model.claudeSummaryRunner)
    #expect(model.generationEnvironment(for: claude.id, workspace: "w").home == model.claudeHome)
    // An idle chat waiting for background tasks says so and holds a restart until its agent resumes.
    await model.receive(.init(session: claude.nativeSession, payload: .background(tasks: 2)))
    #expect(model.backgroundWaitNotice(claude.id)?.contains("2") == true && model.backgroundWaitNotice(codex.id) == nil)
    #expect(model.restartBlockers.contains(L10n.text("Ждёт фоновые задачи: ", "Waiting for background tasks: ") + "Claude"))
    #expect(!model.readyForRestart)
    await model.receive(.init(session: claude.nativeSession, payload: .started(turn: "claude-turn")))
    #expect(model.backgroundWaits.isEmpty && model.backgroundWaitNotice(claude.id) == nil)
    // Sub-agent previews belong to their own chat and disappear with an empty list.
    let subagent = AgentSubagent(id: "a1", title: "Check", type: nil, prompt: "", background: true, depth: 1, startedAt: Date())
    await model.receive(.init(session: claude.nativeSession, payload: .subagents([subagent])))
    #expect(model.subagents[claude.id] == [subagent] && model.subagents[codex.id] == nil)
    #expect(SubagentsBar.summary([subagent]) == L10n.text("Подагенты: работают 1", "Sub-agents: 1 running"))
    // A running sub-agent holds a restart even before the background wait is reported; a finished one does not.
    await model.receive(.init(session: claude.nativeSession, payload: .completed(.init(id: "claude-turn", status: .completed, hasError: false, error: nil,
        history: AgentHistoryTurn(id: "claude-turn", items: [], startedAt: nil, completedAt: nil, duration: nil, isComplete: true)))))
    #expect(model.backgroundWorkChatIDs == [claude.id] && !model.readyForRestart)
    #expect(model.restartBlockers.contains(L10n.text("Ждёт фоновые задачи: ", "Waiting for background tasks: ") + "Claude"))
    var finished = subagent; finished.status = .completed
    await model.receive(.init(session: claude.nativeSession, payload: .subagents([finished])))
    #expect(model.backgroundWorkChatIDs.isEmpty)
    await model.receive(.init(session: claude.nativeSession, payload: .subagents([])))
    #expect(model.subagents.isEmpty)
    await model.receive(.init(session: claude.nativeSession, payload: .started(turn: "claude-turn-2")))
    await model.receive(.init(session: codex.nativeSession, payload: .started(turn: "codex-turn")))
    await model.receive(.init(session: nil, payload: .disconnected))
    #expect(model.isBusy(threadID: claude.id))
    #expect(!model.isBusy(threadID: codex.id))
    #expect(try model.clientForChat(claude.id) === model.claudeConnection)
    #expect(try model.clientForChat(codex.id) === model.connection)
}

@Test @MainActor func claudeHandoffAndArchiveUseAppMetadataWithoutDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    _ = try await adapter.connect(.init(executable: binary, home: home)).value()
    let store = AppStore(file: root.appendingPathComponent("store.sqlite"))
    let model = DeskModel(claudeIntegration: adapter, store: store, pluginDirectory: root.appendingPathComponent("plugins"),
                          summaryResources: claudeSkills, summaryHome: root.appendingPathComponent("codex"), claudeHome: home)
    let project = Project(path: root.path)
    model.state.projects = [project]; model.projectID = project.id
    model.claudeConnected = true; model.claudeAuthenticated = true
    var handoff = ContextHandoff(snapshot: .init(conversation: ConversationID("source"), source: .init(connection: .originalCodex, nativeID: "source-native"), revision: "revision", capturedAt: Date(), completeness: .partial, items: []))
    handoff.goal = "Continue review"
    #expect(await model.createHandoffChat(handoff, project: project, route: .direct, agent: .appClaude))
    let chat = try #require(model.selectedChat)
    #expect(chat.nativeSession?.connection == .appClaude)
    #expect(chat.handoffOrigin == handoff.origin)
    #expect(!model.draft.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("submitted").path))
    await model.renameChat(chat.id, title: "Claude review")
    await model.setChatArchived(chat.id, archived: true)
    #expect(model.isArchived(chat.id))
    #expect(model.archiveSummaries[chat.id] == nil)
    await model.queueMissingArchiveSummaries()
    await model.summaryTask?.value
    // A chat without turns has nothing to summarize: the record completes without a model call.
    #expect(model.archiveSummaries[chat.id]?.status == .ready)
    #expect(model.archiveSummaries[chat.id]?.partCount == 0)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("generated").path))
    await model.setChatArchived(chat.id, archived: false)
    #expect(!model.isArchived(chat.id))
    await adapter.disconnect()
}

@Test func claudeInvalidAuthStatusCannotReuseEarlierAuthentication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    try Data().write(to: home.appendingPathComponent("invalid-auth"))
    guard case .failed = await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)) else { Issue.record("Malformed account status allowed dispatch"); return }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("submitted").path))
    await adapter.disconnect()
}

@Test func claudeProjectPathsResolveAliasesNewFilesAndDenyEscapingSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
    #expect(ClaudeIntegration.isWithinProject(alias.appendingPathComponent("new/f.txt").path, cwd: workspace.path))
    #expect(ClaudeIntegration.isWithinProject("nested/new.txt", cwd: workspace.path))
    let escape = workspace.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: root)
    #expect(!ClaudeIntegration.isWithinProject("escape/new.txt", cwd: workspace.path))
    #expect(!ClaudeIntegration.isWithinProject("../new.txt", cwd: workspace.path))
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
    #expect(!ClaudeIntegration.isWithinProject("dangling/new.txt", cwd: workspace.path))
}

@Test func claudeUsageMeterMergesRepeatedBlocksAndAbandonedTurns() {
    var meter = ClaudeUsageMeter(base: .init(input: 50, cached: 10, output: 3), window: 200_000, last: 53)
    let start: JSONValue = .object(["input_tokens": .number(4), "cache_creation_input_tokens": .number(6), "cache_read_input_tokens": .number(90), "output_tokens": .number(1)])
    var changed = meter.observe(message: "a", usage: start); #expect(changed)
    changed = meter.observe(message: "a", usage: start); #expect(!changed)
    changed = meter.observe(message: "a", usage: .object(["output_tokens": .number(7)])); #expect(changed)
    #expect(meter.last == 107)
    #expect(meter.total == TokenCounters(input: 150, cached: 100, output: 10))
    changed = meter.observe(message: "b", usage: .object(["unexpected": .bool(true)])); #expect(!changed)
    changed = meter.observe(message: "b", usage: .object(["input_tokens": .number(1), "cache_read_input_tokens": .number(110), "output_tokens": .number(2)])); #expect(changed)
    #expect(meter.last == 113)
    // A smaller turn summary cannot shrink what the stream already reported.
    var reported = meter
    reported.complete(result: .object(["usage": .object(["input_tokens": .number(1), "output_tokens": .number(1)])]))
    #expect(reported.base == TokenCounters(input: 261, cached: 210, output: 12))
    #expect(reported.window == 200_000)
    meter.abandon()
    #expect(meter.base == TokenCounters(input: 261, cached: 210, output: 12))
    #expect(meter.snapshot().contextFraction == 113.0 / 200_000)
    #expect(ClaudeUsageMeter.window(.object(["x": .object(["contextWindow": .number(1_000_000), "inputTokens": .number(500)]),
        "y": .object(["contextWindow": .number(200_000), "inputTokens": .number(5)])]), model: "unknown") == 1_000_000)
}

@MainActor @Test func usageFooterShowsSizeBeforeWindowIsKnown() {
    #expect(UsageDetail.footer(nil, language: .english) == "Context: no data")
    #expect(UsageDetail.footer(UsageSnapshot(last: 12_345), language: .english) == "Context: 12,345 tokens")
    #expect(UsageDetail.footer(UsageSnapshot(last: 500, window: 1000), language: .english) == "Context ≈50%")
    #expect(UsageDetail.footer(UsageSnapshot(last: 12_345), language: .russian) == "Контекст (токены): 12\u{a0}345")
    #expect(UsageDetail.footer(UsageSnapshot(last: 500, window: 1000), language: .russian) == "Контекст ≈50%")
    #expect(UsageDetail.footer(nil, language: .russian) == "Контекст: нет данных")
}

private let claudeSkills = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Skills")
private actor StartCounter {
    var value = 0
    func increment() { value += 1 }
}
private func generationRequest(_ recipe: AgentGenerationRequest.Recipe, context: AgentContext, session: AgentSessionReference,
                               input: String, id: UUID = UUID()) -> AgentGenerationRequest {
    .init(id: id, source: session, recipe: recipe, historicalInput: input, model: .init(context: context, model: "claude-test"), route: .direct, language: "en")
}
private func generatedCalls(_ home: URL) -> [JSONValue] {
    guard let text = try? String(contentsOf: home.appendingPathComponent("generated"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
}
/// Connects the fixture and completes one "hello" turn, returning the source chunk to summarize.
private func completedClaudeSession(_ adapter: ClaudeIntegration, binary: URL, home: URL, root: URL) async throws -> (AgentDescriptor, AgentSessionReference, SummarySource.Chunk) {
    let events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completion() != nil }
    let source = try await adapter.summarySource(session, context: descriptor.context).value()
    let chunks = try SummarySource(digest: source.digest, fragments: source.fragments.map { .init(reference: $0.reference, kind: $0.kind, text: $0.text) },
                                   turnDates: source.turnDates, omittedDetails: source.omittedDetails).chunks
    return (descriptor, session, try #require(chunks.first))
}

@Test func claudeIsolatedGenerationSummarizesTitlesAndHandsOffWithoutTouchingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (descriptor, session, chunk) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    #expect(descriptor.capabilities.contains(.isolatedGeneration))
    #expect(chunk.fragments.map(\.kind) == ["userMessage", "agentMessage"])
    #expect(chunk.fragments.first?.text == "hello")
    let workspace = root.appendingPathComponent("workspace")
    let environment = AgentGenerationEnvironment(executable: nil, home: home, workspace: workspace,
                                                 recipeDirectory: claudeSkills.appendingPathComponent("archive-summary"))
    let starts = StartCounter()
    let request = generationRequest(.archiveSummaryV1, context: descriptor.context, session: session, input: chunk.json)
    guard case .summary(let summary, let usage, _) = try await adapter.generate(request, environment: environment, willStart: { await starts.increment() }).value() else {
        Issue.record("No summary"); return
    }
    #expect(summary.overview == "Fixture overview")
    #expect(summary.activities.first?.evidence == [chunk.fragments[0].reference])
    #expect(usage == AgentUsage(input: 100, cachedInput: 70, output: 5))
    #expect(await starts.value == 1)
    guard case .rejected(.unknownRequest) = await adapter.generate(request, environment: environment, willStart: {}) else { Issue.record("Replay accepted"); return }
    guard case .title(let title) = try await adapter.generate(generationRequest(.chatTitleV1, context: descriptor.context, session: session, input: "hello"),
                                                              environment: environment, willStart: {}).value() else { Issue.record("No title"); return }
    #expect(title == "Fixture title")
    guard case .handoff(let handoff) = try await adapter.generate(generationRequest(.contextHandoffV1, context: descriptor.context, session: session, input: "{}"),
                                                                  environment: environment, willStart: {}).value() else { Issue.record("No handoff"); return }
    #expect(try HandoffSummary.validate(handoff).goal == "Fixture goal")
    let calls = generatedCalls(home)
    #expect(calls.count == 3)
    #expect(calls.allSatisfy { ($0["cwd"].string ?? "").hasSuffix("/workspace") })
    #expect(calls[0]["input"].string?.hasPrefix("The following JSON is historical evidence") == true)
    // Generation never resumes or extends the source conversation.
    #expect(try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n").count == 1)
    #expect(try await adapter.history(session, context: descriptor.context).value().count == 1)
    await adapter.disconnect()
}

@Test(arguments: ["error", "invalid", "hang"]) func claudeIsolatedGenerationFailuresAreReportedWithoutRetry(_ mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (descriptor, session, chunk) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    try Data(mode.utf8).write(to: home.appendingPathComponent("generation-mode"))
    let request = generationRequest(.archiveSummaryV1, context: descriptor.context, session: session, input: chunk.json)
    let environment = AgentGenerationEnvironment(executable: nil, home: home, workspace: root.appendingPathComponent("workspace"),
                                                 recipeDirectory: claudeSkills.appendingPathComponent("archive-summary"))
    let task = Task { await adapter.generate(request, environment: environment, willStart: {}) }
    if mode == "hang" {
        try await waitFor { !generatedCalls(home).isEmpty }
        await adapter.cancelGeneration(request.id)
    }
    guard case .failed(let failure) = await task.value else { Issue.record("Failure was not reported"); return }
    // A stopped call may already have run; a returned error or rejected result is a known outcome.
    #expect(failure.delivery == (mode == "hang" ? .uncertain : .confirmed))
    #expect(generatedCalls(home).count == 1)
    await adapter.disconnect()
}

@Test func claudeIsolatedGenerationRejectsForeignProfilesAndConnections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (descriptor, session, chunk) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    let request = generationRequest(.archiveSummaryV1, context: descriptor.context, session: session, input: chunk.json)
    let foreign = AgentGenerationEnvironment(executable: nil, home: root.appendingPathComponent("other"), workspace: root.appendingPathComponent("workspace"),
                                             recipeDirectory: claudeSkills.appendingPathComponent("archive-summary"))
    guard case .rejected(.wrongConnection) = await adapter.generate(request, environment: foreign, willStart: {}) else { Issue.record("Foreign profile accepted"); return }
    let codex = generationRequest(.chatTitleV1, context: descriptor.context, session: .init(connection: .originalCodex, nativeID: session.nativeID), input: "hello")
    let local = AgentGenerationEnvironment(executable: nil, home: home, workspace: root.appendingPathComponent("workspace"))
    guard case .rejected(.wrongConnection) = await adapter.generate(codex, environment: local, willStart: {}) else { Issue.record("Codex source accepted"); return }
    guard case .rejected(.wrongConnection) = await adapter.summarySource(.init(connection: .originalCodex, nativeID: session.nativeID), context: descriptor.context) else {
        Issue.record("Codex source read"); return
    }
    #expect(generatedCalls(home).isEmpty)
    await adapter.disconnect()
}

@Test @MainActor func claudeArchivedChatIsSummarizedOnItsOwnConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (_, session, _) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    let store = AppStore(file: root.appendingPathComponent("store.sqlite"))
    let model = DeskModel(claudeIntegration: adapter, store: store, pluginDirectory: root.appendingPathComponent("plugins"),
                          summaryResources: claudeSkills, summaryHome: root.appendingPathComponent("codex"), claudeHome: home)
    let project = Project(path: root.path)
    let chat = Chat(session: session, projectID: project.id, title: "Claude", model: "")
    model.state.projects = [project]; model.state.chats = [chat]
    model.state.model = "codex-model"; model.state.claudeModel = "claude-test"
    // Codex stays disconnected: Claude chats must not depend on it.
    model.claudeConnected = true; model.claudeAuthenticated = true
    #expect(model.canGenerateSummary(chat.id))
    await model.setChatArchived(chat.id, archived: true)
    await model.queueMissingArchiveSummaries()
    await model.summaryTask?.value
    let record = try #require(model.archiveSummaries[chat.id])
    #expect(record.status == .ready)
    #expect(record.model == "claude-test")
    #expect(record.parts.first?.content.overview == "Fixture overview")
    #expect(try await store.loadArchiveSummaries()[chat.id]?.status == .ready)
    let calls = generatedCalls(home)
    #expect(calls.count == 1)
    #expect(calls.first?["args"].array.contains(.string("claude-test")) == true)
    await model.shutdown()
}

@Test func claudeBackgroundTasksResumeTheChatOnTheirOwn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "background")).value()
    // The CLI outlives the turn while its background task runs, then starts a turn of its own.
    try await waitFor { await events.completionCount() == 2 }
    #expect(await events.startedCount() == 2)
    #expect(await events.background() == [1, 0])
    let history = try await adapter.history(session, context: descriptor.context).value()
    // Sub-agent messages stay out of the chat's own reply and go to the sub-agent preview.
    #expect(history.map { $0.items.map(\.text) } == [["background", "launched"], ["woke"]])
    let preview = try #require(await events.subagents().last?.first)
    #expect(preview.title == "Check sources" && preview.background && preview.status == .completed && preview.report == "sub-report")
    #expect(preview.steps.map(\.kind) == [.text, .tool, .result, .text] && preview.steps[1].text == "Read: a.txt")
    #expect(preview.tokens == 120 && preview.toolUses == 1 && preview.endedAt != nil)
    #expect(await events.subagents().contains { $0.first?.activity == "Reading a.txt" })
    // Nothing is left to wait for, so the CLI stays warm and the next message goes to the same process.
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 3 }
    // A new user message starts a fresh round: finished sub-agents leave the preview.
    #expect(await events.subagents().last == [])
    #expect(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count == 1)
    #expect(await events.diagnostics().isEmpty)
    await adapter.disconnect()
}

@Test func claudeOwnTurnBeforeTheQueuedMessageDoesNotEndTheUserTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "notified")).value()
    try await waitFor { await events.completionCount() == 1 }
    // The user's turn ends with the reply to the message, not with the result of the CLI's own turn before it.
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.map { $0.items.map(\.text) } == [["notified", "No response requested.", "handled"]])
    #expect(await events.startedCount() == 1)
    await adapter.disconnect()
}

@Test func claudeStopsOneBackgroundTaskWithoutEndingTheChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(backgroundWaitLimit: .seconds(10), backgroundSettleDelay: .milliseconds(100)), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    func stops() throws -> [String] {
        try String(contentsOf: home.appendingPathComponent("controls"), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["request"] }
            .filter { $0["subtype"].string == "stop_task" }.compactMap { $0["task_id"].string }
    }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: "background-hang")).value()
    try await waitFor { await events.background().last == 1 }
    // An unknown task is rejected before anything reaches the CLI.
    guard case .rejected(.unknownRequest) = await adapter.stopTasks("other", session: session, context: descriptor.context) else {
        Issue.record("unknown task was not rejected"); return
    }
    // The CLI's refusal is reported with its own text; the chat stays connected and the task keeps running.
    try Data().write(to: home.appendingPathComponent("refuse-stop"))
    guard case .failed(let failure) = await adapter.stopTasks(nil, session: session, context: descriptor.context) else {
        Issue.record("refusal was not reported"); return
    }
    #expect(failure.delivery == .confirmed && failure.diagnostic?.contains("Task is busy") == true)
    #expect(await events.subagents().last?.first?.status == .running)
    try FileManager.default.removeItem(at: home.appendingPathComponent("refuse-stop"))
    guard case .success = await adapter.stopTasks("b1", session: session, context: descriptor.context) else {
        Issue.record("stop failed"); return
    }
    #expect(try stops() == ["b1", "b1"])
    try await waitFor { await events.background().last == 0 }
    #expect(await events.subagents().last?.first?.status == .stopped)
    #expect(await events.diagnostics().isEmpty)
    // The released CLI stays warm: the next message reuses it.
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 2 }
    #expect(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count == 1)
    await adapter.disconnect()
}

@Test func claudeOwnTurnDuringStartupDoesNotCloseTheNewProcess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    try Data().write(to: home.appendingPathComponent("own-turn"))
    // The CLI's own turn ends before `initialize` is answered; the user's message is still delivered to the same process.
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 1 }
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.last?.items.map(\.text).last == "hello")
    #expect(await events.startedCount() == 1)
    #expect(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count == 1)
    await adapter.disconnect()
}

@Test(arguments: ["background-idle", "background-hang"]) func claudeIdleBackgroundCliIsReleased(_ prompt: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(backgroundWaitLimit: .seconds(2), backgroundSettleDelay: .milliseconds(100)), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    func launches() throws -> Int { try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: prompt)).value()
    try await waitFor { await events.completionCount() == 1 }
    if prompt == "background-hang" {
        // A message sent while waiting continues in the same CLI, which keeps waiting afterwards.
        _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
        _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
        try await waitFor { await events.completionCount() == 2 }
        #expect(try launches() == 1)
        // The wait is bounded: the CLI is stopped and the lost result is reported, never retried.
        try await waitFor { await !events.diagnostics().isEmpty }
    }
    try await waitFor { await events.background().last == 0 }
    #expect(await events.diagnostics().count == (prompt == "background-hang" ? 1 : 0))
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == (prompt == "background-hang" ? 3 : 2) }
    // A settled CLI stays warm for the next message; one stopped at the wait limit is replaced.
    #expect(try launches() == (prompt == "background-hang" ? 2 : 1))
    #expect(await events.startedCount() == events.completionCount())
    await adapter.disconnect()
}
