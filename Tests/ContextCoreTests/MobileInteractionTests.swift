@_spi(NativeProtocol) import CodexAdapter
import AgentContract
import ContextCore
import Foundation
import Testing
@testable import ContextDesk

// Phone answers to questions and forms, messages for a working chat, and role add-ons (Stage 2).

private func question(_ id: String, _ text: String, options: [AgentInteraction.Field.Option] = [], secret: Bool = false, header: String? = nil) -> AgentInteraction.Field {
    .init(id: id, text: text, options: options, secret: secret, required: true, header: header)
}
private func interaction(_ kind: AgentInteraction.Kind) -> AgentInteraction {
    AgentInteraction(id: UUID(), session: .init(connection: .originalCodex, nativeID: "t"), turn: "v1", kind: kind, reason: nil, details: "")
}

@Test func phoneQuestionsKeepEveryAnswerableDetailAndMarkTheRestMacOnly() throws {
    let pick = question("pick", "Which approach?", options: [.init(label: "A", description: "First", preview: "code A"), .init(label: "B")], header: " Approach ")
    let published = try #require(RemoteInteraction(interaction(.questions([pick, question("name", "Name it")]))))
    #expect(published.kindValue == .questions && published.canAnswer && !published.canDecline && published.macOnly == nil)
    #expect(published.questions[0].header == "Approach" && published.questions[0].allowsOther && published.questions[0].multiSelect == nil)
    #expect(published.questions[0].options == [RemoteQuestionOption(label: "A", description: "First", preview: "code A"), RemoteQuestionOption(label: "B")])
    // Every question needs an answer; an option is sent by its exact label, free text is allowed as on the desktop.
    try published.validate(answers: ["pick": "A", "name": "Свой ответ / own answer"])
    try published.validate(answers: ["pick": "Something else", "name": "x"])
    #expect(throws: RemoteFailure.self) { try published.validate(answers: ["pick": "A"]) }
    #expect(throws: RemoteFailure.self) { try published.validate(answers: ["pick": "A", "name": "  "]) }
    #expect(throws: RemoteFailure.self) { try published.validate(answers: ["pick": "A", "name": "x", "extra": "y"]) }
    #expect(throws: RemoteFailure.self) { try published.validate(answers: ["pick": "A", "name": String(repeating: "x", count: RemoteInteraction.answerBytes + 1)]) }
    var closed = published
    closed.questions[0].allowsOther = false
    #expect(throws: RemoteFailure.self) { try closed.validate(answers: ["pick": "C", "name": "x"]) }

    // Lossy or unsafe requests are published for reading only.
    let secret = try #require(RemoteInteraction(interaction(.questions([question("token", "Token", secret: true)]))))
    #expect(!secret.canAnswer && secret.macOnlyReason == .secret && secret.macOnlyMessage != nil)
    #expect(throws: RemoteFailure.self) { try secret.validate(answers: ["token": "value"]) }
    let longLabel = try #require(RemoteInteraction(interaction(.questions([question("q", "Q", options: [.init(label: String(repeating: "l", count: RemoteInteraction.labelLimit + 1))])]))))
    #expect(!longLabel.canAnswer && longLabel.macOnlyReason == .tooLarge && longLabel.questions[0].options[0].label.count == RemoteInteraction.labelLimit)
    let many = try #require(RemoteInteraction(interaction(.questions((0..<(RemoteInteraction.questionLimit + 1)).map { question("q\($0)", "Q\($0)") }))))
    #expect(!many.canAnswer && many.questions.count == RemoteInteraction.questionLimit)
    let wordy = (0..<8).map { index in
        question("q\(index)", String(repeating: "t", count: 1500), options: (0..<12).map { .init(label: "o\($0)", description: String(repeating: "d", count: 600), preview: String(repeating: "p", count: 1500)) })
    }
    let budget = try #require(RemoteInteraction(interaction(.questions(wordy))))
    #expect(!budget.canAnswer && budget.macOnlyReason == .tooLarge)
    #expect(budget.questions.allSatisfy { $0.options.allSatisfy { $0.description == nil && $0.preview == nil } })
    #expect(try JSONEncoder().encode(budget).count < 40_000)

    let form = try #require(RemoteInteraction(interaction(.form(message: "Fill in", fields: [.init(id: "name", text: "Name", options: [], secret: false, required: false)]))))
    #expect(form.kindValue == .form && form.canAnswer && form.canDecline && form.message == "Fill in")
    try form.validate(answers: [:])
    let link = try #require(RemoteInteraction(interaction(.link(message: "Sign in", url: URL(string: "https://example.com")!))))
    #expect(!link.canAnswer && link.canDecline && link.macOnlyReason == .link)
    let unsupported = try #require(RemoteInteraction(interaction(.unsupported(message: "Enum form"))))
    #expect(!unsupported.canAnswer && unsupported.canDecline && unsupported.macOnlyReason == .unsupported)
    #expect(RemoteInteraction(interaction(.approval(canAllow: true))) == nil)
    var stripped = published
    stripped.requireMac(.setup)
    #expect(!stripped.canAnswer && stripped.macOnlyReason == .setup)
    // Both languages carry wording for every reason.
    for reason in RemoteInteraction.MacOnly.allCases {
        #expect(!reason.message(language: .russian).isEmpty && reason.message(language: .english) != reason.message(language: .russian))
    }
}

@Test func phoneProtocolAdditionsDecodeBothWaysAndCommandsFailClosed() throws {
    // Snapshots and settings from older hosts decode with every addition absent.
    let old = try JSONDecoder().decode(RemoteChat.self, from: Data(#"{"id":"c","project":"p","title":"t","running":true,"messages":[],"approvals":[],"settings":{"options":{"model":"m"},"projectAccess":"standard","canEdit":true}}"#.utf8))
    #expect(old.interactions == nil && old.queue == nil && old.canQueue == nil && old.canInterrupt == nil && old.queuePaused == nil)
    #expect(old.settings?.addOns == nil && old.settings?.options.addOns == nil)
    // A kind or reason from a newer host never breaks decoding.
    let future = try JSONDecoder().decode(RemoteInteraction.self, from: Data(#"{"id":"x","kind":"poll","questions":[],"canAnswer":false,"canDecline":false,"macOnly":"future"}"#.utf8))
    #expect(future.kindValue == nil && future.macOnlyReason == nil && future.macOnlyMessage != nil)

    let owner = UUID().uuidString, device = UUID().uuidString, project = UUID().uuidString
    let handle = UUID().uuidString
    let answer = RemoteCommand.answer(owner: owner, device: device, project: project, chat: "c", interaction: handle, answers: ["q": "A"])
    try answer.validate()
    #expect(answer.needsInteractionSchema && answer.kind == "answer")
    let decoded = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(answer))
    #expect(decoded.answers == ["q": "A"] && decoded.approval == handle)
    var broken = answer; broken.approval = "not-a-uuid"
    #expect(throws: RemoteFailure.self) { try broken.validate() }
    broken = answer; broken.answers = nil
    #expect(throws: RemoteFailure.self) { try broken.validate() }
    broken = answer; broken.text = "text"
    #expect(throws: RemoteFailure.self) { try broken.validate() }
    broken = answer; broken.kind = "send"; broken.text = "hi"
    #expect(throws: RemoteFailure.self) { try broken.validate() } // only answer carries answers
    // Sends that do not use the new fields keep the old envelope and need no new schema.
    let send = RemoteCommand(owner: owner, device: device, project: project, chat: "c", kind: "send", text: "hi")
    let sendJSON = String(decoding: try JSONEncoder().encode(send), as: UTF8.self)
    #expect(!send.needsInteractionSchema && !sendJSON.contains("answers"))

    let queue = RemoteCommand.queue(owner: owner, device: device, project: project, chat: "c", text: "Next")
    try queue.validate()
    #expect(queue.needsInteractionSchema && queue.turn == nil)
    #expect(throws: RemoteFailure.self) { try RemoteCommand.queue(owner: owner, device: device, project: project, chat: "c", text: " ").validate() }
    let interrupt = RemoteCommand.interruptAndSend(owner: owner, device: device, project: project, chat: "c", turn: "turn-1", text: "Instead")
    try interrupt.validate()
    broken = interrupt; broken.turn = nil
    #expect(throws: RemoteFailure.self) { try broken.validate() }
    broken = interrupt; broken.turn = ""
    #expect(throws: RemoteFailure.self) { try broken.validate() }
    let decline = RemoteCommand.decline(owner: owner, device: device, project: project, chat: "c", interaction: handle)
    try decline.validate()
    #expect(decline.kind == "deny" && !decline.needsInteractionSchema)
    var unknown = queue; unknown.kind = "steer"
    #expect(throws: RemoteFailure.self) { try unknown.validate() }

    // Settings: a role or add-ons need the new schema; an add-on change must say which add-ons the phone saw.
    let seen = RemoteChatSettings(options: RemoteChatOptions(model: "m", role: "editor", addOns: []), projectAccess: .standard, canEdit: true,
                                  addOns: [RemoteAddOnOption(id: "mail", name: "Mail")], projectAddOns: [])
    let configure = RemoteCommand.configure(owner: owner, device: device, project: project, chat: "c",
                                            options: RemoteChatOptions(model: "m", role: "reader", addOns: ["mail"]), expected: seen)
    try configure.validate()
    #expect(configure.needsInteractionSchema && configure.settings?.options.addOns == ["mail"] && configure.settings?.expected?.addOns == [])
    var blind = configure; blind.settings?.expected?.addOns = nil
    #expect(throws: RemoteFailure.self) { try blind.validate() }
    // Unchanged add-ons, or a host that offers none, are left out on both sides: the Mac keeps the chat's add-ons.
    var modelOnly = RemoteChatSettings(options: RemoteChatOptions(model: "m", addOns: ["mail"]), projectAccess: .standard, canEdit: true,
                                       addOns: [RemoteAddOnOption(id: "mail", name: "Mail")])
    var unchanged = RemoteCommand.configure(owner: owner, device: device, project: project, chat: "c", options: RemoteChatOptions(model: "n", addOns: ["mail"]), expected: modelOnly)
    try unchanged.validate()
    #expect(unchanged.settings?.options.addOns == nil && unchanged.settings?.expected?.addOns == nil && !unchanged.needsInteractionSchema)
    modelOnly.addOns = nil
    unchanged = RemoteCommand.configure(owner: owner, device: device, project: project, chat: "c", options: RemoteChatOptions(model: "m", addOns: []), expected: modelOnly)
    #expect(unchanged.settings?.options.addOns == nil && unchanged.settings?.expected?.addOns == nil)
    let plain = RemoteCommand.configure(owner: owner, device: device, project: project, chat: "c", options: RemoteChatOptions(model: "m"),
                                        expected: RemoteChatSettings(options: RemoteChatOptions(model: "m"), projectAccess: .standard, canEdit: true))
    #expect(!plain.needsInteractionSchema)
    #expect(throws: RemoteFailure.self) { try RemoteChatOptions(model: "m", addOns: ["mail", "mail"]).validate() }
    #expect(throws: RemoteFailure.self) { try RemoteChatOptions(model: "m", role: "").validate() }
    // The stale check ignores add-ons only for a phone that never sent them.
    let current = RemoteChatOptions(model: "m", role: "editor", addOns: ["userChrome", "mail"])
    #expect(RemoteChatOptions(model: "m", role: "editor").matches(current: current))
    #expect(RemoteChatOptions(model: "m", role: "editor", addOns: ["mail", "userChrome"]).matches(current: current))
    #expect(!RemoteChatOptions(model: "m", role: "editor", addOns: ["mail"]).matches(current: current))
    #expect(!RemoteChatOptions(model: "m", role: "reader").matches(current: current))

    #expect(RemoteQueuedMessage(id: "q", text: String(repeating: "x", count: RemoteQueuedMessage.textLimit + 1)).truncated == true)
    for failure in [RemoteFailure.interactionSetup, .invalidAnswer] { #expect(failure.errorDescription?.isEmpty == false) }
}

@Test @MainActor func snapshotWithoutInteractionSchemaWithdrawsPhoneActionsOnly() throws {
    var chat = RemoteChat(id: "c", project: "p", title: "t", running: true, messages: [], approvals: [])
    chat.canQueue = true; chat.canInterrupt = true
    chat.interactions = [try #require(RemoteInteraction(interaction(.questions([question("q", "Q")]))))]
    chat.queue = [RemoteQueuedMessage(id: "m", text: "waiting")]
    var snapshot = RemoteSnapshot(projects: [], chats: [chat])
    MobileRemoteHost.applyInteractionSchema(true, to: &snapshot)
    #expect(snapshot.chats[0] == chat)
    MobileRemoteHost.applyInteractionSchema(false, to: &snapshot)
    #expect(snapshot.chats[0].canQueue == nil && snapshot.chats[0].canInterrupt == nil)
    #expect(snapshot.chats[0].interactions?.first?.canAnswer == false && snapshot.chats[0].interactions?.first?.macOnlyReason == .setup)
    #expect(snapshot.chats[0].queue == chat.queue)
}

@MainActor private func withWorkingChat(_ body: (DeskModel, CodexConnection, AppStore, Project) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, sys
    requests = []
    turns = 0
    refuse_interrupt = False
    for line in sys.stdin:
        m = json.loads(line)
        if 'method' not in m:
            requests.append(m); continue
        if 'id' not in m: continue
        method = m['method']
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'test/refuseInterrupt': refuse_interrupt = True
        if method == 'turn/interrupt' and refuse_interrupt:
            requests.append(m)
            print(json.dumps({'id': m['id'], 'error': {'code': -32603, 'message': 'fixture refuses'}}), flush=True)
            continue
        if method == 'turn/start':
            turns += 1
            result = {'turn': {'id': 'v' + str(turns)}}
        if method == 'test/emit': print(json.dumps(m['params']), flush=True)
        if method == 'test/requests': result = requests
        else: requests.append(m)
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let integration = CodexIntegration(client: CodexClient(transport: connection))
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: integration, store: store, summaryExecutable: executable, summaryHome: folder)
    model.state.defaultRoute = .direct
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id
    model.state.chats = [Chat(id: "t", projectID: project.id, title: "Work", model: "fixture-model")]
    model.connected = true; model.authenticated = true; model.draft = "Desktop draft"
    model.codexModels = [AgentModelInfo(id: "fixture-model", displayName: "Model A", defaultEffort: "medium")]
    await integration.observe(sessions: [.init(connection: .originalCodex, nativeID: "t")])
    let reader = Task { @MainActor in
        for await event in integration.events {
            if case .interaction(let interaction) = event.payload { model.pending.append(PendingAction(interaction: interaction, threadID: "t")) }
        }
    }
    defer { reader.cancel() }
    do { try await body(model, connection, store, project); await model.shutdown() }
    catch { await model.shutdown(); throw error }
}
@MainActor private func turnStarts(_ connection: CodexConnection) async throws -> [String] {
    try await connection.request("test/requests").array.filter { $0["method"].string == "turn/start" }
        .map { $0["params"]["input"].array.compactMap { $0["text"].string }.joined() }
}
@MainActor private func settle(_ model: DeskModel, until done: () async throws -> Bool) async throws {
    for _ in 0..<200 { if try await done() { return }; try await Task.sleep(for: .milliseconds(10)) }
}

@Test @MainActor func phoneQueueJoinsTheDesktopQueueAndRunsOnceAfterTheTurn() async throws {
    try await withWorkingChat { model, connection, _, project in
        let owner = UUID().uuidString, device = UUID().uuidString
        let send = RemoteCommand(owner: owner, device: device, project: project.id.uuidString, chat: "t", kind: "send", text: "First")
        #expect(try await model.executeRemote(send) == "submitted")
        var snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.running && snapshot.turn == "v1" && snapshot.canQueue == true && snapshot.canInterrupt == true && snapshot.queue == nil)
        // A plain send still refuses a working chat; the queue accepts it.
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(RemoteCommand(owner: owner, device: device, project: send.project, chat: "t", kind: "send", text: "Busy")) }
        let queued = RemoteCommand.queue(owner: owner, device: device, project: send.project, chat: "t", text: "From the phone")
        #expect(try await model.executeRemote(queued) == "submitted")
        #expect(model.queuedMessages.map(\.text) == ["From the phone"] && model.chatID == nil && model.draft == "Desktop draft")
        snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.queue?.map(\.command) == [queued.id] && snapshot.queuePaused == nil)
        #expect(try await turnStarts(connection) == ["First"])
        // The same command is never queued twice, even when it reaches the Mac again.
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(queued) }
        model.finishActiveTurn(threadID: "t", turnID: "v1", status: .completed, hasError: false)
        try await settle(model) { try await turnStarts(connection).count == 2 && !model.isSending(threadID: "t") }
        #expect(try await turnStarts(connection) == ["First", "From the phone"])
        #expect(model.queuedMessages.isEmpty)
        // A stopped turn pauses the queue: a phone message joins it and waits for the Mac, as a desktop one does.
        model.finishActiveTurn(threadID: "t", turnID: "v2", status: .cancelled, hasError: false)
        #expect(try await model.executeRemote(RemoteCommand.queue(owner: owner, device: device, project: send.project, chat: "t", text: "Later")) == "submitted")
        try await settle(model) { try await turnStarts(connection).count == 3 }
        let held = RemoteCommand.queue(owner: owner, device: device, project: send.project, chat: "t", text: "Held")
        model.finishActiveTurn(threadID: "t", turnID: "v3", status: .cancelled, hasError: false)
        model.state.queuedMessages = [QueuedMessage(id: "desk", threadID: "t", projectID: project.id, text: "Desk", model: "fixture-model", effort: "medium")]
        #expect(try await model.executeRemote(held) == "submitted")
        snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.queue?.map(\.text) == ["Desk", "Held"] && snapshot.queuePaused == true && snapshot.queue?.first?.command == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await turnStarts(connection).count == 3)
    }
}

@Test @MainActor func phoneInterruptAndSendStopsOnlyTheObservedTurnAndSendsOnceWithTheNote() async throws {
    try await withWorkingChat { model, connection, _, project in
        let owner = UUID().uuidString, device = UUID().uuidString
        #expect(try await model.executeRemote(RemoteCommand(owner: owner, device: device, project: project.id.uuidString, chat: "t", kind: "send", text: "First")) == "submitted")
        model.state.queuedMessages = [QueuedMessage(id: "desk", threadID: "t", projectID: project.id, text: "Desk later", model: "fixture-model", effort: "medium")]
        let stale = RemoteCommand.interruptAndSend(owner: owner, device: device, project: project.id.uuidString, chat: "t", turn: "v0", text: "Instead")
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(stale) }
        let command = RemoteCommand.interruptAndSend(owner: owner, device: device, project: project.id.uuidString, chat: "t", turn: "v1", text: "Instead")
        #expect(try await model.executeRemote(command) == "submitted")
        let interrupts = try await connection.request("test/requests").array.filter { $0["method"].string == "turn/interrupt" }
        #expect(interrupts.count == 1 && interrupts.first?["params"]["turnId"].string == "v1")
        var snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.queue?.map(\.text) == ["Instead", "Desk later"] && snapshot.queue?.first?.claimed == true)
        #expect(snapshot.canInterrupt == false && snapshot.queuePaused == nil)
        // A second interrupt for the same turn is refused while the first waits.
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(RemoteCommand.interruptAndSend(owner: owner, device: device, project: command.project, chat: "t", turn: "v1", text: "Again")) }
        model.finishActiveTurn(threadID: "t", turnID: "v1", status: .cancelled, hasError: false)
        try await settle(model) { try await turnStarts(connection).count == 2 && !model.isSending(threadID: "t") }
        let sent = try await turnStarts(connection)
        #expect(sent.count == 2 && sent[1].hasPrefix("Instead\n\n[Switchboard: ") && InterruptedTurnNote.stripped(sent[1]) == "Instead")
        snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.queue?.map(\.text) == ["Desk later"] && snapshot.turn == "v2")
        // An idle chat has no turn to interrupt.
        model.finishActiveTurn(threadID: "t", turnID: "v2", status: .completed, hasError: false)
        try await settle(model) { try await turnStarts(connection).count == 3 && !model.isSending(threadID: "t") }
        model.finishActiveTurn(threadID: "t", turnID: "v3", status: .completed, hasError: false)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(RemoteCommand.interruptAndSend(owner: owner, device: device, project: command.project, chat: "t", turn: "v3", text: "Late")) }
        #expect(try await turnStarts(connection).count == 3)
    }
}

@Test @MainActor func phoneInterruptWhoseStopFailsLeavesTheMessageWaitingAndUnsent() async throws {
    try await withWorkingChat { model, connection, _, project in
        let owner = UUID().uuidString, device = UUID().uuidString
        #expect(try await model.executeRemote(RemoteCommand(owner: owner, device: device, project: project.id.uuidString, chat: "t", kind: "send", text: "First")) == "submitted")
        _ = try await connection.request("test/refuseInterrupt")
        let command = RemoteCommand.interruptAndSend(owner: owner, device: device, project: project.id.uuidString, chat: "t", turn: "v1", text: "Instead")
        // Not a definite rejection for the host: the stop may have reached the engine, so the command ends uncertain.
        do { _ = try await model.executeRemote(command); Issue.record("Expected the stop to fail") }
        catch RemoteFailure.invalidCommand { Issue.record("A failed stop must not look like a rejected command") }
        catch {}
        #expect(model.queuedMessages.map(\.text) == ["Instead"] && !model.queuedMessageIsClaimed(model.queuedMessages[0].id))
        var snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.queuePaused == true && snapshot.canInterrupt == true)
        // The turn ends on its own: the paused queue keeps the message for the user on the Mac.
        model.finishActiveTurn(threadID: "t", turnID: "v1", status: .completed, hasError: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await turnStarts(connection) == ["First"])
        snapshot = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first)
        #expect(snapshot.queue?.map(\.command) == [command.id] && snapshot.queuePaused == true)
    }
}

@Test @MainActor func phoneAnswersTheExactPendingQuestionOnceAndDeclinesOnlyForms() async throws {
    try await withWorkingChat { model, connection, _, project in
        let owner = UUID().uuidString, device = UUID().uuidString
        _ = try await connection.request("test/emit", params: .object([
            "id": .string("ask-fixture"), "method": .string("item/tool/requestUserInput"),
            "params": .object(["threadId": .string("t"), "turnId": .string("v1"), "questions": .array([
                .object(["id": .string("pick"), "header": .string("Approach"), "question": .string("Which one?"),
                         "options": .array([.object(["label": .string("Fast"), "description": .string("Ship today")]), .object(["label": .string("Safe")])])])
            ])])
        ]))
        try await settle(model) { !model.pending.isEmpty }
        let action = try #require(model.pending.first)
        let published = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.interactions?.first)
        #expect(published.id == action.id && published.canAnswer && published.questions.first?.header == "Approach")
        #expect(published.questions.first?.options.map(\.label) == ["Fast", "Safe"])
        // Questions have no Decline on the desktop, so none from the phone.
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.decline(owner: owner, device: device, project: project.id.uuidString, chat: "t", interaction: action.id)) }
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.answer(owner: owner, device: device, project: project.id.uuidString, chat: "t", interaction: UUID().uuidString, answers: ["pick": "Fast"])) }
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.answer(owner: owner, device: device, project: project.id.uuidString, chat: "t", interaction: action.id, answers: ["other": "Fast"])) }
        let answer = RemoteCommand.answer(owner: owner, device: device, project: project.id.uuidString, chat: "t", interaction: action.id.lowercased(), answers: ["pick": "Safe"])
        #expect(try await model.executeRemote(answer) == "submitted")
        #expect(model.pending.isEmpty)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(answer) }
        let replies = try await connection.request("test/requests").array.filter { $0["id"].string == "ask-fixture" }
        #expect(replies.count == 1 && replies.first?["result"]["answers"]["pick"]["answers"] == .array([.string("Safe")]))

        _ = try await connection.request("test/emit", params: .object([
            "id": .string("form-fixture"), "method": .string("mcpServer/elicitation/request"),
            "params": .object(["threadId": .string("t"), "turnId": .string("v1"), "mode": .string("form"), "message": .string("Details"),
                               "requestedSchema": .object(["type": .string("object"), "properties": .object(["name": .object(["type": .string("string"), "title": .string("Name")])])])])
        ]))
        try await settle(model) { !model.pending.isEmpty }
        let form = try #require(model.pending.first)
        #expect(try await model.executeRemote(.decline(owner: owner, device: device, project: project.id.uuidString, chat: "t", interaction: form.id)) == "submitted")
        let declined = try await connection.request("test/requests").array.filter { $0["id"].string == "form-fixture" }
        #expect(declined.count == 1 && declined.first?["result"]["action"].string == "decline")
        #expect(model.pending.isEmpty)

        // A secret question is shown, never answered from the phone.
        let secret = PendingAction(interaction: AgentInteraction(id: UUID(), session: .init(connection: .originalCodex, nativeID: "t"), turn: "v1",
            kind: .questions([.init(id: "token", text: "Token", options: [], secret: true, required: true)]), reason: nil, details: ""), threadID: "t")
        model.pending = [secret]
        #expect(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.interactions?.first?.macOnlyReason == .secret)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.answer(owner: owner, device: device, project: project.id.uuidString, chat: "t", interaction: secret.id, answers: ["token": "x"])) }
        #expect(model.pending.count == 1)
    }
}

@Test @MainActor func phoneAddOnsStayWithinTheProjectDefaultAndOlderPhonesKeepThem() async throws {
    try await withWorkingChat { model, _, store, project in
        let owner = UUID().uuidString, device = UUID().uuidString
        // Editor projects grant neither connectors nor the user's Chrome: the phone may not turn them on.
        var settings = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings)
        #expect(settings.addOns == [] && settings.options.addOns == [] && settings.projectAddOns == [])
        #expect(await model.remoteSnapshot(projects: [project.id.uuidString]).projects.first?.settings?.addOns == [])
        var change = settings.options; change.addOns = [RoleAddOn.mail.rawValue]
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.configure(owner: owner, device: device, project: project.id.uuidString, chat: "t", options: change, expected: settings)) }
        // An Operator project already allows everything an add-on adds.
        model.state.projects[0].chatRoleID = AgentRoleID.fullOperator
        model.state.projects[0].chatRoleAddOns = [RoleAddOn.mail.rawValue]
        settings = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings)
        #expect(settings.addOns?.map(\.id) == [RoleAddOn.mail.rawValue, RoleAddOn.userChrome.rawValue] && settings.projectAddOns == [RoleAddOn.mail.rawValue])
        #expect(settings.addOns?.first?.name == RoleAddOn.mail.title && settings.options.addOns == [RoleAddOn.mail.rawValue])
        change = settings.options; change.addOns = [RoleAddOn.userChrome.rawValue, "future-add-on"]
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.configure(owner: owner, device: device, project: project.id.uuidString, chat: "t", options: change, expected: settings)) }
        change.addOns = [RoleAddOn.userChrome.rawValue]
        var stale = settings; stale.options.addOns = []
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.configure(owner: owner, device: device, project: project.id.uuidString, chat: "t", options: change, expected: stale)) }
        #expect(try await model.executeRemote(.configure(owner: owner, device: device, project: project.id.uuidString, chat: "t", options: change, expected: settings)) == "submitted")
        #expect(try await store.load().chats.first?.roleAddOns == [RoleAddOn.userChrome.rawValue])
        // A phone that knows nothing about add-ons changes the model or role and leaves the add-ons as they are.
        settings = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings)
        var older = settings; older.options.addOns = nil
        #expect(try await model.executeRemote(.configure(owner: owner, device: device, project: project.id.uuidString, chat: "t",
                                                         options: RemoteChatOptions(model: "fixture-model", role: AgentRoleID.reader), expected: older)) == "submitted")
        #expect(model.state.chats.first?.roleID == AgentRoleID.reader && model.state.chats.first?.roleAddOns == [RoleAddOn.userChrome.rawValue])
        // Back on an Editor project the add-on already on stays selectable (to turn it off), nothing else is offered.
        model.state.projects[0].chatRoleID = AgentRoleID.editor; model.state.projects[0].chatRoleAddOns = nil
        settings = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings)
        #expect(settings.addOns?.map(\.id) == [RoleAddOn.userChrome.rawValue])
        change = settings.options; change.addOns = []
        #expect(try await model.executeRemote(.configure(owner: owner, device: device, project: project.id.uuidString, chat: "t", options: change, expected: settings)) == "submitted")
        #expect(model.state.chats.first?.roleAddOns == [])
        // A new chat may name add-ons within the project default only.
        let raised = RemoteCommand.newChat(owner: owner, device: device, project: project.id.uuidString, text: "New",
                                           options: RemoteChatOptions(model: "fixture-model", addOns: [RoleAddOn.mail.rawValue]))
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(raised) }
        #expect(model.state.chats.count == 1)
    }
}
