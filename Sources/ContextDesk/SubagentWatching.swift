import Foundation
import AgentContract
import ContextCore

/// State of the check loop for silent sub-agents (`SubagentWatching`).
@MainActor final class SubagentWatchClock {
    var task: Task<Void, Never>?
    var lastCheck: Date?
    /// When the Mac last woke up, judged from a late check; sleep stops the agents too.
    var awakeSince: Date?
    /// Chat ID -> stalls the parent agent was already told about (`SubagentWatch.Silence.key`).
    var reported: [String: Set<String>] = [:]
}

/// Every `SubagentWatch.checkInterval` while a chat has running sub-agents: sub-agents silent too long are marked in
/// the sub-agent panel, and the parent agent gets one message per stall as soon as it is idle. Nothing is stopped
/// or retried automatically.
@MainActor extension DeskModel {
    /// Starts the loop when a chat reports running sub-agents; it ends by itself when none run.
    func startSubagentWatch() {
        guard subagentWatch.task == nil else { return }
        subagentWatch.lastCheck = Date()
        subagentWatch.task = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(SubagentWatch.checkInterval)) } catch { self?.subagentWatch.task = nil; return }
                guard let self else { return }
                guard self.checkSubagents() else { self.subagentWatch.task = nil; return }
            }
        }
    }

    /// One pass over every chat. Returns false when no sub-agent runs any more.
    @discardableResult
    func checkSubagents(now: Date = Date()) -> Bool {
        // A check far later than planned means the Mac slept; silence counts from the wake-up.
        if let last = subagentWatch.lastCheck, now.timeIntervalSince(last) > SubagentWatch.checkInterval + 60 { subagentWatch.awakeSince = now }
        subagentWatch.lastCheck = now
        var running = false
        for (thread, agents) in subagents {
            guard agents.contains(where: { $0.status == .running }) else { continue }
            running = true
            let silences = markStalledSubagents(thread, now: now)
            var reported = (subagentWatch.reported[thread] ?? []).intersection(silences.map(\.key))
            let fresh = silences.filter { !reported.contains($0.key) }
            if !fresh.isEmpty, parentCanBeTold(thread),
               queueContinuation(thread, text: SubagentWatch.message(fresh, now: now), localID: Self.subagentCheckPrefix + UUID().uuidString) {
                reported.formUnion(fresh.map(\.key))
                AppLog.delivery.notice("Chat \(thread, privacy: .public): \(fresh.count, privacy: .public) silent sub-agent(s); the parent agent was told")
            }
            subagentWatch.reported[thread] = reported.isEmpty ? nil : reported
        }
        for thread in subagentWatch.reported.keys where subagents[thread]?.contains(where: { $0.status == .running }) != true {
            subagentWatch.reported[thread] = nil
        }
        for thread in stalledSubagents.keys where subagents[thread]?.contains(where: { $0.status == .running }) != true {
            stalledSubagents[thread] = nil
        }
        return running
    }

    static let subagentCheckPrefix = "subagent-check:"

    /// Updates the chat's "no response" marks and returns its current stalls.
    @discardableResult
    func markStalledSubagents(_ thread: String, now: Date = Date()) -> [SubagentWatch.Silence] {
        let silences = SubagentWatch.silences(subagents[thread] ?? [], now: now, awakeSince: subagentWatch.awakeSince)
        let ids = Set(silences.map(\.agentID))
        let current = stalledSubagents[thread] ?? []
        if ids != current {
            stalledSubagents[thread] = ids.isEmpty ? nil : ids
            if !ids.subtracting(current).isEmpty {
                AppLog.delivery.notice("Chat \(thread, privacy: .public): sub-agent(s) without activity: \(ids.sorted().joined(separator: ","), privacy: .public)")
            }
        }
        return silences
    }

    /// The parent hears about a stall only between its own turns, with nothing else waiting in the chat: no approval or
    /// question, no queued or paused message of the user. A busy parent is told on a later pass.
    private func parentCanBeTold(_ thread: String) -> Bool {
        guard let chat = state.chats.first(where: { $0.id == thread }), !chat.isArchived, !chat.isScheduledRecord, !shuttingDown else { return false }
        return chatIsAvailable(thread) && chatConnected(thread) && chatAuthenticated(thread)
            && !isBusy(threadID: thread) && !isSending(threadID: thread) && !isChangingChat(thread)
            && !pending.contains { $0.threadID == thread } && !queuedMessages.contains { $0.threadID == thread }
    }
}
