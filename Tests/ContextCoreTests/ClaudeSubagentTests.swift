import Foundation
import Testing
import AgentContract
@testable import ClaudeAdapter
@testable import ContextCore

private func frame(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

/// Frames as Claude Code 2.1.292 reports two background sub-agents, one of which starts its own background command.
@Test func claudeSubagentTrackerFollowsTheCliTaskEvents() throws {
    var tracker = ClaudeSubagentTracker()
    let start = Date(timeIntervalSince1970: 1000)
    for json in [
        #"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"call-a","description":"Agent A","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"Run A"}"#,
        #"{"type":"system","subtype":"task_started","task_id":"b1","tool_use_id":"call-b","description":"Agent B","subagent_type":"Explore","is_backgrounded":false,"task_type":"local_agent","prompt":"Run B"}"#,
        #"{"type":"assistant","parent_tool_use_id":"call-a","message":{"id":"m1","content":[{"type":"thinking","thinking":""},{"type":"tool_use","id":"bash-a","name":"Bash","input":{"command":"sleep 8; echo alpha","description":"Run sleep 8\nthen echo"}}]}}"#,
        #"{"type":"system","subtype":"task_progress","task_id":"a1","description":"Running Run sleep 8 then echo alpha","usage":{"total_tokens":11416,"tool_uses":1}}"#,
        // A command owned by the sub-agent is not a sub-agent itself.
        #"{"type":"system","subtype":"task_started","task_id":"bash1","tool_use_id":"bash-a","description":"Run sleep","task_type":"local_bash","parent_task_id":"a1"}"#,
        #"{"type":"user","parent_tool_use_id":"call-a","message":{"content":[{"type":"tool_result","tool_use_id":"bash-a","content":"alpha"}]}}"#,
        #"{"type":"user","parent_tool_use_id":"call-b","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":[{"type":"text","text":"Blocked"}],"is_error":true}]}}"#,
        #"{"type":"assistant","parent_tool_use_id":"unknown","message":{"id":"m9","content":[{"type":"text","text":"ignored"}]}}"#,
        #"{"type":"assistant","message":{"id":"main","content":[{"type":"text","text":"main agent"}]}}"#,
    ] { _ = tracker.observe(try frame(json), now: start) }
    #expect(tracker.agents.map(\.id) == ["a1", "b1"])
    var a = tracker.agents[0]
    #expect(a.title == "Agent A" && a.type == "general-purpose" && a.background && a.prompt == "Run A" && a.status == .running)
    #expect(a.activity == "Running Run sleep 8 then echo alpha" && a.tokens == 11416 && a.toolUses == 1)
    #expect(a.steps.map(\.text) == ["Bash: Run sleep 8 then echo", "alpha"])
    #expect(tracker.agents[1].steps.first?.isError == true && !tracker.agents[1].background)

    let changed1 = tracker.observe(try frame(#"{"type":"system","subtype":"task_updated","task_id":"b1","patch":{"status":"killed"}}"#), now: start.addingTimeInterval(5))
    #expect(changed1)
    let changed2 = tracker.observe(try frame(#"{"type":"system","subtype":"task_notification","task_id":"a1","status":"completed","summary":"alpha done","usage":{"total_tokens":12057,"tool_uses":2}}"#), now: start.addingTimeInterval(9))
    #expect(changed2)
    a = tracker.agents[0]
    #expect(a.status == .completed && a.report == "alpha done" && a.activity == nil && a.endedAt == start.addingTimeInterval(9) && a.toolUses == 2)
    #expect(tracker.agents[1].status == .stopped)
    // A background sub-agent resumes when its own background work finishes, keeping its steps.
    let changed3 = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"call-a","description":"Agent A","task_type":"local_agent","prompt":"<task-notification>"}"#), now: start)
    #expect(changed3)
    #expect(tracker.agents[0].status == .running && tracker.agents[0].endedAt == nil && tracker.agents[0].steps.count == 2 && tracker.agents[0].prompt == "Run A")
    // The CLI going away stops what still runs; a new user message drops finished ones.
    let stopped = tracker.stopRunning(now: start), stoppedAgain = tracker.stopRunning()
    #expect(stopped && !stoppedAgain && tracker.agents.allSatisfy { $0.status == .stopped })
    let cleared = tracker.clearFinished()
    #expect(cleared && tracker.agents.isEmpty)
    let changed4 = tracker.observe(try frame(#"{"type":"assistant","parent_tool_use_id":"call-a","message":{"id":"late","content":[{"type":"text","text":"late"}]}}"#))
    #expect(!changed4)
}

@Test func claudeSubagentTrackerBoundsItsHistory() throws {
    var tracker = ClaudeSubagentTracker()
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"a","tool_use_id":"c","description":"Long","task_type":"local_agent"}"#))
    let long = String(repeating: "x", count: 5000)
    for index in 0..<(ClaudeSubagentTracker.stepLimit + 10) {
        _ = tracker.observe(.object(["type": .string("assistant"), "parent_tool_use_id": .string("c"), "message": .object([
            "id": .string("m\(index)"), "content": .array([.object(["type": .string("text"), "text": .string(long)])])])]))
    }
    let agent = tracker.agents[0]
    #expect(agent.steps.count == ClaudeSubagentTracker.stepLimit && agent.droppedSteps == 10)
    #expect(agent.steps.first?.id == "m10:text" && agent.steps.allSatisfy { $0.text.count == ClaudeSubagentTracker.textLimit })
    for index in 0..<(ClaudeSubagentTracker.agentLimit + 3) {
        _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"t\#(index)","tool_use_id":"x\#(index)","description":"d","task_type":"local_agent"}"#))
        _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_notification","task_id":"t\#(index)","status":"completed"}"#))
    }
    #expect(tracker.agents.count == ClaudeSubagentTracker.agentLimit && tracker.agents.contains { $0.id == "a" })
}

@Test func claudeFullAccessChatsAreToldToUseResultsAsSubagentsFinish() throws {
    func prompt(_ access: AccessMode) throws -> String {
        let args = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: access, model: "", effort: nil)
        return args[args.firstIndex(of: "--append-system-prompt")! + 1]
    }
    #expect(try prompt(.fullAccess).contains(ClaudeIntegration.delegationInstructions()))
    #expect(try !prompt(.standard).contains("run_in_background"))
    for language in [AppLanguage.russian, .english] {
        #expect(ClaudeIntegration.delegationInstructions(language: language).contains("run_in_background: true"))
    }
    #expect(ClaudeIntegration.delegationInstructions(language: .russian).hasPrefix("Подагенты в Switchboard"))
    #expect(ClaudeIntegration.delegationInstructions(language: .english).hasPrefix("Sub-agents in Switchboard"))
    #expect(ClaudeIntegration.delegationInstructions(language: .russian).contains("не больше 2 подагентов"))
    #expect(ClaudeIntegration.delegationInstructions(language: .english).contains("at most 2 sub-agents"))
}

/// Frames as Claude Code 2.1.292 reports a dev server, a foreground test run moved to the background and a sub-agent's own command.
@Test func claudeBackgroundTaskTrackerFollowsCommandsButNotSubagents() throws {
    var tracker = ClaudeBackgroundTaskTracker()
    let start = Date(timeIntervalSince1970: 1000)
    for json in [
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"call-dev","name":"Bash","input":{"command":"npm run dev\n  --port 3000","run_in_background":true}},{"type":"tool_use","id":"call-test","name":"Bash","input":{"command":"swift test"}}]}}"#,
        #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"dev","task_type":"local_bash","description":"Dev server"},{"task_id":"a1","task_type":"local_agent","description":"Agent"}]}"#,
        #"{"type":"system","subtype":"task_started","task_id":"dev","tool_use_id":"call-dev","description":"Dev server","task_type":"local_bash","is_backgrounded":true}"#,
        #"{"type":"system","subtype":"task_started","task_id":"a1","description":"Agent","task_type":"local_agent","subagent_type":"general-purpose"}"#,
        // A foreground command is not listed until it moves to the background.
        #"{"type":"system","subtype":"task_started","task_id":"test","tool_use_id":"call-test","description":"Run tests","task_type":"local_bash","is_backgrounded":false}"#,
    ] { _ = tracker.observe(try frame(json), now: start) }
    #expect(tracker.tasks.map(\.id) == ["dev"])
    #expect(tracker.tasks[0].command == "npm run dev --port 3000" && tracker.tasks[0].kind == .shell && tracker.tasks[0].status == .running)
    let moved = tracker.observe(try frame(#"{"type":"system","subtype":"task_updated","task_id":"test","patch":{"is_backgrounded":true}}"#), now: start)
    #expect(moved && tracker.tasks.map(\.id) == ["dev", "test"] && tracker.tasks[1].command == "swift test")
    // A sub-agent's command names its parent, which then waits for it.
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"sub","description":"UI tests","task_type":"local_bash","is_backgrounded":true,"parent_task_id":"a1"}"#), now: start)
    #expect(tracker.waitingParents == ["a1"])
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_notification","task_id":"sub","status":"failed","summary":"exit code 1"}"#), now: start.addingTimeInterval(4))
    let sub = try #require(tracker.task("sub"))
    #expect(sub.status == .failed && sub.report == "exit code 1" && sub.endedAt == start.addingTimeInterval(4) && tracker.waitingParents.isEmpty)
    // A task that leaves the level without a notification has ended.
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"test","task_type":"local_bash","description":"Run tests"}]}"#), now: start)
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#), now: start)
    #expect(tracker.task("dev")?.status == .completed && tracker.task("test")?.status == .completed)
    let cleared = tracker.clearFinished()
    #expect(cleared && tracker.tasks.isEmpty)
    // The CLI going away ends what still runs.
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"watch","description":"Watch logs","task_type":"monitor_mcp"}"#), now: start)
    let stopped = tracker.stopRunning(now: start), stoppedAgain = tracker.stopRunning()
    #expect(tracker.tasks.first?.kind == .monitor && stopped && !stoppedAgain && tracker.tasks.first?.status == .stopped)
}

@Test func claudeTaskOutputIsPlainText() throws {
    #expect(ClaudeBackgroundTaskTracker.plain("\u{1B}[1;32mok\u{1B}[0m\r\n\u{1B}]0;title\u{07}next 1/3\rnext 3/3\n") == "ok\nnext 3/3\n")
    let output = ClaudeBackgroundTaskTracker.output(try frame(#"{"output":"tail","total_bytes":9000,"truncated":true}"#))
    #expect(output == .init(text: "tail", totalBytes: 9000, truncated: true))
    #expect(ClaudeBackgroundTaskTracker.output(try frame(#"{"total_bytes":0}"#)) == nil)
}

@Test func claudeSubagentWaitingForItsCommandsStaysAfterANewMessage() throws {
    var tracker = ClaudeSubagentTracker()
    for json in [
        #"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"call-a","description":"UI agent","task_type":"local_agent","is_backgrounded":true}"#,
        #"{"type":"system","subtype":"task_started","task_id":"a2","tool_use_id":"call-b","description":"Done agent","task_type":"local_agent","is_backgrounded":true}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"a1","status":"completed","summary":"waiting for tests"}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"a2","status":"completed","summary":"done"}"#,
    ] { _ = tracker.observe(try frame(json)) }
    let cleared = tracker.clearFinished(keeping: ["a1"])
    #expect(cleared && tracker.agents.map(\.id) == ["a1"])
    // Its steps still land in its row once it resumes.
    _ = tracker.observe(try frame(#"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"call-a","description":"UI agent","task_type":"local_agent"}"#))
    let changed = tracker.observe(try frame(#"{"type":"assistant","parent_tool_use_id":"call-a","message":{"id":"r","content":[{"type":"text","text":"tests passed"}]}}"#))
    #expect(changed && tracker.agents[0].status == .running && tracker.agents[0].steps.last?.text == "tests passed")
}
