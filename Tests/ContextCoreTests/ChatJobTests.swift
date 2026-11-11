@_spi(NativeProtocol) import CodexAdapter
import AgentContract
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test func chatJobNoteFollowsCriterionAndClose() {
    #expect(ChatJob.criterion("  \n ") == nil)
    #expect(ChatJob.criterion("  tests pass \n") == "tests pass")
    #expect(ChatJob.criterion(String(repeating: "a", count: 3_000))?.count == ChatJob.criterionLimit)

    var job = ChatJob(doneWhen: "tests pass", started: Date(timeIntervalSince1970: 0))
    #expect(job.pendingNote == .criterion("tests pass"))
    job.markAnnounced(.criterion("tests pass"))
    #expect(job.pendingNote == nil && job.announced == "tests pass")
    // An edited criterion is announced again; a note for the old one changes nothing.
    job.doneWhen = "tests pass and pushed"
    job.markAnnounced(.criterion("tests pass"))
    #expect(job.pendingNote == .criterion("tests pass and pushed"))
    job.markAnnounced(.criterion("tests pass and pushed"))
    job.close(done: false, at: Date(timeIntervalSince1970: 60_480))
    #expect(job.status == .cancelled && job.pendingNote == .closed(done: false))
    #expect(job.elapsed(now: Date(timeIntervalSince1970: 99_999)) == 60_480)
    job.close(done: true)
    #expect(job.status == .cancelled)
    job.markAnnounced(.closed(done: false))
    #expect(job.pendingNote == nil && job.announced == nil)
    // A job closed before the agent heard of it needs no note.
    var unannounced = ChatJob(doneWhen: "x")
    unannounced.close(done: true)
    #expect(unannounced.pendingNote == nil)

    #expect(ChatJob.duration(60_480, language: .english) == "16h 48m")
    #expect(ChatJob.duration(60_480, language: .russian) == "16 ч 48 мин")
    #expect(ChatJob.duration(125, language: .english) == "2m 5s")
}

@Test func chatJobNotesAreHiddenFromTranscripts() {
    for language in [AppLanguage.russian, .english] {
        let criterion = ChatJobNote.applying(ChatJob.noteText(.criterion("ship [it]"), language: language), to: "Go")
        #expect(TranscriptItem(id: "u", kind: "user", text: criterion).text == "Go")
        let closed = ChatJobNote.applying(ChatJob.noteText(.closed(done: true), language: language), to: "Next")
        #expect(TranscriptItem(id: "u", kind: "user", text: closed).text == "Next")
        let both = ChatJobNote.applying(ChatJob.noteText(.criterion("x"), language: language),
                                        to: InterruptedTurnNote.applying(InterruptedTurnNote.english, to: "Instead"))
        #expect(TranscriptItem(id: "u", kind: "user", text: both).text == "Instead")
    }
    #expect(ChatJobNote.stripped("Text [Switchboard: chat job]") == "Text [Switchboard: chat job]")
    #expect(TranscriptItem(id: "a", kind: "assistant", text: "A\n\n[Switchboard: chat job. x]").text == "A\n\n[Switchboard: chat job. x]")
}

@Test func chatJobRoundTripsWithTheChat() throws {
    var chat = Chat(id: "t", projectID: UUID(), title: "Fixture", model: "")
    let legacy = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
    #expect(legacy.job == nil)
    chat.job = ChatJob(doneWhen: "done", started: Date(timeIntervalSince1970: 100), announced: "done")
    chat.job?.close(done: true, at: Date(timeIntervalSince1970: 200))
    let decoded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
    #expect(decoded.job == chat.job)
}

@Test @MainActor func chatJobCriterionGoesOutOnceWithTheNextMessage() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json, os, pathlib
    calls = pathlib.Path(os.environ['CODEX_HOME']) / 'calls.jsonl'
    turns = 0
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method = m['method']
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'turn/start':
            turns += 1
            result = {'turn': {'id': 'v' + str(turns)}}
        if method == 'test/requests':
            result = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        else:
            with calls.open('a') as log: log.write(json.dumps(m) + '\n')
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    let client = CodexClient(transport: connection)
    try await client.start(executable: executable, home: folder)
    let integration = CodexIntegration(client: client)
    defer { Task { await integration.disconnect() } }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: integration, store: store, summaryExecutable: executable, summaryHome: folder)
    model.state.defaultRoute = .direct
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id; model.chatID = "t"
    model.state.chats = [Chat(id: "t", projectID: project.id, title: "Fixture", model: "")]
    model.connected = true; model.authenticated = true

    #expect(!model.setChatJob("t", doneWhen: "   "))
    #expect(model.setChatJob("t", doneWhen: "tests pass"))
    model.draft = "First"
    await model.send()
    model.finishActiveTurn(threadID: "t", turnID: "v1", status: .completed, hasError: false)
    model.draft = "Second"
    await model.send()
    model.finishActiveTurn(threadID: "t", turnID: "v2", status: .completed, hasError: false)
    await model.closeChatJob("t", done: true)
    model.draft = "Third"
    await model.send()

    let requests = try await connection.request("test/requests").array
    let sent = requests.filter { $0["method"].string == "turn/start" }.map { $0["params"]["input"].array.compactMap { $0["text"].string }.joined() }
    try #require(sent.count == 3)
    #expect(sent[0].hasPrefix("First\n\n[Switchboard: ") && sent[0].contains("tests pass") && ChatJobNote.stripped(sent[0]) == "First")
    #expect(sent[1] == "Second")
    #expect(sent[2].hasPrefix("Third\n\n[Switchboard: ") && ChatJobNote.stripped(sent[2]) == "Third")
    #expect(model.items.map(\.text) == ["First", "Second", "Third"])
    let job = try #require(model.state.chats.first?.job)
    #expect(job.status == .done && job.pendingNote == nil && job.finished != nil)
}
