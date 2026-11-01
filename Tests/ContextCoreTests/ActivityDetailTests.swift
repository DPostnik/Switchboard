import AppKit
import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import CodexAdapter
@testable import ClaudeAdapter
@testable import ContextTranscript

// Detailed activity (AUD-007): thinking rows, command rows with exit codes and output, their retention.

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// `ThreadItem` "commandExecution" as Codex 0.160.0 sends it (`codex app-server generate-ts`, v2/ThreadItem.ts).
private func codexCommand(status: String, exitCode: String = "null", output: String = "null", duration: String = "null") -> String {
    #"{"type":"commandExecution","id":"call_7","pluginId":null,"scriptPath":null,"command":"/bin/zsh -lc 'swift test --filter Queue'","cwd":"/Users/me/project","processId":"4182","source":"agent","status":"\#(status)","commandActions":[{"type":"unknown","command":"swift test --filter Queue"}],"aggregatedOutput":\#(output),"exitCode":\#(exitCode),"durationMs":\#(duration)}"#
}

private func notification(_ method: String, item: String) throws -> JSONValue {
    try json(#"{"method":"\#(method)","params":{"threadId":"thread-1","turnId":"turn-1","item":\#(item)}}"#)
}

@Test func codexCommandDecodesCallAndResultWithExitCodeOutputAndDuration() throws {
    // Started: only the call, marked as a command; no result yet.
    let started = try notification("item/started", item: codexCommand(status: "inProgress"))
    guard case .item(let call) = try #require(CodexEventDecoder.notification(started)).payload else { Issue.record("no call"); return }
    #expect(call.id == "call_7" && call.kind == "activity" && call.tool == ActivityDetail.codexCommandTool)
    #expect(call.text == "/bin/zsh -lc 'swift test --filter Queue'")
    #expect(CodexEventDecoder.commandResult(started) == nil)
    // Completed with a failing exit: the call again, then its result.
    let failed = try notification("item/completed", item: codexCommand(status: "failed", exitCode: "1", output: #""error: no tests matched\n""#, duration: "2300"))
    let event = try #require(CodexEventDecoder.commandResult(failed))
    #expect(event.session == AgentSessionReference(connection: .originalCodex, nativeID: "thread-1"))
    guard case .item(let result) = event.payload else { Issue.record("no result"); return }
    #expect(result.id == "call_7:result" && result.kind == "activity" && result.turnID == "turn-1")
    #expect(result.text == "error: no tests matched\n" && result.exitCode == 1 && result.failed == nil && result.seconds == 2.3)
    #expect(ActivityDetail.outcome(result) == .exit(1))
    // Success, decline and a failure without an exit code.
    let ok = try #require(CodexDecoding.commandResult(try json(codexCommand(status: "completed", exitCode: "0", output: #""""#, duration: "40"))))
    #expect(ok.exitCode == 0 && ok.text.isEmpty && ActivityDetail.outcome(ok) == .succeeded)
    let declined = try #require(CodexDecoding.commandResult(try json(codexCommand(status: "declined"))))
    #expect(declined.failed == true && declined.exitCode == nil && declined.text == L10n.text("Команда отклонена", "Command declined"))
    #expect(ActivityDetail.outcome(declined) == .failed)
    let lost = try #require(CodexDecoding.commandResult(try json(codexCommand(status: "failed"))))
    #expect(lost.failed == true && ActivityDetail.outcome(lost) == .failed)
    #expect(CodexDecoding.commandResult(try json(codexCommand(status: "future"))) == nil)
    // History (`thread/read` turns) carries the result item after its call.
    let turn = try json(#"{"id":"turn-1","status":"completed","items":[\#(codexCommand(status: "completed", exitCode: "0", output: #""ok\n""#, duration: "12"))]}"#)
    #expect(AgentHistoryTurn(turn).items.map(\.id) == ["call_7", "call_7:result"])
}

/// `ThreadItem` "reasoning": `summary` and `content` are string arrays; deltas name the part by index.
@Test func codexReasoningBecomesThinkingAndStreamsThrottled() throws {
    let completed = try notification("item/completed", item: #"{"type":"reasoning","id":"rs_1","summary":["**Inspecting the queue**\n\nI need to read DeskModel first.","Then the tests."],"content":[]}"#)
    guard case .item(let thinking) = try #require(CodexEventDecoder.notification(completed)).payload else { Issue.record("no thinking"); return }
    #expect(thinking.kind == ActivityDetail.thinkingKind && thinking.id == "rs_1" && thinking.turnID == "turn-1")
    #expect(thinking.text == "**Inspecting the queue**\n\nI need to read DeskModel first.\n\nThen the tests.")
    #expect(thinking.seconds == nil)
    // Raw content when there is no summary; nothing when both are empty (encrypted reasoning only).
    #expect(CodexDecoding.transcriptItem(try json(#"{"type":"reasoning","id":"rs_2","summary":[],"content":["raw step"]}"#))?.text == "raw step")
    #expect(CodexDecoding.transcriptItem(try json(#"{"type":"reasoning","id":"rs_3","summary":[" "],"content":[]}"#)) == nil)
    #expect(CodexEventDecoder.notification(try notification("item/started", item: #"{"type":"reasoning","id":"rs_1","summary":[],"content":[]}"#)) == nil)

    var stream = CodexReasoningStream()
    let start = Date(timeIntervalSince1970: 1_000)
    func delta(_ text: String, index: Int, method: String = "item/reasoning/summaryTextDelta") throws -> JSONValue {
        let key = method.hasSuffix("summaryTextDelta") ? "summaryIndex" : "contentIndex"
        return try json(#"{"method":"\#(method)","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"rs_9","delta":"\#(text)","\#(key)":\#(index)}}"#)
    }
    let first = try #require(stream.receive(try delta("Reading ", index: 0), at: start))
    guard case .item(let live) = first.payload else { Issue.record("no live item"); return }
    #expect(live.id == "rs_9" && live.kind == ActivityDetail.thinkingKind && live.text == "Reading" && live.turnID == "turn-1")
    // Within the interval the text is collected but not published.
    #expect(stream.receive(try delta("files", index: 0), at: start.addingTimeInterval(0.1)) == nil)
    #expect(stream.receive(try delta("Next part", index: 1), at: start.addingTimeInterval(0.2)) == nil)
    let later = try #require(stream.receive(try delta(".", index: 1), at: start.addingTimeInterval(0.5)))
    guard case .item(let joined) = later.payload else { Issue.record("no update"); return }
    #expect(joined.text == "Reading files\n\nNext part.")
    // The completed item ends the stream; later deltas start from scratch.
    #expect(stream.receive(try json(#"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"reasoning","id":"rs_9","summary":[],"content":[]}}}"#), at: start) == nil)
    guard case .item(let fresh) = try #require(stream.receive(try delta("again", index: 0), at: start.addingTimeInterval(1))).payload else { return }
    #expect(fresh.text == "again")
}

@Test func claudeThinkingCaptureStreamsMeasuresAndSkipsRedactedBlocks() {
    var capture = ClaudeThinkingCapture(turn: "turn")
    let start = Date(timeIntervalSince1970: 2_000)
    capture.start(message: "msg_1", index: 0, at: start)
    #expect(capture.delta("", index: 0, at: start) == nil)
    let first = capture.delta("Сначала изучу ", index: 0, at: start)
    #expect(first?.id == "thinking:msg_1" && first?.kind == ActivityDetail.thinkingKind && first?.text == "Сначала изучу ")
    #expect(capture.delta("тесты.", index: 0, at: start.addingTimeInterval(0.1)) == nil)
    #expect(capture.delta("other block", index: 3, at: start.addingTimeInterval(0.5)) == nil)
    let stopped = capture.stop(index: 0, at: start.addingTimeInterval(12))
    #expect(stopped?.text == "Сначала изучу тесты." && stopped?.seconds == 12)
    // The complete message repeats the streamed text: nothing new to publish.
    #expect(capture.message("msg_1", thinking: "Сначала изучу тесты.") == nil)
    // A second block of the same message continues after a blank line and adds its duration.
    capture.start(message: "msg_1", index: 2, at: start.addingTimeInterval(20))
    _ = capture.delta("Потом код.", index: 2, at: start.addingTimeInterval(21))
    let second = capture.stop(index: 2, at: start.addingTimeInterval(23))
    #expect(second?.text == "Сначала изучу тесты.\n\nПотом код." && second?.seconds == 15)
    // Redacted or omitted thinking (signature only) produces no item.
    capture.start(message: "msg_2", index: 0, at: start)
    #expect(capture.stop(index: 0, at: start.addingTimeInterval(4)) == nil)
    #expect(capture.message("msg_2", thinking: "") == nil)
    // Without a stream the complete message supplies the text.
    #expect(capture.message("msg_3", thinking: "Только итог")?.text == "Только итог")
}

@Test func claudeBashResultsMapToExitCodes() {
    let bash = TranscriptItem(id: "toolu_1", kind: "activity", text: "Bash\n" + JSONValue.object(["command": .string("git status"), "description": .string("Show status")]).display)
    let background = TranscriptItem(id: "toolu_2", kind: "activity", text: "Bash\n" + JSONValue.object(["command": .string("swift build"), "run_in_background": .bool(true)]).display)
    let read = TranscriptItem(id: "toolu_3", kind: "activity", text: "Read\n{\"file_path\" : \"/a\"}")
    #expect(ActivityDetail.isShellCall(bash) && ActivityDetail.command(bash) == "git status")
    #expect(!ActivityDetail.isShellCall(read))
    // Claude Code 2.1.x: a failing command is an error result starting with "Exit code N"; a clean one names no code.
    #expect(ActivityDetail.claudeOutcome(call: bash, result: "Exit code 128\nfatal: not a git repository", isError: true) == (128, nil))
    #expect(ActivityDetail.claudeOutcome(call: bash, result: "On branch main", isError: false) == (0, nil))
    #expect(ActivityDetail.claudeOutcome(call: bash, result: "<tool_use_error>Denied</tool_use_error>", isError: true) == (nil, true))
    #expect(ActivityDetail.claudeOutcome(call: background, result: "Command running in background with ID: b1", isError: false) == (nil, nil))
    #expect(ActivityDetail.claudeOutcome(call: read, result: "Exit code 1", isError: true) == (nil, nil))
    #expect(ActivityDetail.claudeOutcome(call: nil, result: "x", isError: false) == (nil, nil))
    // Results recorded before the fields existed still show a leading exit code.
    #expect(ActivityDetail.outcome(TranscriptItem(id: "old:result", kind: "activity", text: "Exit code 2\nboom")) == .exit(2))
    #expect(ActivityDetail.outcome(TranscriptItem(id: "old:result", kind: "activity", text: "fine")) == nil)
    #expect(ActivityDetail.label(.exit(1)) == L10n.text("код 1", "exit 1"))
    #expect(ActivityDetail.oneLine("git log \\\n  --oneline") == "git log \\ …")
    #expect(ActivityDetail.oneLine(String(repeating: "x", count: 200), limit: 10) == String(repeating: "x", count: 9) + "…")
}

@Test func commandOutputShowsTheLastLinesWithinTheLimits() {
    let lines = (1...250).map { "line \($0)" }
    var result = TranscriptItem(id: "c:result", kind: "activity", text: "Exit code 1\n" + lines.joined(separator: "\n") + "\n")
    let output = ActivityDetail.output(result)
    #expect(output.omittedLines == 50 && !output.capped && !output.archived)
    #expect(output.text == lines.suffix(200).joined(separator: "\n"))
    // The byte limit cuts at a whole line.
    let wide = ActivityDetail.output(TranscriptItem(id: "w:result", kind: "activity", text: (1...100).map { "\($0) " + String(repeating: "y", count: 1_000) }.joined(separator: "\n")))
    let shown = wide.text.components(separatedBy: "\n")
    #expect(wide.text.utf8.count <= ActivityDetail.outputByteLimit && wide.text.utf8.count > ActivityDetail.outputByteLimit - 1_100)
    #expect(shown.first?.hasPrefix("\(100 - shown.count + 1) y") == true && wide.omittedLines + shown.count == 100 && shown.last?.hasPrefix("100 ") == true)
    result.fullLength = 90_000
    #expect(ActivityDetail.output(result).capped)
    // Reduced (archived) results keep only their headline.
    let reduced = ActivityRetention.reduce([TranscriptItem(id: "c:result", kind: "activity", text: "first\nsecond")])[0]
    #expect(ActivityDetail.output(reduced) == .init(text: "first second", omittedLines: 0, capped: false, archived: true))
}

@Test func thinkingAndCommandFieldsFollowTheRetentionPolicy() throws {
    var thinking = TranscriptItem(id: "rs_1", kind: ActivityDetail.thinkingKind, text: String(repeating: "думаю ", count: 5_000))
    thinking.seconds = 12
    var call = TranscriptItem(id: "call_1", kind: "activity", text: "make test"); call.tool = ActivityDetail.codexCommandTool
    var result = TranscriptItem(id: "call_1:result", kind: "activity", text: "compiling\nerror: boom"); result.exitCode = 2; result.seconds = 3.3
    var declined = TranscriptItem(id: "call_2:result", kind: "activity", text: "Command declined"); declined.failed = true
    // Active chat: thinking is capped like tool bodies; fields stay.
    let capped = ActivityRetention.cap(thinking)
    #expect(capped.fullLength == thinking.text.utf8.count && capped.text.utf8.count < ActivityRetention.capBytes + 100 && capped.seconds == 12)
    // Archived: headline plus metadata, outcome fields kept on the items.
    let reduced = ActivityRetention.reduce([TranscriptItem(id: "u", kind: "user", text: "go"), capped, call, result, declined])
    #expect(reduced[0].text == "go")
    #expect(reduced[1].reduced == true && reduced[1].seconds == 12)
    #expect(reduced[1].text == ActivityRetention.headline(thinking.text) + "\n#activity kind=thinking size=\(thinking.text.utf8.count) seconds=12.0")
    #expect(reduced[2].text == "make test\n#activity tool=commandExecution size=9 output=21")
    #expect(reduced[3].text == "compiling error: boom\n#activity tool=commandExecution output=21 exit=2 error=\"compiling | error: boom\" seconds=3.3")
    #expect(reduced[3].exitCode == 2 && ActivityDetail.outcome(reduced[3]) == .exit(2))
    #expect(reduced[4].text.hasSuffix("#activity output=16 error=\"Command declined\"") && ActivityDetail.outcome(reduced[4]) == .failed)
    #expect(ActivityRetention.isReduced(reduced) && !ActivityRetention.isReduced([thinking]))
    #expect(ActivityDetail.thinkingText(reduced[1]) == ActivityRetention.headline(thinking.text))
    // A reduced Claude Bash call is still a command, its command its headline, its exit code from the metadata.
    let bash = TranscriptItem(id: "b", kind: "activity", text: "Bash\n{\n  \"command\" : \"ls -la\"\n}")
    let legacy = ActivityRetention.reduce([bash, TranscriptItem(id: "b:result", kind: "activity", text: "Exit code 1\nnope")])
    #expect(ActivityDetail.isShellCall(legacy[0]) && ActivityDetail.command(legacy[0]) == "ls -la")
    #expect(ActivityDetail.outcome(legacy[1]) == .exit(1))
    // Snapshots: thinking counts as an activity body, compaction notes do not keep a chat unreduced.
    let source = AgentSessionReference(connection: .originalCodex, nativeID: "n")
    let snapshot = try LocalHistory.snapshot(conversation: ConversationID("c"), source: source,
                                             items: [thinking, TranscriptItem(id: "k", kind: "compaction", text: "Compacted", phase: "completed")])
    #expect(!ActivityRetention.isReduced(snapshot))
    let reducedSnapshot = try ActivityRetention.reduce(snapshot)
    #expect(ActivityRetention.isReduced(reducedSnapshot))
    #expect(LocalHistory.items(reducedSnapshot).map(\.kind) == [ActivityDetail.thinkingKind, "compaction"])
}

@Test func storedItemsWithoutTheNewFieldsStillDecode() throws {
    // A transcript entry and a snapshot as stored before 2026-11-01.
    let legacyItem = #"{"id":"b:result","kind":"activity","text":"Exit code 1\nboom","showsAuthor":true,"showsCopyControl":true,"fullLength":20000}"#
    let item = try JSONDecoder().decode(TranscriptItem.self, from: Data(legacyItem.utf8))
    #expect(item.exitCode == nil && item.failed == nil && item.seconds == nil && item.tool == nil && item.fullLength == 20000)
    #expect(ActivityDetail.outcome(item) == .exit(1))
    // Items without the fields are stored without them (no extra bytes per item) and read back unchanged.
    let snapshot = try LocalHistory.snapshot(conversation: ConversationID("c"), source: AgentSessionReference(connection: .originalCodex, nativeID: "n"), items: [item])
    let stored = try JSONEncoder().encode(snapshot)
    #expect(!String(decoding: stored, as: UTF8.self).contains("exitCode") && !String(decoding: stored, as: UTF8.self).contains("seconds"))
    #expect(LocalHistory.items(try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: stored)) == [item])
    // New fields round-trip.
    var detailed = item; detailed.exitCode = 1; detailed.seconds = 2.5; detailed.tool = "commandExecution"; detailed.failed = false
    #expect(try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(detailed)) == detailed)
}

// MARK: Transcript

private func command(_ id: String, _ text: String, exit: Int?, output: String, seconds: Double? = nil) -> [TranscriptItem] {
    var call = TranscriptItem(id: id, kind: "activity", text: text); call.tool = ActivityDetail.codexCommandTool
    var result = TranscriptItem(id: id + ":result", kind: "activity", text: output); result.exitCode = exit; result.seconds = seconds
    return [call, result]
}

@Test @MainActor func thinkingRowsStartCollapsedOpenToTheirTextAndMerge() throws {
    var first = TranscriptItem(id: "thinking:m1", kind: ActivityDetail.thinkingKind, text: "Сначала прочитаю очередь."); first.seconds = 7
    var second = TranscriptItem(id: "thinking:m2", kind: ActivityDetail.thinkingKind, text: "**Plan**\nПотом тесты."); second.seconds = 5
    let empty = TranscriptItem(id: "thinking:m3", kind: ActivityDetail.thinkingKind, text: "  ")
    let third = TranscriptItem(id: "thinking:m5", kind: ActivityDetail.thinkingKind, text: "И сборку.")
    let items = [TranscriptItem(id: "u", kind: "user", text: "Проверь"), first, TranscriptItem(id: "t1", kind: "activity", text: "Read\n{}"),
                 second, TranscriptItem(id: "t2", kind: "activity", text: "Grep\n{}"), empty, third,
                 TranscriptItem(id: "a", kind: "assistant", text: "Готово")]
    let grouped = TranscriptScrollView.groupActivities(items, isWorking: false)
    // Tool calls move into their card, so the thinking between them becomes adjacent and shares one row; the empty one adds nothing.
    #expect(grouped.items.map(\.kind) == ["user", ActivityDetail.thinkingKind, "activity", ActivityDetail.thinkingKind, "assistant"])
    #expect(grouped.items[1].seconds == 7 && grouped.items[3].seconds == 5)
    #expect(grouped.groups["thinking:m2"]?.map(\.id) == ["thinking:m2", "thinking:m5"])
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    view.update(items: items, conversationID: "thinking", followOutput: false)
    let label = ActivityDetail.thinkingLabel(seconds: 7)
    #expect(label == L10n.text("Размышления · 7 с", "Thinking · 7s"))
    #expect(view.transcript.string.contains(label + "  ▸"))
    #expect(!view.transcript.string.contains("Сначала прочитаю"))
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("thinking", row: "thinking:m1"), at: 0)
    #expect(view.transcript.string.contains(label + "  ▾"))
    #expect(view.transcript.string.contains("Сначала прочитаю очередь."))
    let storage = try #require(view.transcript.textStorage)
    let body = (storage.string as NSString).range(of: "Сначала прочитаю")
    #expect(storage.attribute(.foregroundColor, at: body.location, effectiveRange: nil) as? NSColor == DeskPalette.ns.muted)
    // Streaming into an open row shows the new text; the rows before it are not rendered again.
    var live = TranscriptItem(id: "thinking:m4", kind: ActivityDetail.thinkingKind, text: "Думаю")
    var streamed = items + [TranscriptItem(id: "u2", kind: "user", text: "Ещё"), live]
    view.update(items: streamed, conversationID: "thinking", followOutput: false, isWorking: true)
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("thinking", row: "thinking:m4"), at: 0)
    let renders = view.renderCount
    live.text += " дальше"; streamed[streamed.count - 1] = live
    view.update(items: streamed, conversationID: "thinking", followOutput: false, isWorking: true)
    #expect(view.transcript.string.contains("Думаю дальше"))
    #expect(view.renderCount - renders == 2) // the thinking row and the working row
    // The second merged row opens to both parts, with the bold title unmarked.
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("thinking", row: "thinking:m2"), at: 0)
    #expect(view.transcript.string.contains("\nPlan\nПотом тесты.\n\nИ сборку."))
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("thinking", row: "thinking:m1"), at: 0)
    #expect(!view.transcript.string.contains("Сначала прочитаю"))
}

@Test @MainActor func commandRowsShowExitBadgesAndOpenToCopyableOutput() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let failing = (1...230).map { "test \($0) failed" }.joined(separator: "\n")
    let items = [TranscriptItem(id: "u", kind: "user", text: "Запусти тесты")]
        + command("c1", "swift build", exit: 0, output: "Build complete!", seconds: 41)
        + command("c2", "swift test\n--parallel", exit: 1, output: failing)
        + [TranscriptItem(id: "r", kind: "activity", text: "Read\n{\"file_path\" : \"/a.swift\"}"),
           TranscriptItem(id: "r:result", kind: "activity", text: "contents")]
        + [TranscriptItem(id: "c3", kind: "activity", text: "sleep 100", phase: nil)]
    var running = items; running[running.count - 1].tool = ActivityDetail.codexCommandTool
    let view = TranscriptScrollView(pasteboard: pasteboard)
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
    view.update(items: running, conversationID: "commands", followOutput: false)
    // Commands and their results share rows: 3 commands and the Read call and result.
    #expect(view.transcript.string.contains("Действия Codex · 5") || view.transcript.string.contains("Codex actions · 5"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:c1", at: 0)
    let text = view.transcript.string
    #expect(text.contains("1. $ swift build"))
    #expect(text.contains("2. $ swift test …  " + L10n.text("код 1", "exit 1") + "  ▸"))
    #expect(text.contains("3. Read\n{"))
    #expect(text.contains("4. contents"))
    #expect(text.contains("5. $ sleep 100") && !text.contains("5. $ sleep 100  ▸"))
    #expect(!text.contains("Build complete!") && !text.contains("test 230 failed"))
    let storage = try #require(view.transcript.textStorage)
    let badge = (storage.string as NSString).range(of: L10n.text("код 1", "exit 1"))
    #expect(storage.attribute(.foregroundColor, at: badge.location, effectiveRange: nil) as? NSColor == DeskPalette.ns.problem)
    let success = (storage.string as NSString).range(of: "1. $ swift build")
    let check = NSMaxRange(success) + 2
    #expect((storage.attribute(.attachment, at: check, effectiveRange: nil) as? NSTextAttachment)?.image?.accessibilityDescription == L10n.text("код 0", "exit 0"))
    #expect(storage.string.contains(" · " + ResponseTiming.duration(41)))
    // Opening the failing command shows its last 200 lines in monospace with a note and a copy control.
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("output", row: "c1", target: "c2"), at: 0)
    let open = view.transcript.string
    #expect(open.contains("test 230 failed") && open.contains("test 31 failed") && !open.contains("test 30 failed\n"))
    #expect(open.contains(L10n.text("ещё 30 выше скрыто", "30 earlier lines are hidden")))
    let line = (open as NSString).range(of: "test 230 failed")
    #expect((storage.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
    #expect(view.transcript.isSelectable)
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("copy", row: "c1", target: "c2"), at: 0)
    #expect(pasteboard.string(forType: .string) == failing)
    #expect(view.transcript.string.contains(L10n.text("Скопировано", "Copied")))
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("output", row: "c1", target: "c2"), at: 0)
    #expect(!view.transcript.string.contains("test 230 failed"))
    // An archived chat keeps the rows and badges; the output is its first line with a note.
    let archived = ActivityRetention.reduce(running)
    view.update(items: archived, conversationID: "archived", followOutput: false)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:c1", at: 0)
    #expect(view.transcript.string.contains("2. $ swift test --parallel  " + L10n.text("код 1", "exit 1")))
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("output", row: "c1", target: "c1"), at: 0)
    #expect(view.transcript.string.contains("Build complete!"))
    #expect(view.transcript.string.contains(L10n.text("В архиве хранится только первая строка вывода.", "Archived chats keep only the first line of the output.")))
}
