import Foundation

/// One changed file in `git status --porcelain=v1`: the index (X) and work-tree (Y) codes and, for a rename or
/// copy, the source path. Paths are relative to the repository root.
public struct GitWorkingFile: Identifiable, Equatable, Sendable {
    public var path: String
    public var originalPath: String?
    public var index: Character
    public var workTree: Character
    public var id: String { path }

    public init(path: String, originalPath: String? = nil, index: Character, workTree: Character) {
        self.path = path; self.originalPath = originalPath; self.index = index; self.workTree = workTree
    }

    public var isUntracked: Bool { index == "?" }
    /// One letter for the file list: the work-tree change when there is one, otherwise the staged one.
    public var code: String { isUntracked ? "?" : String(workTree == " " ? index : workTree) }
    /// A deletion already staged: the path exists neither in the work tree nor in the index, so `git add` would
    /// reject it; `git commit -- path` still records it.
    var isStagedDeletion: Bool { index == "D" && workTree == " " }

    /// Parses `git status --porcelain=v1 -z`; with -z a rename or copy carries its source path as the next field.
    public static func parse(_ output: Data) -> [GitWorkingFile] {
        let fields = output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var files: [GitWorkingFile] = []
        var index = 0
        while index < fields.count {
            let field = Array(fields[index])
            index += 1
            guard field.count > 3, field[2] == " " else { continue }
            var file = GitWorkingFile(path: String(field[3...]), index: field[0], workTree: field[1])
            if file.index == "!" { continue }
            if "RC".contains(file.index) || "RC".contains(file.workTree), index < fields.count {
                file.originalPath = fields[index]; index += 1
            }
            files.append(file)
        }
        return files
    }
}

/// What the git actions need to know about a folder's repository.
public struct GitRepositoryState: Equatable, Sendable {
    /// The work tree's top level; every action runs there because porcelain paths are relative to it.
    public var root: String
    public var status: GitStatus
    public var files: [GitWorkingFile]
    /// The remote pushes and pull requests use: the upstream's, else `origin`, else the only one. Nil without remotes.
    public var remote: String?
    /// The repository's default branch (remote HEAD, GitHub, or a local main/master), nil when unknown.
    public var defaultBranch: String?

    public init(root: String, status: GitStatus, files: [GitWorkingFile] = [], remote: String? = nil, defaultBranch: String? = nil) {
        self.root = root; self.status = status; self.files = files; self.remote = remote; self.defaultBranch = defaultBranch
    }

    /// The upstream's branch name without the remote, e.g. `feature` for `origin/feature`.
    public var upstreamBranch: String? {
        guard let upstream = status.upstream else { return nil }
        if let remote, upstream.hasPrefix(remote + "/") { return String(upstream.dropFirst(remote.count + 1)) }
        return upstream.split(separator: "/", maxSplits: 1).last.map(String.init)
    }

    /// The branch on the remote that a push or a pull request would use.
    public var pushBranch: String? { upstreamBranch ?? status.branch }

    /// Pushing here lands directly on the default branch, so it needs an explicit confirmation.
    public var pushesToDefaultBranch: Bool {
        guard let target = pushBranch else { return false }
        if let defaultBranch { return target == defaultBranch }
        return ["main", "master"].contains(target)
    }
}

/// Whether the branch already has an open pull request (checked with `gh`).
public enum GitPullRequestLookup: Equatable, Sendable {
    case checking
    case none
    case open(String)
    /// `gh` did not answer (for example not signed in); creating stays possible and `gh` reports any problem.
    case failed(String)
}

public enum GitAction: String, CaseIterable, Identifiable, Sendable {
    case commit, commitAndPush, commitPushAndCreatePR, push, pull, createPR
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .commit: L10n.text("Закоммитить", "Commit")
        case .commitAndPush: L10n.text("Закоммитить и отправить", "Commit & push")
        case .commitPushAndCreatePR: L10n.text("Закоммитить, отправить и создать PR", "Commit, push & create PR")
        case .push: L10n.text("Отправить", "Push")
        case .pull: L10n.text("Подтянуть", "Pull")
        case .createPR: L10n.text("Создать PR", "Create PR")
        }
    }

    public var commits: Bool { [.commit, .commitAndPush, .commitPushAndCreatePR].contains(self) }
    public var pushes: Bool { [.commitAndPush, .commitPushAndCreatePR, .push].contains(self) }
    public var createsPullRequest: Bool { [.commitPushAndCreatePR, .createPR].contains(self) }
}

public enum GitActionAvailability: Equatable, Sendable {
    case enabled
    case disabled(String)
    /// Not offered at all, with the hint shown instead (`gh` missing).
    case hidden(String)

    public var isEnabled: Bool { self == .enabled }
    public var reason: String? {
        switch self { case .enabled: nil; case .disabled(let text), .hidden(let text): text }
    }
}

/// The git actions offered from the branch chip: commit, push (`-u` without an upstream), `pull --ff-only` and
/// `gh pr create`. No force push, rebase or reset anywhere. Each call runs once and reports git's own output; a
/// timeout or launch failure is reported, never retried.
public struct GitActions: Sendable {
    public struct Outcome: Equatable, Sendable {
        public var succeeded: Bool
        /// git's or gh's output and errors, for the user to read.
        public var output: String
        /// The created pull request's address.
        public var url: String?
        /// The command did not answer in time and may have completed; it must not be run again blindly.
        public var uncertain: Bool
        public init(succeeded: Bool, output: String, url: String? = nil, uncertain: Bool = false) {
            self.succeeded = succeeded; self.output = output; self.url = url; self.uncertain = uncertain
        }
    }

    let git: GitRunner
    let gitHub: GitRunner?

    /// Commits run hooks and pushes talk to the network, hence the generous git timeout.
    public init(git: GitRunner = GitRunner(timeout: 120, environment: ["PATH": GitActions.toolPath]),
                gitHub: GitRunner? = GitRunner.gitHub(timeout: 60)) {
        self.git = git; self.gitHub = gitHub
    }

    /// Hooks and helpers (git-lfs, linters, credential helpers) usually live in Homebrew or ~/.local/bin, which an
    /// app started from the Dock does not have on its PATH.
    public static var toolPath: String {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
         ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
    }

    public var gitHubAvailable: Bool { gitHub != nil }

    // MARK: Availability

    public static func availability(_ action: GitAction, state: GitRepositoryState, gitHubAvailable: Bool,
                                    pullRequest: GitPullRequestLookup, folderBusy: Bool) -> GitActionAvailability {
        let status = state.status
        if action.createsPullRequest && !gitHubAvailable {
            return .hidden(L10n.text("Нужен GitHub CLI (gh)", "Requires GitHub CLI (gh)"))
        }
        if folderBusy {
            return .disabled(L10n.text("Агент работает в этой папке: дождись конца хода", "An agent is working in this folder: wait for the turn to end"))
        }
        guard let branch = status.branch else {
            return .disabled(L10n.text("HEAD отсоединён: переключись на ветку, чтобы коммитить и отправлять",
                                       "Detached HEAD: switch to a branch to commit or push"))
        }
        if action.commits && !status.hasChanges {
            return .disabled(L10n.text("Нет изменений для коммита", "No changes to commit"))
        }
        if action.pushes || action.createsPullRequest {
            guard state.remote != nil else { return .disabled(L10n.text("У репозитория нет удалённого репозитория", "The repository has no remote")) }
            if status.behind > 0 {
                return .disabled(L10n.text("Ветка отстаёт от \(status.upstream ?? "") на \(status.behind): сначала подтяни",
                                           "The branch is \(status.behind) behind \(status.upstream ?? ""): pull first"))
            }
        }
        if action.createsPullRequest {
            if let base = state.defaultBranch, state.pushBranch == base || branch == base {
                return .disabled(L10n.text("Это основная ветка: для PR создай отдельную", "This is the default branch: create another branch for a pull request"))
            }
            switch pullRequest {
            case .checking: return .disabled(L10n.text("Проверяю, есть ли уже PR…", "Checking for an existing pull request…"))
            case .open: return .disabled(L10n.text("Для этой ветки уже открыт PR", "This branch already has an open pull request"))
            case .none, .failed: break
            }
        }
        switch action {
        case .commit, .commitAndPush, .commitPushAndCreatePR:
            return .enabled
        case .push:
            guard status.commit != nil else { return .disabled(L10n.text("В ветке ещё нет коммитов", "The branch has no commits yet")) }
            if status.upstream != nil && status.ahead == 0 { return .disabled(L10n.text("Нечего отправлять", "Nothing to push")) }
            return .enabled
        case .pull:
            guard status.upstream != nil else { return .disabled(L10n.text("У ветки нет вышестоящей ветки", "The branch has no upstream")) }
            return .enabled
        case .createPR:
            guard status.upstream != nil else { return .disabled(L10n.text("Сначала отправь ветку", "Push the branch first")) }
            if status.ahead > 0 {
                return .disabled(L10n.text("Сначала отправь коммиты: не отправлено \(status.ahead)", "Push first: \(status.ahead) commits are not pushed"))
            }
            return .enabled
        }
    }

    // MARK: Reading

    /// The folder's repository state; nil outside a work tree. Only local git commands: no fetch, no `gh`
    /// unless the default branch cannot be found locally.
    public func state(at folder: String) async -> GitRepositoryState? {
        guard let top = try? await git.run(["rev-parse", "--show-toplevel"], in: folder), top.succeeded else { return nil }
        let root = top.text.trimmingCharacters(in: .newlines)
        guard root.hasPrefix("/"), let status = try? await GitStatus.read(at: root, runner: git),
              let listed = try? await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root), listed.succeeded else { return nil }
        var state = GitRepositoryState(root: root, status: status, files: GitWorkingFile.parse(listed.output))
        state.remote = await remote(root: root, upstream: status.upstream)
        if let remote = state.remote { state.defaultBranch = await defaultBranch(root: root, remote: remote) }
        return state
    }

    func remote(root: String, upstream: String?) async -> String? {
        guard let listed = try? await git.run(["remote"], in: root), listed.succeeded else { return nil }
        let remotes = listed.text.split(separator: "\n").map(String.init)
        if let upstream, let match = remotes.filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) { return match }
        if remotes.contains("origin") { return "origin" }
        return remotes.count == 1 ? remotes[0] : nil
    }

    /// The remote's HEAD (`refs/remotes/<remote>/HEAD`), else GitHub's default branch, else main or master if
    /// the remote or the repository has one.
    public func defaultBranch(root: String, remote: String) async -> String? {
        if let head = try? await git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], in: root), head.succeeded {
            let name = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix(remote + "/") { return String(name.dropFirst(remote.count + 1)) }
        }
        if let gitHub, let view = try? await gitHub.run(["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], in: root),
           view.succeeded {
            let name = view.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !name.contains(where: \.isWhitespace) { return name }
        }
        for name in ["main", "master"] {
            for ref in ["refs/remotes/\(remote)/\(name)", "refs/heads/\(name)"] {
                if let found = try? await git.run(["rev-parse", "--verify", "--quiet", ref], in: root), found.succeeded { return name }
            }
        }
        return nil
    }

    /// Branches on the remote, for the pull request's base picker; the default branch first.
    public func remoteBranches(root: String, remote: String, defaultBranch: String?) async -> [String] {
        guard let listed = try? await git.run(["for-each-ref", "--format=%(refname:short)", "refs/remotes/\(remote)/"], in: root),
              listed.succeeded else { return defaultBranch.map { [$0] } ?? [] }
        let prefix = remote + "/"
        var names: [String] = []
        for line in listed.text.split(separator: "\n") where line.hasPrefix(prefix) {
            let name = String(line.dropFirst(prefix.count))
            if name != "HEAD" && !name.isEmpty { names.append(name) }
        }
        if let defaultBranch {
            names.removeAll { $0 == defaultBranch }
            names.insert(defaultBranch, at: 0)
        }
        return names
    }

    /// The branch's open pull request, if any, from `gh pr list --head`.
    public func pullRequest(root: String, head: String) async -> GitPullRequestLookup {
        guard let gitHub else { return .failed(L10n.text("Нужен GitHub CLI (gh)", "Requires GitHub CLI (gh)")) }
        do {
            let result = try await gitHub.run(["pr", "list", "--head", head, "--state", "open", "--json", "url", "--limit", "1"], in: root)
            guard result.succeeded else { return .failed(Self.message(result, tool: "gh")) }
            struct Entry: Decodable { var url: String }
            guard let entries = try? JSONDecoder().decode([Entry].self, from: result.output) else {
                return .failed(L10n.text("gh вернул непонятный ответ", "gh returned an unrecognized answer"))
            }
            return entries.first.map { .open($0.url) } ?? .none
        } catch {
            return .failed(Self.describe(error, tool: "gh"))
        }
    }

    // MARK: Generation context

    /// What the commit draft is based on: recent subjects and the exact diff of the selected files as they would
    /// be committed, built in a private copy of the index so the user's index stays untouched.
    public func commitContext(root: String, files: [GitWorkingFile]) async throws -> (recentCommits: String, stat: String, diff: String) {
        let log = (try? await git.run(["log", "--oneline", "--no-decorate", "-15"], in: root)).flatMap { $0.succeeded ? $0.text : nil } ?? ""
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-commit-\(UUID().uuidString).index")
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(at: index.appendingPathExtension("lock"))
        }
        var privateGit = git
        privateGit.environment["GIT_INDEX_FILE"] = index.path
        let located = try await checked(["rev-parse", "--git-path", "index"], in: root).text.trimmingCharacters(in: .newlines)
        let userIndex = located.hasPrefix("/") ? located : root + "/" + located
        if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: userIndex), to: index)) == nil {
            _ = try? await privateGit.run(["read-tree", "HEAD"], in: root)
        }
        let added = Self.addPaths(files)
        if !added.isEmpty { _ = try await checked(["add", "--"] + added, in: root, runner: privateGit) }
        let paths = Self.commitPaths(files)
        let stat = try await checked(["diff", "--cached", "--no-color", "--no-ext-diff", "--stat=100", "--"] + paths, in: root, runner: privateGit).text
        let diff = try await checked(["diff", "--cached", "--no-color", "--no-ext-diff", "--"] + paths, in: root, runner: privateGit).text
        return (log, stat, diff)
    }

    /// What the pull request draft is based on: the branch's commits, file statistics and diff against the
    /// base, and the repository's pull request template.
    public func pullRequestContext(root: String, remote: String, base: String) async throws -> (commits: String, stat: String, diff: String, template: String?) {
        let baseRef = (try? await git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(base)"], in: root))?.succeeded == true
            ? "\(remote)/\(base)" : base
        let commits = try await checked(["log", "--no-decorate", "--no-merges", "--format=- %s%n%w(0,2,2)%b", "-100", "\(baseRef)..HEAD"], in: root).text
        let stat = try await checked(["diff", "--no-color", "--no-ext-diff", "--stat=100", "\(baseRef)...HEAD"], in: root).text
        let diff = try await checked(["diff", "--no-color", "--no-ext-diff", "\(baseRef)...HEAD"], in: root).text
        return (commits, stat, diff, Self.pullRequestTemplate(root: root))
    }

    /// `.github/pull_request_template.md` (any letter case), as GitHub reads it.
    public static func pullRequestTemplate(root: String) -> String? {
        for name in ["pull_request_template.md", "PULL_REQUEST_TEMPLATE.md"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(".github").appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), data.count <= 64 * 1024 {
                let text = String(decoding: data, as: UTF8.self)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
        }
        return nil
    }

    // MARK: Actions

    /// `git add -- <files>` then `git commit -m <message> -- <files>`, once each. The pathspec keeps anything
    /// else that was already staged out of this commit; hooks run as usual.
    public func commit(_ files: [GitWorkingFile], message: String, root: String) async -> Outcome {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return Outcome(succeeded: false, output: L10n.text("Пустое сообщение коммита", "Empty commit message")) }
        guard !files.isEmpty else { return Outcome(succeeded: false, output: L10n.text("Не выбраны файлы", "No files selected")) }
        var output: [String] = []
        let added = Self.addPaths(files)
        if !added.isEmpty {
            let add = await run(["add", "--"] + added, in: root, tool: "git", runner: git)
            if !add.output.isEmpty { output.append(add.output) }
            guard add.succeeded else { return Outcome(succeeded: false, output: output.joined(separator: "\n"), uncertain: add.uncertain) }
        }
        let commit = await run(["commit", "-m", message, "--"] + Self.commitPaths(files), in: root, tool: "git", runner: git)
        output.append(commit.output)
        return Outcome(succeeded: commit.succeeded, output: output.filter { !$0.isEmpty }.joined(separator: "\n"), uncertain: commit.uncertain)
    }

    /// `git push`, or `git push -u <remote> <branch>` when the branch has no upstream. Never forced.
    public func push(state: GitRepositoryState) async -> Outcome {
        await run(Self.pushArguments(state: state), in: state.root, tool: "git", runner: git)
    }

    public static func pushArguments(state: GitRepositoryState) -> [String] {
        guard state.status.upstream == nil, let remote = state.remote, let branch = state.status.branch else { return ["push"] }
        return ["push", "-u", remote, branch]
    }

    /// `git pull --no-rebase --ff-only`: fast-forward or refuse, never merge or rebase.
    public func pull(root: String) async -> Outcome {
        await run(["pull", "--no-rebase", "--ff-only"], in: root, tool: "git", runner: git)
    }

    public static func pullRequestArguments(title: String, base: String, head: String, draft: Bool) -> [String] {
        ["pr", "create", "--title", title, "--body-file", "-", "--base", base, "--head", head] + (draft ? ["--draft"] : [])
    }

    /// `gh pr create` once, the body on stdin. The pull request's address is read from gh's output.
    public func createPullRequest(title: String, body: String, base: String, head: String, draft: Bool, root: String) async -> Outcome {
        guard let gitHub else { return Outcome(succeeded: false, output: L10n.text("Нужен GitHub CLI (gh)", "Requires GitHub CLI (gh)")) }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return Outcome(succeeded: false, output: L10n.text("Пустой заголовок PR", "Empty pull request title")) }
        guard !base.isEmpty, !head.isEmpty, !base.hasPrefix("-"), !head.hasPrefix("-") else {
            return Outcome(succeeded: false, output: L10n.text("Недопустимое имя ветки", "Invalid branch name"))
        }
        var outcome = await run(Self.pullRequestArguments(title: title, base: base, head: head, draft: draft), in: root, tool: "gh",
                                runner: gitHub, input: Data(body.utf8))
        if outcome.succeeded {
            outcome.url = outcome.output.split(whereSeparator: \.isWhitespace).map(String.init).last { $0.hasPrefix("https://") }
        }
        return outcome
    }

    // MARK: Helpers

    /// Paths for `git add`: sources of renames are already staged, and a staged deletion has nothing to add.
    static func addPaths(_ files: [GitWorkingFile]) -> [String] {
        files.filter { !$0.isStagedDeletion }.map(\.path)
    }

    /// Paths for the commit's pathspec, rename sources included so the rename is committed whole.
    static func commitPaths(_ files: [GitWorkingFile]) -> [String] {
        var seen = Set<String>(), paths: [String] = []
        for file in files {
            for path in [file.path, file.originalPath].compactMap({ $0 }) where seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    private func run(_ arguments: [String], in root: String, tool: String, runner: GitRunner, input: Data? = nil) async -> Outcome {
        do {
            let result = try await runner.run(arguments, in: root, input: input)
            let text = [result.text.trimmingCharacters(in: .whitespacesAndNewlines), result.errors].filter { !$0.isEmpty }.joined(separator: "\n")
            if result.succeeded { return Outcome(succeeded: true, output: text) }
            return Outcome(succeeded: false, output: text.isEmpty ? Self.message(result, tool: tool) : text)
        } catch {
            return Outcome(succeeded: false, output: Self.describe(error, tool: tool), uncertain: error == .timedOut)
        }
    }

    private func checked(_ arguments: [String], in root: String, runner: GitRunner? = nil) async throws -> GitRunner.Result {
        let result: GitRunner.Result
        do { result = try await (runner ?? git).run(arguments, in: root) }
        catch { throw ClientFailure(Self.describe(error, tool: "git")) }
        guard result.succeeded else { throw ClientFailure(Self.message(result, tool: "git")) }
        return result
    }

    static func message(_ result: GitRunner.Result, tool: String) -> String {
        result.errors.isEmpty ? L10n.text("\(tool) завершился с кодом \(result.status)", "\(tool) exited with status \(result.status)") : result.errors
    }

    static func describe(_ error: GitRunner.Failure, tool: String) -> String {
        switch error {
        case .timedOut:
            L10n.text("\(tool) не ответил вовремя; команда могла выполниться и не повторяется",
                      "\(tool) timed out; the command may have completed and was not retried")
        case .launch(let message): message
        }
    }
}
