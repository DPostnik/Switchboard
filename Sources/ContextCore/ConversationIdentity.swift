import Foundation
import AgentContract

public enum ConversationIdentity {
    public static var invalidStorage: ClientFailure {
        ClientFailure(L10n.text("Не удалось проверить связи чатов. Выполнение остановлено.",
                                "Could not verify conversation references. Execution stopped."))
    }
    public static var unavailable: ClientFailure {
        ClientFailure(L10n.text("Агент или подключение этого чата недоступны. Чат сохранён; другой агент не выбран.",
                                "This chat's agent or connection is unavailable. The chat is retained; no other agent was selected."))
    }

    /// Preserve every old key. Queues, metrics, summaries and job-run links already
    /// reference those keys, so no cross-file remapping or partial rename is needed.
    public static func migrated(_ source: SavedState) throws -> SavedState {
        var value = source
        guard value.identityVersion == nil || value.identityVersion == 1 || value.identityVersion == 2 else {
            throw invalidStorage
        }
        let legacy = value.identityVersion != 2
        if legacy && value.defaultConnection == nil { value.defaultConnection = .originalCodex }
        guard value.defaultConnection != nil else { throw invalidStorage }
        var ids = Set<String>(), sessions = Set<AgentSessionReference>()
        for index in value.chats.indices {
            let id = value.chats[index].id
            guard !id.isEmpty, ids.insert(id).inserted else { throw invalidStorage }
            if legacy && value.chats[index].nativeSession == nil {
                value.chats[index].nativeSession = AgentSessionReference(connection: .originalCodex, nativeID: id)
            }
            guard let session = value.chats[index].nativeSession, !session.nativeID.isEmpty,
                  sessions.insert(session).inserted else { throw invalidStorage }
        }
        // Missing-chat queues remain stored and paused; never attach them to a new chat.
        value.identityVersion = 2
        return value
    }

    public static func nativeID(for id: String, in state: SavedState, connection: AgentConnectionID = .originalCodex) throws -> String {
        guard let chat = state.chats.first(where: { $0.id == id }),
              let session = chat.nativeSession, !session.nativeID.isEmpty,
              session.connection == connection else { throw unavailable }
        return session.nativeID
    }

    public static func appID(for nativeID: String, in state: SavedState, connection: AgentConnectionID = .originalCodex) -> String? {
        let matches = state.chats.filter { $0.nativeSession == AgentSessionReference(connection: connection, nativeID: nativeID) }
        return matches.count == 1 ? matches.first?.id : nil
    }
}

/// (connection, native ID) -> app chat ID for a fixed list of chats; the same answers as
/// `ConversationIdentity.appID(for:in:connection:)` without filtering every chat per lookup.
/// Build it once per change of the chat list; streamed events resolve their chat through it.
public struct NativeSessionMap: Sendable, Equatable {
    private var ids: [AgentSessionReference: String] = [:]
    /// Sessions several chats claim; they resolve to nil, like the filter's `count == 1` rule.
    private var shared: Set<AgentSessionReference> = []

    public init(chats: [Chat]) {
        ids.reserveCapacity(chats.count)
        for chat in chats {
            guard let session = chat.nativeSession else { continue }
            if ids.updateValue(chat.id, forKey: session) != nil { shared.insert(session) }
        }
    }

    public func appID(for nativeID: String, connection: AgentConnectionID = .originalCodex) -> String? {
        appID(for: AgentSessionReference(connection: connection, nativeID: nativeID))
    }

    public func appID(for session: AgentSessionReference) -> String? {
        shared.contains(session) ? nil : ids[session]
    }
}
