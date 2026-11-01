@_spi(NativeProtocol) import CodexAdapter
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test @MainActor func chatSettingsPersistWithoutChangingOtherChatsOrProjectPolicy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(store: store, summaryResources: nil)
    var project = Project(path: folder.path); project.accessMode = .fullAccess
    model.state.projects = [project]; model.projectID = project.id
    model.state.model = "global-default"
    #expect(model.effort == "medium")
    model.models = [.init(id: "model-a-updated", displayName: "A", defaultEffort: "high", efforts: ["medium", "high"])]
    model.state.chats = [Chat(id: "a", projectID: project.id, title: "A", model: "model-a"),
                         Chat(id: "b", projectID: project.id, title: "B", model: "model-b")]
    model.chatID = "a"
    #expect(model.accessMode == .standard)
    #expect(model.currentModel == "model-a")
    model.selectAccessMode(.fullAccess); model.selectModel("model-a-updated")
    #expect(model.effort == "medium")
    model.effort = "high"
    model.chatID = "b"
    #expect(model.accessMode == .standard)
    #expect(model.currentModel == "model-b")
    #expect(model.effort == "medium")
    model.effort = ""
    model.chatID = "a"; model.chatID = "b"
    #expect(model.effort == "")
    model.selectAccessMode(.standard); model.effort = "low"
    #expect(model.state.projects[0].accessMode == .fullAccess)
    #expect(model.state.model == "global-default")
    model.newChat()
    #expect(model.accessMode == .standard)
    model.selectAccessMode(.fullAccess)
    #expect(model.effort == "medium")
    model.selectModel("new-draft")
    #expect(model.effort == "medium")
    model.effort = ""
    #expect(model.effort == "")
    model.chatID = "a"
    #expect(model.currentModel == "model-a-updated")
    #expect(model.effort == "high")
    #expect(model.accessMode == .fullAccess)
    // Round-trip the complete state, including legacy chats with missing fields.
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(model.state))
    let fresh = DeskModel(store: store, summaryResources: nil)
    fresh.state = restored; fresh.projectID = project.id; fresh.chatID = "b"
    #expect(fresh.currentModel == "model-b")
    #expect(fresh.effort == "low")
    #expect(fresh.accessMode == .standard)
    fresh.chatID = "a"
    #expect(fresh.currentModel == "model-a-updated" && fresh.effort == "high" && fresh.accessMode == .fullAccess)
}

@Test @MainActor func chatRequestsUseTheirOwnModelEffortAndPermissions() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,json
    requests=[]
    sessions=0
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='turn/start': result={'turn':{'id':'turn-'+m['params']['threadId']}}
        if method=='thread/start':
            sessions+=1
            result={'thread':{'id':'created-'+str(sessions)}}
        if method=='model/list': result={'data':[{'id':'unrelated-default','model':'unrelated-default','displayName':'Fixture','isDefault':True,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[]}]}
        if method=='test/requests': result=requests
        else: requests.append(m)
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let wire = CodexConnection()
    try await wire.start(executable: executable, home: folder)
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: wire)),
                          store: AppStore(file: folder.appendingPathComponent("state.sqlite")), summaryResources: nil,
                          summaryExecutable: executable, summaryHome: folder,
                          jobStore: JobStore(file: folder.appendingPathComponent("jobs.json")))
    var project = Project(path: folder.path); project.accessMode = .fullAccess
    var a = Chat(id: "a", projectID: project.id, title: "A", model: "model-a")
    a.effort = "high"; a.accessMode = .fullAccess
    var b = Chat(id: "b", projectID: project.id, title: "B", model: "model-b")
    b.effort = "low"
    model.state.projects = [project]; model.state.chats = [a,b]; model.projectID = project.id
    model.state.model = "unrelated-default"; model.state.defaultRoute = .direct
    model.connected = true; model.authenticated = true
    for id in ["a", "b"] {
        model.chatID = id; model.draft = "Message for " + id
        await model.send()
    }
    let requests = try await wire.request("test/requests").array
    let turns = requests.filter { $0["method"].string == "turn/start" }.map { $0["params"] }
    #expect(turns.count == 2)
    #expect(turns[0]["model"].string == "model-a" && turns[0]["effort"].string == "high")
    #expect(turns[0]["approvalPolicy"].string == "never")
    #expect(turns[1]["model"].string == "model-b" && turns[1]["effort"].string == "low")
    #expect(turns[1]["approvalPolicy"].string == "on-request")
    #expect(turns[1]["sandboxPolicy"]["type"].string == "workspaceWrite")
    await model.refreshModels()
    #expect(model.currentModel == "model-b" && model.effort == "low")
    model.newChat()
    model.updateProjectRoles(project.id, chatRole: AgentRoleID.fullOperator, jobRole: nil, extraRoots: nil, cookieSites: nil)
    model.selectModel("new-model"); model.effort = "medium"
    model.draft = "Create a new conversation"
    await model.send()
    let created = try #require(model.selectedChat)
    #expect(created.model == "new-model" && created.effort == "medium" && created.inheritsProjectAccess == true && created.resolvedAccessMode(in: model.state.projects[0]) == .fullAccess)
    model.newChat()
    #expect(model.accessMode == .fullAccess)
    // The role chip of a new chat sets that chat's role only; the project default stays.
    model.selectRole(AgentRoleID.reader)
    #expect(model.currentRole.id == AgentRoleID.reader && model.roleSelection == AgentRoleID.reader)
    #expect(model.state.projects[0].chatRoleID == AgentRoleID.fullOperator)
    model.draft = "Create a reader conversation"
    await model.send()
    let reader = try #require(model.selectedChat)
    #expect(reader.id != created.id && reader.roleID == AgentRoleID.reader && reader.inheritsProjectAccess == false)
    #expect(model.state.projects[0].chatRoleID == AgentRoleID.fullOperator)
    model.finishActiveTurn(threadID: reader.id, turnID: "turn-created-2", status: .completed, hasError: false)
    // The picked role is used once; the next new chat starts at the project default again.
    model.newChat()
    #expect(model.currentRole.id == AgentRoleID.fullOperator && model.roleSelection == nil)
    // A later project default must reach resume and turn/start for inherited chats.
    model.updateProjectRoles(project.id, chatRole: AgentRoleID.editor, jobRole: nil, extraRoots: nil, cookieSites: nil)
    model.finishActiveTurn(threadID: created.id, turnID: "turn-created-1", status: .completed, hasError: false)
    model.chatID = created.id; model.draft = "Use the changed project default"
    await model.send()
    let inheritedRequests = try await wire.request("test/requests").array
    let inheritedTurn = try #require(inheritedRequests.last { $0["method"].string == "turn/start" })["params"]
    #expect(inheritedTurn["approvalPolicy"].string == "on-request")
    #expect(inheritedTurn["sandboxPolicy"]["type"].string == "workspaceWrite")
    model.newChat(); model.selectAccessMode(.fullAccess)
    // The scheduled run must ignore the currently selected full-access chat and draft defaults.
    model.chatID = "a"
    model.state.projects[0].accessMode = .standard
    model.schedulerReady = true
    var job = ManagedJob(); job.name = "Scheduled fixture"; job.prompt = "Run fixture"
    job.projectID = project.id; job.model = "scheduled-model"; job.effort = "xhigh"; job.enabled = true
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    let run = try #require(model.jobLedger.runs.first)
    let scheduled = try #require(model.state.chats.first { $0.id == run.threadID })
    #expect(scheduled.model == job.model && scheduled.effort == job.effort && scheduled.accessMode == .standard)
    let finalRequests = try await wire.request("test/requests").array
    let scheduledTurn = try #require(finalRequests.last { $0["method"].string == "turn/start" })["params"]
    #expect(scheduledTurn["model"].string == job.model && scheduledTurn["effort"].string == job.effort)
    #expect(scheduledTurn["approvalPolicy"].string == "on-request")
    #expect(model.chatID == "a" && model.currentModel == "model-a" && model.effort == "high")
    model.chatID = scheduled.id
    #expect(model.effort == job.effort)
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(model.state))
    model.state = restored
    #expect(model.effort == job.effort)
    await model.stopScheduler()
    await wire.stop()
}

@Test @MainActor func projectAccessDefaultsPersistAndRespectOverrides() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(store: store, summaryResources: nil)
    let project = Project(path: folder.path)
    let other = Project(path: folder.appendingPathComponent("other").path)
    model.state.projects = [project, other]; model.projectID = project.id
    let legacy = Chat(id: "legacy", projectID: project.id, title: "Legacy", model: "fixture")
    var inherited = Chat(id: "inherited", projectID: project.id, title: "Inherited", model: "fixture")
    inherited.inheritsProjectAccess = true
    model.state.chats = [legacy, inherited]
    #expect(model.accessMode == .standard)
    // In a new chat the role chip changes only the chat being created, never the project default.
    model.selectAccessMode(.fullAccess)
    #expect(model.accessMode == .fullAccess && model.accessSelection == .fullAccess)
    #expect(model.state.projects[0].defaultChatAccessMode == nil && model.state.projects[0].chatRoleID == nil)
    model.selectRole(nil)
    #expect(model.accessMode == .standard && model.accessSelection == nil)
    model.updateProjectRoles(project.id, chatRole: AccessMode.fullAccess.legacyRoleID, jobRole: nil, extraRoots: nil, cookieSites: nil)
    #expect(model.state.projects[0].defaultChatAccessMode == .fullAccess)
    #expect(model.state.projects[0].accessMode == nil)
    model.chatID = legacy.id
    #expect(model.accessMode == .standard)
    model.chatID = inherited.id
    #expect(model.accessMode == .fullAccess && model.accessSelection == nil)
    model.selectAccessMode(.standard)
    #expect(model.accessMode == .standard && model.accessSelection == .standard)
    #expect(model.state.projects[0].defaultChatAccessMode == .fullAccess)
    model.selectAccessMode(nil)
    #expect(model.accessMode == .fullAccess && model.accessSelection == nil)
    model.newChat(); model.updateProjectRoles(project.id, chatRole: AccessMode.standard.legacyRoleID, jobRole: nil, extraRoots: nil, cookieSites: nil)
    model.chatID = inherited.id
    #expect(model.accessMode == .standard)
    model.newChat(); model.updateProjectRoles(project.id, chatRole: AccessMode.fullAccess.legacyRoleID, jobRole: nil, extraRoots: nil, cookieSites: nil)
    model.projectID = other.id
    #expect(model.accessMode == .standard)
    // A separate store round-trip verifies persisted defaults, inheritance and legacy behavior.
    let disk = AppStore(file: folder.appendingPathComponent("roundtrip.sqlite"))
    try await disk.save(model.state)
    let restored = try await disk.load()
    #expect(restored.projects[0].defaultChatAccessMode == .fullAccess)
    #expect(restored.projects[1].defaultChatAccessMode == nil)
    #expect(restored.chats[0].resolvedAccessMode(in: restored.projects[0]) == .standard)
    #expect(restored.chats[1].resolvedAccessMode(in: restored.projects[0]) == .fullAccess)
    let legacyJSON = #"{"id":"old","projectID":"00000000-0000-0000-0000-000000000001","title":"Old","model":"fixture","updated":0}"#
    let decoded = try JSONDecoder().decode(Chat.self, from: Data(legacyJSON.utf8))
    #expect(decoded.inheritsProjectAccess == nil)
    #expect(decoded.resolvedAccessMode(in: restored.projects[0]) == .standard)
}
