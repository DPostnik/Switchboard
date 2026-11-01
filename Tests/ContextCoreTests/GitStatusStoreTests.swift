import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@MainActor private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

private func makeRepository() async throws -> URL {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let git = GitRunner()
    for arguments in [["init", "-q", "-b", "main"],
                      ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                       "commit", "-q", "--allow-empty", "-m", "first"]] {
        #expect(try await git.run(arguments, in: repo.path).succeeded)
    }
    return repo
}

@Test @MainActor func gitStatusStoreFollowsTheGitDirectoryWithoutPolling() async throws {
    let repo = try await makeRepository()
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: plain) }
    let store = GitStatusStore()
    store.debounce = .milliseconds(50)
    store.track([repo.path, plain.path])
    #expect(await eventually { store.status(for: repo.path)?.branch == "main" })
    #expect(store.status(for: plain.path) == nil)

    // A branch switch made outside the app reaches the store through the watched git directory.
    #expect(try await GitRunner().run(["switch", "-q", "-c", "other"], in: repo.path).succeeded)
    #expect(await eventually { store.status(for: repo.path)?.branch == "other" })

    store.track([plain.path])
    #expect(store.status(for: repo.path) == nil)
}

@Test @MainActor func turnStartRecordsTheProjectBranchOnTheChat() async throws {
    let repo = try await makeRepository()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = Project(path: repo.path)
    model.state.projects = [project]
    model.state.chats = [Chat(id: "chat", projectID: project.id, title: "Chat", model: "")]
    model.recordTurnBranch(threadID: "chat")
    #expect(await eventually { model.state.chats[0].turnBranch == "main" })

    #expect(try await GitRunner().run(["switch", "-q", "-c", "elsewhere"], in: repo.path).succeeded)
    model.gitStatus.setStatus(try await GitStatus.read(at: repo.path), for: repo.path)
    #expect(model.gitStatus.branchChange(for: model.state.chats[0], projectPath: repo.path) == GitBranchChange(from: "main", to: "elsewhere"))
    #expect(await model.gitStatus.switchBranch(repo.path, to: "main") == nil)
    #expect(try await GitStatus.read(at: repo.path)?.branch == "main")
}

@Test func branchSummaryInBothLanguages() {
    let status = GitStatus(branch: "main", upstream: "origin/main", ahead: 2, behind: 1, changedFiles: 3)
    #expect(GitBranchText.aheadBehind(status) == "↑2 ↓1")
    #expect(GitBranchText.aheadBehind(GitStatus(branch: "main", behind: 4)) == "↓4")
    #expect(GitBranchText.summary(status, language: .english) == "Branch: main\nUpstream: origin/main · ahead 2, behind 1\nUncommitted files: 3")
    #expect(GitBranchText.summary(status, language: .russian).hasPrefix("Ветка: main\n"))
    let change = GitBranchChange(from: "feature", to: "main")
    #expect(GitBranchText.changed(change, language: .english) == "Branch changed: this chat worked on feature, now main")
    #expect(GitBranchText.changed(change, language: .russian) == "Ветка сменилась: чат работал в feature, сейчас main")
    #expect(GitBranchText.switchBack("feature", language: .russian) == "Вернуть feature")
}

@Test func gitWatcherIgnoresObjectsAndTurnCheckpoints() {
    let roots = ["/repo/.git"]
    #expect(GitDirectoryWatcher.isRelevant("/repo/.git/HEAD", roots: roots))
    #expect(GitDirectoryWatcher.isRelevant("/repo/.git/refs/heads/main", roots: roots))
    #expect(!GitDirectoryWatcher.isRelevant("/repo/.git/objects/ab/cdef", roots: roots))
    #expect(!GitDirectoryWatcher.isRelevant("/repo/.git/refs/switchboard/checkpoints/chat/3", roots: roots))
    #expect(GitDirectoryWatcher.isRelevant("/repo/.git/refs/switchboardish", roots: roots))
}
