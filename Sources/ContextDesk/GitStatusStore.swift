import CoreServices
import Foundation
import Observation
import ContextCore

/// Git status per project folder for the sidebar, composer and chat rows. No polling: a folder is read when it
/// starts being tracked or selected, when the app becomes active, when a turn in it ends, and when its git
/// directory changes on disk (coalesced FSEvents). Reads run off the main actor; folders outside a repository
/// have no status.
@MainActor @Observable final class GitStatusStore {
    private(set) var statuses: [String: GitStatus] = [:]
    /// Folders with a `git switch` in flight.
    private(set) var switching: Set<String> = []
    /// Dismissed branch-change banners (`bannerKey`), for this launch only.
    private(set) var dismissedBanners: Set<String> = []

    @ObservationIgnored private var tracked: [String: Tracked] = [:]
    @ObservationIgnored private let runner: GitRunner
    @ObservationIgnored private let watchesFileSystem: Bool
    /// Called after every successful read of a repository folder (pull request lookups follow git changes).
    @ObservationIgnored var didRead: ((String, GitStatus) -> Void)?
    /// Delay before a requested read; repeated requests within it share one read.
    @ObservationIgnored var debounce: Duration = .milliseconds(250)

    private final class Tracked {
        var watcher: GitDirectoryWatcher?
        var pending: Task<Void, Never>?
        var running = false
        var again = false
    }

    init(runner: GitRunner = GitRunner(), watchesFileSystem: Bool = true) {
        self.runner = runner
        self.watchesFileSystem = watchesFileSystem
    }

    func status(for path: String?) -> GitStatus? { path.flatMap { statuses[$0] } }

    /// The branch the chat's latest turn started on, when its project is now elsewhere.
    func branchChange(for chat: Chat, projectPath: String?) -> GitBranchChange? {
        GitStatus.branchChange(from: chat.turnBranch, to: status(for: projectPath))
    }

    /// Keeps exactly these folders tracked: new ones are read and watched, dropped ones forgotten.
    func track(_ paths: [String]) {
        let wanted = Set(paths)
        for path in tracked.keys where !wanted.contains(path) {
            tracked[path]?.pending?.cancel()
            tracked[path]?.watcher?.stop()
            tracked[path] = nil
            statuses[path] = nil
        }
        for path in wanted where tracked[path] == nil {
            tracked[path] = Tracked()
            refresh(path, after: .zero)
        }
    }

    /// Reads a tracked folder again after the debounce delay (or `after`).
    func refresh(_ path: String?, after delay: Duration? = nil) {
        guard let path, let entry = tracked[path] else { return }
        entry.pending?.cancel()
        let delay = delay ?? debounce
        entry.pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.load(path)
        }
    }

    func refreshAll() {
        for path in tracked.keys { refresh(path) }
    }

    /// A fresh read for the start of a turn; falls back to the last known status when git does not answer.
    func currentStatus(_ path: String) async -> GitStatus? {
        let runner = runner
        do {
            let status = try await Task.detached { try await GitStatus.read(at: path, runner: runner) }.value
            if tracked[path] != nil, statuses[path] != status { statuses[path] = status }
            return status
        } catch {
            return statuses[path]
        }
    }

    /// `git switch branch` once in the folder; returns git's error text on failure. The status is read again either way.
    func switchBranch(_ path: String, to branch: String) async -> String? {
        guard switching.insert(path).inserted else { return nil }
        defer { switching.remove(path); refresh(path, after: .zero) }
        return await Task.detached { await GitStatus.switchBranch(branch, at: path) }.value
    }

    static func bannerKey(chatID: String, change: GitBranchChange) -> String { chatID + "\n" + change.from + "\n" + change.to }
    func dismissBanner(_ key: String) { dismissedBanners.insert(key) }

    /// Test hook: a status without running git.
    func setStatus(_ status: GitStatus?, for path: String) {
        if tracked[path] == nil { tracked[path] = Tracked() }
        statuses[path] = status
    }

    private func load(_ path: String) async {
        guard let entry = tracked[path] else { return }
        if entry.running { entry.again = true; return }
        entry.running = true
        defer { entry.running = false }
        repeat {
            entry.again = false
            let runner = runner, resolveDirectories = watchesFileSystem && entry.watcher == nil
            // Detached: cancelling a later debounce must not kill a read already running.
            let probe = await Task.detached { await Self.probe(path, runner: runner, resolveDirectories: resolveDirectories) }.value
            guard tracked[path] === entry else { return }
            switch probe {
            case .unavailable: break // Keep the last status after a timeout.
            case .notRepository:
                entry.watcher?.stop(); entry.watcher = nil
                if statuses[path] != nil { statuses[path] = nil }
            case .repository(let status, let directories):
                if statuses[path] != status { statuses[path] = status }
                didRead?(path, status)
                if let directories, entry.watcher == nil {
                    entry.watcher = GitDirectoryWatcher(paths: directories) { [weak self] in
                        Task { @MainActor in self?.refresh(path) }
                    }
                }
            }
        } while entry.again
    }

    private enum Probe: Sendable {
        case repository(GitStatus, directories: [String]?)
        case notRepository
        case unavailable
    }

    private nonisolated static func probe(_ path: String, runner: GitRunner, resolveDirectories: Bool) async -> Probe {
        do {
            guard let status = try await GitStatus.read(at: path, runner: runner) else { return .notRepository }
            let directories = resolveDirectories ? try await GitStatus.gitDirectories(at: path, runner: runner) : nil
            return .repository(status, directories: directories)
        } catch {
            return .unavailable
        }
    }
}

/// Recursive FSEvents watch of a repository's git directories. FSEvents coalesces bursts for `latency` seconds;
/// changes that only touch `objects/` (packing, fetch downloads) or the app's own turn checkpoints
/// (`refs/switchboard/`) do not change the status and are ignored.
final class GitDirectoryWatcher: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "local.daniil.switchboard.git-watch", qos: .utility)
    private var stream: FSEventStreamRef?
    private let box: Unmanaged<Handler>

    static func isRelevant(_ path: String, roots: [String]) -> Bool {
        !roots.contains { root in
            ["/objects", "/refs/switchboard"].contains { path == root + $0 || path.hasPrefix(root + $0 + "/") }
        }
    }

    private final class Handler {
        let roots: [String]
        let changed: @Sendable () -> Void
        init(roots: [String], changed: @escaping @Sendable () -> Void) { self.roots = roots; self.changed = changed }

        func handle(_ paths: [String]) {
            if paths.contains(where: { GitDirectoryWatcher.isRelevant($0, roots: roots) }) { changed() }
        }
    }

    init?(paths: [String], latency: TimeInterval = 1, changed: @escaping @Sendable () -> Void) {
        box = Unmanaged.passRetained(Handler(roots: paths, changed: changed))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().handle(Array(list.prefix(count)))
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else {
            box.release(); return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    /// Ends the watch; no callback runs after it returns.
    func stop() {
        Self.queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            box.release()
        }
    }

    deinit { stop() }
}

extension DeskModel {
    /// Stores the branch checked out in the chat's folder as its turn starts, for the branch-change banner and the chat row.
    func recordTurnBranch(threadID: String) {
        guard let path = workingDirectory(forChat: threadID) else { return }
        Task {
            let branch = await gitStatus.currentStatus(path)?.branch
            guard let index = state.chats.firstIndex(where: { $0.id == threadID }),
                  state.chats[index].turnBranch != branch else { return }
            state.chats[index].turnBranch = branch
            persist()
        }
    }

    /// The agent may have committed, switched branches or edited files. A worktree branch rename that waited for
    /// the turn runs once the turn is marked finished.
    func refreshGitStatus(afterTurnIn threadID: String) {
        gitStatus.refresh(workingDirectory(forChat: threadID))
        refreshPullRequest(folder: pullRequestFolder(forChat: threadID))
        Task { [weak self] in self?.settleWorktreeBranch(threadID) }
    }
}
