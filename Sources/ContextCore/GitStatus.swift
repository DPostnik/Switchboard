import Foundation

/// A folder's git state for the sidebar and composer: branch (or detached commit), upstream, ahead/behind and
/// how many files differ from HEAD, untracked ones included. Read with `git status --porcelain=v2 --branch -z`.
public struct GitStatus: Equatable, Sendable {
    /// Checked-out branch; nil when HEAD is detached.
    public var branch: String?
    /// HEAD commit; nil in a repository without commits.
    public var commit: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// Changed, staged, unmerged and untracked files.
    public var changedFiles = 0

    public init(branch: String? = nil, commit: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changedFiles: Int = 0) {
        self.branch = branch; self.commit = commit; self.upstream = upstream
        self.ahead = ahead; self.behind = behind; self.changedFiles = changedFiles
    }

    public var isDetached: Bool { branch == nil }
    public var hasChanges: Bool { changedFiles > 0 }
    /// The branch, or the short commit when detached.
    public var displayName: String { branch ?? commit.map { String($0.prefix(7)) } ?? "HEAD" }

    /// The branch a chat's latest turn started on, when the folder is now on another branch or commit.
    public static func branchChange(from turnBranch: String?, to current: GitStatus?) -> GitBranchChange? {
        guard let turnBranch, !turnBranch.isEmpty, let current, current.branch != turnBranch else { return nil }
        return GitBranchChange(from: turnBranch, to: current.displayName)
    }

    /// Parses `git status --porcelain=v2 --branch -z`. Unknown lines are ignored; a missing `branch.head` header
    /// (not porcelain v2 output) gives nil.
    public static func parse(_ output: Data) -> GitStatus? {
        var status = GitStatus()
        var sawHead = false
        let fields = output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix("# ") {
                let header = field.dropFirst(2)
                guard let space = header.firstIndex(of: " ") else { continue }
                let key = header[..<space], value = String(header[header.index(after: space)...])
                switch key {
                case "branch.oid": status.commit = value == "(initial)" ? nil : value
                case "branch.head": sawHead = true; status.branch = value == "(detached)" ? nil : value
                case "branch.upstream": status.upstream = value
                case "branch.ab":
                    for part in value.split(separator: " ") {
                        if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                        if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }
            switch field.first {
            case "1", "u", "?": status.changedFiles += 1
            // With -z a rename or copy carries its original path as the next field.
            case "2": status.changedFiles += 1; index += 1
            default: break
            }
        }
        return sawHead ? status : nil
    }

    /// The folder's status; nil when it is not inside a git work tree. A timeout or launch failure throws.
    public static func read(at path: String, runner: GitRunner = GitRunner()) async throws(GitRunner.Failure) -> GitStatus? {
        let result = try await runner.run(["status", "--porcelain=v2", "--branch", "-z"], in: path)
        guard result.succeeded else { return nil }
        return parse(result.output)
    }

    /// The repository's own directories: the work tree's git dir (`HEAD`, `index`) and the common dir (refs),
    /// which differ for linked worktrees. Absolute paths; nil outside a repository.
    public static func gitDirectories(at path: String, runner: GitRunner = GitRunner()) async throws(GitRunner.Failure) -> [String]? {
        let result = try await runner.run(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: path)
        guard result.succeeded else { return nil }
        let lines = result.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        guard !lines.isEmpty else { return nil }
        // A git dir inside the common dir is covered by watching the common dir recursively.
        return lines.sorted { $0.count < $1.count }.reduce(into: [String]()) { kept, path in
            if !kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { kept.append(path) }
        }
    }

    /// `git switch <branch>` once: no force, no stash. Returns git's error text on failure, nil on success.
    /// The generous timeout keeps a large checkout from being killed halfway.
    public static func switchBranch(_ branch: String, at path: String, runner: GitRunner = GitRunner(timeout: 120)) async -> String? {
        guard !branch.isEmpty, !branch.hasPrefix("-") else {
            return L10n.text("Недопустимое имя ветки: \(branch)", "Invalid branch name: \(branch)")
        }
        do {
            let result = try await runner.run(["switch", branch], in: path)
            if result.succeeded { return nil }
            return result.errors.isEmpty ? L10n.text("git switch завершился с кодом \(result.status)", "git switch exited with status \(result.status)") : result.errors
        } catch {
            switch error {
            case .timedOut: return L10n.text("git switch не ответил вовремя", "git switch timed out")
            case .launch(let message): return message
            }
        }
    }
}

public struct GitBranchChange: Equatable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}
