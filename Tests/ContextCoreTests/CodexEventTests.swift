import Foundation
import Testing
import ContextCore
import AgentContract
@_spi(NativeProtocol) @testable import CodexAdapter
@testable import ContextDesk

private func request(_ method: String = "item/commandExecution/requestApproval", id: JSONValue = .number(42), extra: [String: JSONValue] = [:]) -> JSONValue {
    var params: [String: JSONValue] = ["threadId": .string("t"), "turnId": .string("v"), "command": .string("echo test")]
    params.merge(extra) { _, new in new }
    return .object(["id": id, "method": .string(method), "params": .object(params)])
}

@Test func typedApprovalsPreserveChoicesAndNeverExpandPermissions() throws {
    let ordinary = try #require(CodexPendingInteraction.parse(request()))
    #expect(try ordinary.encode(.allowOnce) == .object(["decision": .string("accept")]))
    let denyOnly = try #require(CodexPendingInteraction.parse(request(extra: ["availableDecisions": .array([.string("cancel"), .string("acceptForSession")])])) )
    #expect(throws: ClientFailure.self) { try denyOnly.encode(.allowOnce) }
    #expect(try denyOnly.encode(.deny) == .object(["decision": .string("cancel")]))
    let grantRoot = try #require(CodexPendingInteraction.parse(request("item/fileChange/requestApproval", extra: ["grantRoot": .string("/")])))
    #expect(throws: ClientFailure.self) { try grantRoot.encode(.allowOnce) }
    let permissions: JSONValue = .object(["network": .object(["enabled": .bool(true)]), "fileSystem": .object(["write": .array([.string("/workspace")])])])
    let permission = try #require(CodexPendingInteraction.parse(request("item/permissions/requestApproval", extra: ["permissions": permissions])))
    #expect(try permission.encode(.allowOnce) == .object(["permissions": permissions, "scope": .string("turn")]))
    #expect(try permission.encode(.deny) == .object(["permissions": .object([:]), "scope": .string("turn")]))
    let future = try #require(CodexPendingInteraction.parse(request("item/permissions/requestApproval", extra: ["permissions": .object(["future": .bool(true)])])))
    #expect(throws: ClientFailure.self) { try future.encode(.allowOnce) }
    #expect(CodexPendingInteraction.parse(request("future/request")) == nil)
    #expect(CodexPendingInteraction.parse(request(id: .number(1.5))) == nil)
}

@Test func typedQuestionsAndFormsValidateAnswersWithoutDroppingSchemaRestrictions() throws {
    let question: JSONValue = .object(["id": .string("secret"), "question": .string("Input"), "isSecret": .bool(true)])
    let questions = try #require(CodexPendingInteraction.parse(request("item/tool/requestUserInput", extra: ["questions": .array([question])])))
    guard case .questions(let fields) = questions.interaction.kind else { Issue.record("Expected questions"); return }
    #expect(fields[0].secret)
    let described: JSONValue = .object(["id": .string("pick"), "question": .string("Pick"), "options": .array([
        .object(["label": .string("A"), "description": .string("First")]), .object(["label": .string("B")])])])
    let pick = try #require(CodexPendingInteraction.parse(request("item/tool/requestUserInput", extra: ["questions": .array([described])])))
    guard case .questions(let pickFields) = pick.interaction.kind else { Issue.record("Expected questions"); return }
    #expect(pickFields[0].options == [.init(label: "A", description: "First"), .init(label: "B")])
    #expect(throws: ClientFailure.self) { try questions.encode(.answers([:])) }
    #expect(throws: ClientFailure.self) { try questions.encode(.answers(["secret": "value", "extra": "x"])) }
    #expect(try questions.encode(.answers(["secret": "literal `$(data)`"]))["answers"]["secret"]["answers"] == .array([.string("literal `$(data)`")]))
    #expect(CodexPendingInteraction.parse(request("item/tool/requestUserInput", extra: ["questions": .array([question, question])])) == nil)
    let plain: JSONValue = .object(["type": .string("string"), "title": .string("Name")])
    for constraint in ["enum", "format", "minLength", "pattern", "oneOf"] {
        var field = plain.object; field[constraint] = .string("unsupported")
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["name": .object(field)])])
        let form = try #require(CodexPendingInteraction.parse(request("mcpServer/elicitation/request", extra: ["mode": .string("form"), "requestedSchema": schema])))
        #expect(throws: ClientFailure.self) { try form.encode(.answers(["name": "x"])) }
        #expect(try form.encode(.deny)["action"].string == "decline")
    }
    let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["name": plain]), "required": .array([.string("name")])])
    let form = try #require(CodexPendingInteraction.parse(request("mcpServer/elicitation/request", extra: ["mode": .string("form"), "requestedSchema": schema])))
    #expect(throws: ClientFailure.self) { try form.encode(.answers(["name": " "])) }
    #expect(try form.encode(.answers(["name": "данные / data"]))["content"]["name"].string == "данные / data")
    let badURL = try #require(CodexPendingInteraction.parse(request("mcpServer/elicitation/request", extra: ["mode": .string("url"), "url": .string("file:///tmp")])) )
    #expect(throws: ClientFailure.self) { try badURL.encode(.completed) }
}

private actor EventLog {
    var values: [CodexEvent] = []
    func append(_ value: CodexEvent) { values.append(value) }
    func interaction(count: Int) async throws -> CodexInteraction {
        for _ in 0..<1000 {
            let requests = values.compactMap { event -> CodexInteraction? in
                if case .interaction(let value) = event.payload { return value }; return nil
            }
            if requests.count >= count { return requests[count - 1] }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClientFailure("Fixture did not deliver an interaction")
    }
    func waitForReset(after index: Int) async throws {
        for _ in 0..<1000 {
            if values.dropFirst(index).contains(where: { if case .interactionsReset = $0.payload { return true }; return false }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClientFailure("Fixture did not reset interactions")
    }
}

private func withEventFixture(_ body: (CodexClient, CodexConnection, EventLog) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, sys
    answers = []
    for line in sys.stdin:
        m = json.loads(line)
        if 'method' not in m:
            answers.append(m)
            continue
        if 'id' not in m: continue
        result = {}
        if m['method'] == 'test/oversized': print('x' * 5000, flush=True)
        if m['method'] == 'test/emit': print(json.dumps(m['params']), flush=True)
        if m['method'] == 'test/answers': result = answers
        print(json.dumps({'id':m['id'], 'result':result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let wire = CodexConnection(maximumLineBytes: 4096), log = EventLog()
    let client = CodexClient(transport: wire)
    await client.observeEvents(sessions: [.init(connection: .originalCodex, nativeID: "t")])
    let reader = Task { for await event in client.events { await log.append(event) } }
    defer { reader.cancel() }
    do {
        try await client.start(executable: executable, home: root)
        try await body(client, wire, log)
        await client.stop()
    } catch { await client.stop(); throw error }
}

@Test func interactionsAreSingleUseScopedAndInvalidatedByAccountChanges() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request())
        let first = try await log.interaction(count: 1)
        let wrong = AgentSessionReference(connection: AgentConnectionID(agent: .codex, id: UUID()), nativeID: "t")
        await #expect(throws: ClientFailure.self) { try await client.answer(first.id, session: wrong, response: .allowOnce) }
        try await client.answer(first.id, session: first.session, response: .allowOnce)
        await #expect(throws: ClientFailure.self) { try await client.answer(first.id, session: first.session, response: .allowOnce) }
        let sent = try await wire.request("test/answers").array
        #expect(sent.count == 1 && sent[0]["id"] == .number(42))
        _ = try await wire.request("test/emit", params: request(id: .string("second")))
        let second = try await log.interaction(count: 2)
        let native = try #require(await client.interactions[second.id])
        let index = await log.values.count
        _ = try await wire.request("test/emit", params: .object(["method": .string("account/updated"), "params": .object([:])]))
        // The transport must reject even before the app processes its reset event.
        await #expect(throws: ClientFailure.self) {
            try await wire.answer(id: native.pending.rpcID, result: .object(["decision": .string("accept")]),
                                  generation: native.generation, requestToken: native.token)
        }
        try await log.waitForReset(after: index)
        await #expect(throws: ClientFailure.self) { try await client.answer(second.id, session: second.session, response: .allowOnce) }
        #expect(try await wire.request("test/answers").array.count == 1)
    }
}

@Test func unknownRequestsAndReusedIDsFailClosedAndDisconnectPreventsOldAnswers() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request())
        let first = try await log.interaction(count: 1)
        let old = try #require(await client.interactions[first.id])
        _ = try await wire.request("test/emit", params: request())
        _ = try await wire.request("test/emit", params: request("future/request", id: .string("unknown")))
        _ = try await wire.request("test/emit", params: request(id: .string("foreign"), extra: ["threadId": .string("not-owned")]))
        for _ in 0..<1000 {
            if try await wire.request("test/answers").array.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let rejected = try await wire.request("test/answers").array
        #expect(rejected.count == 3 && rejected.allSatisfy { $0["error"]["code"].int == -32601 })
        await #expect(throws: ClientFailure.self) { try await client.answer(first.id, session: first.session, response: .allowOnce) }
        await client.stop()
        await client.receiveWire(CodexWireEvent(generation: old.generation, message: request(id: .string("late"))))
        #expect(await client.interactions.isEmpty)
        await #expect(throws: ClientFailure.self) { try await wire.answer(id: old.pending.rpcID, result: .object([:]), generation: old.generation, requestToken: old.token) }
    }
}

@Test func scopedCompletionResolvesOnlyItsTurnAndNormalizesTimingAndUsage() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request())
        let first = try await log.interaction(count: 1)
        _ = try await wire.request("test/emit", params: request(id: .string("other"), extra: ["turnId": .string("other")]))
        let other = try await log.interaction(count: 2)
        let raw: JSONValue = .object(["method": .string("turn/completed"), "params": .object(["threadId": .string("t"), "turn": .object(["id": .string("v"), "status": .string("completed"), "completedAt": .number(100), "durationMs": .number(1500)])])])
        _ = try await wire.request("test/emit", params: raw)
        for _ in 0..<1000 {
            if await client.interactions[first.id] == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await #expect(throws: ClientFailure.self) { try await client.answer(first.id, session: first.session, response: .allowOnce) }
        try await client.answer(other.id, session: other.session, response: .deny)
        let event = try #require(CodexEventDecoder.notification(raw))
        guard case .completed(let completion) = event.payload else { Issue.record("Missing completion"); return }
        #expect(completion.timing(fallback: ResponseTiming(startedAt: nil, completedAt: Date())).durationSeconds == 1.5)
        let usage = try #require(CodexEventDecoder.notification(.object(["method": .string("thread/tokenUsage/updated"), "params": .object(["threadId": .string("t")])])) )
        guard case .usage(_, let total, let snapshot) = usage.payload else { Issue.record("Missing usage"); return }
        #expect(total == nil && snapshot.input == nil && snapshot.output == nil)
        #expect(CodexEventDecoder.notification(.object(["method": .string("item/agentMessage/delta"), "params": .object(["itemId": .string("bad")])])) == nil)
    }
}

@Test func oversizedWireEventDisconnectsAndInvalidatesInteractionWithoutReplay() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request())
        let pending = try await log.interaction(count: 1)
        do { _ = try await wire.request("test/oversized") } catch { /* transport closes pending RPCs */ }
        for _ in 0..<1000 {
            if await log.values.contains(where: { if case .disconnected = $0.payload { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await log.values
        #expect(events.contains { if case .diagnostic = $0.payload { return true }; return false })
        #expect(events.contains { if case .disconnected = $0.payload { return true }; return false })
        await #expect(throws: ClientFailure.self) { try await client.answer(pending.id, session: pending.session, response: .allowOnce) }
    }
}
