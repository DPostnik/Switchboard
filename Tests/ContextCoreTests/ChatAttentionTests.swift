import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

@Test func chatAttentionOrdersWhatTheUserMustDo() {
    #expect(ChatAttention.of(approval: true, question: true, running: true, unread: true, failed: true) == .needsApproval)
    #expect(ChatAttention.of(approval: false, question: true, running: true, unread: false, failed: false) == .needsAnswer)
    // A running chat with an old unread result waits for nobody yet.
    #expect(ChatAttention.of(approval: false, question: false, running: true, unread: true, failed: false) == nil)
    #expect(ChatAttention.of(approval: false, question: false, running: false, unread: true, failed: true) == .failed)
    #expect(ChatAttention.of(approval: false, question: false, running: false, unread: true, failed: false) == .finishedUnread)
    #expect(ChatAttention.of(approval: false, question: false, running: false, unread: false, failed: true) == nil)
    #expect(ChatAttention.needsApproval < .needsAnswer && ChatAttention.failed < .finishedUnread)
}

@Test func turnRecapTakesTheQuestionOrTheFirstSentences() {
    #expect(TurnRecap.make("") == nil && TurnRecap.make("```\nlet x = 1\n```") == nil)
    #expect(TurnRecap.make("**Готово.** Сборка прошла, тесты зелёные. Дальше этап 2.\n\n- деталь") == "Готово. Сборка прошла, тесты зелёные.")
    // Version numbers and lower-case continuations do not end a sentence.
    #expect(TurnRecap.make("Pinned CLI is 2.1.292 now. Next step is the badge, e.g. for Claude chats. Then commit.")
            == "Pinned CLI is 2.1.292 now. Next step is the badge, e.g. for Claude chats.")
    // An answer that asks something is summed up by its question; code and tables are skipped.
    let asking = "Plan is ready in `docs/plan.md`.\n\n| a | b |\n|---|---|\n```swift\nlet q = \"?\"\n```\n1. Option one\n2. Option two\n\nWhich option do you want?"
    #expect(TurnRecap.make(asking) == "Which option do you want?")
    #expect(TurnRecap.make("See [the plan](docs/plan.md) for details.") == "See the plan for details.")
    let long = String(repeating: "word ", count: 80)
    let recap = TurnRecap.make(long)
    #expect(recap?.count == TurnRecap.limit && recap?.hasSuffix("…") == true)
}

@Test @MainActor func finishedTurnsLeaveARecapAndJoinTheNeedsYouList() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil)
    let project = Project(path: root.path)
    let first = Chat(session: .init(connection: .appClaude, nativeID: "one"), projectID: project.id, title: "One", model: "claude")
    let second = Chat(session: .init(connection: .appClaude, nativeID: "two"), projectID: project.id, title: "Two", model: "claude")
    model.state.projects = [project]; model.state.chats = [first, second]; model.projectID = project.id
    #expect(model.attentionChats.isEmpty)
    func finish(_ chat: Chat, turn: String, answer: String?, failed: Bool) async {
        await model.receive(.init(session: chat.nativeSession, payload: .started(turn: turn)))
        if let answer {
            var item = TranscriptItem(id: "assistant:" + turn, kind: "assistant", text: answer); item.turnID = turn
            await model.receive(.init(session: chat.nativeSession, payload: .item(item)))
        }
        await model.receive(.init(session: chat.nativeSession, payload: .completed(.init(id: turn, status: failed ? .failed : .completed, hasError: failed,
            error: failed ? "Claude connection closed. Not retried." : nil,
            history: AgentHistoryTurn(id: turn, items: [], startedAt: nil, completedAt: nil, duration: nil, isComplete: true)))))
    }
    await finish(first, turn: "t1", answer: "Done. The badge works.\n\nDetails follow.", failed: false)
    await finish(second, turn: "t2", answer: "Partial answer", failed: true)
    let one = try #require(model.state.chats.first { $0.id == first.id })
    let two = try #require(model.state.chats.first { $0.id == second.id })
    #expect(one.recap == "Done. The badge works." && one.lastTurnFailed == nil)
    #expect(two.recap == "Claude connection closed. Not retried." && two.lastTurnFailed == true)
    // Failed results lead; the detail line is the recap.
    #expect(model.attentionChats.map(\.chat.id) == [second.id, first.id])
    #expect(model.attentionChats.map(\.attention) == [.failed, .finishedUnread])
    #expect(model.attentionDetail(one) == "Done. The badge works.")
    // A successful next turn clears the failure; a read result leaves the list.
    await finish(second, turn: "t3", answer: "Fixed now.", failed: false)
    #expect(model.state.chats.first { $0.id == second.id }?.lastTurnFailed == nil)
    if let index = model.state.chats.firstIndex(where: { $0.id == first.id }) { model.state.chats[index].unreadCompletionID = nil }
    #expect(model.attentionChats.map(\.chat.id) == [second.id])
}
