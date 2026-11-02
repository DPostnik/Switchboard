import Foundation
import AgentContract

/// Turn checkpoints: snapshots of a project's working tree stored as commits under hidden refs
/// (`refs/switchboard/checkpoints/<chat>/<n>`) in the project's own repository. A private temporary index keeps the
/// user's index, HEAD and branches untouched, and `git add -A` respects `.gitignore`. Folders that are not git work
/// trees have no checkpoints. Every git call runs once through `GitRunner`; failures are reported, never retried.
public struct GitCheckpoints: Sendable {
    public static let refPrefix = "refs/switchboard/checkpoints/"
    /// 30 turns with a start and an end checkpoint each.
    public static let keptRefs = 60
    /// Untracked, not ignored files are copied into the repository's objects; past these sizes the snapshot is
    /// skipped so a dataset or an unignored dependency folder never bloats the user's repository.
    public static let untrackedFileLimit = 25 * 1024 * 1024
    public static let untrackedTotalLimit = 250 * 1024 * 1024
    /// Patches beyond these sizes are not shown in full.
    public static let patchByteLimit = 512 * 1024
    public static let patchLineLimit = 20_000

    public struct Checkpoint: Equatable, Sendable {
        public let commit: String
        public let tree: String
        public init(commit: String, tree: String) { self.commit = commit; self.tree = tree }
    }

    public struct FileChange: Identifiable, Equatable, Sendable {
        public enum Status: String, Sendable { case added, modified, deleted, renamed, copied, typeChanged }
        public var path: String
        /// The source path of a rename or copy.
        public var oldPath: String?
        public var status: Status
        /// Nil for binary files.
        public var added: Int?
        public var removed: Int?
        public var id: String { path }
        public var isBinary: Bool { added == nil && removed == nil }
        public init(path: String, oldPath: String? = nil, status: Status, added: Int?, removed: Int?) {
            self.path = path; self.oldPath = oldPath; self.status = status; self.added = added; self.removed = removed
        }
    }

    public struct Patch: Equatable, Sendable {
        public var text: String
        /// Cut at `patchByteLimit`.
        public var truncated = false
        /// Not read at all: more than `patchLineLimit` changed lines.
        public var tooLarge = false
    }

    public struct RestoreReport: Equatable, Sendable {
        public var restored: [String] = []
        public var deleted: [String] = []
        public var failures: [String] = []
    }

    public struct Failure: LocalizedError, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    let git: GitRunner

    public init(git: GitRunner = GitRunner(timeout: 30)) { self.git = git }

    // MARK: Snapshots

    /// The work tree's top level, or nil when the folder is not inside a git work tree. The home folder and `/`
    /// are refused: snapshotting a whole home directory would copy everything not ignored into its repository.
    public func repositoryRoot(for folder: String) async -> String? {
        guard let result = try? await git.run(["rev-parse", "--show-toplevel"], in: folder), result.succeeded else { return nil }
        let root = result.text.trimmingCharacters(in: .newlines)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        guard root.hasPrefix("/"), root != "/", URL(fileURLWithPath: root).resolvingSymlinksInPath().path != home else { return nil }
        return root
    }

    /// Records the work tree as a commit under the chat's checkpoint refs and prunes the oldest refs past `keep`.
    /// An unchanged tree reuses `previous` and creates nothing.
    public func snapshot(root: String, chatID: String, previous: Checkpoint? = nil, keep: Int = keptRefs) async throws -> Checkpoint {
        let tree = try await workTree(root: root)
        if let previous, previous.tree == tree { return previous }
        let head = try await git.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: root)
        var arguments = ["commit-tree", "--no-gpg-sign", "-m", "Switchboard checkpoint"]
        let parent = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.succeeded, !parent.isEmpty { arguments += ["-p", parent] }
        let identity = ["GIT_AUTHOR_NAME": "Switchboard", "GIT_AUTHOR_EMAIL": "switchboard@localhost",
                        "GIT_COMMITTER_NAME": "Switchboard", "GIT_COMMITTER_EMAIL": "switchboard@localhost"]
        let commit = try await checked(arguments + [tree], in: root, environment: identity).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await refNumbers(root: root, chatID: chatID)
        var commands = "create \(Self.ref(chatID, (existing.last ?? 0) + 1)) \(commit)\n"
        for number in existing.prefix(max(0, existing.count + 1 - max(1, keep))) { commands += "delete \(Self.ref(chatID, number))\n" }
        _ = try await checked(["update-ref", "--stdin"], in: root, input: Data(commands.utf8))
        return Checkpoint(commit: commit, tree: tree)
    }

    /// The current work tree as a tree object, built in a private index seeded from the user's index (its stat
    /// cache spares rehashing unchanged files); the user's index file is only read.
    func workTree(root: String) async throws -> String {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-checkpoint-\(UUID().uuidString).index")
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(at: index.appendingPathExtension("lock"))
        }
        let privateIndex = ["GIT_INDEX_FILE": index.path]
        let located = try await checked(["rev-parse", "--git-path", "index"], in: root).text.trimmingCharacters(in: .newlines)
        let userIndex = located.hasPrefix("/") ? located : root + "/" + located
        if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: userIndex), to: index)) == nil {
            // No index yet: start from HEAD, or empty in a repository without commits.
            _ = try await git.run(["read-tree", "HEAD"], in: root, input: nil, environment: privateIndex)
        }
        try await checkUntracked(root: root, environment: privateIndex)
        // Unreadable files are skipped rather than failing the whole snapshot; both ends of a turn skip them alike.
        _ = try await git.run(["add", "-A", "--ignore-errors"], in: root, input: nil, environment: privateIndex)
        return try await checked(["write-tree"], in: root, environment: privateIndex).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkUntracked(root: String, environment: [String: String]) async throws {
        let listed = try await checked(["ls-files", "-z", "--others", "--exclude-standard"], in: root, environment: environment)
        var total = 0
        for path in Self.fields(listed.output) {
            let size = (try? FileManager.default.attributesOfItem(atPath: root + "/" + path)[.size] as? Int) ?? 0
            total += size
            if size > Self.untrackedFileLimit {
                throw Failure("untracked file over \(Self.untrackedFileLimit / 1_048_576) MB: \(path)")
            }
            if total > Self.untrackedTotalLimit {
                throw Failure("untracked files over \(Self.untrackedTotalLimit / 1_048_576) MB in total")
            }
        }
    }

    // MARK: Changes

    /// Files that differ between two checkpoints, with rename detection and line counts (nil for binary files).
    public func changes(root: String, from start: String, to end: String) async throws -> [FileChange] {
        if start == end { return [] }
        let names = try await checked(["diff-tree", "-r", "-z", "-M", "--no-commit-id", "--name-status", start, end], in: root)
        let counts = try await checked(["diff-tree", "-r", "-z", "-M", "--no-commit-id", "--numstat", start, end], in: root)
        return Self.parse(nameStatus: names.output, numstat: counts.output)
    }

    static func parse(nameStatus: Data, numstat: Data) -> [FileChange] {
        var lines: [String: (Int?, Int?)] = [:]
        var fields = Self.fields(numstat)[...]
        while let record = fields.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty { _ = fields.popFirst(); path = fields.popFirst() ?? "" }
            lines[path] = (Int(parts[0]), Int(parts[1]))
        }
        var result: [FileChange] = []
        fields = Self.fields(nameStatus)[...]
        while let code = fields.popFirst(), let letter = code.first {
            let status: FileChange.Status
            switch letter {
            case "A": status = .added
            case "D": status = .deleted
            case "R": status = .renamed
            case "C": status = .copied
            case "T": status = .typeChanged
            default: status = .modified
            }
            var oldPath: String?
            if status == .renamed || status == .copied { oldPath = fields.popFirst() }
            guard let path = fields.popFirst() else { break }
            let count = lines[path]
            result.append(FileChange(path: path, oldPath: oldPath, status: status, added: count?.0, removed: count?.1))
        }
        return result
    }

    /// The unified diff of one file between two checkpoints, capped for display.
    public func patch(root: String, from start: String, to end: String, file: FileChange) async throws -> Patch {
        if (file.added ?? 0) + (file.removed ?? 0) > Self.patchLineLimit { return Patch(text: "", tooLarge: true) }
        let paths = [file.oldPath, file.path].compactMap { $0 }
        let result = try await checked(["diff-tree", "-r", "-p", "-M", "--no-commit-id", "--no-color", "--no-ext-diff",
                                        "--src-prefix=a/", "--dst-prefix=b/", start, end, "--"] + paths, in: root)
        guard result.output.count > Self.patchByteLimit else { return Patch(text: result.text) }
        var cut = result.output.prefix(Self.patchByteLimit)
        if let newline = cut.lastIndex(of: 10) { cut = cut[..<newline] }
        return Patch(text: String(decoding: cut, as: UTF8.self), truncated: true)
    }

    /// Paths among `files` whose current content differs from the end checkpoint (edited after the turn).
    public func editedSince(root: String, end: String, files: [FileChange]) async throws -> Set<String> {
        let current = try await workTree(root: root)
        let differing = try await checked(["diff-tree", "-r", "-z", "--no-renames", "--name-only", end, current], in: root)
        let touched = Set(files.flatMap { [$0.path, $0.oldPath].compactMap { $0 } })
        return Set(Self.fields(differing.output)).intersection(touched)
    }

    // MARK: Restore

    /// Puts the files a turn changed back to their content in the start checkpoint: files added in the turn are
    /// deleted, the others are written from the checkpoint through a private index. Only these files are touched.
    public func restore(root: String, to start: String, files: [FileChange]) async throws -> RestoreReport {
        var report = RestoreReport()
        var restores: [String] = [], deletions: [String] = []
        for file in files {
            switch file.status {
            case .added, .copied: deletions.append(file.path)
            case .renamed:
                deletions.append(file.path)
                if let old = file.oldPath { restores.append(old) }
            case .modified, .deleted, .typeChanged: restores.append(file.path)
            }
        }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for path in deletions {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard parent == base || parent.hasPrefix(base + "/") else {
                report.failures.append(path + L10n.text(": вне репозитория", ": outside the repository")); continue
            }
            guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
                report.deleted.append(path); continue // Already gone.
            }
            // A folder (a nested repository) is never removed recursively.
            guard type != .typeDirectory else {
                report.failures.append(path + L10n.text(": это папка, не удалена", ": is a folder, not removed")); continue
            }
            do { try FileManager.default.removeItem(at: url); report.deleted.append(path) }
            catch { report.failures.append(path + ": " + error.localizedDescription) }
        }
        guard !restores.isEmpty else { return report }
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-restore-\(UUID().uuidString).index")
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(at: index.appendingPathExtension("lock"))
        }
        let privateIndex = ["GIT_INDEX_FILE": index.path]
        _ = try await checked(["read-tree", start], in: root, environment: privateIndex)
        let input = Data(restores.joined(separator: "\0").utf8) + Data([0])
        let result = try await git.run(["checkout-index", "-f", "-z", "--stdin"], in: root, input: input, environment: privateIndex)
        if result.succeeded { report.restored = restores }
        else {
            // checkout-index names each path it could not write; the others were written.
            let failed = restores.filter { result.errors.contains($0) }
            report.restored = restores.filter { !failed.contains($0) }
            report.failures.append(result.errors.isEmpty ? L10n.text("git не смог восстановить файлы", "git could not restore the files") : result.errors)
        }
        return report
    }

    // MARK: Retention

    /// Deletes all of a chat's checkpoint refs; their objects go with the repository's next garbage collection.
    public func removeCheckpoints(root: String, chatID: String) async throws {
        let numbers = try await refNumbers(root: root, chatID: chatID)
        guard !numbers.isEmpty else { return }
        let commands = numbers.map { "delete \(Self.ref(chatID, $0))\n" }.joined()
        _ = try await checked(["update-ref", "--stdin"], in: root, input: Data(commands.utf8))
    }

    func refNumbers(root: String, chatID: String) async throws -> [Int] {
        let prefix = Self.refPrefix + Self.component(chatID)
        let listed = try await checked(["for-each-ref", "--format=%(refname)", prefix], in: root)
        return listed.text.split(separator: "\n").compactMap { line in
            line.hasPrefix(prefix + "/") ? Int(line.dropFirst(prefix.count + 1)) : nil
        }.sorted()
    }

    static func ref(_ chatID: String, _ number: Int) -> String { refPrefix + component(chatID) + "/\(number)" }

    /// Chat IDs as one safe ref component.
    static func component(_ chatID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(chatID.map { allowed.contains($0) ? $0 : "_" })
        return mapped.isEmpty ? "chat" : mapped
    }

    static func fields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    private func checked(_ arguments: [String], in root: String, input: Data? = nil, environment: [String: String] = [:]) async throws -> GitRunner.Result {
        let result = try await git.run(arguments, in: root, input: input, environment: environment)
        guard result.succeeded else {
            throw Failure("git \(arguments.first ?? ""): " + (result.errors.isEmpty ? "exit \(result.status)" : result.errors))
        }
        return result
    }
}

extension GitRunner {
    /// One call with extra environment on top of the runner's own.
    func run(_ arguments: [String], in directory: String, input: Data?, environment extra: [String: String]) async throws -> Result {
        var runner = self
        runner.environment.merge(extra) { _, new in new }
        do { return try await runner.run(arguments, in: directory, input: input) }
        catch .timedOut { throw GitCheckpoints.Failure("git \(arguments.first ?? ""): timed out after \(Int(timeout)) s") }
        catch .launch(let message) { throw GitCheckpoints.Failure("git: " + message) }
    }
}

/// One display line of a unified diff with its old and new line numbers. File headers (`diff --git`, `index`,
/// `---`, `+++`) are dropped; mode, rename and binary notices stay as notes.
public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case hunk, added, removed, context, note }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let old: Int?
    public let new: Int?

    public init(id: Int, kind: Kind, text: String, old: Int?, new: Int?) {
        self.id = id; self.kind = kind; self.text = text; self.old = old; self.new = new
    }

    public static func parse(_ patch: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var inHunk = false, old = 0, new = 0
        func add(_ kind: Kind, _ text: Substring, old: Int? = nil, new: Int? = nil) {
            result.append(DiffLine(id: result.count, kind: kind, text: String(text), old: old, new: new))
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { inHunk = false; continue }
            if line.hasPrefix("@@") {
                // @@ -a[,b] +c[,d] @@ context
                let ranges = line.split(separator: " ")
                old = ranges.first { $0.hasPrefix("-") }.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                new = ranges.first { $0.hasPrefix("+") }.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                inHunk = true
                add(.hunk, line)
                continue
            }
            guard inHunk else {
                if line.isEmpty || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") { continue }
                add(.note, line); continue
            }
            switch line.first {
            case "+"?: add(.added, line.dropFirst(), new: new); new += 1
            case "-"?: add(.removed, line.dropFirst(), old: old); old += 1
            case " "?: add(.context, line.dropFirst(), old: old, new: new); old += 1; new += 1
            case nil: continue // The patch's final newline.
            default: add(.note, line) // "\ No newline at end of file"
            }
        }
        return result
    }
}

extension TurnChanges {
    /// "3 files changed · +12 −4" for the transcript row.
    public func label(language: AppLanguage = L10n.language) -> String {
        let counts = "+\(added) −\(removed)"
        let base = L10n.text("Изменено файлов: \(files) · \(counts)", "\(files) \(files == 1 ? "file" : "files") changed · \(counts)", language: language)
        guard otherChats == true else { return base }
        return base + L10n.text(" · возможно, с правками другого чата", " · may include another chat's edits", language: language)
    }
}
