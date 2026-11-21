import Foundation
import Testing
import AgentContract
import ContextCore
@_spi(NativeProtocol) import CodexAdapter
@testable import ContextDesk

private let handoffOutput = #"{"goal":"Finish the review","decisions":"Keep permissions","changedFiles":"Sources/Example.swift","validation":"Build passed; tests not run","remainingWork":"Run tests","continuation":"ready"}"#
private func handoffSnapshot(_ text: String) -> AgentTranscriptSnapshot {
    .init(conversation: ConversationID("source"), source: .init(connection: .originalCodex, nativeID: "source"),
          revision: "revision", capturedAt: Date(), completeness: .partial,
          items: [.init(id: "message", kind: .user, text: text)])
}

@Test func handoffSummaryPreservesLongUnicodeEvidenceAndLocalizedDrafts() throws {
    let text = String(repeating: "Начало 🐱 \"quoted\"\n", count: 9000) + "LAST USER CORRECTION"
    let snapshot = handoffSnapshot(text)
    let chunks = try HandoffSummary.chunks(snapshot)
    #expect(chunks.count > 1)
    #expect(chunks.flatMap(\.fragments).map(\.text).joined() == text)
    let summary = try HandoffSummary.validate(handoffOutput)
    for language in AppLanguage.allCases {
        let handoff = try summary.applying(to: snapshot, language: language)
        #expect(handoff.origin.revision == "revision" && handoff.history == snapshot)
        #expect(handoff.validation == "Build passed; tests not run")
        #expect(!handoff.includeTranscript)
        #expect(handoff.instructions.contains(language == .russian ? "Продолжи" : "Continue"))
        #expect(try handoff.prompt(language: language).utf8.count < 131_072)
    }
    for chunk in chunks {
        let input = try HandoffSummary.input(chunk: chunk, previous: summary, completeness: .partial)
        #expect(input.utf8.count <= AgentGenerationRequest.maximumInputBytes)
        #expect(input.contains("previousSummary") && input.contains("tests not run") && input.contains("partial"))
    }
    #expect(throws: ClientFailure.self) { try HandoffSummary.chunks(handoffSnapshot("")) }
    #expect(throws: ClientFailure.self) { try HandoffSummary.validate("{}") }
    #expect(throws: ClientFailure.self) { try HandoffSummary.validate(handoffOutput.replacingOccurrences(of: "Run tests", with: " ")) }
}

@Test func handoffSummaryContinuesOnlyAnAuthorizedNextAction() throws {
    let snapshot = handoffSnapshot("Historical task")
    let ready = try HandoffSummary.validate(handoffOutput)
    let paused = try HandoffSummary.validate(handoffOutput.replacingOccurrences(of: #""ready""#, with: #""wait""#))
    for language in AppLanguage.allCases {
        let continued = try ready.applying(to: snapshot, language: language, automatic: true)
        let waiting = try paused.applying(to: snapshot, language: language, automatic: true)
        let blocked = try ready.applying(to: snapshot, language: language, automatic: true, forceWait: true)
        let continuationText = language == .russian ? "Продолжи ближайший шаг" : "Continue with the next step"
        let pauseText = language == .russian ? "Сохрани паузу" : "Preserve the pause"
        #expect(continued.instructions.contains(continuationText))
        let automaticPrompt = try continued.prompt(language: language)
        let evidenceStart = try #require(automaticPrompt.range(of: "\n{")?.upperBound)
        #expect(!automaticPrompt[..<evidenceStart].contains("Finish the review"))
        #expect(automaticPrompt[evidenceStart...].contains("Finish the review"))
        #expect(waiting.instructions.contains(pauseText))
        #expect(blocked.instructions == waiting.instructions)
    }
    #expect(throws: ClientFailure.self) {
        try HandoffSummary.validate(handoffOutput.replacingOccurrences(of: #""ready""#, with: #""unknown""#))
    }
}

private func handoffEngine(_ root: URL, mode: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
    try Data(handoffOutput.utf8).write(to: root.appendingPathComponent("output"))
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, os, sys, time
    from pathlib import Path
    root=Path(os.environ['CODEX_HOME'])
    mode=(root/'mode').read_text()
    reads=0
    def emit(value): print(json.dumps(value),flush=True)
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m or 'method' not in m: continue
        method=m['method'];p=m.get('params',{});result={}
        with (root/'calls.jsonl').open('a') as f: f.write(json.dumps({'method':method,'params':p})+'\n')
        if method=='initialize': result={'userAgent':'context_desk/0.159.0 (test)'}
        if method=='config/read':result={'config':{'mcp_servers':{'configured':{}}}}
        if method=='thread/read':
            reads+=1
            text='Review remaining work' if mode!='stale' or reads==1 else 'New user correction'
            result={'thread':{'id':'source','turns':[{'id':'turn','status':'completed','items':[{'id':'u','type':'userMessage','content':[{'type':'text','text':text}]}]}]}}
        if method=='thread/start':
            assert p['ephemeral'] and p['sandbox']=='read-only' and p['environments']==[]
            assert p['approvalPolicy']=='untrusted' and p['config']['mcp_servers."configured".enabled']==False
            result={'thread':{'id':'summary','ephemeral':True,'environments':[]},'sandbox':{'type':'readOnly'},'model':p['model'],'modelProvider':p['modelProvider']}
        if method=='mcpServerStatus/list':result={'data':[]}
        if method=='turn/start':
            assert p['threadId']=='summary' and 'remainingWork' in p['outputSchema']['properties']
            data=json.loads(p['input'][0]['text'])
            assert data['nextTranscriptChunk'][0]['text']=='Review remaining work'
            if mode=='disconnect':sys.exit(0)
            if mode=='cancel':
                (root/'dispatched').write_text('yes')
                time.sleep(120)
                continue
            emit({'id':m['id'],'result':{'turn':{'id':'generated'}}})
            if mode=='approval':
                emit({'id':'bad','method':'item/fileChange/requestApproval','params':{'threadId':'summary','turnId':'generated'}})
                continue
            emit({'method':'item/completed','params':{'threadId':'summary','turnId':'generated','item':{'type':'agentMessage','text':(root/'output').read_text()}}})
            emit({'method':'turn/completed','params':{'threadId':'summary','turn':{'id':'generated','status':'completed','error':None}}})
            continue
        emit({'id':m['id'],'result':result})
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return executable
}

@Test @MainActor func automaticHandoffPreparesEditableFieldsWithoutMutatingSource() async throws {
    try await checkHandoff(mode: "success")
}
@Test(arguments: ["disconnect", "approval", "stale", "cancel"])
@MainActor func automaticHandoffStopsWithoutRetry(mode: String) async throws {
    try await checkHandoff(mode: mode)
}
@MainActor private func checkHandoff(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try handoffEngine(root, mode: mode)
    let wire = CodexConnection()
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: wire)),
        store: AppStore(file: root.appendingPathComponent("state.sqlite")), summaryResources: nil, summaryExecutable: executable, summaryHome: root)
    _ = try await model.connection.start(.init(executable: executable, home: root))
    model.connected = true; model.authenticated = true
    let project = Project(path: root.path)
    let chat = Chat(id: "source", projectID: project.id, title: "Review", model: "fixture-model")
    model.state.projects = [project]; model.state.chats = [chat]
    model.chatID = chat.id; model.draft = "Preserve my draft"
    let preparation = Task { await model.prepareHandoff(chat) }
    if mode == "cancel" {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("dispatched").path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("dispatched").path))
        model.cancelHandoffPreparation()
        #expect(!model.preparingHandoff && model.handoffProgress.isEmpty)
    }
    let handoff = await preparation.value
    if mode == "success" {
        let handoff = try #require(handoff)
        #expect(handoff.goal == "Finish the review" && handoff.remainingWork == "Run tests")
        #expect(handoff.validation == "Build passed; tests not run" && !handoff.includeTranscript)
        #expect(handoff.history.items.first?.text == "Review remaining work")
        #expect(model.error == nil)
    } else {
        #expect(handoff == nil)
        #expect((model.error != nil) == (mode != "cancel"))
    }
    #expect(!model.preparingHandoff && model.handoffProgress.isEmpty)
    #expect(model.draft == "Preserve my draft" && model.state.chats.count == 1)
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
    #expect(calls.components(separatedBy: #""method": "turn/start""#).count - 1 == 1)
    #expect(!calls.contains("thread/resume") && !calls.contains("thread/compact"))
    await model.connection.stop()
}
