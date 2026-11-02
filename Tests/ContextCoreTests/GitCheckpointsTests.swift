import AppKit
import Foundation
import Testing
@testable import ContextTranscript
@testable import AgentContract
@testable import ContextCore
@testable import ContextDesk

/// A temporary repository driven through `GitRunner`; commits never sign or run the user's hooks.
private struct Repo {
    let root: URL
    let git = GitRunner()

    static func make(commit: Bool = true) async throws -> Repo {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoints-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The real path, as git reports it (/private/var, not /var; `resolvingSymlinksInPath` drops /private).
        let real = realpath(root.path, nil)
        defer { free(real) }
        let repo = Repo(root: URL(fileURLWithPath: real.map { String(cString: $0) } ?? root.path))
        _ = try await repo.run("init", "-q", "-b", "main")
        if commit {
            try repo.write("tracked.txt", "one\ntwo\nthree\n")
            try repo.write(".gitignore", "*.log\n")
            try await repo.commit("initial")
        }
        return repo
    }

    var path: String { root.path }

    @discardableResult func run(_ arguments: String...) async throws -> String {
        let result = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                                        "-c", "core.hooksPath=/dev/null"] + arguments, in: path)
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.errors)")
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ message: String) async throws {
        try await run("add", "-A")
        try await run("commit", "-q", "--no-verify", "-m", message)
    }

    func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ name: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func checkpointSnapshotLeavesHeadIndexAndBranchAlone() async throws {
    let repo = try await Repo.make()
    defer { repo.remove() }
    try repo.write("tracked.txt", "one\nTWO\nthree\n")
    try repo.write("staged.txt", "staged\n")
    try await repo.run("add", "staged.txt")
    try repo.write("untracked.txt", "new\n")
    try repo.write("debug.log", "ignored\n")
    let head = try await repo.run("rev-parse", "HEAD")
    let status = try await repo.run("status", "--porcelain")
    let index = try Data(contentsOf: repo.root.appendingPathComponent(".git/index"))

    let checkpoints = GitCheckpoints()
    #expect(await checkpoints.repositoryRoot(for: repo.root.appendingPathComponent(".").path) == repo.path)
    let checkpoint = try await checkpoints.snapshot(root: repo.path, chatID: "chat:1")

    #expect(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")) == index)
    #expect(try await repo.run("rev-parse", "HEAD") == head)
    #expect(try await repo.run("symbolic-ref", "--short", "HEAD") == "main")
    #expect(try await repo.run("status", "--porcelain") == status)
    #expect(try await repo.run("branch", "--list") == "* main")
    let files = try await repo.run("ls-tree", "-r", "--name-only", checkpoint.commit).split(separator: "\n").map(String.init)
    #expect(Set(files) == [".gitignore", "tracked.txt", "staged.txt", "untracked.txt"])
    #expect(try await repo.run("show", checkpoint.commit + ":tracked.txt") == "one\nTWO\nthree")
    #expect(try await repo.run("rev-parse", checkpoint.commit + "^") == head)
    #expect(try await repo.run("rev-parse", "refs/switchboard/checkpoints/chat_1/1") == checkpoint.commit)
    // An unchanged tree reuses the previous checkpoint and adds no ref.
    #expect(try await checkpoints.snapshot(root: repo.path, chatID: "chat:1", previous: checkpoint) == checkpoint)
    #expect(try await checkpoints.refNumbers(root: repo.path, chatID: "chat:1") == [1])
}

@Test func checkpointWorksInRepositoryWithoutCommitsAndInLinkedWorktree() async throws {
    let empty = try await Repo.make(commit: false)
    defer { empty.remove() }
    try empty.write("a.txt", "a\n")
    let checkpoints = GitCheckpoints()
    let first = try await checkpoints.snapshot(root: empty.path, chatID: "c")
    #expect(try await empty.run("ls-tree", "-r", "--name-only", first.commit) == "a.txt")
    #expect(try await empty.run("status", "--porcelain") == "?? a.txt")

    let repo = try await Repo.make()
    defer { repo.remove() }
    let linked = repo.root.deletingLastPathComponent().appendingPathComponent("linked-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repo.run("worktree", "add", "-q", "-b", "side", linked.path)
    try Data("edited in worktree\n".utf8).write(to: linked.appendingPathComponent("tracked.txt"))
    let root = try #require(await checkpoints.repositoryRoot(for: linked.path))
    let checkpoint = try await checkpoints.snapshot(root: root, chatID: "w")
    #expect(try await repo.run("show", checkpoint.commit + ":tracked.txt") == "edited in worktree")
    // Refs are shared with the main checkout; the main checkout's files and branch are untouched.
    #expect(try await repo.run("rev-parse", "refs/switchboard/checkpoints/w/1") == checkpoint.commit)
    #expect(try await repo.run("symbolic-ref", "--short", "HEAD") == "main")
    #expect(repo.read("tracked.txt") == "one\ntwo\nthree\n")
}

@Test func checkpointChangesSummarizeAndRestore() async throws {
    let repo = try await Repo.make()
    defer { repo.remove() }
    try repo.write("gone.txt", "bye\n")
    try repo.write("old-name.txt", String(repeating: "same content line\n", count: 20))
    try await repo.commit("more")
    let checkpoints = GitCheckpoints()
    let start = try await checkpoints.snapshot(root: repo.path, chatID: "chat")

    try repo.write("tracked.txt", "one\nTWO\nthree\nfour\n")
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))
    try repo.write("dir/added.txt", "fresh\n")
    try FileManager.default.moveItem(at: repo.root.appendingPathComponent("old-name.txt"), to: repo.root.appendingPathComponent("new-name.txt"))
    try Data([0, 1, 2, 3, 0, 255]).write(to: repo.root.appendingPathComponent("blob.bin"))
    try repo.write("noise.log", "ignored\n")
    let end = try await checkpoints.snapshot(root: repo.path, chatID: "chat", previous: start)

    let changes = try await checkpoints.changes(root: repo.path, from: start.commit, to: end.commit)
    let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
    #expect(Set(byPath.keys) == ["tracked.txt", "gone.txt", "dir/added.txt", "new-name.txt", "blob.bin"])
    #expect(byPath["tracked.txt"]?.status == .modified)
    #expect(byPath["tracked.txt"]?.added == 2 && byPath["tracked.txt"]?.removed == 1)
    #expect(byPath["gone.txt"]?.status == .deleted && byPath["gone.txt"]?.removed == 1)
    #expect(byPath["dir/added.txt"]?.status == .added && byPath["dir/added.txt"]?.added == 1)
    #expect(byPath["new-name.txt"]?.status == .renamed && byPath["new-name.txt"]?.oldPath == "old-name.txt")
    #expect(byPath["blob.bin"]?.isBinary == true)

    let patch = try await checkpoints.patch(root: repo.path, from: start.commit, to: end.commit, file: try #require(byPath["tracked.txt"]))
    #expect(patch.text.contains("@@ -1,3 +1,4 @@") && patch.text.contains("\n-two\n") && patch.text.contains("\n+TWO\n"))
    #expect(!patch.truncated && !patch.tooLarge)
    let huge = GitCheckpoints.FileChange(path: "x", status: .modified, added: GitCheckpoints.patchLineLimit, removed: 1)
    #expect(try await checkpoints.patch(root: repo.path, from: start.commit, to: end.commit, file: huge).tooLarge)

    // Edited after the turn: detected before restoring.
    try repo.write("tracked.txt", "later edit\n")
    #expect(try await checkpoints.editedSince(root: repo.path, end: end.commit, files: changes) == ["tracked.txt"])

    let head = try await repo.run("rev-parse", "HEAD")
    let index = try Data(contentsOf: repo.root.appendingPathComponent(".git/index"))
    let report = try await checkpoints.restore(root: repo.path, to: start.commit, files: changes)
    #expect(report.failures.isEmpty)
    #expect(repo.read("tracked.txt") == "one\ntwo\nthree\n")
    #expect(repo.read("gone.txt") == "bye\n")
    #expect(repo.exists("old-name.txt") && !repo.exists("new-name.txt"))
    #expect(!repo.exists("dir/added.txt") && !repo.exists("blob.bin"))
    #expect(repo.read("noise.log") == "ignored\n")
    #expect(try await repo.run("status", "--porcelain") == "")
    #expect(try await repo.run("rev-parse", "HEAD") == head)
    #expect(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")) == index)
}

@Test func checkpointRestoreNeverRemovesFolders() async throws {
    let repo = try await Repo.make()
    defer { repo.remove() }
    try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try repo.write("nested/keep.txt", "keep\n")
    let file = GitCheckpoints.FileChange(path: "nested", status: .added, added: 0, removed: 0)
    let report = try await GitCheckpoints().restore(root: repo.path, to: "HEAD", files: [file])
    #expect(report.deleted.isEmpty && report.failures.count == 1)
    #expect(repo.exists("nested/keep.txt"))
}

@Test func checkpointsAreAbsentOutsideRepositoriesAndSkipLargeUntrackedFiles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(await GitCheckpoints().repositoryRoot(for: folder.path) == nil)
    #expect(await GitCheckpoints().repositoryRoot(for: folder.appendingPathComponent("missing").path) == nil)

    let repo = try await Repo.make()
    defer { repo.remove() }
    let big = repo.root.appendingPathComponent("dataset.csv")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: UInt64(GitCheckpoints.untrackedFileLimit + 1))
    try handle.close()
    await #expect(throws: GitCheckpoints.Failure.self) { try await GitCheckpoints().snapshot(root: repo.path, chatID: "c") }
    #expect(try await repo.run("for-each-ref", "refs/switchboard") == "")
}

@Test func checkpointRetentionPrunesOldestAndDeletionRemovesAll() async throws {
    let repo = try await Repo.make()
    defer { repo.remove() }
    let checkpoints = GitCheckpoints()
    for step in 1...5 {
        try repo.write("tracked.txt", "step \(step)\n")
        _ = try await checkpoints.snapshot(root: repo.path, chatID: "chat", keep: 3)
    }
    _ = try await checkpoints.snapshot(root: repo.path, chatID: "other")
    #expect(try await checkpoints.refNumbers(root: repo.path, chatID: "chat") == [3, 4, 5])
    try await checkpoints.removeCheckpoints(root: repo.path, chatID: "chat")
    #expect(try await checkpoints.refNumbers(root: repo.path, chatID: "chat") == [])
    #expect(try await checkpoints.refNumbers(root: repo.path, chatID: "other") == [1])
}

@Test func checkpointParsesRenamesAndBinaryCounts() {
    let names = Data("M\0a.txt\0R090\0old.txt\0new.txt\0A\0bin.dat\0".utf8)
    let counts = Data("3\t1\ta.txt\u{0}1\t1\t\u{0}old.txt\u{0}new.txt\u{0}-\t-\tbin.dat\u{0}".utf8)
    let parsed = GitCheckpoints.parse(nameStatus: names, numstat: counts)
    #expect(parsed == [
        .init(path: "a.txt", status: .modified, added: 3, removed: 1),
        .init(path: "new.txt", oldPath: "old.txt", status: .renamed, added: 1, removed: 1),
        .init(path: "bin.dat", status: .added, added: nil, removed: nil)
    ])
}

@Test @MainActor func turnCheckpointCoordinatorMeasuresTurnsAndFlagsOtherChats() async throws {
    let repo = try await Repo.make()
    defer { repo.remove() }
    let coordinator = TurnCheckpointCoordinator(startBound: .seconds(30))
    await coordinator.prepareStart(chatID: "a", projectPath: repo.path)
    coordinator.turnStarted(chatID: "a", turnID: "t1", projectPath: repo.path, running: ["a"])
    await coordinator.prepareStart(chatID: "b", projectPath: repo.path)
    coordinator.turnStarted(chatID: "b", turnID: "u1", projectPath: repo.path, running: ["a", "b"])
    try repo.write("tracked.txt", "changed\n")
    let first = try #require(coordinator.turnCompleted(chatID: "a", turnID: "t1", running: ["a", "b"]))
    let changes = try #require(await first.value)
    #expect(changes.files == 1 && changes.added == 1 && changes.removed == 3)
    #expect(changes.otherChats == true && changes.repository == repo.path)
    let other = try #require(coordinator.turnCompleted(chatID: "b", turnID: "u1", running: ["b"]))
    #expect(try #require(await other.value).otherChats == true)

    // A turn alone in the folder that changes nothing: no flag, no files, and its start reuses the last checkpoint.
    await coordinator.prepareStart(chatID: "a", projectPath: repo.path)
    coordinator.turnStarted(chatID: "a", turnID: "t2", projectPath: repo.path, running: ["a"])
    let second = try #require(coordinator.turnCompleted(chatID: "a", turnID: "t2", running: ["a"]))
    let quiet = try #require(await second.value)
    #expect(quiet.files == 0 && quiet.otherChats == nil && quiet.start == quiet.end && quiet.start == changes.end)
    // An unseen turn and a folder outside git yield nothing.
    #expect(coordinator.turnCompleted(chatID: "a", turnID: "unknown", running: []) == nil)
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-" + UUID().uuidString).path
    coordinator.turnStarted(chatID: "c", turnID: "x", projectPath: plain, running: ["c"])
    let outside = try #require(coordinator.turnCompleted(chatID: "c", turnID: "x", running: []))
    #expect(await outside.value == nil)

    // Deleting a chat removes its refs and leaves other chats' refs.
    coordinator.forget(chatID: "a", projectPath: repo.path)
    let checkpoints = GitCheckpoints()
    let deadline = Date().addingTimeInterval(10)
    var remaining = try await checkpoints.refNumbers(root: repo.path, chatID: "a")
    while !remaining.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
        remaining = try await checkpoints.refNumbers(root: repo.path, chatID: "a")
    }
    #expect(remaining.isEmpty)
    #expect(try await !checkpoints.refNumbers(root: repo.path, chatID: "b").isEmpty)
}

@Test @MainActor func answerWithTurnChangesShowsCardThatOpensTheViewer() throws {
    var opened: [(String?, TurnChanges, String?)] = []
    TranscriptLinks.openTurnChanges = { opened.append(($0, $1, $2)) }
    defer { TranscriptLinks.openTurnChanges = nil }
    let list = [TurnChanges.File(path: "docs/burndown-status.agent.md", status: "added", added: 482, removed: 0, size: 15_800),
                TurnChanges.File(path: "Sources/App/View.swift", status: "modified", added: 12, removed: 4),
                TurnChanges.File(path: "old.txt", status: "deleted", added: 0, removed: 9)]
    let changes = TurnChanges(repository: "/repo", start: "a", end: "b", files: 3, added: 494, removed: 13, list: list)
    let timing = ResponseTiming(startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 167), changes: changes)
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 360)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Make the file"),
                 TranscriptItem(id: "a", kind: "assistant", text: "Done.", timing: timing)]
    view.update(items: items, conversationID: "chat", followOutput: false)
    view.layoutSubtreeIfNeeded()
    let storage = try #require(view.transcript.textStorage)
    let string = storage.string as NSString
    // The card sits under the answer, one row per file; the header no longer carries a changes pill.
    let answer = string.range(of: "Done.").location
    let row = string.range(of: "burndown-status.agent.md").location
    #expect(answer != NSNotFound && row != NSNotFound && row > answer)
    #expect(storage.attribute(.changesCard, at: row, effectiveRange: nil) as? String == "a:changes")
    #expect(string.range(of: "View.swift").location != NSNotFound && string.range(of: "old.txt").location != NSNotFound)
    #expect(string.range(of: changes.label()).location == NSNotFound)
    let link = try #require(storage.attribute(.link, at: row, effectiveRange: nil) as? String)
    _ = view.textView(view.transcript, clickedOnLink: link, at: row)
    #expect(opened.count == 1 && opened.first?.0 == "chat" && opened.first?.1 == changes && opened.first?.2 == "docs/burndown-status.agent.md")
    if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
        view.drawsBackground = true
        view.backgroundColor = DeskPalette.ns.canvas
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".changes.png"))
    }
    // An older turn without a file list gets one summary row; no card without a viewer.
    var legacy = changes; legacy.list = nil
    view.update(items: [TranscriptItem(id: "c", kind: "assistant", text: "Old.", timing: ResponseTiming(startedAt: nil, completedAt: Date(), changes: legacy))],
                conversationID: "chat3", followOutput: false)
    #expect(view.transcript.string.contains(L10n.text("Изменено файлов: 3", "3 files changed")))
    TranscriptLinks.openTurnChanges = nil
    view.update(items: [TranscriptItem(id: "b", kind: "assistant", text: "Done.", timing: timing)], conversationID: "chat2", followOutput: false)
    #expect(!view.transcript.string.contains("burndown-status"))
}

@Test func turnChangesListKeepsAddedFileSizes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(count: 1234).write(to: root.appendingPathComponent("new.md"))
    let list = TurnChanges.list([GitCheckpoints.FileChange(path: "new.md", status: .added, added: 3, removed: 0),
                                 GitCheckpoints.FileChange(path: "b.swift", oldPath: "a.swift", status: .renamed, added: 1, removed: 1)], root: root.path)
    #expect(list.first?.size == 1234 && list.first?.status == "added")
    #expect(list.last?.oldPath == "a.swift" && list.last?.size == nil)
}

@Test func diffLinesNumberHunksAndKeepNotes() {
    let patch = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -3,3 +3,3 @@ func x()
     keep
    -old
    +new
    \\ No newline at end of file
    diff --git a/b.bin b/b.bin
    new file mode 100644
    Binary files /dev/null and b/b.bin differ

    """
    let lines = DiffLine.parse(patch)
    #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .note, .note, .note])
    #expect(lines[1].text == "keep" && lines[1].old == 3 && lines[1].new == 3)
    #expect(lines[2].old == 4 && lines[2].new == nil)
    #expect(lines[3].new == 4 && lines[3].old == nil)
    #expect(lines[6].text.hasPrefix("Binary files"))
}

@Test func turnChangesPersistBesideTimingsAndOldTimingsDecode() async throws {
    let old = try JSONDecoder().decode(ResponseTiming.self, from: Data(#"{"startedAt":100,"completedAt":167}"#.utf8))
    #expect(old.changes == nil)
    let changes = TurnChanges(repository: "/repo", start: "a", end: "b", files: 3, added: 12, removed: 4)
    #expect(changes.label(language: .english) == "3 files changed · +12 −4")
    #expect(changes.label(language: .russian) == "Изменено файлов: 3 · +12 −4")
    var shared = changes; shared.otherChats = true
    #expect(shared.label(language: .english).hasSuffix("may include another chat's edits"))
    #expect(shared.label(language: .russian).hasSuffix("возможно, с правками другого чата"))

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let timing = ResponseTiming(startedAt: nil, completedAt: Date(timeIntervalSince1970: 167))
    try await store.saveTiming(threadID: "t", turnID: "one", timing: timing)
    try await store.saveTurnChanges(threadID: "t", turnID: "one", changes: changes)
    // A later timing write without changes (late token usage) does not drop them.
    try await store.saveTiming(threadID: "t", turnID: "one", timing: timing)
    let loaded = try await AppStore(file: folder.appendingPathComponent("state.sqlite")).loadTimings(threadID: "t")
    #expect(loaded["one"]?.changes == changes)
    #expect(try JSONDecoder().decode(ResponseTiming.self, from: JSONEncoder().encode(loaded["one"]!)) == loaded["one"])
    // History turns keep the stored changes when they rebuild a timing.
    let turn = AgentHistoryTurn(id: "one", items: [], startedAt: nil, completedAt: Date(), duration: 5)
    #expect(turn.timing(fallback: loaded["one"])?.changes == changes)
    try await store.saveDeletingChat(SavedState(), threadID: "t")
    try await store.saveTiming(threadID: "t", turnID: "one", timing: timing)
    #expect(try await store.loadTimings(threadID: "t")["one"]?.changes == nil)
}
