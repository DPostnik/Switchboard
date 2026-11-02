import Foundation
import Testing
@testable import ACPAdapter
@testable import ContextCore

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
        reply(i, {'sessionId': session, 'configOptions': options} if method == 'session/new' else {'configOptions': options})
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
}

private struct ACPFixture {
    let root: URL, home: URL, project: URL, executable: URL
    let drift = CompatibilityDrift(logging: false)
    let profile: ACPLaunchProfile

    init(_ config: [String: Any] = [:], cancelGrace: Duration = .seconds(30)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-" + UUID().uuidString)
        home = root.appendingPathComponent("home"); project = root.appendingPathComponent("project")
        executable = root.appendingPathComponent("fake-acp")
        for folder in [home, project] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try ("#!" + fixturePython + "\n" + fakeAgent).write(to: executable, atomically: true, encoding: .utf8)
        try installFixtureExecutable(at: executable)
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent("fixture.json"))
        let agent = AgentID(rawValue: "fake-acp")
        profile = ACPLaunchProfile(
            agent: agent, connection: AgentConnectionID(agent: agent, id: UUID()), productName: "Fake ACP", arguments: ["--acp"],
            candidates: { _, _ in [] },
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
    #expect(items.contains { $0.kind == "activity" && $0.text.contains("[x] Look") && $0.text.contains("[~] Answer") })
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
    #expect(unsurfaced["update:available_commands_update"] == 1 && unsurfaced["update:session_info_update"] == 1)
    #expect(unsurfaced["request:fs/read_text_file"] == 1)
    #expect(fixture.driftNames() == ["itemType hologram_update", "notification _fake/notice", "serverRequest _fake/teleport"])
    // The app's own record is the chat's history.
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.count == 1 && history[0].items.first?.text == "stream" && history[0].isComplete)
    await adapter.disconnect()
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
