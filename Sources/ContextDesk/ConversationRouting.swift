import Foundation
import ContextCore
import AgentContract

/// Chat-to-connection routing through the registry: a chat belongs to the connection of its native session, and only a
/// registered connection serves it. Agent-specific model and effort rules follow the connection's traits.
extension DeskModel {
    func sessionForChat(_ appID: String) throws -> AgentSessionReference {
        _ = try nativeThread(appID)
        guard let session = state.chats.first(where: { $0.id == appID })?.nativeSession else {
            throw ConversationIdentity.unavailable
        }
        return session
    }
    /// Application identity ownership remains independent of the native event decoder.
    func nativeThread(_ appID: String) throws -> String {
        guard let session = state.chats.first(where: { $0.id == appID })?.nativeSession,
              isRegistered(session.connection) else { throw ConversationIdentity.unavailable }
        return try ConversationIdentity.nativeID(for: appID, in: state, connection: session.connection)
    }
    func chatIsAvailable(_ appID: String) -> Bool {
        (try? nativeThread(appID)) != nil
    }
    func clientForChat(_ id: String) throws -> AgentClient {
        guard let client = client(try sessionForChat(id).connection) else { throw ConversationIdentity.unavailable }
        return client
    }
    func chatConnected(_ id: String) -> Bool { agentState(connectionOfChat(id)).connected }
    func chatAuthenticated(_ id: String) -> Bool { agentState(connectionOfChat(id)).authenticated }
    /// The selected chat's connection, else the agent chosen for new chats, else the first registered one.
    var currentAgent: AgentConnectionID {
        selectedChat?.nativeSession?.connection ?? state.defaultConnection ?? agentIDs.first ?? .unregistered
    }
    var currentAgentName: String { agentName(currentAgent) }
    var currentAgentConnected: Bool { agentState(currentAgent).connected }
    var currentAgentAuthenticated: Bool { agentState(currentAgent).authenticated }

    /// The agent's default model setting as stored: a catalog agent keeps its own (possibly empty) setting.
    func defaultModelSetting(_ agent: AgentConnectionID) -> String {
        traits(agent).contains(.catalogModels) ? state.claudeModel ?? "" : state.model
    }
    /// The default model a new message uses; a catalog agent resolves an unset setting to the app default.
    func resolvedDefaultModel(_ agent: AgentConnectionID) -> String {
        traits(agent).contains(.catalogModels) ? ClaudeModel.resolved(state.claudeModel) : state.model
    }
    /// The default effort of a new chat on a catalog agent.
    func resolvedDefaultEffort(_ agent: AgentConnectionID) -> String {
        traits(agent).contains(.catalogModels) ? ClaudeEffort.resolved(state.claudeEffort) : draftEffort
    }
    /// Model and effort a queued app message (continuation, Telegram reply) is sent with on the chat's own agent.
    func dispatchModel(_ chat: Chat) -> String {
        traits(chat.nativeSession?.connection).contains(.catalogModels) ? ClaudeModel.resolved(chat.model) : chat.model
    }
    func dispatchEffort(_ chat: Chat) -> String {
        traits(chat.nativeSession?.connection).contains(.catalogModels)
            ? ClaudeEffort.resolved(chat.effort ?? state.claudeEffort) : chat.effort ?? "medium"
    }
    var currentModel: String {
        // A catalog agent has an app default, so a blank value never reaches the CLI as "its own choice".
        if traits(currentAgent).contains(.catalogModels) { return ClaudeModel.resolved(selectedChat?.model ?? state.claudeModel) }
        return selectedChat?.model ?? state.model
    }
    /// The effort the composer sends with: the catalog level, or the selected model's free-form effort.
    var currentEffort: String { traits(currentAgent).contains(.catalogModels) ? claudeEffort : effort }
    func selectCurrentModel(_ value: String) {
        if traits(currentAgent).contains(.catalogModels) {
            if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].model = value }
            else { state.claudeModel = value }
            saveAgentChoice()
        } else { selectModel(value) }
    }
    /// A catalog agent keeps its own effort so another agent's default never leaks into its session.
    /// An unset or blank value resolves to the app default level.
    var claudeEffort: String { ClaudeEffort.resolved(selectedChat?.effort ?? state.claudeEffort) }
    func selectClaudeEffort(_ value: String) {
        guard traits(currentAgent).contains(.catalogModels), ClaudeEffort.isDispatchable(value) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].effort = value }
        else { state.claudeEffort = value }
        saveAgentChoice()
    }
}
