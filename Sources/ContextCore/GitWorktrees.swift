import Foundation

/// A chat's own git worktree: a separate checkout of the project's repository on its own branch, so the chat's agent
/// edits, builds and commits without touching the project folder or other chats.
public struct ChatWorktree: Codable, Hashable, Sendable {
    /// Top level of the worktree checkout.
    public var path: String
    /// The branch checked out there when the chat started using it; nil for a detached existing worktree.
    public var branch: String?
    /// The project folder's path inside its repository when the project is a subfolder of it; the chat works in the
    /// same subfolder of the checkout. Nil at the repository's top level.
    public var subfolder: String?
    /// Picked from the repository's existing worktrees instead of created for this chat: its branch is never renamed.
    public var existing: Bool?
    /// The one rename of the branch to the chat title's slug was attempted (done or skipped).
    public var branchSettled: Bool?

    public init(path: String, branch: String?, subfolder: String? = nil, existing: Bool? = nil) {
        self.path = path; self.branch = branch; self.subfolder = subfolder; self.existing = existing
    }

    /// The folder the chat works in: the checkout, or the project's subfolder inside it.
    public var workingDirectory: String {
        guard let subfolder, !subfolder.isEmpty else { return path }
        return (path as NSString).appendingPathComponent(subfolder)
    }
}

extension Chat {
    /// The single answer to "which folder does this chat work in": its own worktree when it has one, otherwise the
    /// project folder. Engine cwd and permission roots, checkpoints, git status, file links and file reads all use it.
    public func workingDirectory(in project: Project) -> String {
        worktree?.workingDirectory ?? project.path
    }
}

/// Creates, lists, renames and removes chat worktrees. New worktrees live under `root`
/// (`~/.switchboard/worktrees/<project>/<slug>`, no spaces, so agent shell commands and build tools stay safe), and
/// nothing outside `root` is ever removed. Every git call runs once through `GitRunner`; failures carry git's own
/// message and are never retried. Branches are never deleted.
public struct GitWorktrees: Sendable {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".switchboard/worktrees", isDirectory: true)
    }
    public static let branchPrefix = "switchboard/"
    public static let slugLimit = 40

    public struct Failure: LocalizedError, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public enum Removal: Equatable, Sendable {
        case removed
        /// Git refused because the worktree has changes; it stays on disk.
        case keptWithChanges(String)
        case refused(String)
    }

    public let root: URL
    let git: GitRunner

    public init(root: URL = GitWorktrees.defaultRoot, git: GitRunner = GitRunner(timeout: 120)) {
        self.root = root.standardizedFileURL; self.git = git
    }

    // MARK: Names

    /// Lowercase ASCII slug: Cyrillic transliterated, other letters stripped of accents, anything else a hyphen;
    /// at most `limit` characters, cut at a hyphen when one is near. Empty when nothing usable remains.
    public static func slug(_ text: String, limit: Int = slugLimit) -> String {
        let latin = transliterate(text.lowercased()).applyingTransform(.stripDiacritics, reverse: false) ?? text
        var result = ""
        for scalar in latin.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { result.unicodeScalars.append(scalar) }
            else if !result.isEmpty, !result.hasSuffix("-") { result += "-" }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard result.count > limit else { return result }
        var cut = String(result.prefix(limit))
        if let hyphen = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: hyphen) >= limit / 2 {
            cut = String(cut[..<hyphen])
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
        "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
    ]

    /// Russian (and Ukrainian/Belarusian) letters to Latin; expects lowercase text, leaves other characters alone.
    public static func transliterate(_ text: String) -> String {
        text.map { cyrillic[$0] ?? String($0) }.joined()
    }

    /// A short unique starting name, `chat-<6 hex>`.
    public static func temporarySlug() -> String {
        "chat-" + String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
    }

    /// `switchboard/<slug>`, or with `-2`, `-3`… when that branch exists.
    public static func uniqueBranch(_ slug: String, existing: Set<String>) -> String {
        let base = branchPrefix + (slug.isEmpty ? "chat" : slug)
        guard existing.contains(base) else { return base }
        var number = 2
        while existing.contains(base + "-\(number)") { number += 1 }
        return base + "-\(number)"
    }

    /// True for a path strictly inside a project folder under `root` (`root/<project>/<name>…`), after resolving
    /// symlinks and `..`; the root and its project folders themselves are never inside.
    public func contains(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let base = root.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(base + "/") else { return false }
        return target.dropFirst(base.count + 1).split(separator: "/").count >= 2
    }

    // MARK: Git

    private func run(_ arguments: [String], in directory: String) async throws(Failure) -> GitRunner.Result {
        do { return try await git.run(arguments, in: directory) } catch {
            switch error {
            case .timedOut: throw Failure(L10n.text("git не ответил вовремя: git \(arguments.first ?? "")", "git timed out: git \(arguments.first ?? "")"))
            case .launch(let message): throw Failure(message)
            }
        }
    }

    private static func message(_ result: GitRunner.Result, _ command: String) -> String {
        result.errors.isEmpty ? L10n.text("\(command) завершился с кодом \(result.status)", "\(command) exited with status \(result.status)") : result.errors
    }

    private func line(_ result: GitRunner.Result) -> String? {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !text.isEmpty ? text : nil
    }

    private func branches(in directory: String) async throws(Failure) -> Set<String> {
        let result = try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: directory)
        guard result.succeeded else { throw Failure(Self.message(result, "git for-each-ref")) }
        return Set(result.text.split(separator: "\n").map(String.init))
    }

    /// The repository's top level and the project's path inside it.
    private func location(of projectPath: String) async throws(Failure) -> (top: String, subfolder: String?) {
        guard FileManager.default.fileExists(atPath: projectPath) else {
            throw Failure(L10n.text("Папка проекта не найдена: \(projectPath)", "The project folder was not found: \(projectPath)"))
        }
        let result = try await run(["rev-parse", "--show-toplevel"], in: projectPath)
        guard let top = line(result) else {
            throw Failure(result.succeeded ? L10n.text("Папка проекта не в git-репозитории", "The project folder is not in a git repository")
                                           : Self.message(result, "git rev-parse"))
        }
        let resolvedTop = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        let resolvedProject = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
        let subfolder = resolvedProject.hasPrefix(resolvedTop + "/") ? String(resolvedProject.dropFirst(resolvedTop.count + 1)) : nil
        return (top, subfolder)
    }

    /// `git worktree add -b switchboard/chat-<hex> <root>/<project>/chat-<hex> <base>` once, where base is the
    /// project's current branch (or its commit when HEAD is detached). Throws git's error; nothing is retried.
    public func create(projectPath: String) async throws(Failure) -> ChatWorktree {
        let (top, subfolder) = try await location(of: projectPath)
        let head = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: top)
        let base: String
        if let branch = line(head) { base = branch }
        else if let commit = line(try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: top)) { base = commit }
        else { throw Failure(L10n.text("В репозитории ещё нет коммитов: worktree не из чего создать", "The repository has no commits yet, so there is nothing to create a worktree from")) }
        let existing = try await branches(in: top)
        let folderName = Self.slug(URL(fileURLWithPath: top).lastPathComponent)
        let folder = root.appendingPathComponent(folderName.isEmpty ? "project" : folderName, isDirectory: true)
        // A random name that is already taken (a branch or a folder) is replaced before git runs, not retried after.
        var slug = Self.temporarySlug()
        for _ in 0..<16 where existing.contains(Self.branchPrefix + slug) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(slug).path) {
            slug = Self.temporarySlug()
        }
        let branch = Self.branchPrefix + slug, path = folder.appendingPathComponent(slug).path
        guard !existing.contains(branch), !FileManager.default.fileExists(atPath: path) else {
            throw Failure(L10n.text("Не удалось подобрать свободное имя для worktree", "Could not find a free name for the worktree"))
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw Failure(error.localizedDescription) }
        let result = try await run(["worktree", "add", "-b", branch, path, base], in: top)
        guard result.succeeded else { throw Failure(Self.message(result, "git worktree add")) }
        return ChatWorktree(path: path, branch: branch, subfolder: subfolder)
    }

    /// The repository's other worktrees (`git worktree list --porcelain`), for "existing worktree". The project's
    /// own checkout, bare entries and missing folders are left out.
    public func list(projectPath: String) async throws(Failure) -> [ChatWorktree] {
        let (top, subfolder) = try await location(of: projectPath)
        let result = try await run(["worktree", "list", "--porcelain"], in: top)
        guard result.succeeded else { throw Failure(Self.message(result, "git worktree list")) }
        let own = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        return Self.parseList(result.text).filter { entry in
            !entry.bare && URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path != own
                && FileManager.default.fileExists(atPath: entry.path)
        }.map { ChatWorktree(path: $0.path, branch: $0.branch, subfolder: subfolder, existing: true) }
    }

    public struct ListEntry: Equatable, Sendable {
        public var path: String
        public var branch: String?
        public var bare = false
    }

    /// Parses `git worktree list --porcelain`: blank-line separated records of `worktree`, `HEAD`, `branch refs/heads/…`,
    /// `detached`, `bare`, `locked`, `prunable` lines.
    public static func parseList(_ text: String) -> [ListEntry] {
        var entries: [ListEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { entries.append(ListEntry(path: String(line.dropFirst("worktree ".count)))) }
            else if line.hasPrefix("branch "), !entries.isEmpty {
                let ref = line.dropFirst("branch ".count)
                entries[entries.count - 1].branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if line == "bare", !entries.isEmpty { entries[entries.count - 1].bare = true }
        }
        return entries
    }

    /// The one rename of an app-created branch to `switchboard/<title slug>` (`git branch -m` inside the worktree).
    /// Skipped when the worktree was picked rather than created, is already settled, is on another branch now, the
    /// branch has an upstream, or the worktree has unresolved conflicts. Always returns the worktree marked settled;
    /// `problem` carries git's error when the rename itself failed.
    public func settleBranch(_ worktree: ChatWorktree, title: String) async -> (worktree: ChatWorktree, problem: String?) {
        var settled = worktree
        settled.branchSettled = true
        guard worktree.existing != true, worktree.branchSettled != true, let branch = worktree.branch,
              branch.hasPrefix(Self.branchPrefix), FileManager.default.fileExists(atPath: worktree.path) else { return (settled, nil) }
        let slug = Self.slug(title)
        guard !slug.isEmpty else { return (settled, nil) }
        do {
            guard line(try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: worktree.path)) == branch,
                  line(try await run(["for-each-ref", "--format=%(upstream)", "refs/heads/" + branch], in: worktree.path)) == nil
            else { return (settled, nil) }
            let status = try await run(["status", "--porcelain=v2", "-z"], in: worktree.path)
            guard status.succeeded else { return (settled, Self.message(status, "git status")) }
            let unmerged = status.output.split(separator: 0).contains { $0.first == UInt8(ascii: "u") && $0.dropFirst().first == UInt8(ascii: " ") }
            guard !unmerged else { return (settled, nil) }
            let target = Self.uniqueBranch(slug, existing: try await branches(in: worktree.path).subtracting([branch]))
            guard target != branch else { return (settled, nil) }
            let result = try await run(["branch", "-m", branch, target], in: worktree.path)
            guard result.succeeded else { return (settled, Self.message(result, "git branch -m")) }
            settled.branch = target
            return (settled, nil)
        } catch {
            return (settled, error.message)
        }
    }

    /// `git worktree remove <path>` once, without `--force`: a worktree with changes stays. Paths outside `root` are
    /// refused before git runs. The branch is kept.
    public func remove(_ worktree: ChatWorktree, projectPath: String) async -> Removal {
        guard contains(worktree.path) else {
            return .refused(L10n.text("Удаляются только worktree приложения в \(root.path); \(worktree.path) оставлен",
                                      "Only the app's own worktrees in \(root.path) are removed; \(worktree.path) was kept"))
        }
        let directory = FileManager.default.fileExists(atPath: projectPath) ? projectPath : worktree.path
        do {
            let result = try await run(["worktree", "remove", worktree.path], in: directory)
            if result.succeeded { return .removed }
            let text = Self.message(result, "git worktree remove")
            if text.contains("modified or untracked files") || text.contains("use --force") {
                return .keptWithChanges(text)
            }
            return .refused(text)
        } catch {
            return .refused(error.message)
        }
    }
}
