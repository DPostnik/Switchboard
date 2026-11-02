import AppKit
import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ContextTranscript

// Structured calls and plans in the transcript (ACP-shaped model, stage C, 2026-11-02).

private func call(_ id: String, _ text: String, _ structured: AgentToolCall, result: String? = nil, failed: Bool? = nil) -> [TranscriptItem] {
    var item = TranscriptItem(id: id, kind: "activity", text: text); item.toolCall = structured
    guard let result else { return [item] }
    var outcome = TranscriptItem(id: ActivityDetail.resultID(of: id), kind: "activity", text: result); outcome.failed = failed
    return [item, outcome]
}

@Test @MainActor func structuredCallsShowKindTitleStatusLocationsAndDiffs() throws {
    let project = "/Users/me/project"
    let edit = AgentToolCall(id: "e1", kind: .edit, status: .completed, title: ToolCallText.edit("A.swift"),
                             locations: [.init(path: project + "/Sources/A.swift", line: 12)],
                             content: [.diff(.init(path: project + "/Sources/A.swift", oldText: "let a = 1\nlet b = 2", newText: "let a = 3\nlet b = 2"))])
    let grep = AgentToolCall(id: "g1", kind: .search, status: .failed, title: ToolCallText.search("TODO"), locations: [.init(path: "Sources")])
    let write = AgentToolCall(id: "w1", kind: .edit, status: .awaitingApproval, title: ToolCallText.write("N.swift"),
                              locations: [.init(path: project + "/N.swift")], content: [.diff(.init(path: project + "/N.swift", oldText: nil, newText: "x"))])
    let items = [TranscriptItem(id: "u", kind: "user", text: "Fix")]
        + call("e1", "Edit\n{}", edit, result: "The file has been updated.")
        + call("g1", "Grep\n{}", grep, result: "No such directory", failed: true)
        + call("w1", "Write\n{}", write)
        // Stored before the structured model: rows as before.
        + [TranscriptItem(id: "r", kind: "activity", text: "Read\n{\"file_path\" : \"/a.swift\"}"),
           TranscriptItem(id: "r:result", kind: "activity", text: "contents")]
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
    view.update(items: items, conversationID: "calls", followOutput: false, projectPath: project)
    // Each structured call takes its result into its row; the old Read call and result keep two.
    #expect(view.transcript.string.contains(L10n.text("Действия", "actions")) && view.transcript.string.contains("· 5"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:e1", at: 0)
    let text = view.transcript.string
    #expect(text.contains(" " + ToolCallText.edit("A.swift") + "  "))
    #expect(text.contains("Sources/A.swift:12"))
    #expect(text.contains(ToolCallText.search("TODO") + "  " + ToolCallText.status(.failed)))
    #expect(text.contains(ToolCallText.write("N.swift") + "  " + ToolCallText.status(.awaitingApproval)))
    #expect(text.contains("4. Read\n{") && text.contains("5. contents"))
    #expect(!text.contains("let a = 3"))
    let storage = try #require(view.transcript.textStorage)
    let location = (storage.string as NSString).range(of: "Sources/A.swift:12")
    #expect(storage.attribute(.link, at: location.location, effectiveRange: nil) as? String == project + "/Sources/A.swift")
    #expect(storage.attribute(.fileLine, at: location.location, effectiveRange: nil) as? Int == 12)
    // A relative location resolves against the project.
    let relative = (storage.string as NSString).range(of: "  Sources\n")
    #expect(storage.attribute(.link, at: relative.location + 2, effectiveRange: nil) as? String == project + "/Sources")
    // Opening the edit shows its inline diff (not the result text); opening the failing search shows its result.
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("call", row: "e1", target: "e1"), at: 0)
    _ = view.textView(view.transcript, clickedOnLink: TranscriptScrollView.detailLink("call", row: "e1", target: "g1"), at: 0)
    let open = view.transcript.string
    #expect(open.contains("- let a = 1\n+ let a = 3\n  let b = 2"))
    #expect(!open.contains("The file has been updated."))
    #expect(open.contains("No such directory"))
    let added = (open as NSString).range(of: "+ let a = 3")
    #expect(storage.attribute(.diffLine, at: added.location, effectiveRange: nil) as? String == "+")
    #expect(storage.attribute(.codeCard, at: added.location, effectiveRange: nil) as? String == "call:e1:0")
    // A status change of a call that is not the last item re-renders the card.
    var answered = items
    let index = try #require(answered.firstIndex { $0.id == "w1" })
    answered[index].toolCall?.status = .rejected
    view.update(items: answered, conversationID: "calls", followOutput: false, projectPath: project)
    #expect(view.transcript.string.contains(ToolCallText.write("N.swift") + "  " + ToolCallText.status(.rejected)))
}

@Test @MainActor func planItemsRenderAsAChecklistAndOldItemsKeepTheirText() throws {
    let plan = AgentPlan(entries: [.init(content: "Read the queue", status: .completed), .init(content: "Run tests", status: .inProgress),
                                   .init(content: "Ship", status: .pending)], explanation: "Short plan")
    let items = [TranscriptItem(id: "u", kind: "user", text: "Go"), plan.transcriptItem(turn: "t1"),
                 // A stored plan item from a build that had only its text.
                 TranscriptItem(id: "plan:t0", kind: AgentPlan.itemKind, text: "[x] Old")]
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
    view.update(items: items, conversationID: "plan", followOutput: false)
    let text = view.transcript.string
    #expect(text.contains(ToolCallText.planHeader(done: 1, total: 3)))
    #expect(text.contains("Short plan") && text.contains("  Read the queue") && text.contains("  Run tests") && text.contains("  Ship"))
    #expect(!text.contains("[~] Run tests"))
    #expect(text.contains("[x] Old"))
    let storage = try #require(view.transcript.textStorage)
    let done = (text as NSString).range(of: "Read the queue")
    #expect(storage.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    #expect(storage.attribute(.activityCard, at: done.location, effectiveRange: nil) as? String == "plan:t1")
    // The plan replaces itself in place.
    var updated = plan; updated.entries[1].status = .completed
    var next = items; next[1] = updated.transcriptItem(turn: "t1")
    view.update(items: next, conversationID: "plan", followOutput: false)
    #expect(view.transcript.string.contains(ToolCallText.planHeader(done: 2, total: 3)))
}

@Test @MainActor func codexReadCommandsLinkTheirFilesAndAPendingCommandShowsItsApproval() throws {
    var read = TranscriptItem(id: "c1", kind: "activity", text: "cat Sources/A.swift"); read.tool = ActivityDetail.codexCommandTool
    read.toolCall = AgentToolCall(id: "c1", kind: .read, status: .inProgress, title: "cat Sources/A.swift", locations: [.init(path: "/p/Sources/A.swift")],
                                  content: [.terminal(.init(command: "cat Sources/A.swift"))])
    var pending = TranscriptItem(id: "c2", kind: "activity", text: "rm -rf build"); pending.tool = ActivityDetail.codexCommandTool
    pending.toolCall = AgentToolCall(id: "c2", kind: .execute, status: .awaitingApproval, title: "rm -rf build")
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
    view.update(items: [TranscriptItem(id: "u", kind: "user", text: "Go"), read, pending], conversationID: "codex", followOutput: false, projectPath: "/p")
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:c1", at: 0)
    let text = view.transcript.string
    #expect(text.contains("1. $ cat Sources/A.swift  Sources/A.swift"))
    #expect(text.contains("2. $ rm -rf build  " + ToolCallText.status(.awaitingApproval)))
}
