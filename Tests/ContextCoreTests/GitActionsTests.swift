import Foundation
import Testing
import AgentContract
@testable import ContextCore

/// A temporary folder with git repositories configured so the user's global identity, signing and hooks never apply.
private struct GitSandbox {
    let root: URL
    let git = GitRunner(timeout: 30)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func run(_ arguments: [String], in directory: URL, expect succeeded: Bool = true) async throws -> GitRunner.Result {
        let result = try await git.run(arguments, in: directory.path)
        #expect(result.succeeded == succeeded, "\(arguments): \(result.errors)")
        return result
    }

    func configure(_ repo: URL) async throws {
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", "/dev/null"), ("push.default", "simple")] {
            try await run(["config", key, value], in: repo)
        }
    }

    /// A repository with one commit on main.
    func repository(_ name: String = "repo") async throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await run(["init", "-q", "-b", "main"], in: repo)
        try await configure(repo)
        try write("base\n", to: "base.txt", in: repo)
        try await run(["add", "base.txt"], in: repo)
        try await run(["commit", "-q", "-m", "Initial commit"], in: repo)
        return repo
    }

    /// A local bare repository added to `repo` as `origin`.
    func bareOrigin(for repo: URL) async throws -> URL {
        let bare = root.appendingPathComponent("origin.git")
        try await run(["init", "-q", "--bare", "-b", "main", bare.path], in: root)
        try await run(["remote", "add", "origin", bare.path], in: repo)
        return bare
    }

    func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func head(_ repo: URL, _ ref: String = "HEAD") async throws -> String {
        try await run(["rev-parse", ref], in: repo).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `ref` in `first` is the commit checked out in `second`.
    func same(_ first: URL, _ ref: String, as second: URL) async throws -> Bool {
        let one = try await head(first, ref), two = try await head(second)
        return !one.isEmpty && one == two
    }
}

private func actions(gitHub: GitRunner? = nil) -> GitActions { GitActions(git: GitRunner(timeout: 30), gitHub: gitHub) }

@Test func gitActionAvailabilityFollowsTheRepositoryState() {
    func check(_ action: GitAction, _ status: GitStatus, remote: String? = "origin", defaultBranch: String? = "main",
               gh: Bool = true, pr: GitPullRequestLookup = .none, busy: Bool = false) -> GitActionAvailability {
        GitActions.availability(action, state: GitRepositoryState(root: "/r", status: status, remote: remote, defaultBranch: defaultBranch),
                                gitHubAvailable: gh, pullRequest: pr, folderBusy: busy)
    }
    let dirty = GitStatus(branch: "feature", commit: "abc", upstream: "origin/feature", changedFiles: 2)
    let clean = GitStatus(branch: "feature", commit: "abc", upstream: "origin/feature")
    #expect(check(.commit, dirty) == .enabled)
    #expect(check(.commitAndPush, dirty) == .enabled)
    #expect(check(.commitPushAndCreatePR, dirty) == .enabled)
    #expect(!check(.commit, clean).isEnabled)
    // Nothing ahead of the upstream: nothing to push; a pushed branch without a PR can get one.
    #expect(!check(.push, clean).isEnabled)
    #expect(check(.createPR, clean) == .enabled)
    #expect(check(.pull, clean) == .enabled)
    // Without an upstream the first push sets it; a pull request needs the branch pushed.
    let local = GitStatus(branch: "feature", commit: "abc")
    #expect(check(.push, local) == .enabled)
    #expect(!check(.pull, local).isEnabled && !check(.createPR, local).isEnabled)
    #expect(!check(.createPR, GitStatus(branch: "feature", commit: "abc", upstream: "origin/feature", ahead: 1)).isEnabled)
    // Detached HEAD disables commits with an explanation.
    let detached = check(.commit, GitStatus(commit: "abc", changedFiles: 1))
    #expect(!detached.isEnabled && detached.reason?.isEmpty == false)
    // Behind the upstream: commit stays possible, pushing waits for a pull.
    let behind = GitStatus(branch: "feature", commit: "abc", upstream: "origin/feature", ahead: 1, behind: 2, changedFiles: 1)
    #expect(check(.commit, behind) == .enabled)
    #expect(!check(.push, behind).isEnabled && !check(.commitAndPush, behind).isEnabled && check(.pull, behind) == .enabled)
    // No remote, a busy folder, an open PR, the default branch and a missing gh.
    #expect(!check(.push, local, remote: nil).isEnabled)
    for action in GitAction.allCases { #expect(!check(action, dirty, busy: true).isEnabled) }
    #expect(!check(.createPR, clean, pr: .open("https://example.com/pr/1")).isEnabled)
    #expect(!check(.createPR, clean, pr: .checking).isEnabled)
    #expect(check(.createPR, clean, pr: .failed("not signed in")) == .enabled)
    #expect(!check(.createPR, GitStatus(branch: "main", commit: "abc", upstream: "origin/main")).isEnabled)
    #expect(check(.createPR, clean, gh: false) == .hidden("Requires GitHub CLI (gh)") || check(.createPR, clean, gh: false) == .hidden("Нужен GitHub CLI (gh)"))
    if case .hidden = check(.commitPushAndCreatePR, dirty, gh: false) {} else { Issue.record("PR action shown without gh") }
    #expect(check(.commitAndPush, dirty, gh: false) == .enabled)

    // Pushing lands on the default branch: by name, by upstream, or main/master when the default is unknown.
    #expect(GitRepositoryState(root: "/r", status: GitStatus(branch: "main"), remote: "origin", defaultBranch: "main").pushesToDefaultBranch)
    #expect(GitRepositoryState(root: "/r", status: GitStatus(branch: "work", upstream: "origin/trunk"), remote: "origin", defaultBranch: "trunk").pushesToDefaultBranch)
    #expect(GitRepositoryState(root: "/r", status: GitStatus(branch: "master"), remote: "origin").pushesToDefaultBranch)
    #expect(!GitRepositoryState(root: "/r", status: GitStatus(branch: "feature"), remote: "origin", defaultBranch: "main").pushesToDefaultBranch)
}

@Test func gitWorkingFilesParseRenamesAndUntrackedFiles() {
    let output = ["R  new name.swift", "old name.swift", " M Sources/a.swift", "D  gone.txt", "?? notes/todo.md", "!! build.log", "AM added.txt"]
        .joined(separator: "\0") + "\0"
    let files = GitWorkingFile.parse(Data(output.utf8))
    #expect(files.map(\.path) == ["new name.swift", "Sources/a.swift", "gone.txt", "notes/todo.md", "added.txt"])
    #expect(files[0].originalPath == "old name.swift" && files[0].code == "R")
    #expect(files[1].code == "M" && files[3].isUntracked && files[3].code == "?" && files[4].code == "M")
    #expect(GitActions.addPaths(files) == ["new name.swift", "Sources/a.swift", "notes/todo.md", "added.txt"])
    #expect(GitActions.commitPaths(files) == ["new name.swift", "old name.swift", "Sources/a.swift", "gone.txt", "notes/todo.md", "added.txt"])
}

@Test func gitCommitRecordsOnlyTheSelectedFiles() async throws {
    let sandbox = try GitSandbox()
    defer { sandbox.remove() }
    let repo = try await sandbox.repository()
    for name in ["keep.txt", "rename-me.txt", "delete-me.txt", "staged-elsewhere.txt"] { try sandbox.write("\(name)\n", to: name, in: repo) }
    try await sandbox.run(["add", "."], in: repo)
    try await sandbox.run(["commit", "-q", "-m", "Add files"], in: repo)

    try sandbox.write("changed\n", to: "keep.txt", in: repo)
    try sandbox.write("new\n", to: "dir/new.txt", in: repo)
    try sandbox.write("left out\n", to: "untracked-excluded.txt", in: repo)
    try FileManager.default.removeItem(at: repo.appendingPathComponent("delete-me.txt"))
    try await sandbox.run(["mv", "rename-me.txt", "renamed.txt"], in: repo)
    try sandbox.write("staged but excluded\n", to: "staged-elsewhere.txt", in: repo)
    try await sandbox.run(["add", "staged-elsewhere.txt"], in: repo)

    let git = actions()
    let state = try #require(await git.state(at: repo.appendingPathComponent("dir").path))
    // The work tree's top level, not the subfolder (Foundation drops the /private prefix when resolving).
    #expect(URL(fileURLWithPath: state.root).resolvingSymlinksInPath().path == repo.path)
    #expect(Set(state.files.map(\.path)) == ["keep.txt", "dir/new.txt", "untracked-excluded.txt", "delete-me.txt", "renamed.txt", "staged-elsewhere.txt"])
    let selected = state.files.filter { ["keep.txt", "dir/new.txt", "delete-me.txt", "renamed.txt"].contains($0.path) }

    // The draft's diff covers exactly the selected files, untracked content included, and leaves the index alone.
    let context = try await git.commitContext(root: state.root, files: selected)
    #expect(context.recentCommits.contains("Add files"))
    #expect(context.diff.contains("+new") && context.diff.contains("+changed") && context.diff.contains("delete-me.txt"))
    #expect(!context.diff.contains("staged but excluded") && !context.diff.contains("left out"))
    #expect(try await sandbox.run(["diff", "--cached", "--name-only", "--no-renames"], in: repo).text.split(separator: "\n").sorted()
            == ["rename-me.txt", "renamed.txt", "staged-elsewhere.txt"])

    let outcome = await git.commit(selected, message: "Update selected files", root: state.root)
    #expect(outcome.succeeded, "\(outcome.output)")
    let committed = try await sandbox.run(["show", "--name-status", "--format=%s", "HEAD"], in: repo).text
    #expect(committed.hasPrefix("Update selected files"))
    for line in ["M\tkeep.txt", "A\tdir/new.txt", "D\tdelete-me.txt"] { #expect(committed.contains(line), "\(committed)") }
    #expect(committed.contains("renamed.txt") && committed.contains("rename-me.txt"))
    #expect(!committed.contains("staged-elsewhere.txt") && !committed.contains("untracked-excluded.txt"))
    // The excluded staged file is still staged, the excluded untracked one untouched.
    let status = try await sandbox.run(["status", "--porcelain=v1"], in: repo).text
    #expect(status.contains("M  staged-elsewhere.txt") && status.contains("?? untracked-excluded.txt"))

    let empty = await git.commit([], message: "x", root: state.root)
    #expect(!empty.succeeded)
    let noMessage = await git.commit(selected, message: "  ", root: state.root)
    #expect(!noMessage.succeeded)
}

@Test func gitPushSetsTheUpstreamFirstThenPushesToTheBareRemote() async throws {
    let sandbox = try GitSandbox()
    defer { sandbox.remove() }
    let repo = try await sandbox.repository()
    let bare = try await sandbox.bareOrigin(for: repo)
    let git = actions()

    var state = try #require(await git.state(at: repo.path))
    #expect(state.remote == "origin" && state.status.upstream == nil)
    #expect(GitActions.pushArguments(state: state) == ["push", "-u", "origin", "main"])
    var outcome = await git.push(state: state)
    #expect(outcome.succeeded, "\(outcome.output)")
    #expect(try await sandbox.same(bare, "refs/heads/main", as: repo))

    try sandbox.write("more\n", to: "base.txt", in: repo)
    try await sandbox.run(["commit", "-q", "-am", "Second"], in: repo)
    state = try #require(await git.state(at: repo.path))
    #expect(state.status.upstream == "origin/main" && state.status.ahead == 1)
    #expect(GitActions.pushArguments(state: state) == ["push"])
    #expect(state.pushesToDefaultBranch)
    outcome = await git.push(state: state)
    #expect(outcome.succeeded, "\(outcome.output)")
    #expect(try await sandbox.same(bare, "refs/heads/main", as: repo))

    // A feature branch pushed with -u is not the default branch.
    try await sandbox.run(["switch", "-q", "-c", "feature"], in: repo)
    try sandbox.write("feature\n", to: "feature.txt", in: repo)
    try await sandbox.run(["add", "feature.txt"], in: repo)
    try await sandbox.run(["commit", "-q", "-m", "Feature"], in: repo)
    state = try #require(await git.state(at: repo.path))
    #expect(!state.pushesToDefaultBranch && GitActions.pushArguments(state: state) == ["push", "-u", "origin", "feature"])
    outcome = await git.push(state: state)
    #expect(outcome.succeeded, "\(outcome.output)")
    #expect(try await sandbox.same(bare, "refs/heads/feature", as: repo))
    #expect(await git.remoteBranches(root: repo.path, remote: "origin", defaultBranch: "main") == ["main", "feature"])

    // An unreachable remote fails with git's own error and no prompt.
    try await sandbox.run(["remote", "set-url", "origin", sandbox.root.appendingPathComponent("missing.git").path], in: repo)
    try await sandbox.run(["commit", "-q", "--allow-empty", "-m", "Unpushed"], in: repo)
    state = try #require(await git.state(at: repo.path))
    outcome = await git.push(state: state)
    #expect(!outcome.succeeded && !outcome.output.isEmpty && !outcome.uncertain)
}

@Test func gitDefaultBranchComesFromTheRemoteHeadThenGitHubThenMainOrMaster() async throws {
    let sandbox = try GitSandbox()
    defer { sandbox.remove() }
    let repo = try await sandbox.repository()
    let bare = try await sandbox.bareOrigin(for: repo)
    let git = actions()
    // No remote branches and no gh: the local main.
    #expect(await git.defaultBranch(root: repo.path, remote: "origin") == "main")

    // The remote's HEAD wins once known.
    try await sandbox.run(["switch", "-q", "-c", "trunk"], in: repo)
    try await sandbox.run(["push", "-q", "origin", "main", "trunk"], in: repo)
    try await sandbox.run(["symbolic-ref", "HEAD", "refs/heads/trunk"], in: bare)
    try await sandbox.run(["remote", "set-head", "origin", "-a"], in: repo)
    #expect(await git.defaultBranch(root: repo.path, remote: "origin") == "trunk")
    let state = try #require(await git.state(at: repo.path))
    #expect(state.defaultBranch == "trunk" && state.pushesToDefaultBranch)

    // Without a remote HEAD, GitHub's answer comes before the main/master guess.
    try await sandbox.run(["remote", "set-head", "origin", "-d"], in: repo)
    let gh = try fakeGitHub(in: sandbox.root)
    #expect(await actions(gitHub: gh.runner).defaultBranch(root: repo.path, remote: "origin") == "develop")
    #expect(await actions().defaultBranch(root: repo.path, remote: "origin") == "main")
}

@Test func gitPullFastForwardsAndRefusesDivergedBranches() async throws {
    let sandbox = try GitSandbox()
    defer { sandbox.remove() }
    let repo = try await sandbox.repository()
    _ = try await sandbox.bareOrigin(for: repo)
    try await sandbox.run(["push", "-q", "-u", "origin", "main"], in: repo)
    let other = sandbox.root.appendingPathComponent("other")
    try await sandbox.run(["clone", "-q", sandbox.root.appendingPathComponent("origin.git").path, other.path], in: sandbox.root)
    try await sandbox.configure(other)
    let git = actions()

    // Fast-forward.
    try sandbox.write("remote one\n", to: "remote.txt", in: other)
    try await sandbox.run(["add", "remote.txt"], in: other)
    try await sandbox.run(["commit", "-q", "-m", "Remote one"], in: other)
    try await sandbox.run(["push", "-q"], in: other)
    var outcome = await git.pull(root: repo.path)
    #expect(outcome.succeeded, "\(outcome.output)")
    #expect(try await sandbox.same(repo, "HEAD", as: other))

    // Diverged: refused, nothing merged or rebased.
    try sandbox.write("remote two\n", to: "remote.txt", in: other)
    try await sandbox.run(["commit", "-q", "-am", "Remote two"], in: other)
    try await sandbox.run(["push", "-q"], in: other)
    try sandbox.write("local\n", to: "local.txt", in: repo)
    try await sandbox.run(["add", "local.txt"], in: repo)
    try await sandbox.run(["commit", "-q", "-m", "Local"], in: repo)
    let before = try await sandbox.head(repo)
    try await sandbox.run(["config", "pull.rebase", "true"], in: repo)
    outcome = await git.pull(root: repo.path)
    #expect(!outcome.succeeded && !outcome.output.isEmpty)
    #expect(try await sandbox.head(repo) == before)
    #expect(try await sandbox.run(["rev-list", "--count", "HEAD"], in: repo).text.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
}

/// A stand-in `gh` that records its arguments and stdin and answers `pr list`, `pr create` and `repo view`.
private func fakeGitHub(in root: URL, openPullRequest: String? = nil) throws -> (runner: GitRunner, log: URL) {
    let file = root.appendingPathComponent("gh"), log = root.appendingPathComponent("gh-calls.jsonl")
    let listed = openPullRequest.map { "[{\"url\": \"\($0)\"}]" } ?? "[]"
    try Data("""
    #!\(fixturePython)
    import json, os, sys
    args = sys.argv[1:]
    body = sys.stdin.read() if '--body-file' in args else None
    with open(os.environ['FAKE_GH_LOG'], 'a') as log:
        log.write(json.dumps({'args': args, 'stdin': body, 'cwd': os.getcwd(), 'prompt': os.environ.get('GH_PROMPT_DISABLED')}) + '\\n')
    if args[:2] == ['pr', 'list']:
        print('\(listed)')
    elif args[:2] == ['pr', 'create']:
        print('Creating pull request for feature into main\\n')
        print('https://github.com/example/repo/pull/42')
    elif args[:2] == ['repo', 'view']:
        print('develop')
    else:
        sys.exit(1)
    """.utf8).write(to: file)
    try installFixtureExecutable(at: file)
    var runner = try #require(GitRunner.gitHub(searchPaths: [file.path]))
    runner.environment["FAKE_GH_LOG"] = log.path
    return (runner, log)
}

private func recordedCalls(_ log: URL) throws -> [[String: Any]] {
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
}

@Test func gitHubPullRequestCreationPassesArgumentsAndBodyOnce() async throws {
    let sandbox = try GitSandbox()
    defer { sandbox.remove() }
    let repo = try await sandbox.repository()
    #expect(GitActions.pullRequestArguments(title: "Add feature", base: "main", head: "feature", draft: false)
            == ["pr", "create", "--title", "Add feature", "--body-file", "-", "--base", "main", "--head", "feature"])
    #expect(GitActions.pullRequestArguments(title: "--title", base: "main", head: "feature", draft: true).suffix(1) == ["--draft"])

    let gh = try fakeGitHub(in: sandbox.root)
    let git = actions(gitHub: gh.runner)
    #expect(await git.pullRequest(root: repo.path, head: "feature") == GitPullRequestLookup.none)
    let body = "## Summary\n- one\n\n`code` and \"quotes\"\n"
    let outcome = await git.createPullRequest(title: "  Add feature ", body: body, base: "main", head: "feature", draft: true, root: repo.path)
    #expect(outcome.succeeded, "\(outcome.output)")
    #expect(outcome.url == "https://github.com/example/repo/pull/42")
    let calls = try recordedCalls(gh.log)
    #expect(calls.count == 2)
    #expect(calls[1]["args"] as? [String] == ["pr", "create", "--title", "Add feature", "--body-file", "-", "--base", "main", "--head", "feature", "--draft"])
    #expect(calls[1]["stdin"] as? String == body)
    #expect(calls[1]["prompt"] as? String == "1")
    #expect((calls[1]["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == repo.path)

    // Refused before gh runs: empty title or an option-like branch.
    #expect(!(await git.createPullRequest(title: " ", body: "", base: "main", head: "feature", draft: false, root: repo.path)).succeeded)
    #expect(!(await git.createPullRequest(title: "x", body: "", base: "-x", head: "feature", draft: false, root: repo.path)).succeeded)
    #expect(try recordedCalls(gh.log).count == 2)
    #expect(!(await actions().createPullRequest(title: "x", body: "", base: "main", head: "feature", draft: false, root: repo.path)).succeeded)

    let open = try fakeGitHub(in: sandbox.root.appendingPathComponent("second").creatingDirectory(), openPullRequest: "https://github.com/example/repo/pull/7")
    #expect(await actions(gitHub: open.runner).pullRequest(root: repo.path, head: "feature") == .open("https://github.com/example/repo/pull/7"))
}

@Test func gitPullRequestContextAndTemplate() async throws {
    let sandbox = try GitSandbox()
    defer { sandbox.remove() }
    let repo = try await sandbox.repository()
    _ = try await sandbox.bareOrigin(for: repo)
    try await sandbox.run(["push", "-q", "-u", "origin", "main"], in: repo)
    try await sandbox.run(["switch", "-q", "-c", "feature"], in: repo)
    try sandbox.write("feature line\n", to: "feature.txt", in: repo)
    try await sandbox.run(["add", "feature.txt"], in: repo)
    try await sandbox.run(["commit", "-q", "-m", "Add feature file", "-m", "Explains why."], in: repo)
    try sandbox.write("## What\n\n## Why\n", to: ".github/pull_request_template.md", in: repo)
    let context = try await actions().pullRequestContext(root: repo.path, remote: "origin", base: "main")
    #expect(context.commits.contains("- Add feature file") && context.commits.contains("Explains why."))
    #expect(!context.commits.contains("Initial commit"))
    #expect(context.stat.contains("feature.txt") && context.diff.contains("+feature line"))
    #expect(context.template == "## What\n\n## Why\n")
}

@Test func gitGenerationInputsStayBoundedAndDraftsAreCleaned() throws {
    #expect(GitGeneration.truncated("short", bytes: 10) == ("short", false))
    let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
    let cut = GitGeneration.truncated(lines, bytes: 30)
    #expect(cut.truncated && cut.text.utf8.count <= 30 && cut.text.hasSuffix("\n"))
    // A cut never splits a multi-byte character.
    let cyrillic = GitGeneration.truncated(String(repeating: "я", count: 50), bytes: 15)
    #expect(cyrillic.truncated && cyrillic.text == String(repeating: "я", count: 7))

    struct Commit: Decodable { var recentCommits: String; var files: String; var diff: String; var diffTruncated: Bool }
    let hugeDiff = String(repeating: "+added line with some text\n", count: 20_000)
    let input = try GitGeneration.commitInput(recentCommits: "abc Fix bug\n", stat: " a.txt | 1 +\n", diff: hugeDiff)
    #expect(input.utf8.count <= AgentGenerationRequest.maximumInputBytes)
    let decoded = try JSONDecoder().decode(Commit.self, from: Data(input.utf8))
    #expect(decoded.diffTruncated && decoded.diff.utf8.count <= GitGeneration.diffLimit && decoded.recentCommits == "abc Fix bug\n")
    // Escaping can make the JSON much larger than the text; the diff shrinks until the request fits.
    let escaped = try GitGeneration.pullRequestInput(base: "main", head: "feature", commits: "- One\n", stat: "",
                                                     diff: String(repeating: "\u{01}\n", count: 60_000), template: "## What\n")
    #expect(escaped.utf8.count <= AgentGenerationRequest.maximumInputBytes && escaped.contains("\"diffTruncated\":true"))
    let small = try GitGeneration.commitInput(recentCommits: "", stat: "", diff: "+x\n")
    #expect(small.contains("\"diffTruncated\":false"))

    #expect(try GitGeneration.commitMessage(from: #"{"message":"Fix the parser\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n"}"#) == "Fix the parser")
    #expect(try GitGeneration.commitMessage(from: #"{"message":"```\nAdd tests\n```"}"#) == "Add tests")
    #expect(throws: (any Error).self) { try GitGeneration.commitMessage(from: #"{"message":"  "}"#) }
    #expect(throws: (any Error).self) { try GitGeneration.commitMessage(from: "not json") }
    let draft = try GitGeneration.pullRequest(from: ###"{"title":"Add feature\nsecond line","body":"## What\nThings\n\n🤖 Generated with Claude Code"}"###)
    #expect(draft == GitPullRequestText(title: "Add feature", body: "## What\nThings"))
}

private extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
