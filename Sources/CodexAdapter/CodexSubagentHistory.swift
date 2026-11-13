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
                let response = try await readChildThread(child)
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

    /// A child thread shaped as a `thread/read` response with its latest turns and their latest items.
    /// Codex 0.167.0 stores multi-agent v2 children as paginated threads. For a loaded paginated child,
    /// `thread/read` with `includeTurns` fails ("list_turns is not supported yet"); `thread/turns/list` and
    /// `thread/items/list` read the local thread store and work for loaded and unloaded children (probe 2026-11-13).
    /// A legacy child (older engines) keeps the full read.
    func readChildThread(_ child: String, turns turnLimit: Int = 2) async throws -> JSONValue {
        let metadata = try await transport.request("thread/read", params: .object([
            "threadId": .string(child), "includeTurns": .bool(false)
        ]))
        guard metadata["thread"]["id"].string == child else {
            throw ClientFailure(L10n.text("Не удалось проверить состояние подагента.", "Could not verify the sub-agent state."))
        }
        guard metadata["thread"]["historyMode"].string == "paginated" else {
            return try await transport.request("thread/read", params: .object([
                "threadId": .string(child), "includeTurns": .bool(true)
            ]))
        }
        let page = try await transport.request("thread/turns/list", params: .object([
            "threadId": .string(child), "limit": .number(Double(turnLimit)), "sortDirection": .string("desc"),
            "itemsView": .string("notLoaded")
        ]))
        guard case .array(let newestFirst) = page["data"] else {
            throw ClientFailure(L10n.text("Не удалось проверить состояние подагента.", "Could not verify the sub-agent state."))
        }
        var turns: [JSONValue] = []
        for turn in newestFirst.reversed() {
            guard let id = turn["id"].string else { continue }
            var fields = turn.object
            fields["items"] = .array(try await recentChildItems(child, turn: id))
            turns.append(.object(fields))
        }
        var thread = metadata["thread"].object
        thread["turns"] = .array(turns)
        return .object(["thread": .object(thread)])
    }

    /// The turn's latest items (up to the tracker's step limit), oldest first. An item over the transport's
    /// line limit ends the read there: older items of that turn are left out.
    private func recentChildItems(_ child: String, turn: String) async throws -> [JSONValue] {
        var newestFirst: [JSONValue] = [], cursor: String?, limit = 50, requests = 0
        // The watcher repeats this every few seconds: bound the requests per turn.
        while newestFirst.count < CodexSubagentTracker.stepLimit, requests < 6 {
            requests += 1
            var params: [String: JSONValue] = ["threadId": .string(child), "turnId": .string(turn),
                                               "limit": .number(Double(limit)), "sortDirection": .string("desc")]
            if let cursor { params["cursor"] = .string(cursor) }
            let page: JSONValue
            do { page = try await transport.request("thread/items/list", params: .object(params)) } catch is CodexReplyTooLarge {
                guard limit > 1 else { break }
                limit = 1; continue
            }
            newestFirst += page["data"].array.map { $0["item"] }
            guard let next = page["nextCursor"].string else { break }
            cursor = next
        }
        return newestFirst.reversed()
    }
}
