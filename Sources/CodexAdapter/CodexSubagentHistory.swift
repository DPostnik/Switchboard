import Foundation
import ContextCore
import AgentContract

extension CodexClient {
    /// App-server may send only lifecycle items to the subscribed parent. Read child history
    /// on its owning connection as well, without resuming or starting any child turn.
    func watchSubagentHistory(parent: String) {
        guard subagentHistoryTasks[parent] == nil, !subagentTracker.historyIDs(parent: parent).isEmpty else { return }
        let epoch = interactionEpoch
        subagentHistoryTasks[parent] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.refreshSubagentHistory(parent: parent) else { break }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
            await self?.finishSubagentHistory(parent: parent, epoch: epoch)
        }
    }

    private func finishSubagentHistory(parent: String, epoch: UUID) {
        if interactionEpoch == epoch { subagentHistoryTasks[parent] = nil }
    }

    private func refreshSubagentHistory(parent: String) async -> Bool {
        let children = subagentTracker.historyIDs(parent: parent)
        guard !children.isEmpty else { return false }
        let epoch = interactionEpoch
        for child in children {
            do {
                let response = try await transport.request("thread/read", params: .object([
                    "threadId": .string(child), "includeTurns": .bool(true)
                ]))
                guard epoch == interactionEpoch, !Task.isCancelled else { return false }
                for event in subagentTracker.history(response, child: child) { eventSink.yield(event) }
            } catch {
                // Stop this watcher after a failed read. Never replay an uncertain operation.
                guard epoch == interactionEpoch else { return false }
                eventSink.yield(.init(session: .init(connection: .originalCodex, nativeID: parent), payload: .diagnostic(L10n.text(
                    "Не удалось прочитать шаги подагента: \(error.localizedDescription)",
                    "Could not read sub-agent steps: \(error.localizedDescription)"))))
                return false
            }
        }
        return true
    }
}
