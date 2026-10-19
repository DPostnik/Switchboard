import Foundation
import AgentContract
import ContextCore

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
                try? await transport.rejectUnknown(id: raw["id"], generation: wire.generation)
                eventSink.yield(.init(session: nil, payload: .diagnostic(L10n.text("Движок запросил неподдерживаемое или некорректное действие: \(method)", "The engine requested an unsupported or invalid action: \(method)"))))
                return
            }
            interactions[pending.interaction.id] = (pending, wire.generation, token)
            if let record = CodexEventDecoder.capability(request: method, params: p) {
                eventSink.yield(.init(session: pending.interaction.session, payload: .capability(record)))
            }
            eventSink.yield(.init(session: pending.interaction.session, payload: .interaction(pending.interaction)))
            return
        }
        if method == "serverRequest/resolved" {
            resolve { $0.rpcID == p["requestId"] && $0.interaction.session.nativeID == p["threadId"].string }
            return
        }
        if method == "turn/completed", p["turn"]["id"].string != nil {
            resolve { $0.interaction.session.nativeID == p["threadId"].string && $0.interaction.turn == p["turn"]["id"].string }
        }
        if ["client/disconnected", "account/login/completed", "account/updated"].contains(method) { resetInteractions() }
        if let event = CodexEventDecoder.notification(raw) { eventSink.yield(event) }
        if method == "item/started", let native = p["threadId"].string, !native.isEmpty,
           let record = CodexEventDecoder.capability(p["item"], turn: p["turnId"].string) {
            eventSink.yield(.init(session: .init(connection: .originalCodex, nativeID: native), payload: .capability(record)))
        }
    }
    private func resolve(where matches: (CodexPendingInteraction) -> Bool) {
        for (id, value) in interactions where matches(value.pending) {
            interactions[id] = nil
            eventSink.yield(.init(session: value.pending.interaction.session, payload: .resolved(id)))
        }
    }
    public func answer(_ id: UUID, session: AgentSessionReference, response: CodexInteractionResponse) async throws {
        guard let value = interactions[id], value.pending.interaction.session == session else { throw CodexPendingInteraction.invalidResponse }
        let encoded = try value.pending.encode(response)
        // Consume before awaiting the transport: repeated clicks and ambiguous sends never replay.
        interactions[id] = nil
        eventSink.yield(.init(session: session, payload: .resolved(id)))
        try await transport.answer(id: value.pending.rpcID, result: encoded, generation: value.generation, requestToken: value.token)
    }
    public func rejectInteraction(_ id: UUID) async {
        guard let value = interactions.removeValue(forKey: id) else { return }
        try? await transport.rejectUnknown(id: value.pending.rpcID, generation: value.generation)
    }
}
