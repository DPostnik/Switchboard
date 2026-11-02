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
    /// The selected chat's connection, else the agent chosen for new chats (while its CLI is present), else the first
    /// registered one.
    var currentAgent: AgentConnectionID {
        if let connection = selectedChat?.nativeSession?.connection { return connection }
        if let chosen = state.defaultConnection, !isRegistered(chosen) || agentState(chosen).installed { return chosen }
        return agentIDs.first ?? .unregistered
    }
    var currentAgentName: String { agentName(currentAgent) }
    var currentAgentConnected: Bool { agentState(currentAgent).connected }
    var currentAgentAuthenticated: Bool { agentState(currentAgent).authenticated }

    /// The app's model catalog of an agent with `catalogModels` (the adapter's, through the composition root).
    func modelCatalog(_ agent: AgentConnectionID?) -> AgentModelCatalog? {
        traits(agent).contains(.catalogModels) ? profile(agent)?.modelCatalog?() : nil
    }
    /// The agent's default model setting as stored: a catalog agent keeps its own (possibly empty) setting.
    /// `SavedState.claudeModel`, `claudeEffort` and `claudeAdvisor` are the stored settings of the catalog agent.
    func defaultModelSetting(_ agent: AgentConnectionID) -> String {
        if traits(agent).contains(.sessionModels) { return state.agentModels?[agent.agent.rawValue] ?? "" }
        return modelCatalog(agent) != nil ? state.claudeModel ?? "" : state.model
    }
    /// A session-models agent's own default model (empty keeps the agent's default).
    func setDefaultModelSetting(_ model: String, agent: AgentConnectionID) {
        var models = state.agentModels ?? [:]
        models[agent.agent.rawValue] = model.isEmpty ? nil : model
        state.agentModels = models.isEmpty ? nil : models
    }
    /// The default model a new message uses; a catalog agent resolves an unset setting to the app default.
    func resolvedDefaultModel(_ agent: AgentConnectionID) -> String {
        if traits(agent).contains(.sessionModels) { return defaultModelSetting(agent) }
        return modelCatalog(agent)?.resolveModel(state.claudeModel) ?? state.model
    }
    /// The effort sent to a session-models agent: only one the model lists, else none (the agent's own default).
    func sessionEffort(_ effort: String?, model: String, agent: AgentConnectionID?) -> String {
        guard let effort, let listed = agentState(agent).models.first(where: { $0.id == model })?.efforts, listed.contains(effort) else { return "" }
        return effort
    }
    /// The default effort of a new chat on a catalog agent.
    func resolvedDefaultEffort(_ agent: AgentConnectionID) -> String {
        modelCatalog(agent)?.resolveEffort(state.claudeEffort) ?? draftEffort
    }
    /// Model and effort a queued app message (continuation, Telegram reply) is sent with on the chat's own agent.
    func dispatchModel(_ chat: Chat) -> String {
        modelCatalog(chat.nativeSession?.connection)?.resolveModel(chat.model) ?? chat.model
    }
    func dispatchEffort(_ chat: Chat) -> String {
        let agent = chat.nativeSession?.connection
        if traits(agent).contains(.sessionModels) { return sessionEffort(chat.effort, model: chat.model, agent: agent) }
        return modelCatalog(agent)?.resolveEffort(chat.effort ?? state.claudeEffort) ?? chat.effort ?? "medium"
    }
    var currentModel: String {
        // A catalog agent has an app default, so a blank value never reaches the CLI as "its own choice".
        if let catalog = modelCatalog(currentAgent) { return catalog.resolveModel(selectedChat?.model ?? state.claudeModel) }
        if traits(currentAgent).contains(.sessionModels) { return selectedChat?.model ?? defaultModelSetting(currentAgent) }
        return selectedChat?.model ?? state.model
    }
    /// The effort the composer sends with: the catalog level, the selected model's free-form effort, or for a
    /// session-models agent only an effort its model lists.
    var currentEffort: String {
        if modelCatalog(currentAgent) != nil { return claudeEffort }
        if traits(currentAgent).contains(.sessionModels) { return sessionEffort(effort, model: currentModel, agent: currentAgent) }
        return effort
    }
    func selectCurrentModel(_ value: String) {
        if modelCatalog(currentAgent) != nil {
            if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].model = value }
            else { state.claudeModel = value }
            saveAgentChoice()
        } else { selectModel(value) }
    }
    /// A catalog agent keeps its own effort so another agent's default never leaks into its session.
    /// An unset or blank value resolves to the app default level.
    var claudeEffort: String {
        let configured = selectedChat?.effort ?? state.claudeEffort
        return (modelCatalog(currentAgent) ?? modelCatalog(firstAgent(with: .catalogModels)))?.resolveEffort(configured) ?? configured ?? ""
    }
    func selectClaudeEffort(_ value: String) {
        guard let catalog = modelCatalog(currentAgent), catalog.isDispatchableEffort(value) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].effort = value }
        else { state.claudeEffort = value }
        saveAgentChoice()
    }
}
