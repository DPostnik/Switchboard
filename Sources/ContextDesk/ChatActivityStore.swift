import Combine
import Foundation
import Observation
import SwiftUI
import AgentContract
import ContextCore

/// Live per-chat values that change many times during a turn: the activity line, context usage, sub-agents and
/// background waits. As `@Published` properties of `DeskModel` every status line or usage report re-rendered the window
/// body, the whole sidebar and the chat; here each dictionary is tracked on its own (Observation), so only views whose
/// body reads it update. Combine consumers of the model (phone sync, notch island, Fringe) follow `changes` through
/// `DeskModel.changes`. Writing an unchanged value does nothing.
@MainActor @Observable final class ChatActivityStore {
    /// Run key (thread ID, or the new-chat key before the chat exists) -> live activity label of its turn; never persisted.
    /// Shown only while the run is busy (`DeskModel.workingStatus`).
    private(set) var statuses: [String: String] = [:]
    /// Thread ID -> context usage the agent last reported.
    private(set) var usage: [String: UsageSnapshot] = [:]
    /// Idle chats whose agent still runs background tasks and will resume on its own; thread ID -> task count.
    private(set) var backgroundWaits: [String: Int] = [:]
    /// Thread ID -> sub-agents its agent delegated to (running ones and those finished since the last user message).
    private(set) var subagents: [String: [AgentSubagent]] = [:]
    /// Thread ID -> running sub-agents silent longer than `SubagentWatch` allows; set by `SubagentWatching`.
    private(set) var stalledSubagents: [String: Set<String>] = [:]
    /// Fires after every change.
    @ObservationIgnored let changes = PassthroughSubject<Void, Never>()

    func setStatus(_ text: String?, for key: String) {
        guard statuses[key] != text else { return }
        statuses[key] = text
        changed("statuses")
    }
    /// Moves a run's status to its new key (a new chat got its ID).
    func moveStatus(from old: String, to new: String) {
        guard old != new, statuses[old] != nil || statuses[new] != nil else { return }
        var next = statuses
        next[new] = next.removeValue(forKey: old)
        replace(\.statuses, with: next, "statuses")
    }
    func replaceStatuses(_ value: [String: String]) { replace(\.statuses, with: value, "statuses") }
    func replaceUsage(_ value: [String: UsageSnapshot]) { replace(\.usage, with: value, "usage") }
    func replaceBackgroundWaits(_ value: [String: Int]) { replace(\.backgroundWaits, with: value, "backgroundWaits") }
    func replaceSubagents(_ value: [String: [AgentSubagent]]) { replace(\.subagents, with: value, "subagents") }
    func replaceStalledSubagents(_ value: [String: Set<String>]) { replace(\.stalledSubagents, with: value, "stalledSubagents") }

    /// Forgets the live run state of these chats (their engine reset); usage stays.
    func clearRuns(_ ids: some Sequence<String>) {
        for id in ids {
            if statuses[id] != nil { statuses[id] = nil; changed("statuses") }
            if backgroundWaits[id] != nil { backgroundWaits[id] = nil; changed("backgroundWaits") }
            if subagents[id] != nil { subagents[id] = nil; changed("subagents") }
            if stalledSubagents[id] != nil { stalledSubagents[id] = nil; changed("stalledSubagents") }
        }
    }

    private func replace<Value: Equatable>(_ path: ReferenceWritableKeyPath<ChatActivityStore, Value>, with value: Value, _ name: StaticString) {
        guard self[keyPath: path] != value else { return }
        self[keyPath: path] = value
        changed(name)
    }
    private func changed(_ name: StaticString) {
        Perf.event("activity.publish", "\(name)")
        changes.send()
    }
}

/// The composer's context ring; it reads the usage itself, so a usage report renders only the ring, not the chat.
struct ChatContextRing: View {
    let activity: ChatActivityStore
    let chatID: String?
    let agentName: String
    var body: some View {
        ContextRing(usage: chatID.flatMap { activity.usage[$0] }, agentName: agentName)
    }
}
