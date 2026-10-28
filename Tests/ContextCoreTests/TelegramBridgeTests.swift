import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

@Test func telegramAlertsWaitForTheDelayAndWithdrawEndedWaits() {
    let now = Date(timeIntervalSince1970: 1000)
    let a = TelegramAlerts.Waiting(key: "sb-a-1", chatID: "a", job: "A", question: "Approve?")
    let b = TelegramAlerts.Waiting(key: "sb-b-1", chatID: "b", job: "B", question: "Which?")
    let plan = TelegramAlerts.plan(waiting: [a, b], firstSeen: ["sb-a-1": now.addingTimeInterval(-200), "sb-b-1": now.addingTimeInterval(-10)],
                                   sent: ["sb-old"], now: now, delay: 180)
    #expect(plan.send == [a] && plan.resolve == ["sb-old"])
    // Already sent waits are not sent again; a zero delay sends at once.
    #expect(TelegramAlerts.plan(waiting: [a, b], firstSeen: [:], sent: ["sb-a-1"], now: now, delay: 0).send == [b])
    // Keys keep only what the notifier accepts and stay within its length.
    #expect(TelegramAlerts.key(chatID: "C1D2", wait: "turn:C1D2:t 1") == "sb-C1D2-turn-C1D2-t-1")
    #expect(TelegramAlerts.key(chatID: String(repeating: "a", count: 300), wait: "x").count == 200)
}

@Test func telegramNotifierCallsTheCommandLineOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A stand-in notifier that records its calls and answers like the real one.
    let script = root.appendingPathComponent("notifier.py")
    try #"""
    import json, sys, pathlib
    log = pathlib.Path(sys.argv[0]).with_name('calls')
    with log.open('a') as f: f.write(json.dumps({'args': sys.argv[1:], 'stdin': sys.stdin.read()}) + '\n')
    command = sys.argv[1]
    if command == 'status': print(json.dumps({'configured': True}))
    elif command == 'claim-reply':
        claimed = pathlib.Path(sys.argv[0]).with_name('claimed')
        if claimed.exists(): print('null')
        else:
            claimed.write_text('1'); print(json.dumps({'update_id': 7, 'event_key': 'sb-chat-x', 'thread': 'chat', 'text': 'Option B', 'status': 'claimed'}))
    elif command == 'enqueue' and 'fail' in sys.argv: sys.exit('Invalid event field')
    else: print('ok')
    """#.write(to: script, atomically: true, encoding: .utf8)
    let notifier = TelegramNotifier(script: script.path, python: "/usr/bin/python3")
    #expect(await notifier.isConfigured())
    try await notifier.enqueue(key: "sb-chat-1", job: "Chat", thread: "chat", question: "Which option?")
    await #expect(throws: (any Error).self) { try await notifier.enqueue(key: "fail", job: "Chat", thread: "chat", question: "q") }
    try await notifier.resolve(key: "sb-chat-1")
    #expect(try await notifier.claimReply() == .init(id: 7, key: "sb-chat-x", thread: "chat", text: "Option B"))
    #expect(try await notifier.claimReply() == nil)
    try await notifier.acknowledge(7, forwarded: true)
    let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    let args = calls.map { $0["args"] as? [String] ?? [] }
    #expect(args[1] == ["enqueue", "--key", "sb-chat-1", "--job", "Chat", "--thread", "chat"] && calls[1]["stdin"] as? String == "Which option?")
    #expect(args.contains(["claim-reply", "--key-prefix", "sb-"]) && args.last == ["ack-reply", "--id", "7", "--result", "forwarded"])
    await #expect(throws: (any Error).self) { try await TelegramNotifier(script: root.appendingPathComponent("missing.py").path).resolve(key: "k") }
}

@Test @MainActor func telegramRepliesWaitInTheChatQueueAndFailedTurnsAreReported() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil)
    let project = Project(path: root.path)
    var chat = Chat(session: .init(connection: .appClaude, nativeID: "one"), projectID: project.id, title: "One", model: "claude-sonnet-5-5")
    chat.lastTurnFailed = true; chat.unreadCompletionID = "turn:x:t1"; chat.recap = "Claude connection closed."
    var archived = Chat(session: .init(connection: .appClaude, nativeID: "two"), projectID: project.id, title: "Two", model: "claude")
    archived.archived = true
    model.state.projects = [project]; model.state.chats = [chat, archived]
    let waits = model.telegramWaits()
    #expect(waits.count == 1 && waits[0].chatID == chat.id && waits[0].key.hasPrefix("sb-" + chat.id + "-failed-"))
    #expect(waits[0].question.contains("Claude connection closed."))
    // A reply to an idle chat waits in its queue, once; unknown and archived chats are refused.
    let reply = TelegramNotifier.Reply(id: 42, key: waits[0].key, thread: chat.id, text: " Retry please ")
    #expect(await model.acceptTelegramReply(reply))
    #expect(await model.acceptTelegramReply(reply))
    let queued = model.queuedMessages.filter { $0.threadID == chat.id }
    #expect(queued.count == 1 && queued[0].text.hasSuffix("\n\nRetry please") && queued[0].id == "local-user:telegram:42")
    #expect(!(await model.acceptTelegramReply(.init(id: 43, key: "k", thread: archived.id, text: "x"))))
    #expect(!(await model.acceptTelegramReply(.init(id: 44, key: "k", thread: "missing", text: "x"))))
    #expect(!(await model.acceptTelegramReply(.init(id: 45, key: "k", thread: chat.id, text: "  "))))
}
