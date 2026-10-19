@_spi(NativeProtocol) import CodexAdapter
import AgentContract
import ContextCore
import Foundation
import Testing
@testable import ContextDesk

@Test func remoteCreationEnvelopeKeepsQueueIdentityAndOldSnapshotCompatibility() throws {
    let old = try JSONDecoder().decode(RemoteProject.self, from: Data(#"{"id":"p","name":"Old Mac"}"#.utf8))
    #expect(old.canCreateChat == nil)
    let first = RemoteCommand.newChat(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString, text: "Привет / Hello")
    try first.validate()
    let decoded = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(first))
    #expect(decoded.createsChat && decoded.chat == first.chat && decoded.id == first.id)
    let later = RemoteCommand(owner: first.owner, device: first.device, project: first.project, chat: first.chat, kind: "send", text: "Next")
    #expect(!later.createsChat)
    let empty = RemoteCommand.newChat(owner: first.owner, device: first.device, project: first.project, text: " \n")
    #expect(throws: RemoteFailure.self) { try empty.validate() }
}

@MainActor private func withMobileActionFixture(_ body: (DeskModel, CodexConnection, AppStore, Project) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, sys
    received = []
    for line in sys.stdin:
        request = json.loads(line)
        received.append(request)
        if 'method' not in request or 'id' not in request: continue
        method = request['method']
        result = {}
        if method == 'initialize': result = {'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'thread/start': result = {'thread':{'id':'created-native'}}
        if method == 'turn/start': result = {'turn':{'id':'remote-turn'}}
        if method == 'test/emit': print(json.dumps(request['params']), flush=True)
        if method == 'test/received': result = received[:-1]
        print(json.dumps({'id':request['id'], 'result':result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let wire = CodexConnection()
    try await wire.start(executable: executable, home: folder)
    let integration = CodexIntegration(client: CodexClient(transport: wire))
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: integration, store: store, summaryExecutable: executable, summaryHome: folder)
    var project = Project(path: folder.path)
    project.accessMode = .fullAccess // Scheduled permission must not leak into interactive chats.
    project.defaultChatAccessMode = .standard
    model.state.projects = [project]; model.connected = true; model.authenticated = true
    model.state.model = "fixture-model"; model.projectID = project.id; model.draft = "Desktop draft"
    model.models = [AgentModelInfo(id: "fixture-model", displayName: "Model A", defaultEffort: "medium"),
                    AgentModelInfo(id: "fixture-alternate", displayName: "Model B", defaultEffort: "low")]
    await integration.observe(sessions: [.init(connection: .originalCodex, nativeID: "existing")])
    let reader = Task { @MainActor in
        for await event in integration.events {
            if case .interaction(let interaction) = event.payload {
                model.pending.append(PendingAction(interaction: interaction, threadID: "existing"))
            }
        }
    }
    defer { reader.cancel() }
    do { try await body(model, wire, store, project); await model.shutdown() }
    catch { await model.shutdown(); throw error }
}

@Test(arguments: RemoteAccessMode.allCases) @MainActor func mobileCreationAppliesExplicitModelAndAccess(access: RemoteAccessMode) async throws {
    try await withMobileActionFixture { model, wire, store, project in
        let options = RemoteChatOptions(model: "fixture-alternate", access: access)
        let command = RemoteCommand.newChat(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString, text: "Chosen settings", options: options)
        #expect(command.kind == "create")
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded.settings?.options == options)
        if access == .fullAccess {
            // The phone never raises a chat above the project's default role (audit M3).
            await #expect(throws: RemoteFailure.self) { try await model.executeRemote(decoded) }
            #expect(try await store.load().chats.isEmpty)
            let snapshot = await model.remoteSnapshot(projects: [project.id.uuidString])
            #expect(snapshot.projects.first?.settings?.projectRole == AgentRoleID.editor)
            #expect(snapshot.projects.first?.settings?.roles?.map(\.id) == [AgentRoleID.reader, AgentRoleID.editor])
            return
        }
        #expect(try await model.executeRemote(decoded) == "submitted")
        let saved = try #require(await store.load().chats.first)
        #expect(saved.model == options.model && saved.effort == "low")
        #expect(saved.inheritsProjectAccess == false && saved.accessMode?.rawValue == access.rawValue)
        #expect(model.state.projects.first?.defaultChatAccessMode == .standard)
        let requests = try await wire.request("test/received").array
        for method in ["thread/start", "turn/start"] {
            let params = try #require(requests.first(where: { $0["method"].string == method }))["params"]
            #expect(params["model"].string == options.model)
            #expect(params["approvalPolicy"].string == (access == .fullAccess ? "never" : "on-request"))
        }
    }
}

@Test @MainActor func mobileSettingsPersistWithoutDispatchAndRejectStaleBusyOrUnknownChoices() async throws {
    try await withMobileActionFixture { model, wire, store, project in
        model.state.chats = [Chat(id: "existing", projectID: project.id, title: "Existing", model: "fixture-model")]
        let initial = await model.remoteSnapshot(projects: [project.id.uuidString])
        #expect(initial.projects.first?.models?.map(\.id) == ["fixture-model", "fixture-alternate"])
        let expected = try #require(initial.chats.first?.settings)
        let raised = RemoteCommand.configure(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString,
                                             chat: "existing", options: RemoteChatOptions(model: "fixture-alternate", access: .fullAccess), expected: expected)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(raised) } // never above the project default
        let options = RemoteChatOptions(model: "fixture-alternate", role: AgentRoleID.reader)
        var command = RemoteCommand.configure(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString,
                                              chat: "existing", options: options, expected: expected)
        #expect(try await model.executeRemote(command) == "submitted")
        let saved = try #require(await store.load().chats.first)
        #expect(saved.model == options.model && saved.roleID == AgentRoleID.reader && saved.accessMode == .standard && saved.effort == "low")
        #expect(saved.inheritsProjectAccess == false)
        #expect(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings?.options.role == AgentRoleID.reader)
        #expect(model.chatID == nil && model.draft == "Desktop draft" && model.state.model == "fixture-model")
        #expect(model.state.projects.first?.defaultChatAccessMode == .standard)
        #expect(try await wire.request("test/received").array.allSatisfy { !["thread/start", "turn/start"].contains($0["method"].string ?? "") })
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
        var current = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings)
        command = .configure(owner: command.owner, device: command.device, project: command.project, chat: command.chat,
                             options: RemoteChatOptions(model: "unavailable-model"), expected: current)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
        command = .configure(owner: command.owner, device: command.device, project: command.project, chat: command.chat,
                             options: RemoteChatOptions(model: options.model), expected: current)
        #expect(try await model.executeRemote(command) == "submitted")
        #expect(model.state.chats.first?.inheritsProjectAccess == true && model.state.chats.first?.accessMode == nil)
        current = try #require(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings)
        let send = RemoteCommand(owner: command.owner, device: command.device, project: command.project, chat: command.chat, kind: "send", text: "Start work")
        #expect(try await model.executeRemote(send) == "submitted")
        command = .configure(owner: command.owner, device: command.device, project: command.project, chat: command.chat, options: options, expected: current)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
        #expect(await model.remoteSnapshot(projects: [project.id.uuidString]).chats.first?.settings?.canEdit == false)
    }
}

@Test func mobileSettingsCommandsRejectMalformedOrMisroutedOptions() throws {
    let options = RemoteChatOptions(model: "model", access: .standard)
    var command = RemoteCommand.newChat(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString, text: "Hi", options: options)
    try command.validate()
    command.kind = "send"
    #expect(throws: RemoteFailure.self) { try command.validate() }
    command.kind = "configure"
    #expect(throws: RemoteFailure.self) { try command.validate() }
    command.kind = "create"; command.chat = "existing"
    #expect(throws: RemoteFailure.self) { try command.validate() }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RemoteChatOptions.self, from: Data(#"{"model":"model","access":"future-mode"}"#.utf8)) }
}

@Test @MainActor func phoneCreatesAndPersistsChatWithoutChangingDesktopOrReplaying() async throws {
    try await withMobileActionFixture { model, wire, store, project in
        let command = RemoteCommand.newChat(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString, text: "From phone")
        let before = await model.remoteSnapshot(projects: [project.id.uuidString])
        #expect(before.projects.first?.canCreateChat == true && before.chats.isEmpty)
        // Claude is not connected: only Codex models are offered, and a Claude model is refused before anything starts.
        #expect(before.projects.first?.newChatModels?.map(\.id) == ["fixture-model", "fixture-alternate"])
        #expect(before.projects.first?.newChatModels?.allSatisfy { $0.agent == RemoteModelOption.codexAgent } == true)
        let claude = RemoteCommand.newChat(owner: command.owner, device: command.device, project: command.project, text: "Claude",
                                           options: RemoteChatOptions(model: ClaudeModel.defaultID))
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(claude) }
        #expect(model.state.chats.isEmpty)
        #expect(try await model.executeRemote(command) == "submitted")
        let chat = try #require(model.state.chats.first)
        #expect(chat.id == command.chat && chat.nativeSession?.nativeID == "created-native")
        #expect(chat.resolvedAccessMode(in: project) == .standard && chat.inheritsProjectAccess == true)
        #expect(chat.model == "fixture-model" && chat.route == .direct)
        #expect(model.chatID == nil && model.draft == "Desktop draft")
        #expect(try await store.load().chats.first?.id == command.chat)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
        let unknown = RemoteCommand(owner: command.owner, device: command.device, project: command.project, chat: "missing", kind: "send", text: "Do not create")
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(unknown) }
        let requests = try await wire.request("test/received").array
        let starts = requests.filter { $0["method"].string == "thread/start" }
        let sends = requests.filter { $0["method"].string == "turn/start" }
        #expect(starts.count == 1 && sends.count == 1)
        #expect(starts.first?["params"]["cwd"].string == project.path)
        #expect(starts.first?["params"]["approvalPolicy"].string == "on-request")
        #expect(sends.first?["params"]["threadId"].string == "created-native")
    }
}

@Test(arguments: ["allow", "deny"]) @MainActor func phoneApprovalUsesDatabaseUUIDAndAnswersExactlyOnce(kind: String) async throws {
    try await withMobileActionFixture { model, wire, _, project in
        model.state.chats = [Chat(id: "existing", projectID: project.id, title: "Existing", model: "")]
        _ = try await wire.request("test/emit", params: .object([
            "id": .string("permission-fixture"), "method": .string("item/commandExecution/requestApproval"),
            "params": .object(["threadId": .string("existing"), "turnId": .string("turn"), "command": .string("echo fixture")])
        ]))
        for _ in 0..<200 { if !model.pending.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        let action = try #require(model.pending.first)
        let snapshot = await model.remoteSnapshot(projects: [project.id.uuidString])
        let approval = try #require(snapshot.chats.first?.approvals.first)
        #expect(approval.canAllow)
        var command = RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString,
                                    chat: "existing", kind: kind, approval: approval.id.lowercased())
        command.approval = UUID().uuidString.lowercased()
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
        command.approval = action.id.lowercased() // PostgreSQL uuid serializes in lower case.
        #expect(try await model.executeRemote(command) == "submitted")
        #expect(model.pending.isEmpty)
        await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
        let replies = try await wire.request("test/received").array.filter { $0["id"].string == "permission-fixture" }
        #expect(replies.count == 1)
        #expect(replies.first?["result"]["decision"].string == (kind == "allow" ? "accept" : "decline"))
    }
}

@Test @MainActor func phonePrioritizesPendingChatsAndRejectsTruncatedOrUnsupportedApprovals() async throws {
    try await withMobileActionFixture { model, _, _, project in
        model.state.chats = (0..<25).map { Chat(id: "chat-\($0)", projectID: project.id, title: "Chat", model: "") }
        model.state.chats[0].updated = .distantPast
        for (canAllow, details) in [(true, String(repeating: "x", count: 8001)), (false, "Unsupported") ] {
            let action = PendingAction(interaction: AgentInteraction(id: UUID(), session: .init(connection: .originalCodex, nativeID: "chat-0"),
                turn: "turn", kind: .approval(canAllow: canAllow), reason: nil, details: details), threadID: "chat-0")
            model.pending = [action]
            let snapshot = await model.remoteSnapshot(projects: [project.id.uuidString])
            #expect(snapshot.chats.first?.id == "chat-0" && snapshot.chats.count == 20)
            #expect(snapshot.chats.first?.approvals.first?.canAllow == false)
            let command = RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString,
                                        chat: "chat-0", kind: "allow", approval: action.id.lowercased())
            await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
            #expect(model.pending.count == 1)
        }
    }
}
