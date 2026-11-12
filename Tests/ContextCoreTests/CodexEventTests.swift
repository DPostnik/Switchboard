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
    let longCommand = "echo " + String(repeating: "x", count: 2000)
    let typed = try #require(CodexPendingInteraction.parse(request(extra: ["command": .string(longCommand), "cwd": .string("/workspace")])) )
    #expect(typed.interaction.command == longCommand && typed.interaction.workingDirectory == "/workspace")
}

@Test func commandSessionApprovalPreservesNativeDefaultsAndRestrictions() throws {
    let offered = try #require(CodexPendingInteraction.parse(request(extra: [
        "availableDecisions": .array([.string("accept"), .string("acceptForSession"), .string("decline")])
    ])))
    #expect(offered.interaction.canAllowChat)
    #expect(offered.toolApprovalServer == nil)
    #expect(try offered.encode(.allowChat) == .object(["decision": .string("acceptForSession")]))
    #expect(try offered.encode(.allowOnce) == .object(["decision": .string("accept")]))
    let legacy = try #require(CodexPendingInteraction.parse(request()))
    #expect(legacy.interaction.canAllowChat)
    #expect(try legacy.encode(.allowChat) == .object(["decision": .string("acceptForSession")]))
    for decisions: JSONValue in [.array([.string("accept"), .string("decline")]),
                                  .array([.string("acceptForSession"), .string("cancel")])] {
        let pending = try #require(CodexPendingInteraction.parse(request(extra: ["availableDecisions": decisions])))
        #expect(!pending.interaction.canAllowChat)
        #expect(throws: ClientFailure.self) { try pending.encode(.allowChat) }
    }
    let file = try #require(CodexPendingInteraction.parse(request("item/fileChange/requestApproval", extra: [
        "availableDecisions": .array([.string("accept"), .string("acceptForSession"), .string("decline")])
    ])))
    #expect(!file.interaction.canAllowChat)
    #expect(throws: ClientFailure.self) { try file.encode(.allowChat) }
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
    func capabilities(count: Int) async throws -> [AgentCapabilityRecord] {
        for _ in 0..<1000 {
            let records = values.compactMap { event -> AgentCapabilityRecord? in
                if case .capability(let value) = event.payload { return value }; return nil
            }
            if records.count >= count { return records }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClientFailure("Fixture did not deliver capability records")
    }
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
        if m['method'] == 'test/oversized-reply':
            print(json.dumps({'id':m['id'], 'result':'x' * 5000}), flush=True)
            continue
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

@Test func isolatedWorkerAccountAnnouncementKeepsTheSharedAccountRevision() async throws {
    try await withEventFixture { client, wire, _ in
        // Real app-servers send `account/updated` right after `initialize`; a Chrome worker's start must not stale a send.
        let worker = await wire.sibling(preservingAccountRevision: true)
        let home = try #require(await wire.activeHome)
        try await worker.start(executable: home.appendingPathComponent("engine.py"), home: home)
        defer { Task { await worker.stop() } }
        let epoch = await wire.accountEpoch
        _ = try await worker.request("test/emit", params: .object(["method": .string("account/updated"), "params": .object([:])]))
        _ = try await CodexDispatchContext.$epoch.withValue(epoch) { try await wire.request("test/answers") }
        #expect(await wire.accountEpoch == epoch)
        _ = try await wire.request("test/emit", params: .object(["method": .string("account/updated"), "params": .object([:])]))
        #expect(await wire.accountEpoch != epoch)
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

@Test func oversizedWireEventIsSkippedWithAChatNoticeAndTheProcessKeepsRunning() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request())
        let pending = try await log.interaction(count: 1)
        // The oversized line precedes this request's own reply, which still arrives.
        _ = try await wire.request("test/oversized")
        for _ in 0..<1000 {
            if await log.values.contains(where: { if case .diagnostic = $0.payload { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await log.values
        let notice = events.first { if case .diagnostic = $0.payload { return true }; return false }
        #expect(notice?.session?.nativeID == "t")
        #expect(!events.contains { if case .disconnected = $0.payload { return true }; return false })
        // An oversized reply fails its request at once instead of waiting for the timeout.
        let started = ContinuousClock.now
        await #expect(throws: CodexReplyTooLarge.self) { _ = try await wire.request("test/oversized-reply") }
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(await wire.isRunning)
        try await client.answer(pending.id, session: pending.session, response: .allowOnce)
        #expect(try await wire.request("test/answers").array.count == 1)
    }
}

@Test func mcpElicitationAuditRecordsTypedLifecycleWithoutSecretPayloadsOrInferredAuthority() async throws {
    let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["token": .object(["type": .string("string")])])])
    let params: [String: JSONValue] = ["mode": .string("form"), "message": .string("Allow the secret server to run tool browser_eval?"), "requestedSchema": schema]
    let parsed = try #require(CodexPendingInteraction.parse(request("mcpServer/elicitation/request", extra: params)))
    let encoded = try JSONEncoder().encode(parsed.capability(stage: .requested))
    let auditText = String(decoding: encoded, as: UTF8.self)
    #expect(!auditText.contains("secret server") && !auditText.contains("browser_eval") && !auditText.contains("token"))
    #expect(parsed.interaction.auditSource == "mcpServer/elicitation/request")
    #expect(parsed.interaction.command == nil && parsed.interaction.workingDirectory == nil)
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request("mcpServer/elicitation/request", extra: params))
        let interaction = try await log.interaction(count: 1)
        try await client.answer(interaction.id, session: interaction.session, response: .answers(["token": "never-log-this-answer"]))
        let records = try await log.capabilities(count: 2)
        #expect(records.count == 2 && records.allSatisfy { $0.requestID == interaction.id.uuidString })
        #expect(records.map(\.stage) == [.requested, .responded])
        #expect(records.map(\.decision) == [.asked, .answered])
        #expect(records.allSatisfy { $0.capability == .other && $0.tool == "mcpElicitation" && $0.target == nil })
        #expect(records[1].outcome == .unknown)
        #expect(!String(decoding: try JSONEncoder().encode(records), as: UTF8.self).contains("never-log-this-answer"))
    }
}

private func toolApproval(server: String, id: JSONValue, persist: JSONValue = .array([.string("session"), .string("always")])) -> JSONValue {
    // Literal wire keys from Codex rust-v0.167.0, protocol/src/mcp_approval_meta.rs
    // and core/src/mcp_tool_call.rs. Never reuse the adapter's constants here.
    request("mcpServer/elicitation/request", id: id, extra: [
        "mode": .string("form"), "serverName": .string(server), "message": .string("Allow \(server) to run tool input?"),
        "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
        "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "persist": persist])])
}

@Test func browserToolApprovalsOfferAChatGrantOnlyForAppOwnedServers() throws {
    let chrome = try #require(CodexPendingInteraction.parse(toolApproval(server: "switchboard_user_chrome", id: .number(1))))
    guard case .approval(true) = chrome.interaction.kind else { Issue.record("Expected an approval"); return }
    #expect(chrome.interaction.canAllowChat && chrome.toolApprovalServer == "switchboard_user_chrome")
    #expect(try chrome.encode(.allowOnce) == .object(["action": .string("accept"), "content": .object([:])]))
    #expect(try chrome.encode(.allowChat)["_meta"] == .object(["persist": .string("session")]))
    #expect(try chrome.encode(.deny) == .object(["action": .string("decline")]))
    #expect(throws: ClientFailure.self) { try chrome.encode(.answers([:])) }
    let alwaysOnly = try #require(CodexPendingInteraction.parse(toolApproval(server: "switchboard_browser", id: .number(2), persist: .string("always"))))
    #expect(try alwaysOnly.encode(.allowChat)["_meta"] == .object([:]))
    let other = try #require(CodexPendingInteraction.parse(toolApproval(server: "github", id: .number(3))))
    #expect(!other.interaction.canAllowChat)
    #expect(throws: ClientFailure.self) { try other.encode(.allowChat) }
    // A server's own form without the engine's approval marker stays a form.
    var plain = toolApproval(server: "switchboard_user_chrome", id: .number(4)).object
    var params = plain["params"]!.object; params["_meta"] = nil; plain["params"] = .object(params)
    let form = try #require(CodexPendingInteraction.parse(.object(plain)))
    guard case .form = form.interaction.kind else { Issue.record("Expected a form"); return }
    #expect(!form.interaction.canAllowChat && form.toolApprovalServer == nil)
}

@Test func browserChatGrantRejectsUnrecognizedMarkersAndMalformedSchemas() throws {
    let original = toolApproval(server: "switchboard_browser", id: .number(8))
    for meta: JSONValue in [
        .object(["codex/approvals/mcp_tool_call/kind": .string("mcp_tool_call")]),
        .object(["codex_approval_kind": .string("browser_auth")]),
        .object(["codex_approval_kind": .bool(true)]), .null
    ] {
        var raw = original.object, params = original["params"].object
        params["_meta"] = meta; raw["params"] = .object(params)
        let pending = try #require(CodexPendingInteraction.parse(.object(raw)))
        #expect(!pending.interaction.canAllowChat && pending.toolApprovalServer == nil)
        #expect(throws: ClientFailure.self) { try pending.encode(.allowChat) }
    }
    for required: JSONValue in [.string("unexpected"), .array([.string("missing")]), .bool(false)] {
        var raw = original.object, params = original["params"].object
        var schema = params["requestedSchema"]!.object
        schema["required"] = required; params["requestedSchema"] = .object(schema)
        raw["params"] = .object(params)
        let pending = try #require(CodexPendingInteraction.parse(.object(raw)))
        #expect(!pending.interaction.canAllowChat && pending.toolApprovalServer == nil)
    }
}

@Test func chatGrantAnswersLaterCallsOfTheSameServerInTheSameChatUntilReset() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: toolApproval(server: "switchboard_user_chrome", id: .string("a")))
        let first = try await log.interaction(count: 1)
        try await client.answer(first.id, session: first.session, response: .allowChat)
        _ = try await wire.request("test/emit", params: toolApproval(server: "switchboard_user_chrome", id: .string("b")))
        var sent: [JSONValue] = []
        for _ in 0..<200 {
            sent = try await wire.request("test/answers").array
            if sent.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sent.map { $0["id"] } == [.string("a"), .string("b")])
        #expect(sent.allSatisfy { $0["result"]["action"].string == "accept" })
        #expect(await client.interactions.isEmpty)
        // Another server still asks.
        _ = try await wire.request("test/emit", params: toolApproval(server: "switchboard_browser", id: .string("c")))
        let other = try await log.interaction(count: 2)
        try await client.answer(other.id, session: other.session, response: .deny)
        let records = try await log.capabilities(count: 5)
        #expect(records.contains { $0.stage == .responded && $0.decision == .allowed && $0.target == "switchboard_user_chrome" && $0.capability == .browser })
        // A reset forgets the grant.
        let index = await log.values.count
        _ = try await wire.request("test/emit", params: .object(["method": .string("account/updated"), "params": .object([:])]))
        try await log.waitForReset(after: index)
        #expect(await client.chatToolGrants.isEmpty)
    }
}

@Test func failedCodexAnswerAuditRemainsUnknownAndTheRequestCannotReplay() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: request())
        let interaction = try await log.interaction(count: 1)
        // An invalidated native token makes the transport reject this consumed answer.
        await wire.invalidateAccount()
        await #expect(throws: ClientFailure.self) { try await client.answer(interaction.id, session: interaction.session, response: .allowOnce) }
        await #expect(throws: ClientFailure.self) { try await client.answer(interaction.id, session: interaction.session, response: .allowOnce) }
        let records = try await log.capabilities(count: 2)
        #expect(records.count == 2 && records[1].stage == .responded && records[1].outcome == .unknown)
        #expect(records[1].decision == .allowed && records[1].requestID == interaction.id.uuidString)
        #expect(try await wire.request("test/answers").array.isEmpty)
    }
}

@Test func failedChatGrantAnswerDoesNotAuthorizeLaterBrowserCalls() async throws {
    try await withEventFixture { client, wire, log in
        _ = try await wire.request("test/emit", params: toolApproval(server: "switchboard_user_chrome", id: .string("grant-fail")))
        let interaction = try await log.interaction(count: 1)
        await wire.invalidateAccount()
        await #expect(throws: ClientFailure.self) {
            try await client.answer(interaction.id, session: interaction.session, response: .allowChat)
        }
        #expect(await client.chatToolGrants.isEmpty)
    }
}

@Test func codexItemAuditNeedsKnownIDsAndExplicitResultsForSuccess() async throws {
    let item: JSONValue = .object(["type": .string("commandExecution"), "id": .string("command-1"), "command": .string("false"), "status": .string("completed"), "exitCode": .number(1)])
    let start = try #require(CodexEventDecoder.capability(item, turn: "v"))
    #expect(start.stage == .started && start.outcome == nil && start.decision == .used)
    let end = try #require(CodexEventDecoder.capability(item, turn: "v", completed: true))
    #expect(end.stage == .completed && end.outcome == .failed && end.requestID == start.requestID)
    try await withEventFixture { _, wire, log in
        func emit(_ method: String, turn: String) async throws {
            _ = try await wire.request("test/emit", params: .object(["method": .string(method), "params": .object(["threadId": .string("t"), "turnId": .string(turn), "item": item])]))
        }
        try await emit("item/started", turn: "v")
        try await emit("item/completed", turn: "other") // Same item ID in another turn is not this execution.
        try await emit("item/completed", turn: "v")
        let records = try await log.capabilities(count: 2)
        #expect(records.count == 2 && records.map(\.stage) == [.started, .completed])
        #expect(records[1].outcome == .failed)
    }
}

/// Project skills (`ProjectSkills`) ride only on the chat's own worker, next to the app's workflows.
@Test func codexWorkersRegisterTheirOwnProjectSkillsNextToTheWorkflows() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let links = root.appendingPathComponent("links"), workflows = root.appendingPathComponent("workflows")
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, sys
    log = []
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m or 'method' not in m: continue
        result = {}
        if m['method'].startswith('skills/'): log.append({'method': m['method'], 'params': m.get('params')})
        if m['method'] == 'test/log': result = log
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let project = try projectSkillFixture()
    func sent(_ client: CodexClient) async throws -> [JSONValue] { try await client.transport.request("test/log").array }
    func current() throws -> (folder: URL, skills: [ProjectSkills.Skill])? { try ProjectSkills.linkFolder(projectPath: project.path, root: links) }
    let client = CodexClient(transport: CodexConnection())
    try await client.start(executable: executable, home: root)
    var worker: CodexClient?
    do {
        try await client.registerWorkflows(at: [workflows])
        let skills = try #require(try current())
        let chat = try await client.isolatedSibling(projectSkills: skills)
        worker = chat
        #expect(await chat.registeredSkillRoots == [workflows, skills.folder])
        // The shared process (and so every other project's chat) does not get this project's skills.
        #expect(await client.registeredSkillRoots == [workflows])
        let start = try await sent(chat)
        #expect(start.count == 1 && start[0]["params"]["extraRoots"] == .array([.string(workflows.path), .string(skills.folder.path)]))

        // Nothing changed: nothing is sent, the process stays.
        try await chat.refreshProjectSkills(try current(), projectPath: project.path)
        #expect(try await sent(chat).count == 1)
        // A new skill in the same folder: Codex rescans the project's skills.
        try writeSkillFixture(skillHeader("new-skill", "Added later"), to: project.appendingPathComponent(".agents/skills/new-skill/SKILL.md"))
        try await chat.refreshProjectSkills(try current(), projectPath: project.path)
        let rescan = try await sent(chat)
        #expect(rescan.count == 2 && rescan[1]["method"].string == "skills/list" && rescan[1]["params"]["forceReload"].bool == true)
        // A later workflow registration keeps the project's folder on its worker.
        try await chat.registerWorkflows(at: [workflows])
        #expect(await chat.registeredSkillRoots == [workflows, skills.folder])
        // No skill left: the folder leaves the roots.
        for source in ProjectSkills.sources { try FileManager.default.removeItem(at: project.appendingPathComponent(source)) }
        try await chat.refreshProjectSkills(try current(), projectPath: project.path)
        #expect(await chat.registeredSkillRoots == [workflows])
    } catch { await worker?.stop(); await client.stop(); throw error }
    await worker?.stop(); await client.stop()
}
