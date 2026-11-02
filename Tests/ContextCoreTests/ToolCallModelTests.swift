import Foundation
import Testing
import AgentContract
@testable import ContextCore

// ACP-shaped transcript model (stage C, 2026-11-02): structured tool calls, plans, stop reasons, and stored data that
// predates them.

/// Item shapes as Switchboard stored them before tool calls were structured: a Claude session record's turn (call with
/// JSON input, capped result, reduced call, reduced result with exit code) and an app-store presentation item.
private let storedTurn = #"""
{"id":"84469237-5652-40A5-96BE-260A78B78F8D","completedAt":813747386.005851,"isComplete":false,"items":[
 {"showsAuthor":true,"showsCopyControl":true,"turnID":"84469237-5652-40A5-96BE-260A78B78F8D","text":"Run the checks","id":"user:84469237-5652-40A5-96BE-260A78B78F8D","kind":"user","agentName":"Claude"},
 {"showsAuthor":true,"showsCopyControl":true,"turnID":"84469237-5652-40A5-96BE-260A78B78F8D","text":"Edit\n{\n  \"file_path\" : \"/tmp/a.swift\",\n  \"new_string\" : \"b\",\n  \"old_string\" : \"a\"\n}","id":"toolu_01A","kind":"activity","agentName":"Claude"},
 {"showsAuthor":true,"showsCopyControl":true,"turnID":"84469237-5652-40A5-96BE-260A78B78F8D","text":"head\n… 10 bytes omitted …\ntail","id":"toolu_01A:result","kind":"activity","agentName":"Claude","fullLength":20000},
 {"reduced":true,"showsAuthor":true,"showsCopyControl":true,"turnID":"84469237-5652-40A5-96BE-260A78B78F8D","text":"Bash · Read the routine\n#activity tool=Bash target=\"Read the routine\" input=202 output=6614","id":"toolu_01B","kind":"activity","fullLength":202},
 {"showsAuthor":true,"turnID":"84469237-5652-40A5-96BE-260A78B78F8D","id":"toolu_01B:result","showsCopyControl":true,"fullLength":11812,"reduced":true,"kind":"activity","text":"--- title\n#activity output=11812 exit=0","exitCode":0},
 {"showsAuthor":true,"showsCopyControl":true,"text":"/bin/zsh -lc 'ls'","id":"call_9","kind":"activity","tool":"commandExecution","seconds":1.5}
]}
"""#

@Test func storedTranscriptItemsDecodeUnchangedWithoutStructuredFields() throws {
    let turn = try JSONDecoder().decode(AgentHistoryTurn.self, from: Data(storedTurn.utf8))
    #expect(turn.items.count == 6)
    #expect(turn.items.allSatisfy { $0.toolCall == nil && $0.plan == nil })
    #expect(turn.items[1].text.hasPrefix("Edit\n{"))
    #expect(turn.items[4].exitCode == 0 && turn.items[4].reduced == true)
    #expect(turn.items[5].tool == "commandExecution" && turn.items[5].seconds == 1.5)
    // Re-encoding adds no new keys, so older builds keep reading what this build writes for old items.
    let encoded = String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)
    #expect(!encoded.contains("toolCall") && !encoded.contains("\"plan\""))
    // The local snapshot round trip keeps them too.
    let snapshot = try LocalHistory.snapshot(conversation: ConversationID("chat"), source: .init(connection: .appClaude, nativeID: "s"), turns: [turn])
    let decoded = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(LocalHistory.items(decoded).map(\.id) == turn.items.map(\.id))
    #expect(LocalHistory.items(decoded).allSatisfy { $0.toolCall == nil })
}

@Test func toolCallRoundTripsAndDecodesUnknownValuesLeniently() throws {
    var item = TranscriptItem(id: "toolu_1", kind: "activity", text: "Edit\n{}")
    item.toolCall = AgentToolCall(id: "toolu_1", kind: .edit, status: .inProgress, title: "Edit a.swift",
                                  locations: [.init(path: "/p/a.swift", line: 3)],
                                  content: [.diff(.init(path: "/p/a.swift", oldText: "a", newText: "b", line: 3)),
                                            .terminal(.init(command: "ls", output: "x", exitCode: 1)), .text("note")],
                                  inputSummary: "a → b")
    let data = try JSONEncoder().encode(item)
    #expect(try JSONDecoder().decode(TranscriptItem.self, from: data) == item)

    // A newer build's kind, status and content type never break reading the history.
    let future = #"{"id":"c","kind":"teleport","status":"orbiting","title":"T","locations":[{"path":"/a"},{"nope":1}],"content":[{"type":"hologram","x":1},{"type":"text","text":"kept"}]}"#
    let call = try JSONDecoder().decode(AgentToolCall.self, from: Data(future.utf8))
    #expect(call.kind == .other && call.status == .completed)
    #expect(call.locations == [.init(path: "/a")])
    #expect(call.content == [.text("kept")])
}

@Test func laterItemWithTheSameIDReplacesTheCallInPlace() {
    var items = [TranscriptItem(id: "u", kind: "user", text: "go")]
    var call = TranscriptItem(id: "c1", kind: "activity", text: "ls")
    call.toolCall = .init(id: "c1", kind: .execute, status: .inProgress, title: "ls")
    TranscriptItem.merge(call, into: &items)
    TranscriptItem.merge(TranscriptItem(id: "a", kind: "assistant", text: "done"), into: &items)
    call.toolCall?.status = .completed
    TranscriptItem.merge(call, into: &items)
    #expect(items.map(\.id) == ["u", "c1", "a"])
    #expect(items[1].toolCall?.status == .completed)
}

@Test func planBecomesOneChecklistItemPerTurnThatUpdatesReplace() {
    let plan = AgentPlan(entries: [.init(content: "Read", status: .completed), .init(content: "Write", status: .inProgress, priority: .high),
                                   .init(content: "Test", status: .pending)])
    let item = plan.transcriptItem(turn: "t1", agentName: "Codex")
    #expect(item.id == "plan:t1" && item.kind == AgentPlan.itemKind && item.turnID == "t1" && item.plan == plan)
    #expect(item.text == "[x] Read\n[~] Write\n[ ] Test")
    #expect(plan.progress == (1, 3))
    var items = [TranscriptItem(id: "u", kind: "user", text: "go"), item, TranscriptItem(id: "a", kind: "assistant", text: "ok")]
    var next = plan; next.entries[1].status = .completed
    TranscriptItem.merge(next.transcriptItem(turn: "t1"), into: &items)
    #expect(items.map(\.id) == ["u", "plan:t1", "a"] && items[1].plan?.entries[1].status == .completed)
    // Unknown statuses and priorities from a newer build read as pending and medium.
    let entry = try? JSONDecoder().decode(AgentPlan.Entry.self, from: Data(#"{"content":"x","status":"paused","priority":"urgent"}"#.utf8))
    #expect(entry == .init(content: "x", status: .pending, priority: .medium))
}

@Test func plansAreCarriedIntoHistoryThatLacksThem() {
    var user = TranscriptItem(id: "u1", kind: "user", text: "go"); user.turnID = "t1"
    var call = TranscriptItem(id: "c1", kind: "activity", text: "ls"); call.turnID = "t1"
    let plan = AgentPlan(entries: [.init(content: "Step", status: .inProgress)]).transcriptItem(turn: "t1")
    var answer = TranscriptItem(id: "a1", kind: "assistant", text: "ok"); answer.turnID = "t1"
    var gone = AgentPlan(entries: [.init(content: "Old", status: .completed)]).transcriptItem(turn: "t0"); gone.turnID = "t0"
    let stored = [gone, user, call, plan, answer]
    // Engine history: same turn without the plan, item turn ids unset (Codex `thread/read`).
    let history = [AgentHistoryTurn(id: "t1", items: [TranscriptItem(id: "u1", kind: "user", text: "go"),
                                                     TranscriptItem(id: "c1", kind: "activity", text: "ls"),
                                                     TranscriptItem(id: "a1", kind: "assistant", text: "ok")],
                                    startedAt: nil, completedAt: nil, duration: nil)]
    let carried = AgentPlan.carry(from: stored, into: history)
    #expect(carried.map { $0.items.map(\.id) } == [["u1", "c1", "plan:t1", "a1"]])
    // Already present: unchanged; nothing to carry: the same turns.
    #expect(AgentPlan.carry(from: stored, into: carried).map { $0.items.map(\.id) } == [["u1", "c1", "plan:t1", "a1"]])
    #expect(AgentPlan.carry(from: [user, call], into: history).map { $0.items.map(\.id) } == [["u1", "c1", "a1"]])

    var flat = [user, call, answer]
    #expect(AgentPlan.carry(from: stored, into: &flat))
    #expect(flat.map(\.id) == ["u1", "c1", "plan:t1", "a1"])
}

@Test func structuredCallBodiesAreCappedAndDroppedOnArchive() {
    let long = String(repeating: "line of output\n", count: 2_000)
    var item = TranscriptItem(id: "c", kind: "activity", text: "Write\n{}")
    item.toolCall = .init(id: "c", kind: .edit, status: .completed, title: "Write a", locations: [.init(path: "/a")],
                          content: [.diff(.init(path: "/a", oldText: nil, newText: long)), .terminal(.init(command: "x", output: long))])
    let capped = ActivityRetention.cap(item)
    let diff = capped.toolCall?.diffs.first?.newText ?? ""
    #expect(diff.utf8.count <= ActivityRetention.contentBytes + 100 && diff.contains("…"))
    #expect((capped.toolCall?.terminal?.output.utf8.count ?? 0) <= ActivityRetention.contentBytes + 100)
    #expect(ActivityRetention.cap(capped) == capped)
    let reduced = ActivityRetention.reduce([capped])[0]
    #expect(reduced.reduced == true && reduced.toolCall?.content == [] && reduced.toolCall?.locations == [.init(path: "/a")])
    #expect(reduced.toolCall?.kind == .edit && reduced.toolCall?.title == "Write a")
}

@Test func turnCompletionCarriesAStopReason() {
    let turn = AgentHistoryTurn(id: "t", items: [], startedAt: nil, completedAt: nil, duration: nil)
    #expect(AgentTurnCompletion(id: "t", status: .completed, hasError: false, error: nil, history: turn).stopReason == .endTurn)
    #expect(AgentTurnCompletion(id: "t", status: .cancelled, hasError: false, error: nil, history: turn).stopReason == .cancelled)
    #expect(AgentTurnCompletion(id: "t", status: .failed, hasError: true, error: nil, history: turn,
                                usageLimit: .init(resetsAt: nil)).stopReason == .usageLimit)
    #expect(AgentTurnCompletion(id: "t", status: .uncertain, hasError: true, error: nil, history: turn).stopReason == nil)
    #expect(AgentTurnCompletion(id: "t", status: .completed, hasError: false, error: nil, history: turn, stopReason: .maxTokens).stopReason == .maxTokens)
}
