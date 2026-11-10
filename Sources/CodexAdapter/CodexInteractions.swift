import Foundation
import AgentContract
import ContextCore

struct CodexCapabilityItemKey: Hashable, Sendable {
    let session: AgentSessionReference
    let turn: String?
    let item: String
}

struct CodexChatToolGrant: Hashable, Sendable {
    let session: AgentSessionReference
    let server: String
}

extension CodexClient {
    /// Seed only references owned by this connection; the app still owns conversation IDs.
    public func observeEvents(sessions: [AgentSessionReference] = []) {
        knownSessions.formUnion(sessions.filter { $0.connection == .originalCodex && !$0.nativeID.isEmpty })
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, transport] in
            for await event in transport.scopedEvents {
                guard !Task.isCancelled else { return }
                await self?.receiveWire(event)
            }
        }
    }
    func resetInteractions() {
        interactionEpoch = UUID()
        for task in subagentHistoryTasks.values { task.cancel() }
        subagentHistoryTasks.removeAll()
        for event in subagentTracker.reset() { eventSink.yield(event) }
        for value in interactions.values { audit(value.pending, stage: .resolved, outcome: .unknown) }
        for (key, var record) in capabilityItems {
            record.stage = .completed; record.outcome = .unknown; record.source = "client/reset"
            eventSink.yield(.init(session: key.session, payload: .capability(record)))
        }
        capabilityItems.removeAll()
        chatToolGrants.removeAll()
        interactions.removeAll()
        eventSink.yield(.init(session: nil, payload: .interactionsReset))
    }
    func receiveWire(_ wire: CodexWireEvent) async {
        let epoch = interactionEpoch
        guard await transport.isCurrent(wire.generation), epoch == interactionEpoch else { return }
        if requestGeneration != wire.generation {
            requestGeneration = wire.generation; seenRequestIDs.removeAll()
        }
        let raw = wire.message, method = raw["method"].string ?? "", p = raw["params"]
        if raw["id"] != .null {
            guard let token = wire.requestToken, let pending = CodexPendingInteraction.parse(raw), knownSessions.contains(pending.interaction.session),
                  seenRequestIDs.insert(pending.rpcID).inserted else {
                resolve { $0.rpcID == raw["id"] }
                // Unsupported form shapes still belong in the audit, without recording the form itself.
                if let native = p["threadId"].string,
                   knownSessions.contains(.init(connection: .originalCodex, nativeID: native)),
                   seenRequestIDs.insert(raw["id"]).inserted {
                    let record = AgentCapabilityRecord(tool: method == "mcpServer/elicitation/request" ? "mcpElicitation" : "serverRequest",
                        capability: .other, decision: .unsupportedTool, turn: p["turnId"].string,
                        requestID: UUID().uuidString, source: method, stage: .requested, outcome: .unknown)
                    eventSink.yield(.init(session: .init(connection: .originalCodex, nativeID: native), payload: .capability(record)))
                }
                try? await transport.rejectUnknown(id: raw["id"], generation: wire.generation)
                eventSink.yield(.init(session: nil, payload: .diagnostic(L10n.text("Движок запросил неподдерживаемое или некорректное действие: \(method)", "The engine requested an unsupported or invalid action: \(method)"))))
                return
            }
            if pending.interaction.canAllowChat, let server = pending.toolApprovalServer,
               chatToolGrants.contains(.init(session: pending.interaction.session, server: server)) {
                // The user already allowed this server in this chat; answer once, never retry.
                audit(pending, stage: .requested)
                do {
                    try await transport.answer(id: pending.rpcID, result: try pending.encode(.allowChat), generation: wire.generation, requestToken: token)
                    audit(pending, stage: .responded, response: .allowChat, outcome: .unknown)
                } catch {
                    chatToolGrants.remove(.init(session: pending.interaction.session, server: server))
                    audit(pending, stage: .resolved, outcome: .unknown)
                    eventSink.yield(.init(session: pending.interaction.session, payload: .diagnostic(L10n.text(
                        "Не удалось автоматически разрешить вызов инструмента \(server): \(error.localizedDescription)",
                        "Could not allow the \(server) tool call automatically: \(error.localizedDescription)"))))
                }
                return
            }
            interactions[pending.interaction.id] = (pending, wire.generation, token)
            audit(pending, stage: .requested)
            eventSink.yield(.init(session: pending.interaction.session, payload: .interaction(pending.interaction)))
            return
        }
        if method == "serverRequest/resolved" {
            resolve { $0.rpcID == p["requestId"] && $0.interaction.session.nativeID == p["threadId"].string }
            return
        }
        if method == "turn/completed", p["turn"]["id"].string != nil {
            resolve { $0.interaction.session.nativeID == p["threadId"].string && $0.interaction.turn == p["turn"]["id"].string }
            for (key, var record) in capabilityItems where key.session.nativeID == p["threadId"].string && key.turn == p["turn"]["id"].string {
                capabilityItems[key] = nil; record.stage = .completed; record.outcome = .unknown; record.source = method
                eventSink.yield(.init(session: key.session, payload: .capability(record)))
            }
        }
        if ["client/disconnected", "account/login/completed", "account/updated"].contains(method) { resetInteractions() }
        if let event = CodexEventDecoder.notification(raw) {
            for event in compactions.observe(event) { eventSink.yield(event) }
        }
        if let event = CodexEventDecoder.commandResult(raw) { eventSink.yield(event) }
        if let event = reasoning.receive(raw, at: Date()) { eventSink.yield(event) }
        if let event = subagentTracker.receive(raw) {
            eventSink.yield(event)
            if let parent = event.session?.nativeID { watchSubagentHistory(parent: parent) }
        }
        if ["item/started", "item/completed"].contains(method), let native = p["threadId"].string, !native.isEmpty,
           let item = p["item"]["id"].string, !item.isEmpty {
            let session = AgentSessionReference(connection: .originalCodex, nativeID: native)
            let key = CodexCapabilityItemKey(session: session, turn: p["turnId"].string, item: item)
            if method == "item/started", capabilityItems[key] == nil,
               let record = CodexEventDecoder.capability(p["item"], turn: key.turn) {
                capabilityItems[key] = record
                eventSink.yield(.init(session: session, payload: .capability(record)))
            } else if method == "item/completed", var record = capabilityItems.removeValue(forKey: key) {
                let result = CodexEventDecoder.capability(p["item"], turn: key.turn, completed: true)
                record.stage = .completed; record.source = method
                record.outcome = result?.tool == record.tool && result?.capability == record.capability ? result?.outcome : .unknown
                eventSink.yield(.init(session: session, payload: .capability(record)))
            }
        }
    }
    private func resolve(where matches: (CodexPendingInteraction) -> Bool) {
        for (id, value) in interactions where matches(value.pending) {
            interactions[id] = nil
            audit(value.pending, stage: .resolved, outcome: .unknown)
            eventSink.yield(.init(session: value.pending.interaction.session, payload: .resolved(id)))
        }
    }
    public func answer(_ id: UUID, session: AgentSessionReference, response: CodexInteractionResponse) async throws {
        guard let value = interactions[id], value.pending.interaction.session == session else { throw CodexPendingInteraction.invalidResponse }
        let encoded = try value.pending.encode(response)
        // Consume before awaiting the transport: repeated clicks and ambiguous sends never replay.
        interactions[id] = nil
        if case .allowChat = response, let server = value.pending.toolApprovalServer {
            chatToolGrants.insert(.init(session: session, server: server))
        }
        eventSink.yield(.init(session: session, payload: .resolved(id)))
        do {
            try await transport.answer(id: value.pending.rpcID, result: encoded, generation: value.generation, requestToken: value.token)
            // A pipe write has no server acknowledgement and proves no tool execution outcome.
            audit(value.pending, stage: .responded, response: response, outcome: .unknown)
        } catch {
            // The response may have reached the engine, but a failed write cannot establish a live chat grant.
            if case .allowChat = response, let server = value.pending.toolApprovalServer {
                chatToolGrants.remove(.init(session: session, server: server))
            }
            audit(value.pending, stage: .responded, response: response, outcome: .unknown)
            throw error
        }
    }
    public func rejectInteraction(_ id: UUID) async {
        guard let value = interactions.removeValue(forKey: id) else { return }
        audit(value.pending, stage: .resolved, outcome: .unknown)
        try? await transport.rejectUnknown(id: value.pending.rpcID, generation: value.generation)
    }
    private func audit(_ pending: CodexPendingInteraction, stage: AgentCapabilityRecord.Stage,
                       response: CodexInteractionResponse? = nil, outcome: AgentCapabilityRecord.Outcome? = nil) {
        if let record = pending.capability(stage: stage, response: response, outcome: outcome) {
            eventSink.yield(.init(session: pending.interaction.session, payload: .capability(record)))
        }
    }
}
