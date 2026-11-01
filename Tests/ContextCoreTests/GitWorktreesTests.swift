@testable import ClaudeAdapter
@testable import CodexAdapter
import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

/// A temporary repository plus a temporary worktree root; worktrees are never created in real repositories.
private struct Sandbox {
    let folder: URL
    let repo: URL
    let root: URL
    let git = GitRunner()
    var engine: GitWorktrees { GitWorktrees(root: root) }

    static func make(name: String = "Мой проект") async throws -> Sandbox {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("worktrees-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The real path, as git reports it (/private/var, not /var).
        let real = realpath(base.path, nil)
        defer { free(real) }
        let folder = URL(fileURLWithPath: real.map { String(cString: $0) } ?? base.path)
        let sandbox = Sandbox(folder: folder, repo: folder.appendingPathComponent(name), root: folder.appendingPathComponent("root"))
        try FileManager.default.createDirectory(at: sandbox.repo.appendingPathComponent("app"), withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: sandbox.repo.appendingPathComponent("app/tracked.txt"))
        try await sandbox.run("init", "-q", "-b", "main")
        try await sandbox.run("add", "-A")
        try await sandbox.run("commit", "-q", "--no-verify", "-m", "initial")
        return sandbox
    }

    @discardableResult func run(_ arguments: String..., in directory: String? = nil) async throws -> String {
        let result = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                                        "-c", "core.hooksPath=/dev/null"] + arguments, in: directory ?? repo.path)
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.errors)")
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func branches() async throws -> [String] {
        try await run("for-each-ref", "--format=%(refname:short)", "refs/heads/").split(separator: "\n").map(String.init)
    }

    func remove() {
        _ = try? FileManager.default.removeItem(at: folder)
    }
}

@Test func worktreeSlugsTransliterateAndStayShort() {
    #expect(GitWorktrees.slug("Починить сборку") == "pochinit-sborku")
    #expect(GitWorktrees.slug("Щука и ёжик: Fix the BUILD!") == "shchuka-i-ezhik-fix-the-build")
    #expect(GitWorktrees.slug("Café déjà vu") == "cafe-deja-vu")
    #expect(GitWorktrees.slug("  ---  ") == "")
    #expect(GitWorktrees.slug("Мой проект") == "moy-proekt")
    let long = GitWorktrees.slug("Очень длинное название чата про исправление сборки приложения и тестов")
    #expect(long.count <= GitWorktrees.slugLimit)
    #expect(!long.hasSuffix("-") && !long.contains(" "))
    #expect(long.hasPrefix("ochen-dlinnoe-nazvanie"))
    #expect(GitWorktrees.temporarySlug().range(of: "^chat-[0-9a-f]{6}$", options: .regularExpression) != nil)
    #expect(GitWorktrees.uniqueBranch("fix", existing: []) == "switchboard/fix")
    #expect(GitWorktrees.uniqueBranch("fix", existing: ["switchboard/fix", "switchboard/fix-2"]) == "switchboard/fix-3")
    #expect(GitWorktrees.uniqueBranch("", existing: []) == "switchboard/chat")
}

@Test func worktreeListParsesPorcelain() {
    let text = "worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /wt/one\nHEAD def\ndetached\n\nworktree /bare\nbare\n"
    #expect(GitWorktrees.parseList(text) == [.init(path: "/repo", branch: "main"), .init(path: "/wt/one", branch: nil),
                                             .init(path: "/bare", branch: nil, bare: true)])
}

@Test func worktreeIsCreatedFromTheProjectBranchWithoutSpaces() async throws {
    let sandbox = try await Sandbox.make()
    defer { sandbox.remove() }
    let worktree = try await sandbox.engine.create(projectPath: sandbox.repo.path)
    let branch = try #require(worktree.branch)
    #expect(branch.range(of: "^switchboard/chat-[0-9a-f]{6}$", options: .regularExpression) != nil)
    #expect(worktree.path == sandbox.root.appendingPathComponent("moy-proekt").appendingPathComponent(String(branch.dropFirst("switchboard/".count))).path)
    #expect(!worktree.path.contains(" "))
    #expect(worktree.subfolder == nil && worktree.existing == nil && worktree.branchSettled == nil)
    #expect(worktree.workingDirectory == worktree.path)
    #expect(FileManager.default.fileExists(atPath: worktree.path + "/app/tracked.txt"))
    #expect(try await sandbox.run("symbolic-ref", "--short", "HEAD", in: worktree.path) == branch)
    #expect(try await sandbox.run("rev-parse", "HEAD", in: worktree.path) == sandbox.run("rev-parse", "main"))
    // The project folder stays on its branch.
    #expect(try await sandbox.run("symbolic-ref", "--short", "HEAD") == "main")
    #expect(sandbox.engine.contains(worktree.path))
    // The repository's other worktrees are offered as existing ones; the project's own checkout is not.
    let listed = try await sandbox.engine.list(projectPath: sandbox.repo.path)
    #expect(listed.map(\.branch) == [branch])
    #expect(listed.first?.existing == true)
}

@Test func worktreeOfASubfolderProjectWorksInTheSameSubfolder() async throws {
    let sandbox = try await Sandbox.make(name: "repo")
    defer { sandbox.remove() }
    // A detached HEAD bases the worktree on the commit.
    try await sandbox.run("checkout", "-q", "--detach")
    let worktree = try await sandbox.engine.create(projectPath: sandbox.repo.appendingPathComponent("app").path)
    #expect(worktree.subfolder == "app")
    #expect(worktree.workingDirectory == worktree.path + "/app")
    #expect(FileManager.default.fileExists(atPath: worktree.workingDirectory + "/tracked.txt"))
}

@Test func worktreeCreationReportsGitFailures() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("root-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: root) }
    await #expect(throws: GitWorktrees.Failure.self) { try await GitWorktrees(root: root).create(projectPath: folder.path) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    // A repository without commits has nothing to branch from.
    #expect(try await GitRunner().run(["init", "-q"], in: folder.path).succeeded)
    await #expect(throws: GitWorktrees.Failure.self) { try await GitWorktrees(root: root).create(projectPath: folder.path) }
}

@Test func worktreeBranchIsRenamedOnceToAUniqueTitleSlug() async throws {
    let sandbox = try await Sandbox.make()
    defer { sandbox.remove() }
    try await sandbox.run("branch", "switchboard/pochinit-sborku")
    let worktree = try await sandbox.engine.create(projectPath: sandbox.repo.path)
    let (renamed, problem) = await sandbox.engine.settleBranch(worktree, title: "Починить сборку")
    #expect(problem == nil)
    #expect(renamed.branch == "switchboard/pochinit-sborku-2")
    #expect(renamed.branchSettled == true)
    #expect(try await sandbox.run("symbolic-ref", "--short", "HEAD", in: worktree.path) == "switchboard/pochinit-sborku-2")
    // Once only: a later title changes nothing.
    let again = await sandbox.engine.settleBranch(renamed, title: "Другое название")
    #expect(again.worktree == renamed)
    #expect(try await sandbox.branches().contains("switchboard/pochinit-sborku-2"))

    // A branch with an upstream keeps its name; so does a picked existing worktree.
    let tracked = try await sandbox.engine.create(projectPath: sandbox.repo.path)
    try await sandbox.run("branch", "--set-upstream-to=main", tracked.branch!, in: tracked.path)
    let kept = await sandbox.engine.settleBranch(tracked, title: "Новая ветка")
    #expect(kept.worktree.branch == tracked.branch && kept.worktree.branchSettled == true)
    var picked = try await sandbox.engine.create(projectPath: sandbox.repo.path)
    picked.existing = true
    #expect(await sandbox.engine.settleBranch(picked, title: "Новая ветка").worktree.branch == picked.branch)
}

@Test func worktreeRemovalKeepsChangesAndNeverLeavesTheRoot() async throws {
    let sandbox = try await Sandbox.make()
    defer { sandbox.remove() }
    let dirty = try await sandbox.engine.create(projectPath: sandbox.repo.path)
    try Data("draft".utf8).write(to: URL(fileURLWithPath: dirty.path).appendingPathComponent("new.txt"))
    guard case .keptWithChanges = await sandbox.engine.remove(dirty, projectPath: sandbox.repo.path) else {
        Issue.record("A worktree with changes must be kept"); return
    }
    #expect(FileManager.default.fileExists(atPath: dirty.path + "/new.txt"))

    let clean = try await sandbox.engine.create(projectPath: sandbox.repo.path)
    #expect(await sandbox.engine.remove(clean, projectPath: sandbox.repo.path) == .removed)
    #expect(!FileManager.default.fileExists(atPath: clean.path))
    #expect(try await sandbox.branches().contains(clean.branch!)) // The branch is never deleted.

    // Outside the root: the project itself, the root's own folders and `..` escapes are refused before git runs.
    let outside = ChatWorktree(path: sandbox.repo.path, branch: "main")
    guard case .refused = await sandbox.engine.remove(outside, projectPath: sandbox.repo.path) else {
        Issue.record("A path outside the root must be refused"); return
    }
    #expect(FileManager.default.fileExists(atPath: sandbox.repo.path + "/app/tracked.txt"))
    #expect(!sandbox.engine.contains(sandbox.root.path))
    #expect(!sandbox.engine.contains(sandbox.root.appendingPathComponent("moy-proekt").path))
    #expect(!sandbox.engine.contains(sandbox.root.path + "/moy-proekt/../../" + sandbox.repo.lastPathComponent))
    #expect(!sandbox.engine.contains("relative/path"))
}

@Test func chatWorkingDirectoryFollowsItsWorktree() throws {
    let project = Project(path: "/tmp/project")
    var chat = Chat(id: "chat", projectID: project.id, title: "Chat", model: "")
    #expect(chat.workingDirectory(in: project) == "/tmp/project")
    chat.worktree = ChatWorktree(path: "/tmp/wt/project/chat-abcdef", branch: "switchboard/chat-abcdef")
    #expect(chat.workingDirectory(in: project) == "/tmp/wt/project/chat-abcdef")
    chat.worktree?.subfolder = "app"
    #expect(chat.workingDirectory(in: project) == "/tmp/wt/project/chat-abcdef/app")
    // The engines take the worktree as the chat's project root: writable for Codex, inside the project for Claude.
    let role = AgentRoleCatalog.preset(AgentRoleID.developer)
    let codex = role.profile(for: project).codexTurnParameters(projectPath: chat.workingDirectory(in: project))
    #expect(codex["sandboxPolicy"]?["writableRoots"].array.first?.string == "/tmp/wt/project/chat-abcdef/app")
    #expect(ClaudeIntegration.isWithinProject("/tmp/wt/project/chat-abcdef/app/main.swift", cwd: chat.workingDirectory(in: project)))
    #expect(!ClaudeIntegration.isWithinProject("/tmp/project/main.swift", cwd: chat.workingDirectory(in: project)))
}

@Test func chatsWithoutAWorktreeDecodeAsBefore() throws {
    let projectID = "00000000-0000-0000-0000-000000000001"
    let legacy = Data(#"{"projects":[{"id":"\#(projectID)","name":"legacy","path":"/tmp/legacy"}],"chats":[{"id":"c1","projectID":"\#(projectID)","title":"Old","model":"m","updated":0}],"model":""}"#.utf8)
    var state = try JSONDecoder().decode(SavedState.self, from: legacy)
    #expect(state.chats[0].worktree == nil)
    #expect(state.chats[0].workingDirectory(in: state.projects[0]) == "/tmp/legacy")
    var worktree = ChatWorktree(path: "/tmp/wt/legacy/chat-123456", branch: "switchboard/chat-123456", subfolder: "app")
    worktree.branchSettled = true
    state.chats[0].worktree = worktree
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    #expect(restored.chats[0].worktree == worktree)
}

@Test @MainActor func modelRoutesChatFoldersAndOffersOnlyItsOwnWorktrees() async throws {
    let sandbox = try await Sandbox.make()
    defer { sandbox.remove() }
    let data = sandbox.folder.appendingPathComponent("data")
    let model = DeskModel(store: AppStore(file: data.appendingPathComponent("state.sqlite")),
                          pluginDirectory: data.appendingPathComponent("plugins"),
                          jobStore: JobStore(file: data.appendingPathComponent("jobs.json")))
    model.worktrees = sandbox.engine
    let project = Project(path: sandbox.repo.path)
    model.state.projects = [project]
    let worktree = try await sandbox.engine.create(projectPath: project.path)
    var own = Chat(id: "own", projectID: project.id, title: "Own", model: "")
    own.worktree = worktree
    var shared = Chat(id: "shared", projectID: project.id, title: "Shared", model: "")
    shared.worktree = ChatWorktree(path: "/tmp/elsewhere", branch: "feature", existing: true)
    model.state.chats = [own, shared, Chat(id: "plain", projectID: project.id, title: "Plain", model: "")]
    #expect(model.workingDirectory(forChat: "own") == worktree.path)
    #expect(model.workingDirectory(forChat: "plain") == project.path)
    #expect(model.workingDirectory(forChat: "missing") == nil)
    #expect(model.trackedGitPaths == [project.path, worktree.path, "/tmp/elsewhere"])

    // A worktree outside the app's root is never offered for removal; the app's own one is, once.
    model.offerWorktreeRemoval(shared)
    #expect(model.worktreeRemovalOffers.isEmpty)
    model.state.chats.removeAll { $0.id == "own" }
    model.offerWorktreeRemoval(own)
    model.offerWorktreeRemoval(own)
    #expect(model.worktreeRemovalOffers.map(\.worktree) == [worktree])
    model.answerWorktreeRemoval(model.worktreeRemovalOffers[0], remove: false)
    #expect(model.worktreeRemovalOffers.isEmpty)
    #expect(FileManager.default.fileExists(atPath: worktree.path))

    // A new chat's worktree is created once and reused by a send that did not go out.
    model.newChatWorkspaces[project.id] = .newWorktree
    let first = await model.worktreeForNewChat(project)
    #expect(!first.failed)
    let created = try #require(first.worktree)
    #expect(model.newChatWorkspaces[project.id] == .worktree(created))
    #expect(await model.worktreeForNewChat(project).worktree == created)
    model.consumeNewChatWorktree(created, project: project.id)
    #expect(model.newChatWorkspaces[project.id] == nil)
}
