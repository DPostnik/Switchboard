import Foundation
import Testing
@testable import ContextCore

@Test func gitStatusParsesBranchUpstreamAndChanges() throws {
    let output = [
        "# branch.oid 0123456789abcdef0123456789abcdef01234567",
        "# branch.head feature/long-name",
        "# branch.upstream origin/feature/long-name",
        "# branch.ab +3 -2",
        "1 .M N... 100644 100644 100644 aaa bbb Sources/a.swift",
        // A rename carries its original path as the next field, which must not count as a second file.
        "2 R. N... 100644 100644 100644 aaa bbb R100 new name.swift", "1 old name.swift",
        "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift",
        "? notes.txt",
        "! ignored.log",
    ].joined(separator: "\0") + "\0"
    let status = try #require(GitStatus.parse(Data(output.utf8)))
    #expect(status == GitStatus(branch: "feature/long-name", commit: "0123456789abcdef0123456789abcdef01234567",
                                upstream: "origin/feature/long-name", ahead: 3, behind: 2, changedFiles: 4))
    #expect(status.displayName == "feature/long-name" && status.hasChanges && !status.isDetached)

    let detached = try #require(GitStatus.parse(Data("# branch.oid abcdef1234567\0# branch.head (detached)\0".utf8)))
    #expect(detached.isDetached && detached.displayName == "abcdef1" && !detached.hasChanges && detached.upstream == nil)

    let empty = try #require(GitStatus.parse(Data("# branch.oid (initial)\0# branch.head main\0? a\0".utf8)))
    #expect(empty.commit == nil && empty.branch == "main" && empty.changedFiles == 1 && empty.ahead == 0)

    #expect(GitStatus.parse(Data()) == nil)
    #expect(GitStatus.parse(Data(" M file.swift\0".utf8)) == nil)
}

@Test func gitBranchChangeOnlyWhenTheFolderMovedOn() {
    let main = GitStatus(branch: "main", commit: "abcdef1234")
    #expect(GitStatus.branchChange(from: "main", to: main) == nil)
    #expect(GitStatus.branchChange(from: nil, to: main) == nil)
    #expect(GitStatus.branchChange(from: "main", to: nil) == nil)
    #expect(GitStatus.branchChange(from: "feature", to: main) == GitBranchChange(from: "feature", to: "main"))
    #expect(GitStatus.branchChange(from: "main", to: GitStatus(commit: "abcdef1234")) == GitBranchChange(from: "main", to: "abcdef1"))
}

@Test func gitStatusReadsRealRepositoriesAndWorktrees() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let repo = root.appendingPathComponent("repo"), plain = root.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitRunner()
    @discardableResult func run(_ arguments: [String], in directory: URL = repo) async throws -> GitRunner.Result {
        let result = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                                        "-c", "core.hooksPath=/dev/null"] + arguments, in: directory.path)
        #expect(result.succeeded, "\(arguments): \(result.errors)")
        return result
    }

    #expect(try await GitStatus.read(at: plain.path) == nil)
    #expect(try await GitStatus.gitDirectories(at: plain.path) == nil)

    try await run(["init", "-q", "-b", "main"])
    try Data("one\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
    try await run(["add", "a.txt"])
    try await run(["commit", "-q", "-m", "first"])
    var status = try #require(try await GitStatus.read(at: repo.path))
    #expect(status.branch == "main" && status.changedFiles == 0 && status.upstream == nil && status.commit?.count == 40)

    // Untracked and modified files both count.
    try Data("two\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
    try Data("new\n".utf8).write(to: repo.appendingPathComponent("b.txt"))
    status = try #require(try await GitStatus.read(at: repo.path))
    #expect(status.changedFiles == 2)
    try await run(["checkout", "-q", "--", "a.txt"])
    try FileManager.default.removeItem(at: repo.appendingPathComponent("b.txt"))

    // Ahead/behind against an upstream.
    try await run(["branch", "base"])
    try await run(["branch", "-q", "--set-upstream-to=base"])
    try Data("three\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
    try await run(["commit", "-q", "-am", "second"])
    status = try #require(try await GitStatus.read(at: repo.path))
    #expect(status.upstream == "base" && status.ahead == 1 && status.behind == 0)

    #expect(try await GitStatus.gitDirectories(at: repo.path) == [repo.appendingPathComponent(".git").path])

    // A linked worktree has a `.git` file; its HEAD lives under the common dir, which alone is watched.
    let linked = root.appendingPathComponent("linked")
    try await run(["worktree", "add", "-q", "-b", "side", linked.path])
    status = try #require(try await GitStatus.read(at: linked.path))
    #expect(status.branch == "side")
    #expect(try await GitStatus.gitDirectories(at: linked.path) == [repo.appendingPathComponent(".git").path])

    // Detached HEAD shows the short commit.
    try await run(["checkout", "-q", "--detach"])
    status = try #require(try await GitStatus.read(at: repo.path))
    #expect(status.isDetached && status.displayName.count == 7)
}

@Test func gitSwitchRunsOnceAndReportsGitErrors() async throws {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = GitRunner()
    for arguments in [["init", "-q", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                                                     "commit", "-q", "--allow-empty", "-m", "first"], ["branch", "other"]] {
        #expect(try await git.run(arguments, in: repo.path).succeeded)
    }
    #expect(await GitStatus.switchBranch("other", at: repo.path) == nil)
    #expect(try await GitStatus.read(at: repo.path)?.branch == "other")
    let missing = try #require(await GitStatus.switchBranch("missing", at: repo.path))
    #expect(missing.contains("missing"))
    #expect(await GitStatus.switchBranch("-f", at: repo.path) != nil)
    #expect(try await GitStatus.read(at: repo.path)?.branch == "other")
}

@Test func chatTurnBranchDecodesFromOlderData() throws {
    var chat = Chat(id: "c", projectID: UUID(), title: "Chat", model: "")
    let legacy = try JSONEncoder().encode(chat)
    #expect(!String(decoding: legacy, as: UTF8.self).contains("turnBranch"))
    #expect(try JSONDecoder().decode(Chat.self, from: legacy).turnBranch == nil)
    chat.turnBranch = "feature/x"
    #expect(try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat)).turnBranch == "feature/x")
}
