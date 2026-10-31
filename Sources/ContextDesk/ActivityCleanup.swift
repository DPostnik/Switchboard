import Foundation
import ContextCore

/// Tool bodies of archived chats are reduced to headline and metadata (`ActivityRetention`): at archive time, when an
/// archive summary becomes ready, and once per launch for everything archived earlier.
extension DeskModel {
    struct ActivityReduction: Equatable {
        var chats = 0
        var bytesBefore = 0
        var bytesAfter = 0
        /// Chats whose `historyReduced` flag was set by this pass; the caller persists the state once.
        var historiesMarked = 0
        mutating func add(_ other: Self) {
            chats += other.chats; bytesBefore += other.bytesBefore; bytesAfter += other.bytesAfter; historiesMarked += other.historiesMarked
        }
    }
    static let activityCleanupBatch = 8

    /// What may be reduced for a chat right now. The app's transcript blob feeds only the transcript view, so it is
    /// reduced as soon as the chat is archived and idle. The Claude session file is also the archive summary's source
    /// (up to 3 000 characters per action), so it waits only while a summary is queued or being generated; a chat
    /// that never got a summary is reduced too (user decision 2026-10-31: a later summary sees the dialogue in full and
    /// the actions as headline and metadata). A chat marked `historyReduced` keeps its file unread: the launch pass
    /// would otherwise decode every archived session on every start. Codex keeps its history in its own thread store,
    /// which the app never rewrites.
    func activityReductionTargets(_ id: String) -> (transcript: Bool, session: AgentSessionReference?) {
        guard let chat = state.chats.first(where: { $0.id == id }), chat.isArchived, !isBusy(threadID: id), !isSending(threadID: id),
              !isChangingChat(id), summaryActiveThread != id else { return (false, nil) }
        let summaryInProgress = supportsSummaries(chat)
            && [.queued, .reading, .generating].contains(archiveSummaries[id]?.status ?? .stale)
        let session = chat.nativeSession?.connection == .appClaude && !summaryInProgress && claudeConnected && chat.historyReduced != true
            ? chat.nativeSession : nil
        return (true, session)
    }

    /// Reduces one archived chat now. Returns the sizes that changed; a chat already reduced counts as unchanged.
    /// With `persisting` false the caller writes the state after its batch (the launch pass marks hundreds of chats).
    @discardableResult
    func reduceArchivedActivity(_ id: String, persisting: Bool = true) async -> ActivityReduction {
        let targets = activityReductionTargets(id)
        var result = ActivityReduction()
        guard targets.transcript else { return result }
        do {
            if let sizes = try await store.reduceTranscript(conversationID: id) {
                result.chats = 1; result.bytesBefore += sizes.before; result.bytesAfter += sizes.after
            }
        } catch { AppLog.lifecycle.error("Transcript of chat \(id, privacy: .public) not reduced: \(error.localizedDescription, privacy: .public)") }
        if let session = targets.session {
            do {
                if let reduction = try await claudeConnection.reduceHistory(session) {
                    result.chats = 1; result.bytesBefore += reduction.bytesBefore; result.bytesAfter += reduction.bytesAfter
                }
                // Restored from the archive while the file was being reduced: new turns may follow, so the mark waits.
                if let index = state.chats.firstIndex(where: { $0.id == id }), state.chats[index].isArchived, state.chats[index].historyReduced != true {
                    state.chats[index].historyReduced = true
                    result.historiesMarked = 1
                    if persisting { persist() }
                }
            } catch { AppLog.lifecycle.error("Claude history of chat \(id, privacy: .public) not reduced: \(error.localizedDescription, privacy: .public)") }
        }
        return result
    }

    /// One-time launch pass, detached at utility priority: after `activityCleanupLaunchDelay` (launch work and the first
    /// turns come first), every archived chat in batches, one summary log line, then a single VACUUM when more than a
    /// quarter of the store is free.
    func startActivityCleanup() {
        guard activityCleanupTask == nil else { return }
        activityCleanupTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: await self.activityCleanupLaunchDelay)
            guard !Task.isCancelled else { return }
            let total = await self.cleanUpArchivedActivity()
            guard !Task.isCancelled else { return }
            AppLog.lifecycle.notice("Tool bodies reduced in \(total.chats, privacy: .public) archived chat(s): \(total.bytesBefore, privacy: .public) -> \(total.bytesAfter, privacy: .public) bytes")
            await self.vacuumStoreIfIdle()
        }
    }

    /// Every archived chat whose stored transcript still carries full bodies, `activityCleanupBatch` chats per batch with
    /// a pause between batches. Idempotent: a reduced blob is recognized by its stamp without decoding it, a reduced
    /// Claude history by the chat's `historyReduced` mark, and busy or active chats are skipped. The decode and encode
    /// work runs on the store and adapter actors, which live turns need too: while any chat runs or sends, the pass
    /// pauses `activityCleanupBusyPause` before each chat (one job per second instead of back to back; it never waits
    /// for a full stop, since some chat is nearly always working).
    func cleanUpArchivedActivity() async -> ActivityReduction {
        let ids = state.chats.filter(\.isArchived).map(\.id)
        var total = ActivityReduction()
        for start in stride(from: 0, to: ids.count, by: Self.activityCleanupBatch) {
            guard !Task.isCancelled else { break }
            for id in ids[start..<min(start + Self.activityCleanupBatch, ids.count)] {
                if anyChatRunsOrSends { try? await Task.sleep(for: activityCleanupBusyPause) }
                guard !Task.isCancelled else { break }
                total.add(await reduceArchivedActivity(id, persisting: false))
            }
            if start + Self.activityCleanupBatch < ids.count { try? await Task.sleep(for: .milliseconds(50)) }
        }
        if total.historiesMarked > 0 { persist() }
        return total
    }

    /// `VACUUM` only while no chat is busy; the rebuild itself runs on the store actor, off the main actor.
    func vacuumStoreIfIdle() async {
        guard !anyBusy else { AppLog.lifecycle.notice("Store not compacted: chats are busy"); return }
        do {
            if try await store.vacuumIfFragmented() { AppLog.lifecycle.notice("Store compacted after the archive cleanup") }
        } catch { AppLog.lifecycle.error("Store not compacted: \(error.localizedDescription, privacy: .public)") }
    }
}
