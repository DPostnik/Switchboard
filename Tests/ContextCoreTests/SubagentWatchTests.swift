import Foundation
import Testing
import AgentContract
@testable import ClaudeAdapter
@testable import ContextCore
@testable import ContextDesk

private func frame(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

/// The stage E agent of 2026-11-02 hung after one message with a `Write` and a `Bash` call: no result, no frame, for an hour.
@Test func claudeSubagentTrackerRecordsActivityAndPendingTools() throws {
    var tracker = ClaudeSubagentTracker()
    let start = Date(timeIntervalSince1970: 1000)
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"call-a","description":"Stage E","task_type":"local_agent","is_backgrounded":true,"prompt":"Run"}"#), now: start)
    #expect(tracker.agents[0].lastActivityAt == start && tracker.agents[0].pendingTools.isEmpty)

    let calls = #"{"type":"assistant","parent_tool_use_id":"call-a","message":{"id":"m1","content":[{"type":"tool_use","id":"w1","name":"Write","input":{"file_path":"/tmp/x.py"}},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"make","timeout":600000}}]}}"#
    #expect(tracker.observe(try frame(calls), now: start.addingTimeInterval(10)))
    var agent = tracker.agents[0]
    #expect(agent.lastActivityAt == start.addingTimeInterval(10))
    #expect(agent.pendingTools == [.init(id: "w1", name: "Write"), .init(id: "b1", name: "Bash", timeout: 600)])

    // Streamed output moves the activity time, but at most every 30 s, so streaming does not republish the list.
    let stream = #"{"type":"stream_event","parent_tool_use_id":"call-a","event":{"type":"content_block_delta"}}"#
    #expect(!tracker.observe(try frame(stream), now: start.addingTimeInterval(20)))
    #expect(tracker.agents[0].lastActivityAt == start.addingTimeInterval(10))
    #expect(tracker.observe(try frame(stream), now: start.addingTimeInterval(45)))
    #expect(tracker.agents[0].lastActivityAt == start.addingTimeInterval(45))
    // Frames of the main agent or of unknown calls say nothing about this sub-agent.
    #expect(!tracker.observe(try frame(#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#), now: start.addingTimeInterval(500)))
    #expect(!tracker.observe(try frame(#"{"type":"tool_progress","parent_tool_use_id":"other","tool_use_id":"x"}"#), now: start.addingTimeInterval(500)))

    let result = #"{"type":"user","parent_tool_use_id":"call-a","message":{"content":[{"type":"tool_result","tool_use_id":"w1","content":"written"}]}}"#
    #expect(tracker.observe(try frame(result), now: start.addingTimeInterval(50)))
    agent = tracker.agents[0]
    #expect(agent.pendingTools.map(\.id) == ["b1"] && agent.lastActivityAt == start.addingTimeInterval(50))
    #expect(tracker.observe(try frame(#"{"type":"system","subtype":"task_progress","task_id":"a1","description":"Running make"}"#), now: start.addingTimeInterval(60)))
    #expect(tracker.agents[0].lastActivityAt == start.addingTimeInterval(60))

    #expect(tracker.observe(try frame(#"{"type":"system","subtype":"task_notification","task_id":"a1","status":"completed","summary":"done"}"#), now: start.addingTimeInterval(70)))
    #expect(tracker.agents[0].pendingTools.isEmpty && tracker.agents[0].status == .completed)
    // A finished sub-agent keeps its last activity time.
    #expect(!tracker.observe(try frame(stream), now: start.addingTimeInterval(200)))
    #expect(tracker.agents[0].lastActivityAt == start.addingTimeInterval(60))
}

private func agent(_ id: String, quietFor seconds: TimeInterval, now: Date, status: AgentSubagent.Status = .running,
                   pending: [AgentSubagent.PendingTool] = []) -> AgentSubagent {
    AgentSubagent(id: id, title: "Agent \(id)", type: nil, prompt: "", background: true, depth: 1, status: status,
                  startedAt: now.addingTimeInterval(-3600), lastActivityAt: now.addingTimeInterval(-seconds), pendingTools: pending)
}

@Test func subagentWatchAllowsEachToolItsOwnTimeLimit() {
    let now = Date(timeIntervalSince1970: 100_000)
    let agents = [
        agent("model", quietFor: 299, now: now),
        agent("hung", quietFor: 300, now: now, pending: [.init(id: "w", name: "Write"), .init(id: "b", name: "Bash")]),
        agent("build", quietFor: 700, now: now, pending: [.init(id: "b", name: "Bash", timeout: 600)]),
        agent("late-build", quietFor: 780, now: now, pending: [.init(id: "b", name: "Bash", timeout: 600)]),
        // Its own sub-agent is watched instead.
        agent("parent", quietFor: 5000, now: now, pending: [.init(id: "c", name: "Agent")]),
        agent("done", quietFor: 5000, now: now, status: .completed),
    ]
    let silences = SubagentWatch.silences(agents, now: now)
    #expect(silences.map(\.agentID) == ["hung", "late-build"])
    #expect(silences[0].pendingTools == ["Write", "Bash"] && silences[0].quietSince == now.addingTimeInterval(-300))
    // After the Mac slept the silence counts from the wake-up.
    #expect(SubagentWatch.silences(agents, now: now, awakeSince: now.addingTimeInterval(-120)).isEmpty)
    #expect(SubagentWatch.silences(agents, now: now, awakeSince: now.addingTimeInterval(-300)).map(\.agentID) == ["hung"])
    // The same stall keeps its key; new activity makes a new one.
    let later = SubagentWatch.silences(agents, now: now.addingTimeInterval(180))
    #expect(later.first { $0.agentID == "hung" }?.key == silences[0].key)
    #expect(SubagentWatch.silences([agent("hung", quietFor: 400, now: now)], now: now)[0].key != silences[0].key)
}

@Test func subagentWatchMessageIsWrittenInBothLanguages() {
    let now = Date(timeIntervalSince1970: 100_000)
    let silences = SubagentWatch.silences([agent("a05", quietFor: 420, now: now, pending: [.init(id: "w", name: "Write")]),
                                           agent("b07", quietFor: 360, now: now)], now: now)
    let ru = SubagentWatch.message(silences, now: now, language: .russian)
    let en = SubagentWatch.message(silences, now: now, language: .english)
    #expect(ru.contains("Проверка Switchboard") && ru.contains("«Agent a05» (ID a05): нет активности 7 мин; ждёт результата: Write.")
            && ru.contains("«Agent b07» (ID b07): нет активности 6 мин.") && ru.contains("ничего не останавливал"))
    #expect(en.contains("Switchboard check") && en.contains("\"Agent a05\" (ID a05): no activity for 7 min; waiting for: Write.")
            && en.contains("\"Agent b07\" (ID b07): no activity for 6 min.") && en.contains("stopped and retried nothing"))
}

@Test @MainActor func deskModelMarksSilentSubagentsAndTellsTheIdleParentOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"),
                          summaryResources: nil, jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = Project(path: root.path)
    model.state.projects = [project]
    let chat = Chat(id: "parent", projectID: project.id, title: "Parent", model: "fixture")
    model.state.chats = [chat]
    let source = try #require(chat.nativeSession)
    let now = Date()

    // Busy parent: the sub-agent is marked, the message waits for a later pass.
    await model.receive(.init(session: source, payload: .started(turn: "turn")))
    await model.receive(.init(session: source, payload: .subagents([agent("hung", quietFor: 400, now: now),
                                                                    agent("fine", quietFor: 10, now: now, pending: [.init(id: "b", name: "Bash", timeout: 600)])])))
    model.connected = true; model.authenticated = true
    #expect(model.checkSubagents(now: now))
    #expect(model.stalledSubagents[chat.id] == ["hung"])
    #expect(model.queuedMessages.isEmpty)

    await model.receive(.init(session: source, payload: .completed(.init(id: "turn", status: .completed, hasError: false, error: nil,
        history: AgentHistoryTurn(id: "turn", items: [], startedAt: nil, completedAt: nil, duration: nil, isComplete: true)))))
    #expect(!model.isBusy(threadID: chat.id))
    #expect(model.checkSubagents(now: now.addingTimeInterval(180)))
    #expect(model.queuedMessages.count == 1)
    let message = try #require(model.queuedMessages.first)
    #expect(message.threadID == chat.id && message.id.hasPrefix(DeskModel.subagentCheckPrefix) && message.text.contains("(ID hung)") && !message.text.contains("(ID fine)"))

    // The same stall is reported once.
    model.state.queuedMessages = []
    #expect(model.checkSubagents(now: now.addingTimeInterval(360)))
    #expect(model.queuedMessages.isEmpty)

    // New activity clears the mark at once; a finished list ends the loop's work.
    await model.receive(.init(session: source, payload: .subagents([agent("hung", quietFor: 0, now: Date()), agent("fine", quietFor: 0, now: Date())])))
    #expect(model.stalledSubagents[chat.id] == nil)
    await model.receive(.init(session: source, payload: .subagents([agent("hung", quietFor: 0, now: now, status: .completed)])))
    #expect(!model.checkSubagents(now: now.addingTimeInterval(540)))
}
