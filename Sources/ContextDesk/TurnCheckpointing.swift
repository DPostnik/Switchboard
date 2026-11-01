import Foundation
import os
import ContextCore
import AgentContract

private let checkpointLog = Logger(subsystem: AppLog.subsystem, category: "checkpoints")

/// Takes a checkpoint of the project's git work tree when a turn starts and when it ends (`GitCheckpoints`), for
/// Codex and Claude chats alike. Snapshots of one chat run one after another; a failed or timed-out snapshot is
/// logged and skipped, never retried. Folders that are not git work trees get nothing.
@MainActor final class TurnCheckpointCoordinator {
    struct Snapshot: Equatable, Sendable {
        let root: String
        let checkpoint: GitCheckpoints.Checkpoint
    }
    private struct ActiveTurn {
        let chatID: String
        let projectPath: String
        let start: Task<Snapshot?, Never>
        var otherChats: Bool
    }

    let engine: GitCheckpoints
    /// How long a send waits for its start checkpoint before it goes out anyway.
    var startBound: Duration
    private var roots: [String: (root: String?, checked: Date)] = [:]
    /// Start checkpoints taken before a send, not yet bound to the engine's turn.
    private var pendingStarts: [String: Task<Snapshot?, Never>] = [:]
    private var active: [String: ActiveTurn] = [:]
    /// The chat's most recent snapshot: the next one waits for it and reuses it when the tree is unchanged.
    private var latest: [String: Task<Snapshot?, Never>] = [:]
    /// End checkpoints still being taken; a message sent meanwhile (a queued follow-up) starts from them.
    private var runningEnds: [String: Task<Snapshot?, Never>] = [:]

    init(engine: GitCheckpoints = GitCheckpoints(), startBound: Duration = .milliseconds(1500)) {
        self.engine = engine; self.startBound = startBound
    }

    /// Repository root for a project folder; a folder that is not a repository is checked again after five minutes.
    func root(for projectPath: String) async -> String? {
        if let cached = roots[projectPath], cached.root != nil || Date().timeIntervalSince(cached.checked) < 300 { return cached.root }
        let root = await engine.repositoryRoot(for: projectPath)
        roots[projectPath] = (root, Date())
        return root
    }

    private func snapshot(chatID: String, projectPath: String, label: String) -> Task<Snapshot?, Never> {
        let previous = latest[chatID]
        let engine = engine
        let task = Task { [weak self] () -> Snapshot? in
            let prior = await previous?.value
            guard let self, let root = await self.root(for: projectPath) else { return nil }
            let started = Date()
            do {
                let checkpoint = try await engine.snapshot(root: root, chatID: chatID, previous: prior?.root == root ? prior?.checkpoint : nil)
                checkpointLog.info("Checkpoint \(label, privacy: .public) for chat \(chatID, privacy: .public): \(checkpoint.commit, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
                return Snapshot(root: root, checkpoint: checkpoint)
            } catch {
                checkpointLog.error("Checkpoint \(label, privacy: .public) skipped for chat \(chatID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        latest[chatID] = task
        return task
    }

    /// Before a send: starts the start checkpoint and waits for it at most `startBound`, so sending is never held longer.
    func prepareStart(chatID: String, projectPath: String) async {
        let task = runningEnds[chatID] ?? snapshot(chatID: chatID, projectPath: projectPath, label: "start")
        pendingStarts[chatID] = task
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in _ = await task.value; once.resume() }
            Task { @MainActor [startBound] in try? await Task.sleep(for: startBound); once.resume() }
        }
    }

    /// A send that failed leaves no turn for its start checkpoint.
    func discardPending(chatID: String) { pendingStarts[chatID] = nil }

    /// The engine started a turn. Turns it started on its own (no send) get their start checkpoint now.
    /// `running` holds the chats running right now; another one in the same folder marks both turns.
    func turnStarted(chatID: String, turnID: String, projectPath: String, running: Set<String>) {
        let key = chatID + "\n" + turnID
        guard active[key] == nil else { return }
        active = active.filter { $0.value.chatID != chatID && running.contains($0.value.chatID) }
        let start = pendingStarts.removeValue(forKey: chatID) ?? snapshot(chatID: chatID, projectPath: projectPath, label: "start")
        var otherChats = false
        for (other, turn) in active where turn.projectPath == projectPath {
            active[other]?.otherChats = true; otherChats = true
        }
        active[key] = ActiveTurn(chatID: chatID, projectPath: projectPath, start: start, otherChats: otherChats)
    }

    /// The turn ended: starts the end checkpoint now and returns the measurement of the change, which yields nil
    /// when either checkpoint is missing. Nil for a turn whose start was never seen.
    func turnCompleted(chatID: String, turnID: String, running: Set<String>) -> Task<TurnChanges?, Never>? {
        guard let turn = active.removeValue(forKey: chatID + "\n" + turnID) else { return nil }
        let otherChats = turn.otherChats || active.values.contains {
            $0.projectPath == turn.projectPath && $0.chatID != chatID && running.contains($0.chatID)
        }
        let endTask = snapshot(chatID: chatID, projectPath: turn.projectPath, label: "end")
        runningEnds[chatID] = endTask
        let engine = engine
        return Task { [weak self] in
            let start = await turn.start.value, end = await endTask.value
            if self?.runningEnds[chatID] == endTask { self?.runningEnds[chatID] = nil }
            guard let start, let end, start.root == end.root else { return nil }
            let files: [GitCheckpoints.FileChange]
            do { files = try await engine.changes(root: end.root, from: start.checkpoint.commit, to: end.checkpoint.commit) }
            catch {
                checkpointLog.error("Turn changes unavailable for chat \(chatID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
            return TurnChanges(repository: end.root, start: start.checkpoint.commit, end: end.checkpoint.commit, files: files.count,
                               added: files.reduce(0) { $0 + ($1.added ?? 0) }, removed: files.reduce(0) { $0 + ($1.removed ?? 0) },
                               otherChats: otherChats ? true : nil)
        }
    }

    /// A deleted chat's refs are removed after its last snapshot finishes; archived chats keep theirs.
    func forget(chatID: String, projectPath: String) {
        let last = latest.removeValue(forKey: chatID)
        pendingStarts[chatID] = nil; runningEnds[chatID] = nil
        active = active.filter { $0.value.chatID != chatID }
        let engine = engine
        Task { [weak self] in
            _ = await last?.value
            guard let root = await self?.root(for: projectPath) else { return }
            do { try await engine.removeCheckpoints(root: root, chatID: chatID) }
            catch { checkpointLog.error("Could not remove checkpoints of chat \(chatID, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// Resumes a continuation from whichever of two tasks finishes first.
@MainActor private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() { continuation?.resume(); continuation = nil }
}

// MARK: - Model hooks

@MainActor extension DeskModel {
    private var runningChatIDs: Set<String> { Set(state.chats.lazy.map(\.id).filter { self.isBusy(threadID: $0) }) }

    /// Called right before a message goes to the engine; waits briefly for the start checkpoint.
    func prepareTurnCheckpoint(chatID: String, projectPath: String) async {
        await turnCheckpoints.prepareStart(chatID: chatID, projectPath: projectPath)
    }

    func noteTurnStarted(chatID: String, turnID: String) {
        guard let path = workingDirectory(forChat: chatID) else { return }
        turnCheckpoints.turnStarted(chatID: chatID, turnID: turnID, projectPath: path, running: runningChatIDs)
    }

    /// Takes the end checkpoint in the background, stores the turn's changes and shows them on its answer.
    func recordTurnChanges(chatID: String, turnID: String) {
        guard let measuring = turnCheckpoints.turnCompleted(chatID: chatID, turnID: turnID, running: runningChatIDs) else { return }
        Task { [weak self] in
            guard let changes = await measuring.value, let self else { return }
            guard state.chats.contains(where: { $0.id == chatID }) else { return }
            do { try await store.saveTurnChanges(threadID: chatID, turnID: turnID, changes: changes) }
            catch { checkpointLog.error("Could not save turn changes: \(error.localizedDescription, privacy: .public)"); return }
            if self.chatID == chatID, let index = items.lastIndex(where: { $0.kind == "assistant" && $0.turnID == turnID }),
               items[index].timing != nil, items[index].timing?.changes != changes {
                items[index].timing?.changes = changes
            }
        }
    }

    func forgetTurnCheckpoints(chatID: String) {
        guard let path = workingDirectory(forChat: chatID) else { return }
        turnCheckpoints.forget(chatID: chatID, projectPath: path)
    }

    /// Restoring files is unavailable while any chat working in the same folder or repository is running.
    func turnChangesBlocked(_ changes: TurnChanges, chatID: String?) -> Bool {
        let projectID = chatID.flatMap { id in state.chats.first { $0.id == id }?.projectID }
        let repository = changes.repository
        return state.chats.contains { chat in
            guard isBusy(threadID: chat.id) else { return false }
            if chat.projectID == projectID { return true }
            guard let path = workingDirectory(forChat: chat.id) else { return false }
            return path == repository || path.hasPrefix(repository + "/") || repository.hasPrefix(path + "/")
        }
    }
}
