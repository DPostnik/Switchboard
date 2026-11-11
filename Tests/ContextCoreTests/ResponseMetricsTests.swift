@_spi(NativeProtocol) @testable import CodexAdapter
import AppKit
import Foundation
import Testing
import ContextCore
import ContextTranscript
@testable import ContextDesk

@Test func responseTimingUsesServerHistoryAndMilliseconds() throws {
    let old = ResponseTiming(startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2))
    let timing = try #require(CodexDecoding.responseTiming(.object([
        "startedAt": .number(100), "completedAt": .number(168), "durationMs": .number(67_500)
    ]), fallback: old))
    #expect(timing.label(language: .english) == "Worked for 1m 7s")
    #expect(timing.label(language: .russian) == "Время работы: 1 мин 7 с")
    #expect(timing.completedAt == Date(timeIntervalSince1970: 168))
    #expect(CodexDecoding.responseTiming(.object(["startedAt": .number(100)])) == nil)
    #expect(CodexDecoding.responseTiming(.null, fallback: old) == old)
    let timestampsOnly = try #require(CodexDecoding.responseTiming(.object(["startedAt": .number(100), "completedAt": .number(156)])))
    #expect(timestampsOnly.label(language: .english) == "Worked for 56s")
    let invalid = try #require(CodexDecoding.responseTiming(.object(["startedAt": .number(200), "completedAt": .number(156), "durationMs": .number(-1)])))
    #expect(invalid.label(language: .english) == "Work finished")
}

@Test func responseTokensUseCumulativeDifferencesWithoutDoubleCounting() throws {
    var tracker = ResponseTokenTracker(baseline: TokenCounters(input: 10_000, cached: 8_000, output: 1_000))
    tracker.observe(TokenCounters(input: 12_000, cached: 9_000, output: 1_100))
    tracker.observe(TokenCounters(input: 12_000, cached: 9_000, output: 1_100))
    tracker.observe(TokenCounters(input: 15_000, cached: 11_000, output: 1_400))
    let result = try #require(tracker.result)
    #expect(result.counts == TokenCounters(input: 5_000, cached: 3_000, output: 400))
    #expect(!result.isPartial)
    #expect(result.detail(language: .english).contains("Input: 5,000 · cached subset: 3,000"))
    #expect(result.detail(language: .russian).contains("Токены за весь запрос"))
    #expect(result.detail(language: .english).contains("Output: 400"))
    var next = ResponseTokenTracker(baseline: TokenCounters(input: 15_000, cached: 11_000, output: 1_400))
    next.observe(TokenCounters(input: 16_000, cached: 11_000, output: 1_450))
    #expect(next.result?.counts == TokenCounters(input: 1_000, cached: 0, output: 50))
    #expect(tracker.result == result)
}

@Test func tokenGapsAndResetsDoNotClaimWholeRequestCounts() throws {
    var tracker = ResponseTokenTracker(baseline: nil)
    tracker.observe(TokenCounters(input: 1_000, cached: 500, output: 100))
    tracker.observe(TokenCounters(input: 1_000, cached: 500, output: 100))
    #expect(tracker.result == nil)
    tracker.observe(TokenCounters(input: 2_000, cached: 1_000, output: 200))
    #expect(tracker.result?.isPartial == true)
    #expect(tracker.result?.detail(language: .english).contains("only part") == true)
    tracker.observe(TokenCounters(input: 100, cached: 0, output: 10))
    #expect(tracker.result == nil)
    tracker.observe(TokenCounters(input: 150, cached: 0, output: 15))
    #expect(tracker.result?.counts == TokenCounters(input: 50, cached: 0, output: 5))
    #expect(tracker.result?.isPartial == true)
    #expect(CodexDecoding.tokenCounters(.object(["inputTokens": .number(1), "cachedInputTokens": .number(2), "outputTokens": .number(1)])) == nil)
    #expect(CodexDecoding.tokenCounters(.object(["inputTokens": .number(-1), "cachedInputTokens": .number(0), "outputTokens": .number(1)])) == nil)
}

@Test func responseTokenDetailsPersistWithTimingAndReadOldRecords() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("state.sqlite")
    var tracker = ResponseTokenTracker(baseline: .zero)
    tracker.observe(TokenCounters(input: 500, cached: 200, output: 50))
    let timing = ResponseTiming(startedAt: nil, completedAt: Date(timeIntervalSince1970: 167), durationSeconds: 67, tokens: tracker.result)
    try await AppStore(file: file).saveTiming(threadID: "one", turnID: "turn", timing: timing)
    #expect(try await AppStore(file: file).loadTimings(threadID: "one")["turn"] == timing)
    #expect(try await AppStore(file: file).loadTimings(threadID: "two").isEmpty)
    let old = try JSONDecoder().decode(ResponseTiming.self, from: Data(#"{"startedAt":100,"completedAt":167}"#.utf8))
    #expect(old.tokens == nil)
    #expect(old.durationSeconds == nil)
}

@Test @MainActor func oneAuthorPerQuestionAndClickableTimePreserveFollowingContent() throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 650)
    var tracker = ResponseTokenTracker(baseline: .zero)
    tracker.observe(TokenCounters(input: 500, cached: 200, output: 50))
    let timing = ResponseTiming(startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 167), tokens: tracker.result)
    var items = [TranscriptItem(id: "u", kind: "user", text: "Проверь проект"),
        TranscriptItem(id: "a", kind: "assistant", text: "Начинаю проверку."),
        TranscriptItem(id: "tool", kind: "activity", text: "Run checks"),
        TranscriptItem(id: "b", kind: "assistant", text: "Проверяю результаты."),
        TranscriptItem(id: "final", kind: "assistant", text: "Проверка завершена.", timing: timing),
        TranscriptItem(id: "u2", kind: "user", text: "Следующий вопрос"),
        TranscriptItem(id: "next", kind: "assistant", text: "Следующий ответ")]
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(view.transcript.string.components(separatedBy: "Codex\n").count - 1 == 2)
    let rendered = view.transcript.string as NSString
    #expect(rendered.range(of: timing.label()).location < rendered.range(of: "Начинаю проверку.").location)
    #expect(view.transcript.string.components(separatedBy: timing.label()).count - 1 == 1)
    #expect(!view.transcript.string.contains(timing.tokens!.detail()))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-metrics:a", at: 0)
    #expect(view.transcript.string.contains(timing.tokens!.detail()))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:tool", at: 0)
    #expect(view.transcript.string.contains("Run checks"))
    items[6].text += " — продолжение"
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(view.transcript.string.contains("Следующий ответ — продолжение"))
    #expect(view.transcript.string.contains(timing.tokens!.detail()))
    for width: CGFloat in [360, 760] {
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.transcript.layoutManager)
        let container = try #require(view.transcript.textContainer)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).maxX + view.transcript.textContainerOrigin.x <= view.contentSize.width)
    }
    if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
        view.drawsBackground = true; view.backgroundColor = .windowBackgroundColor
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".details.png"))
    }
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-metrics:a", at: 0)
    #expect(!view.transcript.string.contains(timing.tokens!.detail()))
    #expect(view.transcript.string.contains("Следующий ответ — продолжение"))
}

@Test @MainActor func reopeningHistoryUsesServerTurnTimingAndSavedTokenDetails() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json
    for line in sys.stdin:
        message = json.loads(line)
        if 'id' not in message: continue
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture', 'thread': {'id': 'thread', 'turns': [{'id': 'turn', 'status': 'completed',
            'startedAt': 100, 'completedAt': 168, 'durationMs': 67500,
            'items': [{'id': 'comment', 'type': 'agentMessage', 'text': 'Checking'},
                      {'id': 'answer', 'type': 'agentMessage', 'text': 'Done', 'phase': 'final_answer'}]}]}}
        print(json.dumps({'id': message['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    let fixtureClient = CodexClient(transport: connection)
    try await fixtureClient.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    var tracker = ResponseTokenTracker(baseline: .zero)
    tracker.observe(TokenCounters(input: 500, cached: 200, output: 50))
    try await store.saveTiming(threadID: "thread", turnID: "turn", timing:
        ResponseTiming(startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2), tokens: tracker.result))
    let model = DeskModel(connection: CodexIntegration(client: fixtureClient), store: store, pluginDirectory: folder.appendingPathComponent("plugins"))
    let project = Project(path: folder.path)
    let chat = Chat(id: "thread", projectID: project.id, title: "History", model: "")
    model.state.projects = [project]; model.state.chats = [chat]
    try await store.save(model.state)
    await model.openChat(chat)
    #expect(model.error == nil)
    #expect(model.items.count == 2)
    #expect(model.items.first?.timing == nil)
    #expect(model.items.last?.timing?.label(language: .english) == "Worked for 1m 7s")
    #expect(model.items.last?.timing?.tokens == tracker.result)
    #expect(model.items.last?.turnID == "turn")
    let saved = try #require(try await store.loadTranscript(conversationID: chat.id))
    #expect(LocalHistory.items(saved) == model.items)
    await connection.stop()
}
