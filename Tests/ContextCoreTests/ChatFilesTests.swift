import AppKit
import SwiftUI
import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ContextTranscript
@testable import ContextDesk

private let base = URL(fileURLWithPath: "/repo", isDirectory: true)
private let existing: Set<String> = ["/repo/Sources/App.swift", "/repo/README.md", "/repo/Sources/Model.swift", "/repo/docs/guide.md"]
private let isFile: ChatFiles.FileCheck = { existing.contains($0) }

private func call(_ id: String, kind: AgentToolCall.Kind, status: AgentToolCall.Status = .completed,
                  locations: [AgentToolCall.Location] = [], diffs: [AgentToolCall.Diff] = []) -> TranscriptItem {
    var item = TranscriptItem(id: id, kind: "activity", text: id)
    item.toolCall = AgentToolCall(id: id, kind: kind, status: status, title: id, locations: locations, content: diffs.map { .diff($0) })
    return item
}

@Test @MainActor func messageTextCitesFilesAsTheTranscriptLinksThem() {
    let text = """
    See [the guide](docs/guide.md) and `Sources/App.swift:42`, then Sources/Model.swift.
    `README.md` alone is a bare name; Sources/Missing.swift does not exist.
    ```
    Sources/Model.swift:7 inside a fence is ignored
    ```
    Again `Sources/App.swift`.
    """
    let found = ChatFiles.textReferences(text, baseDirectory: base, isFile: isFile)
    #expect(found.map(\.path) == ["/repo/docs/guide.md", "/repo/Sources/App.swift", "/repo/Sources/Model.swift"])
    #expect(found[1].line == 42)
}

@Test @MainActor func collectKeepsEveryMentionAndShowsTheStrongestUseNewestFirst() {
    let items = [
        TranscriptItem(id: "u1", kind: "user", text: "Fix `Sources/App.swift`"),
        call("read", kind: .read, locations: [.init(path: "/repo/Sources/App.swift", line: 10)]),
        call("edit", kind: .edit, diffs: [.init(path: "/repo/Sources/App.swift", oldText: "a", newText: "b", line: 12),
                                          .init(path: "/repo/Sources/App.swift", oldText: "c", newText: "d", line: 40)]),
        call("refused", kind: .edit, status: .rejected, diffs: [.init(path: "Sources/Model.swift", oldText: "x", newText: "y")]),
        call("search", kind: .search, locations: [.init(path: "/repo/Sources"), .init(path: "/repo/README.md")]),
        call("rm", kind: .delete, locations: [.init(path: "/repo/old.txt")]),
        TranscriptItem(id: "a1", kind: "assistant", text: "Done in [App](Sources/App.swift:12)."),
        TranscriptItem(id: "a1:result", kind: "activity", text: "Sources/Model.swift"),
    ]
    let files = ChatFiles.collect(items, baseDirectory: base, isFile: isFile)
    #expect(files.map(\.path) == ["/repo/Sources/App.swift", "/repo/old.txt", "/repo/README.md", "/repo/Sources/Model.swift"])
    let app = files[0]
    #expect(app.use == .edited)
    // One mention per item: the edit's two hunks name the file once.
    #expect(app.mentions.map(\.itemID) == ["u1", "read", "edit", "a1"])
    #expect(app.line == 12)
    #expect(files[1].deleted && files[1].use == .edited)
    // A refused edit did not change the file; the folder from the search is not a file.
    #expect(files[3].use == .mentioned)
    #expect(!files.contains { $0.path == "/repo/Sources" })
}

@Test @MainActor func indexReparsesOnlyChangedItems() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let checks = Counter()
    let index = ChatFilesIndex { path in checks.value += 1; return existing.contains(path) }
    var items = [TranscriptItem(id: "a", kind: "assistant", text: "`Sources/App.swift`"),
                 TranscriptItem(id: "b", kind: "assistant", text: "Streaming")]
    _ = index.collect(items, baseDirectory: base)
    let first = checks.value
    items[1].text = "Streaming `README.md` and `docs/guide.md`"
    let files = index.collect(items, baseDirectory: base)
    #expect(files.map(\.path) == ["/repo/docs/guide.md", "/repo/Sources/App.swift"])
    #expect(checks.value - first == 1) // Only the changed message is parsed again; a bare name needs no check.
}

private func turn(_ number: Int, _ id: String, otherChats: Bool? = nil) -> ChatTurnChanges {
    ChatTurnChanges(itemID: id, number: number, completedAt: nil,
                    changes: TurnChanges(repository: "/repo", start: "s\(number)", end: "e\(number)", files: 1, added: 1, removed: 0, otherChats: otherChats))
}

@Test func turnChangesComeFromAnswersWithCheckpoints() {
    var answer = TranscriptItem(id: "a1", kind: "assistant", text: "done")
    answer.timing = ResponseTiming(startedAt: nil, completedAt: Date(timeIntervalSince1970: 10),
                                   changes: TurnChanges(repository: "/repo", start: "s", end: "e", files: 1, added: 2, removed: 1))
    var empty = TranscriptItem(id: "a2", kind: "assistant", text: "nothing")
    empty.timing = ResponseTiming(startedAt: nil, completedAt: Date(), changes: TurnChanges(repository: "/repo", start: "x", end: "x", files: 0, added: 0, removed: 0))
    let turns = ChatFiles.turnChanges([TranscriptItem(id: "u", kind: "user", text: "go"), answer, empty])
    #expect(turns.map(\.itemID) == ["a1"])
    #expect(turns.first?.number == 1 && turns.first?.completedAt == Date(timeIntervalSince1970: 10))
}

@Test func mergedChangesSumTurnsAndKeepTheNetStatus() {
    typealias Change = GitCheckpoints.FileChange
    let merged = ChatFiles.mergeChanges([
        (turn(2, "t2"), [Change(path: "new.swift", status: .modified, added: 3, removed: 1),
                         Change(path: "kept.swift", status: .deleted, added: 0, removed: 9),
                         Change(path: "renamed.swift", oldPath: "before.swift", status: .renamed, added: 1, removed: 1),
                         Change(path: "image.png", status: .modified, added: nil, removed: nil)]),
        (turn(1, "t1"), [Change(path: "new.swift", status: .added, added: 10, removed: 0),
                         Change(path: "kept.swift", status: .modified, added: 2, removed: 2),
                         Change(path: "before.swift", status: .modified, added: 4, removed: 0),
                         Change(path: "image.png", status: .modified, added: 1, removed: 0)]),
    ])
    let byPath = Dictionary(uniqueKeysWithValues: merged.map { ($0.path, $0) })
    #expect(merged.count == 4)
    #expect(byPath["new.swift"]?.status == .added)
    #expect(byPath["new.swift"]?.added == 13 && byPath["new.swift"]?.removed == 1)
    #expect(byPath["new.swift"]?.turns.map(\.turn.itemID) == ["t1", "t2"])
    #expect(byPath["kept.swift"]?.status == .deleted)
    #expect(byPath["renamed.swift"]?.status == .renamed)
    #expect(byPath["renamed.swift"]?.turns.count == 2 && byPath["before.swift"] == nil)
    #expect(byPath["image.png"]?.isBinary == true)
    #expect(byPath["new.swift"]?.absolutePath == "/repo/new.swift")
}

@Test @MainActor func revealScrollsToTheMessageAndItsFileLink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Target.swift")
    try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
    var items: [TranscriptItem] = []
    for index in 0..<60 {
        items.append(TranscriptItem(id: "u\(index)", kind: "user", text: "Question \(index)"))
        items.append(TranscriptItem(id: "a\(index)", kind: "assistant", text: index == 5 ? "Changed `Target.swift:1` here." : "Answer \(index) with some text."))
    }
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
    view.update(items: items, conversationID: "chat", followOutput: true, projectPath: directory.path)
    view.layoutSubtreeIfNeeded()
    #expect(view.reveal(itemID: "missing") == false)
    #expect(view.reveal(itemID: "a5", file: file.standardizedFileURL.path))
    let visible = view.transcript.visibleRect
    let storage = try #require(view.transcript.textStorage)
    var linkRange: NSRange?
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
        if (value as? URL)?.standardizedFileURL.path == file.standardizedFileURL.path { linkRange = range; stop.pointee = true }
    }
    let range = try #require(linkRange)
    let manager = try #require(view.transcript.layoutManager), container = try #require(view.transcript.textContainer)
    var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
    rect.origin.y += view.transcript.textContainerOrigin.y
    #expect(visible.intersects(rect))
}

@Test func storedFilesStandInForGitOnlyWhenComplete() {
    let list = [TurnChanges.File(path: "a.swift", status: "added", added: 2, removed: 0),
                TurnChanges.File(path: "b.swift", oldPath: "c.swift", status: "renamed", added: 1, removed: 1)]
    let complete = TurnChanges(repository: "/repo", start: "s", end: "e", files: 2, added: 3, removed: 1, list: list)
    let files = ChatFiles.storedFiles(complete)
    #expect(files?.map(\.status) == [.added, .renamed] && files?.last?.oldPath == "c.swift")
    var cut = complete; cut.files = 50
    #expect(ChatFiles.storedFiles(cut) == nil)
    cut.list = nil
    #expect(ChatFiles.storedFiles(cut) == nil)
}

@Test func binaryCardRowsOpenThePreviewInsteadOfTheDiff() {
    let list = [TurnChanges.File(path: "docs/report.pdf", status: "added", added: nil, removed: nil),
                TurnChanges.File(path: "old.png", status: "deleted", added: nil, removed: nil),
                TurnChanges.File(path: "a.swift", status: "modified", added: 2, removed: 1)]
    let changes = TurnChanges(repository: "/repo", start: "s", end: "e", files: 3, added: 2, removed: 1, list: list)
    #expect(TranscriptChangesCard.previewURL(changes, file: "docs/report.pdf")?.path == "/repo/docs/report.pdf")
    #expect(TranscriptChangesCard.previewURL(changes, file: "old.png") == nil)
    #expect(TranscriptChangesCard.previewURL(changes, file: "a.swift") == nil)
    #expect(TranscriptChangesCard.previewURL(changes, file: nil) == nil)
}

/// Cost of the column on a long chat: 3,000 items with paths in prose and tool calls, real file checks.
@Test @MainActor func collectStaysCheapOnALongChat() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<200 { try "x".write(to: root.appendingPathComponent("Sources/File\(index).swift"), atomically: false, encoding: .utf8) }
    var items: [TranscriptItem] = []
    for index in 0..<1000 {
        items.append(TranscriptItem(id: "u\(index)", kind: "user", text: "Please look at `Sources/File\(index % 200).swift` and fix it."))
        items.append(call("c\(index)", kind: .edit, diffs: [.init(path: root.path + "/Sources/File\(index % 200).swift", oldText: "a", newText: "b")]))
        items.append(TranscriptItem(id: "a\(index)", kind: "assistant", text: String(repeating: "Some prose about the change. ", count: 20)
            + "Changed Sources/File\((index + 1) % 200).swift:12 and [this](Sources/File\((index + 2) % 200).swift)."))
    }
    let index = ChatFilesIndex()
    let clock = ContinuousClock()
    let first = clock.measure { _ = index.collect(items, baseDirectory: root) }
    items[items.count - 1].text += " More `Sources/File3.swift`."
    let streamed = clock.measure { _ = index.collect(items, baseDirectory: root) }
    print("ChatFiles collect: first \(first), streamed update \(streamed)")
    #expect(first < .seconds(2))
    #expect(streamed < .milliseconds(100))
}

/// Draws the closed tile and the open panel; with SWITCHBOARD_RENDER_PATH set the images are written for a visual check.
@Test @MainActor func overlayShowsTileThenPanel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let extra = (1...14).map { "Feature\($0)View.swift" }
    for name in ["App.swift", "Model.swift", "README.md"] + extra { try "x".write(to: root.appendingPathComponent("Sources/" + name), atomically: false, encoding: .utf8) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("metadata.sqlite")), summaryResources: nil)
    let project = Project(path: root.path)
    let chat = Chat(id: "chat", projectID: project.id, title: "Chat", model: "model")
    model.state.projects = [project]; model.state.chats = [chat]; model.chatID = "chat"
    var answer = TranscriptItem(id: "a", kind: "assistant", text: "Edited `Sources/App.swift` and `Sources/README.md`.")
    answer.timing = ResponseTiming(startedAt: nil, completedAt: Date(), changes: TurnChanges(
        repository: root.path, start: "s", end: "e", files: 4, added: 514, removed: 4,
        list: [.init(path: "docs/burndown-status.agent.md", status: "added", added: 482, removed: 0, size: 15_800),
               .init(path: "Sources/SubagentWatch.swift", status: "added", added: 15, removed: 0),
               .init(path: "Fixtures/compat/snapshot.json", status: "added", added: 5, removed: 0),
               .init(path: "Sources/App.swift", status: "modified", added: 12, removed: 4)]))
    let items = [TranscriptItem(id: "u", kind: "user", text: "Look at Sources/Model.swift and " + extra.map { "`Sources/\($0)`" }.joined(separator: ", ")),
                 call("e", kind: .edit, diffs: [.init(path: root.path + "/Sources/App.swift", oldText: "a", newText: "b")]), answer]
    let files = ChatFilesModel()
    files.update(chatID: "chat", items: items, projectPath: root.path, engine: GitCheckpoints(), immediately: true)
    for _ in 0..<100 where files.changed.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(files.files.count == 17 && files.changed.count == 4)
    for open in [false, true] {
        UserDefaults.standard.set(open, forKey: "chatFilesPanelOpen")
        let host = NSHostingView(rootView: ChatFilesOverlay(files: files, model: model, open: { _, _ in }, addToMessage: { _ in })
            .frame(width: 520, height: 640).background(DeskPalette.canvas))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + (open ? ".panel.png" : ".tile.png")))
        }
    }
    UserDefaults.standard.removeObject(forKey: "chatFilesPanelOpen")
}
