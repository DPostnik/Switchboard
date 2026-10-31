import Foundation
import Testing
import AgentContract
import ContextCore
@_spi(NativeProtocol) @testable import CodexAdapter
@testable import ContextDesk

@Test func localHistoryRevisionsPreservePresentationAndLegacySnapshots() throws {
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "native")
    var item = TranscriptItem(id: "reply", kind: "assistant", text: "Привет / Hello", phase: "final_answer",
                              timing: ResponseTiming(startedAt: nil, completedAt: Date(timeIntervalSince1970: 100)))
    item.turnID = "turn"
    let first = try LocalHistory.snapshot(conversation: ConversationID("app"), source: session, items: [item])
    let second = try LocalHistory.snapshot(conversation: ConversationID("app"), source: session, items: [item])
    #expect(first.revision == second.revision)
    #expect(LocalHistory.items(try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: JSONEncoder().encode(first))) == [item])
    item.text += " changed"
    #expect(try LocalHistory.snapshot(conversation: ConversationID("app"), source: session, items: [item]).revision != first.revision)
    let legacy = try JSONDecoder().decode(AgentTranscriptItem.self, from: Data(#"{"id":"old","kind":"user","text":"Original"}"#.utf8))
    #expect(legacy.presentation == nil && legacy.text == "Original")
    for language in AppLanguage.allCases {
        #expect(!LocalHistory.notice(nil, language: language).isEmpty)
        #expect(!LocalHistory.notice(first, language: language).isEmpty)
    }
    #expect(LocalHistory.notice(first, language: .english).contains("incomplete"))
    #expect(LocalHistory.notice(first, language: .russian).contains("неполная"))
}

@Test func localHistoryDoesNotClaimUnknownOrActiveItemsAreComplete() throws {
    let variants = [
        #"{"id":"t","status":"completed","items":[{"id":"i","type":"futureTool"}]}"#,
        #"{"id":"t","status":"inProgress","items":[{"id":"i","type":"agentMessage","text":"Working"}]}"#,
        #"{"id":"t","status":"completed","items":[{"id":"i","type":"userMessage","content":[{"type":"image","url":"fixture"}]}]}"#,
        #"{"id":"t","status":"completed"}"#
    ]
    for json in variants {
        let turn = AgentHistoryTurn(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        #expect(!turn.isComplete)
        let snapshot = try LocalHistory.snapshot(conversation: ConversationID("app"),
            source: .init(connection: .originalCodex, nativeID: "native"), turns: [turn])
        #expect(snapshot.completeness == .partial)
    }
}

@Test @MainActor func itemEventsPersistWithoutSelectingOrResumingTheirChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let model = DeskModel(store: store, summaryResources: nil)
    let chat = Chat(id: "background", projectID: UUID(), title: "Background", model: "fixture")
    model.state.chats = [chat]
    try await store.save(model.state)
    let source = try #require(chat.nativeSession)
    await model.receive(.init(session: source, payload: .item(.init(id: "a", kind: "assistant", text: "Saved in background"))))
    #expect(model.chatID == nil && model.items.isEmpty && model.pending.isEmpty)
    #expect(try await store.loadTranscript(conversationID: chat.id)?.items.map(\.text) == ["Saved in background"])
    let foreign = AgentSessionReference(connection: AgentConnectionID(agent: .claudeCode, id: UUID()), nativeID: source.nativeID)
    await model.receive(.init(session: foreign, payload: .item(.init(id: "a", kind: "assistant", text: "Wrong connection"))))
    #expect(try await store.loadTranscript(conversationID: chat.id)?.items.map(\.text) == ["Saved in background"])
}

@Test @MainActor func localHistorySurvivesUnavailableEngineAndRejectsLateBackfill() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let project = Project(path: "/fixture")
    let session = AgentSessionReference(connection: AgentConnectionID(agent: .claudeCode, id: UUID()), nativeID: "native")
    let chat = Chat(session: session, projectID: project.id, title: "Saved", model: "unavailable")
    var state = SavedState(); state.projects = [project]; state.chats = [chat]
    try await store.save(state)
    let old = try LocalHistory.snapshot(conversation: ConversationID(chat.id), source: session,
        items: [TranscriptItem(id: "first", kind: "user", text: "Original")], capturedAt: Date(timeIntervalSince1970: 1))
    try await store.saveTranscript(old)
    try await store.recordTranscriptItem(TranscriptItem(id: "reply", kind: "assistant", text: "Saved answer"), conversationID: chat.id, source: session)
    try await store.saveTranscript(old)
    let model = DeskModel(store: store, summaryResources: nil)
    model.state = try await store.load()
    await model.openChat(chat)
    #expect(model.items.map(\.text) == ["Original", "Saved answer"])
    #expect(model.localHistoryNotice != nil && !model.loadingChat)
    #expect(!model.canSend && model.queuePaused && model.pending.isEmpty)
    model.newChat()
    #expect(model.localHistoryNotice == nil && model.items.isEmpty)
}

@Test @MainActor func backgroundHistoryReadsOnlyAndPersistsUnselectedChats() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json,sys
    calls=[]
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; p=m.get('params',{}); result={}
        if method=='test/calls': result=calls
        else: calls.append(method)
        if method=='initialize': result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='thread/read': result={'thread':{'id':p['threadId'],'turns':[{'id':'t','status':'completed','items':[{'id':'a','type':'agentMessage','text':'Saved by backfill'}]}]}}
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let wire = CodexConnection()
    let integration = CodexIntegration(client: CodexClient(transport: wire))
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let model = DeskModel(connection: integration, store: store, summaryResources: nil)
    _ = try await model.connection.start(.init(executable: executable, home: root))
    model.connected = true
    let project = Project(path: root.path)
    let chat = Chat(id: "old", projectID: project.id, title: "Saved", model: "fixture")
    var archived = Chat(id: "archived", projectID: project.id, title: "Archived", model: "fixture")
    archived.archived = true
    model.state.projects = [project]; model.state.chats = [chat, archived]
    try await store.save(model.state)
    await model.backfillHistory([chat, archived])
    #expect(model.chatID == nil && model.items.isEmpty)
    let snapshot = try #require(try await store.loadTranscript(conversationID: chat.id))
    #expect(snapshot.completeness == .complete && snapshot.items.map(\.text) == ["Saved by backfill"])
    // Archived chats are not read at connect: one history read, and no stored transcript for the archived one.
    #expect(try await store.loadTranscript(conversationID: archived.id) == nil)
    let calls = try await wire.request("test/calls").array.compactMap(\.string)
    #expect(calls == ["initialize", "thread/read"])
    await model.connection.stop(); model.connected = false
    await model.openChat(chat)
    #expect(model.items.map(\.text) == ["Saved by backfill"])
    #expect(model.localHistoryNotice != nil)
}

@Test @MainActor func remoteSnapshotReusesStoredHistoryUntilTranscriptChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let project = Project(path: "/fixture")
    let session = AgentSessionReference(connection: AgentConnectionID(agent: .claudeCode, id: UUID()), nativeID: "native")
    let chat = Chat(session: session, projectID: project.id, title: "Remote", model: "model")
    var state = SavedState(); state.projects = [project]; state.chats = [chat]
    try await store.save(state)
    let first = try LocalHistory.snapshot(conversation: ConversationID(chat.id), source: session,
        items: [TranscriptItem(id: "first", kind: "user", text: "Hello")], capturedAt: Date(timeIntervalSince1970: 10))
    try await store.saveTranscript(first)
    let model = DeskModel(store: store, summaryResources: nil)
    model.state = try await store.load()
    let projects: Set = [project.id.uuidString]
    #expect(await model.remoteSnapshot(projects: projects).chats.first?.messages.map(\.text) == ["Hello"])
    let revision = await store.transcriptRevision(conversationID: chat.id)
    // A stale snapshot is ignored by the store and must not invalidate cached history.
    try await store.saveTranscript(LocalHistory.snapshot(conversation: ConversationID(chat.id), source: session,
        items: [], capturedAt: Date(timeIntervalSince1970: 1)))
    #expect(await store.transcriptRevision(conversationID: chat.id) == revision)
    try await store.recordTranscriptItem(TranscriptItem(id: "reply", kind: "assistant", text: "Answer"), conversationID: chat.id, source: session)
    #expect(await store.transcriptRevision(conversationID: chat.id) == revision + 1)
    #expect(await model.remoteSnapshot(projects: projects).chats.first?.messages.map(\.text) == ["Hello", "Answer"])
}
