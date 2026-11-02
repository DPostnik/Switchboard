import Foundation
import Testing
import AgentContract
@testable import ACPAdapter
@testable import ContextCore
@testable import ContextDesk

/// A fake ACP v1 agent: one JSON-RPC message per line on stdio. Behavior comes from `<home>/fixture.json` (version,
/// capabilities, auth methods) and from the prompt text; every inbound message is appended to `<home>/received.jsonl`.
private let fakeAgent = #"""
import sys, os, json, time
home = os.environ['ACP_FIXTURE_HOME']
config = json.load(open(os.path.join(home, 'fixture.json'))) if os.path.exists(os.path.join(home, 'fixture.json')) else {}
def log(message):
    with open(os.path.join(home, 'received.jsonl'), 'a') as f: f.write(json.dumps(message) + '\n')
def send(message):
    sys.stdout.write(json.dumps(message) + '\n'); sys.stdout.flush()
def update(session, body):
    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session, 'update': body}})
def reply(i, result): send({'jsonrpc': '2.0', 'id': i, 'result': result})
sessions = {}
pending = {}   # prompt request id waiting for cancel or a permission answer, by session
asked = {}     # permission request id -> (session, prompt id, tool call id)
counter = [0]
for line in sys.stdin:
    message = json.loads(line); log(message)
    method, i, params = message.get('method'), message.get('id'), message.get('params', {})
    if method is None:
        if i in asked:
            session, prompt, tool = asked.pop(i)
            selected = message['result']['outcome']
            status = 'completed' if selected.get('optionId') == 'yes' else 'failed'
            if selected.get('outcome') == 'cancelled': continue
            update(session, {'sessionUpdate': 'tool_call_update', 'toolCallId': tool, 'status': status,
                             'content': [{'type': 'content', 'content': {'type': 'text', 'text': 'wrote it' if status == 'completed' else 'refused'}}]})
            pending.pop(session, None); reply(prompt, {'stopReason': 'end_turn'})
        continue
    if method == 'initialize':
        reply(i, {'protocolVersion': config.get('protocolVersion', 1),
                  'agentInfo': {'name': 'fake', 'title': 'Fake', 'version': config.get('version', '1.0.0')},
                  'agentCapabilities': config.get('capabilities', {'loadSession': True}),
                  'authMethods': config.get('authMethods', [{'id': 'login', 'name': 'Log in'}])})
    elif method == 'authenticate': reply(i, {})
    elif method in ('session/new', 'session/load', 'session/resume'):
        if config.get('authRequired') and method == 'session/new':
            send({'jsonrpc': '2.0', 'id': i, 'error': {'code': -32000, 'message': 'Authentication required.'}}); continue
        counter[0] += 1
        session = params.get('sessionId') or 'session-%d' % counter[0]
        if method == 'session/load':
            update(session, {'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'replayed'}})
            update(session, {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'replayed answer'}})
        options = [{'id': 'model', 'name': 'Model', 'category': 'model', 'type': 'select', 'currentValue': 'fast',
                    'options': [{'value': 'fast', 'name': 'Fast'}, {'group': 'more', 'name': 'More', 'options': [{'value': 'deep', 'name': 'Deep'}]}]}]
        if config.get('legacyModels'):
            # Gemini CLI 0.66.0: the older `models` list instead of config options.
            body = {'models': {'availableModels': [{'modelId': 'auto', 'name': 'Auto'}, {'modelId': 'pro', 'name': 'Pro', 'description': 'Deep'}],
                               'currentModelId': 'auto'}, 'modes': {'availableModes': [], 'currentModeId': 'default'}}
        else: body = {'configOptions': options}
        if method == 'session/new': body['sessionId'] = session
        reply(i, body)
        update(session, {'sessionUpdate': 'available_commands_update', 'availableCommands': [{'name': 'init', 'description': 'Analyze'}]})
    elif method == 'session/set_model': reply(i, {})
    elif method == 'session/set_config_option':
        reply(i, {'configOptions': [{'id': 'model', 'name': 'Model', 'category': 'model', 'type': 'select', 'currentValue': params['value'],
                                     'options': [{'value': 'fast', 'name': 'Fast'}, {'value': 'deep', 'name': 'Deep'}]}]})
    elif method == 'session/cancel':
        session = params['sessionId']
        if session in pending and not config.get('ignoreCancel'): reply(pending.pop(session), {'stopReason': 'cancelled'})
    elif method == 'session/prompt':
        session, text = params['sessionId'], params['prompt'][0]['text']
        if text == 'stream':
            update(session, {'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'pondering'}})
            update(session, {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Hel'}})
            update(session, {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'lo'}})
            update(session, {'sessionUpdate': 'tool_call', 'toolCallId': 't1', 'title': 'Read README', 'kind': 'read', 'status': 'in_progress',
                             'locations': [{'path': os.path.join(params.get('cwd', '/tmp'), 'README.md')}]})
            update(session, {'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'status': 'completed',
                             'content': [{'type': 'content', 'content': {'type': 'text', 'text': '# Readme'}}]})
            update(session, {'sessionUpdate': 'plan', 'entries': [{'content': 'Look', 'status': 'completed', 'priority': 'high'},
                                                                  {'content': 'Answer', 'status': 'in_progress', 'priority': 'low'}]})
            update(session, {'sessionUpdate': 'usage_update', 'used': 1200, 'size': 200000})
            update(session, {'sessionUpdate': 'available_commands_update', 'availableCommands': [{'name': 'memory', 'description': 'Memory'}]})
            update(session, {'sessionUpdate': 'session_info_update', 'title': 'Greeting'})
            update(session, {'sessionUpdate': 'hologram_update'})
            send({'jsonrpc': '2.0', 'method': '_fake/notice', 'params': {}})
            send({'jsonrpc': '2.0', 'id': 'u1', 'method': '_fake/teleport', 'params': {}})
            send({'jsonrpc': '2.0', 'id': 'u2', 'method': 'fs/read_text_file', 'params': {'sessionId': session, 'path': '/etc/hosts'}})
            update(session, {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': ' again'}})
            reply(i, {'stopReason': 'end_turn'})
        elif text in ('permission', 'permission-hang'):
            update(session, {'sessionUpdate': 'tool_call', 'toolCallId': 'w1', 'title': 'Write notes.md', 'kind': 'edit', 'status': 'pending',
                             'locations': [{'path': config.get('writePath', '/tmp/notes.md')}]})
            asked['p1'] = (session, i, 'w1'); pending[session] = i
            send({'jsonrpc': '2.0', 'id': 'p1', 'method': 'session/request_permission', 'params': {
                'sessionId': session, 'toolCall': {'toolCallId': 'w1'},
                'options': [{'optionId': 'yes', 'name': 'Allow', 'kind': 'allow_once'}, {'optionId': 'always', 'name': 'Always', 'kind': 'allow_always'},
                            {'optionId': 'no', 'name': 'Reject', 'kind': 'reject_once'}]}})
        elif text == 'structured':
            path = os.path.join(config.get('project', '/tmp'), 'a.txt')
            update(session, {'sessionUpdate': 'tool_call', 'toolCallId': 'e1', 'title': 'Edit a.txt', 'kind': 'edit', 'status': 'pending',
                             'locations': [{'path': path, 'line': 3}], 'rawInput': {'file_path': path}})
            update(session, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'e1', 'status': 'in_progress'})
            update(session, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'e1', 'status': 'completed',
                             'content': [{'type': 'diff', 'path': path, 'oldText': 'a\n', 'newText': 'b\n'},
                                         {'type': 'content', 'content': {'type': 'text', 'text': 'edited'}}]})
            update(session, {'sessionUpdate': 'tool_call', 'toolCallId': 'm1', 'title': 'Plan mode', 'kind': 'switch_mode', 'status': 'in_progress'})
            update(session, {'sessionUpdate': 'plan', 'entries': [{'content': 'Edit', 'status': 'in_progress', 'priority': 'high'}]})
            update(session, {'sessionUpdate': 'plan', 'entries': [{'content': 'Edit', 'status': 'completed', 'priority': 'high'},
                                                                  {'content': 'Check', 'status': 'pending'}]})
            update(session, {'sessionUpdate': 'available_commands_update', 'availableCommands': [
                {'name': 'memory', 'description': 'Memory', 'input': {'hint': 'show | add <text>'}}, {'name': '', 'description': 'nameless'}]})
            update(session, {'sessionUpdate': 'config_option_update', 'configOptions': [
                {'id': 'mode', 'name': 'Mode', 'category': 'mode', 'type': 'select', 'currentValue': 'ask',
                 'options': [{'value': 'ask', 'name': 'Ask'}, {'value': 'code', 'name': 'Code'}]},
                {'id': 'brief', 'name': 'Brief', 'type': 'boolean', 'currentValue': True}]})
            pending[session] = i
        elif text == 'long': reply(i, {'stopReason': 'max_tokens'})
        elif text == 'hang': pending[session] = i
        elif text == 'exit': sys.exit(3)
        elif text == 'refuse': reply(i, {'stopReason': 'refusal'})
        else:
            update(session, {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'ok'}})
            reply(i, {'stopReason': 'end_turn'})
    elif i is not None:
        send({'jsonrpc': '2.0', 'id': i, 'error': {'code': -32601, 'message': 'Method not found'}})
"""#

private actor ACPEvents {
    var values: [AgentEvent] = []
    func append(_ event: AgentEvent) { values.append(event) }
    func completions() -> [AgentTurnCompletion] { values.compactMap { if case .completed(let value) = $0.payload { return value }; return nil } }
    func interactions() -> [AgentInteraction] { values.compactMap { if case .interaction(let value) = $0.payload { return value }; return nil } }
    func items() -> [TranscriptItem] { values.compactMap { if case .item(let item) = $0.payload { return item }; return nil } }
    func deltas() -> [String] { values.compactMap { if case .delta(_, _, let text) = $0.payload { return text }; return nil } }
    func usage() -> [UsageSnapshot] { values.compactMap { if case .usage(_, _, let snapshot) = $0.payload { return snapshot }; return nil } }
    func capabilities() -> [AgentCapabilityRecord] { values.compactMap { if case .capability(let value) = $0.payload { return value }; return nil } }
    func resolved() -> [UUID] { values.compactMap { if case .resolved(let id) = $0.payload { return id }; return nil } }
    func disconnected() -> Bool { values.contains { if case .disconnected = $0.payload { return true }; return false } }
    func plans() -> [AgentPlan] { values.compactMap { if case .plan(_, let plan) = $0.payload { return plan }; return nil } }
    func commands() -> [[AgentCommand]] { values.compactMap { if case .commands(let list) = $0.payload { return list }; return nil } }
    func options() -> [[AgentConfigOption]] { values.compactMap { if case .configOptions(let list) = $0.payload { return list }; return nil } }
    /// The latest state of every structured call, by call ID.
    func calls() -> [String: AgentToolCall] {
        var result: [String: AgentToolCall] = [:]
        for item in items() { if let call = item.toolCall { result[call.id] = call } }
        return result
    }
    /// The statuses a call went through, repeats of the same status folded.
    func callStatuses(_ id: String) -> [AgentToolCall.Status] {
        items().compactMap { $0.toolCall?.id == id ? $0.toolCall?.status : nil }.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}

private struct ACPFixture {
    let root: URL, home: URL, project: URL, executable: URL
    let drift = CompatibilityDrift(logging: false)
    let profile: ACPLaunchProfile

    init(_ config: [String: Any] = [:], cancelGrace: Duration = .seconds(30), connection: AgentConnectionID? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-" + UUID().uuidString)
        home = root.appendingPathComponent("home"); project = root.appendingPathComponent("project")
        executable = root.appendingPathComponent("fake-acp")
        for folder in [home, project] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try ("#!" + fixturePython + "\n" + fakeAgent).write(to: executable, atomically: true, encoding: .utf8)
        try installFixtureExecutable(at: executable)
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent("fixture.json"))
        let agent = connection?.agent ?? AgentID(rawValue: "fake-acp")
        let found = executable.path
        profile = ACPLaunchProfile(
            agent: agent, connection: connection ?? AgentConnectionID(agent: agent, id: UUID()), productName: "Fake ACP", arguments: ["--acp"],
            candidates: { _, _ in [found] },
            environment: { home, _, inherited in
                var result = inherited.filter { !$0.key.hasPrefix("ACP_") }; result["ACP_FIXTURE_HOME"] = home.path; return result
            },
            verifiedVersions: ["1.0.0"], signInMethod: "login", replaySettle: .milliseconds(100), cancelGrace: cancelGrace,
            startupTimeout: .seconds(20), sessionTimeout: .seconds(20), signInTimeout: .seconds(20))
    }

    func write(_ config: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent("fixture.json"))
    }

    /// Every message the fake agent received, in order.
    func received() -> [JSONValue] {
        guard let text = try? String(contentsOf: home.appendingPathComponent("received.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
    func methods() -> [String] { received().compactMap { $0["method"].string } }

    func start() async throws -> (ACPIntegration, ACPEvents, Task<Void, Never>, AgentDescriptor) {
        let adapter = ACPIntegration(profile: profile, drift: drift, clientVersion: "test")
        let events = ACPEvents()
        let reader = Task { for await event in adapter.events { await events.append(event) } }
        let descriptor = try await adapter.connect(.init(executable: executable, home: home)).value()
        return (adapter, events, reader, descriptor)
    }

    func request(_ descriptor: AgentDescriptor, prompt: String = "hello", session: AgentSessionReference? = nil,
                 permissions: AgentPermissionIntent? = nil, model: String = "") -> AgentExecutionRequest {
        .init(conversation: ConversationID(), session: session, kind: .interactive, prompt: prompt, projectPath: project.path,
              permissions: permissions ?? .workspaceWrite(root: project.path, network: false, approval: .ask),
              model: .init(context: descriptor.context, model: model), route: .direct)
    }

    func driftNames() -> Set<String> { Set(drift.snapshot().map { "\($0.key.category.rawValue) \($0.key.name)" }) }
}

private func waitFor(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ClientFailure("Fixture timed out")
}

@Test func acpHandshakeAdvertisesOnlyWhatTheClientImplements() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (adapter, _, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let initialize = try #require(fixture.received().first)
    #expect(initialize["method"].string == "initialize")
    #expect(initialize["params"]["protocolVersion"].int == 1)
    let capabilities = initialize["params"]["clientCapabilities"]
    #expect(capabilities["fs"]["readTextFile"] == .bool(false) && capabilities["fs"]["writeTextFile"] == .bool(false))
    #expect(capabilities["terminal"] == .bool(false) && capabilities["auth"]["terminal"] == .bool(false))
    #expect(initialize["params"]["clientInfo"]["name"].string == "switchboard")
    #expect(descriptor.engine == AgentEngineVersion(version: "1.0.0", verified: true))
    #expect(descriptor.identityMode == .appOwnedHome)
    #expect(descriptor.capabilities.isSuperset(of: [.interactiveSessions, .history, .streaming, .approvals, .interruption, .authenticationManagement]))
    #expect(!descriptor.capabilities.contains(.modelDiscovery) && !descriptor.capabilities.contains(.isolatedGeneration))
    #expect(try await adapter.account().value().authenticated == false)
    guard case .success(.complete) = await adapter.authenticate(.beginSignIn) else { Issue.record("sign-in"); return }
    #expect(fixture.received().last?["params"]["methodId"].string == "login")
    #expect(try await adapter.account().value().authenticated)
    // Logout is not advertised, so it is never sent.
    guard case .rejected(.unsupported(.authenticationManagement)) = await adapter.authenticate(.signOut) else { Issue.record("sign-out sent"); return }
    await adapter.disconnect()
}

@Test func acpVersionPolicyGatesTheConnection() async throws {
    for (config, expected) in [(["version": "1.0.7"], "unverified"), (["version": "1.1.0"], "rejected"),
                               (["version": "1.0.0", "protocolVersion": 2], "rejected")] as [([String: Any], String)] {
        let fixture = try ACPFixture(config)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = ACPIntegration(profile: fixture.profile, drift: fixture.drift, clientVersion: "test")
        let result = await adapter.connect(.init(executable: fixture.executable, home: fixture.home))
        switch (result, expected) {
        case (.success(let descriptor), "unverified"):
            #expect(descriptor.engine == AgentEngineVersion(version: "1.0.7", verified: false, nearestVerified: "1.0.0"))
        case (.rejected(.incompatibleContract), "rejected"): break
        default: Issue.record("\(config): unexpected \(result)")
        }
        await adapter.disconnect()
    }
    // Terminal-only sign-in is not offered: the client cannot run the agent in a terminal.
    let fixture = try ACPFixture(["authMethods": [["id": "tty", "name": "Terminal", "type": "terminal"]]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (adapter, _, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    #expect(!descriptor.capabilities.contains(.authenticationManagement))
    guard case .rejected(.unsupported(.authenticationManagement)) = await adapter.authenticate(.beginSignIn) else { Issue.record("terminal auth"); return }
    await adapter.disconnect()
}

@Test func acpPromptStreamsUpdatesIntoContractEventsAndCountsTheRest() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    #expect(fixture.received().last?["params"]["cwd"].string == fixture.project.path)
    #expect(fixture.received().last?["params"]["mcpServers"] == .array([]))
    // Models come from the session's config options (groups flattened); a model change goes through set_config_option.
    #expect(try await adapter.models().value().map(\.id) == ["fast", "deep"])
    _ = try await adapter.submit(fixture.request(descriptor, prompt: "stream", session: session, model: "deep")).value()
    try await waitFor { await events.completions().count == 1 }
    let completion = try #require(await events.completions().first)
    #expect(completion.status == .completed && !completion.hasError)
    #expect(await events.deltas() == ["Hel", "lo", " again"])
    let items = await events.items()
    #expect(items.contains { $0.kind == "assistant" && $0.text == "Hello" })
    #expect(items.contains { $0.kind == "assistant" && $0.text == " again" })
    #expect(items.contains { $0.kind == ActivityDetail.thinkingKind && $0.text == "pondering" })
    #expect(items.contains { $0.kind == "activity" && $0.text.hasPrefix("Read README") })
    #expect(items.contains { $0.kind == "activity" && $0.text == "# Readme" })
    // Stage C: the call is structured and the plan is the turn's plan.
    let read = try #require(await events.calls()["t1"])
    #expect(read.kind == .read && read.status == .completed && read.title == "Read README" && read.locations.map(\.path).first?.hasSuffix("README.md") == true)
    #expect(await events.plans().last?.entries.map(\.status) == [.completed, .inProgress])
    #expect(await events.plans().last?.entries.map(\.priority) == [.high, .low])
    #expect(await events.commands().last == [AgentCommand(name: "memory", description: "Memory")])
    #expect(completion.stopReason == .endTurn)
    #expect(await events.usage().map(\.window) == [200000])
    #expect(await events.capabilities().map(\.decision) == [.used])
    let methods = fixture.methods()
    #expect(methods.contains("session/set_config_option"))
    #expect(methods.firstIndex(of: "session/set_config_option")! < methods.firstIndex(of: "session/prompt")!)
    // Unknown agent requests are refused with -32601; known but unadvertised ones too (and only counted, not drift).
    let errors = fixture.received().filter { $0["error"] != .null }
    #expect(Set(errors.compactMap { $0["id"].string }) == ["u1", "u2"])
    #expect(errors.allSatisfy { $0["error"]["code"].int == -32601 })
    let unsurfaced = await adapter.unsurfaced
    #expect(unsurfaced["update:available_commands_update"] == nil && unsurfaced["update:session_info_update"] == 1)
    #expect(unsurfaced["request:fs/read_text_file"] == 1)
    #expect(fixture.driftNames() == ["itemType hologram_update", "notification _fake/notice", "serverRequest _fake/teleport"])
    // The app's own record is the chat's history.
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.count == 1 && history[0].items.first?.text == "stream" && history[0].isComplete)
    #expect(history[0].items.contains { $0.kind == AgentPlan.itemKind && $0.plan?.entries.count == 2 })
    #expect(history[0].items.contains { $0.toolCall?.id == "t1" && $0.toolCall?.status == .completed })
    await adapter.disconnect()
}

@Test func acpCallsPlansCommandsAndOptionsReachTheStructuredContract() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write(["project": fixture.project.path])
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    let handle = try await adapter.submit(fixture.request(descriptor, prompt: "structured", session: session)).value()
    try await waitFor { await events.commands().contains { $0.first?.name == "memory" } }
    try await waitFor { await events.options().contains { $0.contains { $0.category == .mode } } }
    // One call updated in place by its ID: pending, in progress, completed with its diff; text output in the result item.
    let edit = try #require(await events.calls()["e1"])
    #expect(await events.callStatuses("e1") == [.pending, .inProgress, .completed])
    #expect(edit.kind == .edit && edit.title == "Edit a.txt")
    #expect(edit.locations == [.init(path: fixture.project.appendingPathComponent("a.txt").path, line: 3)])
    #expect(edit.diffs == [.init(path: fixture.project.appendingPathComponent("a.txt").path, oldText: "a\n", newText: "b\n")])
    #expect(edit.inputSummary?.contains("file_path") == true)
    #expect(await events.items().contains { $0.id == ActivityDetail.resultID(of: ACPTurn.callID(turn: handle.turnID!, tool: "e1")) && $0.text == "edited" })
    #expect(await events.calls()["m1"]?.kind == .switchMode)
    // Every plan update replaces the turn's plan.
    #expect(await events.plans().map { $0.entries.map(\.content) } == [["Edit"], ["Edit", "Check"]])
    #expect(await events.plans().last?.entries.map(\.priority) == [.high, .medium])
    // Commands: nameless entries are dropped; the input hint is kept.
    #expect(await events.commands().contains([AgentCommand(name: "memory", description: "Memory", inputHint: "show | add <text>")]))
    #expect(await events.commands().first == [AgentCommand(name: "init", description: "Analyze")])
    let options = try #require(await events.options().last)
    #expect(options.map(\.id) == ["mode", "brief"])
    #expect(options[0].category == .mode && options[0].current == "ask" && options[0].kind == .select([.init(id: "ask", name: "Ask"), .init(id: "code", name: "Code")]))
    #expect(options[1].kind == .boolean && options[1].current == "true" && options[1].category == .other)
    // Cancelling ends the turn's unfinished calls as cancelled; finished ones keep their state.
    #expect(try await adapter.cancel(handle).value() == .requested)
    try await waitFor { await events.completions().count == 1 }
    #expect(await events.completions().first?.stopReason == .cancelled)
    let ended = await events.calls()
    #expect(ended["m1"]?.status == .cancelled && ended["e1"]?.status == .completed)
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.last?.items.filter { $0.kind == AgentPlan.itemKind }.count == 1)
    #expect(history.last?.items.first { $0.toolCall?.id == "m1" }?.toolCall?.status == .cancelled)
    // A stop reason other than the end of the turn reaches the contract.
    _ = try await adapter.submit(fixture.request(descriptor, prompt: "long", session: session)).value()
    try await waitFor { await events.completions().count == 2 }
    let long = await events.completions().last
    #expect(long?.stopReason == .maxTokens && long?.status == .failed)
    await adapter.disconnect()
}

@Test func acpOlderSessionModelListSelectsThroughSetModelAndIsCachedForNewChats() async throws {
    let fixture = try ACPFixture(["legacyModels": true])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var (adapter, events, reader, descriptor) = try await fixture.start()
    guard case .rejected(.unsupported(.modelDiscovery)) = await adapter.models() else { Issue.record("models before any session"); return }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    let models = try await adapter.models().value()
    #expect(models.map(\.id) == ["auto", "pro"] && models.map(\.displayName) == ["Auto", "Pro"] && models.first?.isDefault == true)
    // A thought level the session does not offer is not sent; a model it does not offer is refused before the prompt.
    guard case .rejected(.invalidInput) = await adapter.submit(fixture.request(descriptor, session: session, model: "ultra")) else {
        Issue.record("unknown model sent"); return
    }
    var request = fixture.request(descriptor, session: session, model: "pro")
    request = .init(conversation: request.conversation, session: session, kind: .interactive, prompt: "hello", projectPath: fixture.project.path,
                    permissions: request.permissions, model: .init(context: descriptor.context, model: "pro", effort: "medium"), route: .direct)
    _ = try await adapter.submit(request).value()
    try await waitFor { await events.completions().count == 1 }
    let setModel = try #require(fixture.received().first { $0["method"].string == "session/set_model" })
    #expect(setModel["params"]["modelId"].string == "pro" && setModel["params"]["sessionId"].string == session.nativeID)
    #expect(!fixture.methods().contains("session/set_config_option"))
    #expect(fixture.methods().firstIndex(of: "session/set_model")! < fixture.methods().firstIndex(of: "session/prompt")!)
    #expect(await events.options().last?.first?.current == "pro")
    await adapter.disconnect(); reader.cancel()

    // A new process lists the models the last session reported before any session exists.
    (adapter, events, reader, descriptor) = try await fixture.start()
    #expect(try await adapter.models().value().map(\.id) == ["auto", "pro"])
    await adapter.disconnect(); reader.cancel()
}

@Test func acpPermissionPromptsAreAnsweredOnceAndNeverAlways() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write(["writePath": fixture.project.appendingPathComponent("notes.md").path])
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    for (index, response) in [AgentInteractionResponse.allowOnce, .deny].enumerated() {
        _ = try await adapter.submit(fixture.request(descriptor, prompt: "permission", session: session)).value()
        try await waitFor { await events.interactions().count == index + 1 }
        let interaction = try #require(await events.interactions().last)
        guard case .approval(canAllow: true) = interaction.kind else { Issue.record("kind"); return }
        #expect(interaction.reason == "Write notes.md" && !interaction.canAllowTurn)
        guard case .rejected(.invalidResponse) = await adapter.answer(interaction.id, session: session, context: descriptor.context, response: .allowTurn) else {
            Issue.record("allowTurn accepted"); return
        }
        _ = try await adapter.answer(interaction.id, session: session, context: descriptor.context, response: response).value()
        try await waitFor { await events.completions().count == index + 1 }
    }
    let answers = fixture.received().filter { $0["id"].string == "p1" && $0["method"] == .null }.map { $0["result"]["outcome"]["optionId"].string }
    #expect(answers == ["yes", "no"])
    // The call waits for approval, then runs after allow; a refused call stays refused when the agent reports it failed.
    let statuses = await events.callStatuses("w1")
    #expect(statuses.starts(with: [.pending, .awaitingApproval, .inProgress, .completed]))
    #expect(Array(statuses.dropFirst(4)) == [.pending, .awaitingApproval, .rejected])
    #expect(await events.capabilities().map(\.decision) == [.asked, .allowed, .used, .asked, .denied])
    #expect(await events.items().contains { $0.text == "refused" && $0.failed == true })
    // A read-only role refuses the write without asking.
    var readOnly = AgentPermissionProfile.workspace(); readOnly.filesystem = .readOnly
    _ = try await adapter.submit(fixture.request(descriptor, prompt: "permission", session: session,
                                                 permissions: .profile(readOnly, root: fixture.project.path))).value()
    try await waitFor { await events.completions().count == 3 }
    #expect(await events.interactions().count == 2)
    #expect(fixture.received().filter { $0["id"].string == "p1" && $0["method"] == .null }.last?["result"]["outcome"]["optionId"].string == "no")
    // A role that never prompts would need silent approval, which this adapter does not do.
    var never = AgentPermissionProfile.workspace(); never.approvals = .never
    guard case .rejected(.unsupportedPermissions) = await adapter.submit(fixture.request(descriptor, session: session,
                                                                                         permissions: .profile(never, root: fixture.project.path))) else {
        Issue.record("approvals never accepted"); return
    }
    await adapter.disconnect()
}

@Test func acpCancelAnswersPendingPromptsCancelledAndEndsTheTurn() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write(["writePath": fixture.project.appendingPathComponent("notes.md").path])
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    let handle = try await adapter.submit(fixture.request(descriptor, prompt: "permission-hang", session: session)).value()
    try await waitFor { await events.interactions().count == 1 }
    let interaction = try #require(await events.interactions().first)
    #expect(try await adapter.cancel(handle).value() == .requested)
    try await waitFor { await events.completions().count == 1 }
    #expect(await events.completions().first?.status == .cancelled)
    #expect(await events.resolved().contains(interaction.id))
    let answer = try #require(fixture.received().first { $0["id"].string == "p1" && $0["method"] == .null })
    #expect(answer["result"]["outcome"]["outcome"].string == "cancelled")
    #expect(fixture.methods().contains("session/cancel"))
    #expect(try await adapter.cancel(handle).value() == .alreadyFinished)
    await adapter.disconnect()
}

@Test func acpCancelWithoutAnAnswerStopsTheProcessAsUncertain() async throws {
    let fixture = try ACPFixture(["ignoreCancel": true], cancelGrace: .milliseconds(200))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    let handle = try await adapter.submit(fixture.request(descriptor, prompt: "hang", session: session)).value()
    #expect(try await adapter.cancel(handle).value() == .requested)
    #expect(try await adapter.cancel(handle).value() == .requested)
    try await waitFor { await events.completions().count == 1 }
    #expect(await events.completions().first?.status == .uncertain)
    #expect(await events.disconnected())
    #expect(fixture.methods().filter { $0 == "session/cancel" }.count == 1)
    await adapter.disconnect()
}

@Test func acpProcessExitMidTurnIsUncertainAndNeverRetried() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    let handle = try await adapter.submit(fixture.request(descriptor, prompt: "exit", session: session)).value()
    try await waitFor { await events.completions().count == 1 }
    #expect(await events.completions().first?.status == .uncertain)
    #expect(await events.disconnected())
    #expect(fixture.methods().filter { $0 == "session/prompt" }.count == 1)
    #expect(try await adapter.cancel(handle).value() == .alreadyFinished)
    if case .success = await adapter.submit(fixture.request(descriptor, session: session)) { Issue.record("submitted without a process") }
    #expect(fixture.methods().filter { $0 == "session/prompt" }.count == 1)
    await adapter.disconnect()
}

@Test func acpStoredSessionsContinueOnlyThroughAdvertisedMethods() async throws {
    let fixture = try ACPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var (adapter, events, reader, descriptor) = try await fixture.start()
    let session = try await adapter.prepare(fixture.request(descriptor)).value()
    _ = try await adapter.submit(fixture.request(descriptor, session: session)).value()
    try await waitFor { await events.completions().count == 1 }
    await adapter.disconnect(); reader.cancel()

    // A new process loads the session; its history replay is not surfaced and the app's history stays the source.
    (adapter, events, reader, descriptor) = try await fixture.start()
    #expect(try await adapter.history(session, context: descriptor.context).value().count == 1)
    _ = try await adapter.submit(fixture.request(descriptor, prompt: "again", session: session)).value()
    try await waitFor { await events.completions().count == 1 }
    #expect(fixture.methods().contains("session/load") && !fixture.methods().contains("session/resume"))
    #expect(await !events.items().contains { $0.text.contains("replayed") })
    #expect(try await adapter.history(session, context: descriptor.context).value().map { $0.items.first?.text } == ["hello", "again"])
    await adapter.disconnect(); reader.cancel()

    // resume is preferred when advertised.
    try fixture.write(["capabilities": ["loadSession": true, "sessionCapabilities": ["resume": [:]]]])
    (adapter, events, reader, descriptor) = try await fixture.start()
    _ = try await adapter.submit(fixture.request(descriptor, prompt: "third", session: session)).value()
    try await waitFor { await events.completions().count == 1 }
    #expect(fixture.methods().contains("session/resume"))
    await adapter.disconnect(); reader.cancel()

    // Neither advertised: the stored chat cannot continue and nothing is sent.
    try fixture.write(["capabilities": [:]])
    (adapter, events, reader, descriptor) = try await fixture.start()
    let before = fixture.methods().filter { $0 == "session/prompt" }.count
    guard case .failed(let failure) = await adapter.submit(fixture.request(descriptor, prompt: "fourth", session: session)) else {
        Issue.record("continued without load or resume"); return
    }
    #expect(failure.delivery == .notSent)
    #expect(fixture.methods().filter { $0 == "session/prompt" }.count == before)
    await adapter.disconnect(); reader.cancel()
}

@Test func acpAuthRequiredMarksTheAccountSignedOut() async throws {
    let fixture = try ACPFixture(["authRequired": true])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (adapter, events, reader, descriptor) = try await fixture.start()
    defer { reader.cancel() }
    guard case .failed(let failure) = await adapter.prepare(fixture.request(descriptor)) else { Issue.record("session created"); return }
    #expect(failure.delivery == .confirmed)
    #expect(try await adapter.account().value().authenticated == false)
    #expect(await events.completions().isEmpty)
    await adapter.disconnect()
}

@Test func acpLineBufferCapsOneMessage() throws {
    var buffer = ACPLineBuffer(maximumLineBytes: 8)
    #expect(try buffer.append(Data("{}\n{\"a\"".utf8)) == [Data("{}".utf8)])
    #expect(try buffer.append(Data(":1}\n".utf8)) == [Data("{\"a\":1}".utf8)])
    #expect(throws: ACPLineBuffer.Failure.self) { try buffer.append(Data("123456789".utf8)) }
}

@Test func geminiProfileIsolatesItsHomeAndStripsInheritedCredentials() throws {
    let home = URL(fileURLWithPath: "/tmp/switchboard-gemini-test")
    let executable = URL(fileURLWithPath: "/nonexistent/bin/gemini")
    let environment = GeminiProfile.environment(home: home, executable: executable, inherited: [
        "GEMINI_API_KEY": "k", "GOOGLE_API_KEY": "k", "GOOGLE_APPLICATION_CREDENTIALS": "/x", "GOOGLE_GENAI_USE_VERTEXAI": "true",
        "GOOGLE_CLOUD_PROJECT": "p", "GEMINI_CLI_HOME": "/Users/me", "GCLOUD_PROJECT": "p", "PATH": "/usr/bin:relative", "LANG": "en_US.UTF-8"])
    #expect(environment["GEMINI_CLI_HOME"] == home.path)
    #expect(environment["GEMINI_FORCE_FILE_STORAGE"] == "true" && environment["GEMINI_CLI_NO_RELAUNCH"] == "true")
    #expect(environment.keys.filter { $0.hasPrefix("GOOGLE_") || $0 == "GEMINI_API_KEY" || $0 == "GCLOUD_PROJECT" }.isEmpty)
    #expect(environment["LANG"] == "en_US.UTF-8")
    let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    #expect(path.first == "/nonexistent/bin" && path.contains("/opt/homebrew/bin") && path.contains("/usr/bin") && !path.contains("relative"))
    #expect(GeminiProfile.home.lastPathComponent == "gemini")
    let candidates = GeminiProfile.candidates(home: home, environment: ["PATH": "/custom/bin:rel"])
    #expect(candidates == [home.path + "/cli/node_modules/.bin/gemini", "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "/custom/bin/gemini"])
    #expect(GeminiProfile.profile.arguments == ["--acp"] && GeminiProfile.profile.verifiedVersions == ["0.66.0"])
}

@Test func geminiHomeDefaultsAreWrittenOnceAndOwnerOnly() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try GeminiProfile.prepare(home: home)
    let settings = home.appendingPathComponent(".gemini/settings.json")
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settings))
    #expect(value["privacy"]["usageStatisticsEnabled"] == .bool(false) && value["general"]["enableAutoUpdate"] == .bool(false))
    #expect((try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try Data("{}".utf8).write(to: settings)
    try GeminiProfile.prepare(home: home)
    #expect(try Data(contentsOf: settings) == Data("{}".utf8))
}

/// Opt-in, no inference and no sign-in: installs the verified Gemini CLI into a fresh folder (`--ignore-scripts`), or uses
/// `SWITCHBOARD_GEMINI_EXECUTABLE` (scripts/compat-check.py passes the installed CLI), runs `gemini --acp` with a fresh
/// isolated home, checks `initialize` and that `session/new` without credentials fails as auth-required. Never touches
/// `~/.gemini`. `SWITCHBOARD_GEMINI_COMPATIBILITY_LIVE=1`, optional `SWITCHBOARD_GEMINI_VERSION` for the npm install.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_GEMINI_COMPATIBILITY_LIVE"] == "1"), .timeLimit(.minutes(10)))
func geminiLiveHandshakeWithoutSignIn() async throws {
    let environment = ProcessInfo.processInfo.environment
    let given = environment["SWITCHBOARD_GEMINI_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
    let version = environment["SWITCHBOARD_GEMINI_VERSION"] ?? GeminiProfile.verifiedVersions[0]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-live-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    if given == nil {
        let npm = try #require(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first { FileManager.default.isExecutableFile(atPath: $0) })
        let install = Process()
        install.executableURL = URL(fileURLWithPath: npm)
        install.arguments = ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--silent", "--prefix", home.appendingPathComponent("cli").path,
                             "@google/gemini-cli@\(version)"]
        install.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, new in new }
        install.standardOutput = FileHandle.nullDevice; install.standardError = FileHandle.nullDevice
        try install.run(); install.waitUntilExit()
        try #require(install.terminationStatus == 0)
    }
    let drift = CompatibilityDrift(logging: false)
    let adapter = ACPIntegration(profile: GeminiProfile.profile, drift: drift, clientVersion: "live-test")
    let descriptor = try await adapter.connect(.init(executable: given, home: home)).value()
    if given == nil { #expect(descriptor.engine?.version == version) }
    #expect(descriptor.capabilities.contains(.authenticationManagement))
    #expect(try await adapter.account().value().authenticated == false)
    guard case .failed(let failure) = await adapter.prepare(.init(
        conversation: ConversationID(), kind: .interactive, prompt: "", projectPath: project.path,
        permissions: .workspaceWrite(root: project.path, network: false, approval: .ask),
        model: .init(context: descriptor.context, model: ""), route: .direct)) else {
        Issue.record("session/new succeeded without credentials"); await adapter.disconnect(); return
    }
    #expect(failure.delivery == .confirmed)
    await adapter.disconnect()
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/settings.json").path))
    #expect(drift.snapshot().isEmpty, "\(drift.snapshot().map(\.key.name))")
    print("gemini-live: version \(descriptor.engine?.version ?? "?") initialize ok, session/new auth-required, drift \(drift.snapshot().count)")
}

// Stage D wiring: the Gemini registration in the app, driven by the fake ACP agent under Gemini's connection.

@MainActor private func geminiModel(_ fixture: ACPFixture, store: AppStore) -> DeskModel {
    var profile = AgentIntegrationFactory.geminiProfile
    profile.installation = AgentInstallation(isInstalled: { true }, missing: { "" }, hint: { "" })
    let agents = AgentIntegrationFactory.registrations(
        gemini: ACPIntegration(profile: fixture.profile, drift: fixture.drift, clientVersion: "test"), geminiProfile: profile,
        summaryHome: fixture.root.appendingPathComponent("codex"), claudeHome: fixture.root.appendingPathComponent("claude"), geminiHome: fixture.home)
    return DeskModel(agents: agents, store: store, capabilityLedger: CapabilityLedger(file: fixture.root.appendingPathComponent("ledger.sqlite")),
                     pluginDirectory: fixture.root.appendingPathComponent("plugins"), summaryResources: nil,
                     summaryHome: fixture.root.appendingPathComponent("codex"), jobStore: JobStore(file: fixture.root.appendingPathComponent("jobs.json")))
}

@MainActor private func settle(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<1500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
}

@Test @MainActor func geminiChatSignsInRoutesStructuredItemsAndReopensFromItsRecord() async throws {
    let gemini = AgentIntegrationFactory.geminiProfile.connection
    let fixture = try ACPFixture(connection: gemini)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = AppStore(file: fixture.root.appendingPathComponent("store.sqlite"))
    let model = geminiModel(fixture, store: store)
    #expect(model.selectableAgentIDs.contains(gemini) && model.traits(gemini).isSuperset(of: [.sharedEngine, .sessionModels]))
    await model.startEventLoops()
    await model.connect(gemini)
    #expect(model.agentState(gemini).connected && !model.agentState(gemini).authenticated)
    #expect(model.agentState(gemini).descriptor?.engine?.version == "1.0.0")
    // Sign-in is the agent's own authenticate; the fake offers no logout, so sign-out is hidden.
    await model.login(gemini)
    #expect(model.agentState(gemini).authenticated && !model.agentState(gemini).canSignOut && !model.agentState(gemini).signingIn)
    #expect(fixture.received().contains { $0["method"].string == "authenticate" && $0["params"]["methodId"].string == "login" })

    let project = Project(path: fixture.project.path)
    model.state.projects = [project]; model.projectID = project.id; model.state.model = "codex-default"
    model.selectAgent(gemini)
    #expect(model.currentAgent == gemini)
    // A new Gemini chat keeps its own default model; Codex's setting is untouched.
    model.selectModel("deep")
    #expect(model.state.agentModels?[gemini.agent.rawValue] == "deep" && model.state.model == "codex-default" && model.currentModel == "deep")
    #expect(model.currentEffort == "")
    model.draft = "stream"
    #expect(model.canSend)
    await model.send()
    try await settle { model.state.chats.count == 1 && !model.isBusy(threadID: model.state.chats[0].id) && model.items.contains { $0.kind == "assistant" } }
    let chat = model.state.chats[0]
    #expect(chat.nativeSession?.connection == gemini && chat.model == "deep" && chat.effort == "")
    #expect(fixture.received().first { $0["method"].string == "session/set_config_option" }?["params"]["value"].string == "deep")
    // Structured calls and the turn's plan reach the transcript; commands and models come from the session.
    #expect(model.items.contains { $0.toolCall?.id == "t1" && $0.toolCall?.kind == .read && $0.toolCall?.status == .completed })
    #expect(model.items.contains { $0.kind == AgentPlan.itemKind && $0.plan?.entries.map(\.content) == ["Look", "Answer"] })
    try await settle { model.sessionCommands[chat.id]?.map(\.name) == ["memory"] }
    #expect(model.sessionConfigOptions[chat.id]?.first?.category == .model)
    try await settle { model.agentState(gemini).models.map(\.id) == ["fast", "deep"] }
    #expect(model.error == nil)
    await model.flushPersist()
    await model.shutdown()

    // A new app process: the stored chat reopens from the adapter's record and continues through session/load.
    let reopened = geminiModel(fixture, store: store)
    reopened.state = try await store.load()
    await reopened.startEventLoops()
    await reopened.connect(gemini)
    #expect(reopened.agentState(gemini).authenticated)
    // The models of the last session are remembered for new chats before any session exists.
    #expect(reopened.agentState(gemini).models.map(\.id) == ["fast", "deep"])
    let stored = try #require(reopened.state.chats.first)
    reopened.projectID = project.id
    await reopened.openChat(stored)
    #expect(reopened.items.first?.text == "stream" && reopened.items.contains { $0.toolCall?.id == "t1" })
    #expect(reopened.items.contains { $0.kind == AgentPlan.itemKind })
    reopened.draft = "again"
    #expect(reopened.canSend)
    await reopened.send()
    try await settle { !reopened.isBusy(threadID: stored.id) && reopened.items.filter { $0.kind == "user" }.count == 2 }
    #expect(fixture.methods().filter { $0 == "session/load" }.count == 1 && fixture.methods().filter { $0 == "session/new" }.count == 1)
    #expect(reopened.state.chats.count == 1 && reopened.error == nil)
    await reopened.shutdown()
}
