import Foundation
import Testing
import ContextCore
import AgentContract
@_spi(NativeProtocol) @testable import CodexAdapter

struct CodexSubagentTests {
    func frame(_ item: String, parent: String = "parent", method: String = "item/completed") throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data("{\"method\":\"\(method)\",\"params\":{\"threadId\":\"\(parent)\",\"item\":\(item)}}".utf8))
    }
    @Test func boundedHistoryDoesNotDuplicateOnRefresh() throws {
        var tracker = CodexSubagentTracker()
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"started"}"#))
        var items: [JSONValue] = []
        for i in 0..<160 {
            items.append(.object(["type": .string("agentMessage"), "id": .string("msg-\(i)"), "text": .string("Step \(i)")]))
        }
        let response: JSONValue = .object(["thread": .object(["id": .string("child"), "turns": .array([
            .object(["id": .string("turn"), "status": .string("inProgress"), "items": .array(items)])
        ])])])
        let events = tracker.history(response, child: "child")
        guard case .subagents(let agents) = events.last?.payload else { Issue.record("Missing steps"); return }
        #expect(agents[0].steps.count == 150)
        #expect(tracker.history(response, child: "child").isEmpty)
    }

    @Test func historyProvidesTaskAndReportWithoutFakeActivity() throws {
        var tracker = CodexSubagentTracker()
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"started"}"#))
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"child","agentRole":"reader","createdAt":100,"turns":[{"id":"turn","status":"completed","items":[{"type":"userMessage","id":"task","content":[{"text":"Review source"}]},{"type":"agentMessage","id":"answer","text":"Reviewed"}]}]}}"#.utf8))
        let events = tracker.history(response, child: "child")
        guard case .subagents(let agents) = events.last?.payload else { Issue.record("Missing history"); return }
        #expect(agents[0].prompt == "Review source")
        #expect(agents[0].report == "Reviewed")
        #expect(agents[0].type == "reader")
        #expect(agents[0].status == .completed)
        #expect(agents[0].startedAt == Date(timeIntervalSince1970: 100))
        #expect(tracker.historyIDs(parent: "parent").isEmpty)
        #expect(tracker.history(response, child: "child").isEmpty)
    }

    @Test func toolsIncludeInputsErrorsAndUsage() throws {
        var tracker = CodexSubagentTracker()
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"started"}"#))
        let call = try frame(#"{"type":"mcpToolCall","id":"call","server":"browser","tool":"read","arguments":{"url":"https://example.com"},"status":"inProgress"}"#, parent: "child", method: "item/started")
        _ = tracker.receive(call)
        let done = try frame(#"{"type":"mcpToolCall","id":"call","server":"browser","tool":"read","status":"failed","error":{"message":"Denied"}}"#, parent: "child")
        guard case .subagents(let agents) = tracker.receive(done)?.payload else { Issue.record("Missing error"); return }
        #expect(agents[0].steps.last?.isError == true)
        #expect(agents[0].steps.last?.text == "Denied")
        #expect(agents[0].pendingTools.isEmpty)
        #expect(agents[0].toolUses == 1)
        let usage = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"child","tokenUsage":{"total":{"totalTokens":123}}}}"#.utf8))
        guard case .subagents(let updated) = tracker.receive(usage)?.payload else { Issue.record("Missing usage"); return }
        #expect(updated[0].tokens == 123)
    }

    @Test func newParentTurnKeepsRunningAndDropsFinishedChildren() throws {
        var tracker = CodexSubagentTracker()
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"done","kind":"completed"}"#))
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"active","kind":"started"}"#))
        let start = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"method":"turn/started","params":{"threadId":"parent","turn":{"id":"new"}}}"#.utf8))
        guard case .subagents(let agents) = tracker.receive(start)?.payload else { Issue.record("Missing round reset"); return }
        #expect(agents.map(\.id) == ["active"])
    }

    @Test func childStepsStayWithTheirParent() throws {
        var tracker = CodexSubagentTracker()
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"started"}"#))
        let child = try frame(#"{"type":"commandExecution","id":"cmd","command":"rg files","status":"inProgress"}"#, parent: "child", method: "item/started")
        guard case .subagents(let started) = tracker.receive(child)?.payload else { Issue.record("Missing child tool"); return }
        #expect(started[0].steps.first?.text == "rg files")
        #expect(started[0].pendingTools.count == 1)
        let finished = try frame(#"{"type":"commandExecution","id":"cmd","command":"rg files","status":"completed","aggregatedOutput":"found","exitCode":0}"#, parent: "child")
        let received = tracker.receive(finished)
        let event = try #require(received)
        #expect(event.session?.nativeID == "parent")
        guard case .subagents(let agents) = event.payload else { Issue.record("Missing result"); return }
        #expect(agents[0].pendingTools.isEmpty)
        #expect(agents[0].steps.map(\.text) == ["rg files", "found"])
        #expect(tracker.receive(try frame(#"{"type":"agentMessage","id":"msg","text":"unrelated"}"#, parent: "other")) == nil)
        let history = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"child","turns":[{"id":"turn","items":[{"type":"agentMessage","id":"msg","text":"Reading code"}]}]}}"#.utf8))
        #expect(tracker.history(history, child: "other").isEmpty)
        #expect(tracker.history(history, child: "child").count == 1)
        #expect(tracker.history(history, child: "child").isEmpty)
    }
    @Test func readableNamesAndScopedStop() throws {
        #expect(CodexSubagentTracker.displayName("/root/check_subagent_tracker") == "check subagent tracker")
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"thread":{"id":"child","turns":[{"id":"old","status":"completed"},{"id":"active","status":"inProgress"}]}}"#.utf8))
        #expect(try CodexSubagentTracker.interruptTarget(response, child: "child") == "active")
        #expect(throws: (any Error).self) { try CodexSubagentTracker.interruptTarget(response, child: "other") }
        var tracker = CodexSubagentTracker()
        _ = tracker.receive(try frame(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"started"}"#))
        #expect(tracker.runningIDs(parent: "other").isEmpty)
        #expect(tracker.runningIDs(parent: "parent") == ["child"])
        _ = tracker.stopped("child", parent: "parent")
        #expect(tracker.runningIDs(parent: "parent").isEmpty)
    }
    @Test func activityLifecycleAndReset() throws {
        var tracker = CodexSubagentTracker()
        let start = try frame(#"{"type":"subAgentActivity","agentThreadId":"child","agentPath":"/root/research","kind":"started"}"#)
        guard case .subagents(let agents) = tracker.receive(start)?.payload else { Issue.record("Missing agents"); return }
        #expect(agents.first?.status == .running)
        #expect(agents.first?.title == "research")
        let done = try frame(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"completed"}"#)
        guard case .subagents(let finished) = tracker.receive(done)?.payload else { Issue.record("Missing completion"); return }
        #expect(finished.first?.status == .completed)
        #expect(tracker.reset().count == 1)
        #expect(tracker.reset().isEmpty)
    }
    @Test func toolCompletionDoesNotCompleteAgent() throws {
        var tracker = CodexSubagentTracker()
        let spawn = try frame(#"{"type":"collabAgentToolCall","tool":"spawnAgent","status":"completed","receiverThreadIds":["child"],"prompt":"Review routing","model":"gpt-6.1-sol","agentsStates":{"child":{"status":"running"}}}"#)
        guard case .subagents(let agents) = tracker.receive(spawn)?.payload else { Issue.record("Missing spawn"); return }
        #expect(agents.first?.status == .running)
        #expect(agents.first?.type == "gpt-6.1-sol")
        let done = try frame(#"{"type":"collabAgentToolCall","tool":"wait","agentsStates":{"child":{"status":"completed","message":"Reviewed"}}}"#)
        guard case .subagents(let finished) = tracker.receive(done)?.payload else { Issue.record("Missing report"); return }
        #expect(finished.first?.report == "Reviewed")
        #expect(finished.first?.status == .completed)
        #expect(tracker.receive(try frame(#"{"type":"agentMessage","text":"hello"}"#)) == nil)
    }
}

extension CodexSubagentTests {
@Test func codexChildHistoryAndStopUseTheOwningConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, sys
    calls = []
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method, p = m.get('method'), m.get('params', {})
        calls.append({'method':method, 'params':p})
        result = {}
        if method == 'initialize': result = {'userAgent':'fixture'}
        if method == 'test/spawn':
            print(json.dumps({'method':'item/completed','params':{'threadId':'parent','item':{'id':'spawn','type':'subAgentActivity','agentThreadId':'child','agentPath':'/root/research','kind':'started'}}}), flush=True)
        if method == 'thread/read':
            result = {'thread':{'id':p['threadId'],'turns':[{'id':'child-turn','status':'inProgress','items':[
                {'id':'message','type':'agentMessage','text':'Reading source'},
                {'id':'cmd','type':'commandExecution','command':'rg source','status':'completed','aggregatedOutput':'found','exitCode':0}
            ]}]}}
        if method == 'test/calls': result = calls
        print(json.dumps({'id':m['id'],'result':result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let transport = CodexConnection()
    let client = CodexClient(transport: transport)
    try await client.start(executable: executable, home: root)
    do {
        let steps = Task {
            for await event in client.events {
                if case .subagents(let agents) = event.payload,
                   let child = agents.first, child.steps.contains(where: { $0.kind == .result && $0.text == "found" }) {
                    return child
                }
            }
            throw CancellationError()
        }
        _ = try await transport.request("test/spawn")
        let child = try await withThrowingTaskGroup(of: AgentSubagent.self) { group in
            group.addTask { try await steps.value }
            group.addTask { try await Task.sleep(for: .seconds(8)); steps.cancel(); throw CancellationError() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(child.title == "research")
        #expect(child.steps.contains { $0.text == "Reading source" })
        try await client.stopSubagents("child", session: .init(connection: .originalCodex, nativeID: "parent"))
        let calls = try await transport.request("test/calls").array
        let interrupts = calls.filter { $0["method"].string == "turn/interrupt" }
        #expect(interrupts.count == 1)
        #expect(interrupts.first?["params"]["threadId"].string == "child")
        #expect(interrupts.first?["params"]["turnId"].string == "child-turn")
        await client.stop()
    } catch { await client.stop(); throw error }
}

}
