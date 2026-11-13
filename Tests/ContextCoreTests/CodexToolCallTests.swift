import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import CodexAdapter

// Codex 0.160.0 calls, plans and stop reasons in the ACP-shaped model (stage C, 2026-11-02). Item and notification
// shapes follow `codex app-server generate-json-schema --experimental` of 0.160.0 (ThreadItem, FileUpdateChange,
// PatchChangeKind, CommandAction, WebSearchAction, TurnPlanUpdatedNotification).

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

private func itemEvent(_ method: String, _ item: String) throws -> TranscriptItem? {
    let raw = try json(#"{"method":"\#(method)","params":{"threadId":"thread-1","turnId":"turn-1","item":\#(item)}}"#)
    guard case .item(let value) = CodexEventDecoder.notification(raw)?.payload else { return nil }
    return value
}

@Test func codexCommandIsAnExecuteCallWhoseStatusFollowsTheItem() throws {
    func command(_ status: String, exit: String = "null") -> String {
        #"{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc 'swift build'","cwd":"/p","processId":null,"source":"agent","status":"\#(status)","commandActions":[{"type":"unknown","command":"swift build"}],"aggregatedOutput":null,"exitCode":\#(exit),"durationMs":null}"#
    }
    let started = try #require(try itemEvent("item/started", command("inProgress")))
    let call = try #require(started.toolCall)
    #expect(call.id == "call_1" && call.kind == .execute && call.status == .inProgress)
    #expect(call.title == "/bin/zsh -lc 'swift build'" && call.terminal?.command == call.title)
    #expect(started.tool == ActivityDetail.codexCommandTool && started.text == call.title)
    #expect(try itemEvent("item/completed", command("completed", exit: "0"))?.toolCall?.status == .completed)
    #expect(try itemEvent("item/completed", command("completed", exit: "0"))?.toolCall?.terminal?.exitCode == 0)
    #expect(try itemEvent("item/completed", command("failed", exit: "2"))?.toolCall?.status == .failed)
    #expect(try itemEvent("item/completed", command("declined"))?.toolCall?.status == .rejected)
}

@Test func codexCommandsParsedAsReadsOrSearchesNameTheirFiles() throws {
    let read = #"{"type":"commandExecution","id":"c2","command":"sed -n 1,40p Sources/A.swift","cwd":"/p","status":"completed","commandActions":[{"type":"read","command":"sed -n 1,40p Sources/A.swift","name":"A.swift","path":"Sources/A.swift"}],"aggregatedOutput":"x","exitCode":0,"durationMs":3}"#
    let call = try #require(try itemEvent("item/completed", read)?.toolCall)
    #expect(call.kind == .read && call.locations == [.init(path: "/p/Sources/A.swift")])
    let search = #"{"type":"commandExecution","id":"c3","command":"rg -n Plan Sources","cwd":"/p","status":"completed","commandActions":[{"type":"search","command":"rg -n Plan Sources","query":"Plan","path":"Sources"},{"type":"listFiles","command":"ls","path":null}],"aggregatedOutput":"","exitCode":0,"durationMs":1}"#
    let found = try #require(try itemEvent("item/completed", search)?.toolCall)
    #expect(found.kind == .search && found.locations == [.init(path: "/p/Sources")] && found.inputSummary == "Plan")
}

@Test func codexFileChangeCarriesPerFileDiffs() throws {
    let item = #"""
    {"type":"fileChange","id":"fc_1","status":"completed","changes":[
     {"path":"/p/A.swift","kind":{"type":"update","move_path":null},"diff":"@@ -3,3 +3,3 @@\n let a = 1\n-let b = 2\n+let b = 3\n let c = 4\n@@ -20,2 +20,3 @@\n x\n+y\n z\n"},
     {"path":"/p/New.swift","kind":{"type":"add"},"diff":"line 1\nline 2\n"},
     {"path":"/p/Old.swift","kind":{"type":"delete"},"diff":"gone\n"},
     {"path":"/p/From.swift","kind":{"type":"update","move_path":"/p/To.swift"},"diff":"@@ -1 +1 @@\n-a\n+b\n"}
    ]}
    """#
    let transcript = try #require(try itemEvent("item/completed", item))
    let call = try #require(transcript.toolCall)
    #expect(call.kind == .edit && call.status == .completed)
    #expect(call.title == L10n.text("Изменение файлов: 4", "Edit 4 files"))
    #expect(call.locations == [.init(path: "/p/A.swift", line: 3), .init(path: "/p/New.swift"), .init(path: "/p/Old.swift"), .init(path: "/p/To.swift", line: 1)])
    let diffs = call.diffs
    #expect(diffs.count == 5)
    #expect(diffs[0] == .init(path: "/p/A.swift", oldText: "let a = 1\nlet b = 2\nlet c = 4", newText: "let a = 1\nlet b = 3\nlet c = 4", line: 3))
    #expect(diffs[1] == .init(path: "/p/A.swift", oldText: "x\nz", newText: "x\ny\nz", line: 20))
    #expect(diffs[2].path == "/p/New.swift" && diffs[2].oldText == nil && diffs[2].newText == "line 1\nline 2\n")
    #expect(diffs[3] == .init(path: "/p/Old.swift", oldText: "gone\n", newText: ""))
    #expect(diffs[4].path == "/p/To.swift" && diffs[4].oldText == "a" && diffs[4].newText == "b")
    // The old text-only row is kept for readers that know only text.
    #expect(transcript.text == L10n.text("Изменение файлов · completed", "File changes · completed"))

    let single = #"{"type":"fileChange","id":"fc_2","status":"inProgress","changes":[{"path":"/p/A.swift","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1 @@\n-a\n+b"}]}"#
    let one = try #require(try itemEvent("item/started", single)?.toolCall)
    #expect(one.kind == .edit && one.status == .inProgress && one.title == L10n.text("Изменение A.swift", "Edit A.swift"))
    let moved = #"{"type":"fileChange","id":"fc_3","status":"declined","changes":[{"path":"/p/A.swift","kind":{"type":"delete"},"diff":"a"}]}"#
    let deleted = try #require(try itemEvent("item/completed", moved)?.toolCall)
    #expect(deleted.kind == .delete && deleted.status == .rejected)
}

@Test func codexMcpWebSearchAndOtherCallsAreStructured() throws {
    let mcp = #"{"type":"mcpToolCall","id":"m1","server":"switchboard_browser","tool":"browser_open","status":"completed","arguments":{"url":"https://example.com"},"result":{"content":[{"type":"text","text":"opened"}]},"error":null,"durationMs":10}"#
    let call = try #require(try itemEvent("item/completed", mcp)?.toolCall)
    #expect(call.kind == .other && call.title == "switchboard_browser · browser_open" && call.content == [.text("opened")])
    #expect(call.inputSummary == #"{"url":"https://example.com"}"#)
    let failed = #"{"type":"mcpToolCall","id":"m2","server":"s","tool":"t","status":"failed","arguments":{},"result":null,"error":{"message":"boom"},"durationMs":null}"#
    let failure = try #require(try itemEvent("item/completed", failed)?.toolCall)
    #expect(failure.status == .failed && failure.content == [.text("boom")] && failure.inputSummary == nil)

    let search = #"{"type":"webSearch","id":"w1","query":"swift testing","action":{"type":"search","query":"swift testing","queries":null},"results":null}"#
    let web = try #require(try itemEvent("item/completed", search))
    #expect(web.kind == "activity" && web.toolCall?.kind == .fetch && web.toolCall?.title == ToolCallText.webSearch("swift testing"))
    let open = #"{"type":"webSearch","id":"w2","query":"","action":{"type":"openPage","url":"https://swift.org"},"results":null}"#
    #expect(try itemEvent("item/completed", open)?.toolCall?.title == ToolCallText.fetch("https://swift.org"))
    let image = #"{"type":"imageView","id":"i1","path":"/p/shot.png"}"#
    #expect(try itemEvent("item/completed", image)?.toolCall == .init(id: "i1", kind: .read, status: .completed, title: ToolCallText.read("/p/shot.png"), locations: [.init(path: "/p/shot.png")]))
    let dynamic = #"{"type":"dynamicToolCall","id":"d1","tool":"lookup","namespace":null,"status":"completed","arguments":null,"success":false,"contentItems":null,"durationMs":null}"#
    #expect(try itemEvent("item/completed", dynamic)?.toolCall?.status == .failed)
    // Thread history decodes the same structure.
    let turn = try json(#"{"id":"turn-1","status":"completed","items":[\#(mcp),\#(search)],"startedAt":null,"completedAt":null,"durationMs":null}"#)
    #expect(AgentHistoryTurn(turn).items.compactMap(\.toolCall).map(\.id) == ["m1", "w1"])
}

@Test func codexPlanUpdateIsTheWholePlan() throws {
    let raw = try json(#"{"method":"turn/plan/updated","params":{"threadId":"thread-1","turnId":"turn-1","explanation":"  Fix it  ","plan":[{"step":"Read","status":"completed"},{"step":"Change","status":"inProgress"},{"step":"Test","status":"pending"}]}}"#)
    let event = try #require(CodexEventDecoder.notification(raw))
    guard case .plan(let turn, let plan) = event.payload else { Issue.record("no plan"); return }
    #expect(event.session?.nativeID == "thread-1" && turn == "turn-1")
    #expect(plan == AgentPlan(entries: [.init(content: "Read", status: .completed), .init(content: "Change", status: .inProgress),
                                        .init(content: "Test", status: .pending)], explanation: "Fix it"))
    // Without a thread or a turn the update is dropped, like other session-bound notifications.
    #expect(CodexEventDecoder.notification(try json(#"{"method":"turn/plan/updated","params":{"threadId":"","turnId":"t","plan":[]}}"#)) == nil)
    #expect(CodexEventDecoder.notification(try json(#"{"method":"turn/plan/updated","params":{"threadId":"x","plan":[]}}"#)) == nil)
    #expect(CodexProtocolSurface.drift(raw).isEmpty)
}

@Test func codexTurnCompletionNamesItsStopReason() throws {
    func reason(_ turn: String) throws -> AgentStopReason? {
        let raw = try json(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":\#(turn)}}"#)
        guard case .completed(let completion) = CodexEventDecoder.notification(raw)?.payload else { return nil }
        return completion.stopReason
    }
    #expect(try reason(#"{"id":"t","status":"completed","error":null,"items":[]}"#) == .endTurn)
    #expect(try reason(#"{"id":"t","status":"interrupted","error":null,"items":[]}"#) == .cancelled)
    #expect(try reason(#"{"id":"t","status":"failed","error":{"message":"limit","codexErrorInfo":"usageLimitExceeded"},"items":[]}"#) == .usageLimit)
    #expect(try reason(#"{"id":"t","status":"failed","error":{"message":"long","codexErrorInfo":"contextWindowExceeded"},"items":[]}"#) == .maxTokens)
    #expect(try reason(#"{"id":"t","status":"failed","error":{"message":"x","codexErrorInfo":"other"},"items":[]}"#) == .failed)
}

@Test func modelAndEffortBecomeConfigOptions() {
    let models = [AgentModelInfo(id: "gpt-5.5", displayName: "GPT-5.5", isDefault: true, defaultEffort: "medium", efforts: ["low", "medium", "high"])]
    let options = AgentConfigOption.modelAndEffort(models: models, model: "gpt-5.5", effort: "high")
    #expect(options.map(\.id) == ["model", "effort"] && options.map(\.category) == [.model, .thoughtLevel])
    #expect(options[0].kind == .select([.init(id: "gpt-5.5", name: "GPT-5.5")]) && options[0].current == "gpt-5.5")
    #expect(options[1].current == "high")
    if case .select(let values) = options[1].kind { #expect(values.map(\.id) == ["low", "medium", "high"]) } else { Issue.record("effort is a select") }
    // An unknown model is kept as its own value; without efforts there is no effort option.
    let unknown = AgentConfigOption.modelAndEffort(models: [], model: "custom", effort: nil)
    #expect(unknown.count == 1 && unknown[0].kind == .select([.init(id: "custom", name: "custom")]))
}

@Test func unifiedDiffHunksAndLineDiff() {
    #expect(AgentToolCall.Diff.hunks(unifiedDiff: "no hunks here", path: "/a") == nil)
    let hunks = AgentToolCall.Diff.hunks(unifiedDiff: "--- a/x\n+++ b/x\n@@ -5,2 +7,2 @@ func f()\n-old\n+new\n same\n\\ No newline at end of file", path: "/x")
    #expect(hunks == [.init(path: "/x", oldText: "old\nsame", newText: "new\nsame", line: 7)])
    typealias Line = ToolCallDiffLines.Line
    #expect(ToolCallDiffLines.lines(old: "a\nb\nc", new: "a\nB\nc") == [Line(.context, "a"), Line(.removed, "b"), Line(.added, "B"), Line(.context, "c")])
    #expect(ToolCallDiffLines.lines(old: nil, new: "x\ny\n") == [Line(.added, "x"), Line(.added, "y")])
    #expect(ToolCallDiffLines.lines(old: "x", new: "") == [Line(.removed, "x")])
    let big = (0..<700).map(String.init).joined(separator: "\n")
    let lines = ToolCallDiffLines.lines(old: big, new: big + "\nz")
    #expect(lines.count == 1401 && lines.first?.sign == .removed && lines.last == Line(.added, "z"))
}

@Test func codexCollaborationUsesStructuredChipsDuringExecution() throws {
    let prompt = "Review routing\nKeep the existing permissions"
    let raw = JSONValue.object(["type": .string("collabAgentToolCall"), "id": .string("agent-call"),
                               "tool": .string("spawnAgent"), "status": .string("inProgress"),
                               "prompt": .string(prompt)])
    let started = try #require(CodexDecoding.transcriptItem(raw))
    let call = try #require(started.toolCall)
    #expect(started.kind == "activity")
    #expect(call.kind == .think && call.status == .inProgress)
    #expect(call.inputSummary?.contains("\n") == false)
    #expect(call.content == [.text(prompt)])
    let expected: [String: AgentToolCall.Status] = ["completed": .completed, "failed": .failed, "interrupted": .cancelled]
    for (status, mapped) in expected {
        var finished = raw.object
        finished["status"] = .string(status)
        #expect(CodexDecoding.transcriptItem(.object(finished))?.toolCall?.status == mapped)
    }
    var follow = raw.object
    follow["tool"] = .string("followupTask")
    #expect(CodexDecoding.transcriptItem(.object(follow))?.toolCall?.title == L10n.text("Новое задание подагенту", "Follow-up task for sub-agent"))
}
