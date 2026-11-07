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
    /// The app default effort setting of `agent` as stored: the catalog agent's own, else the composer's session value.
    func defaultEffortSetting(_ agent: AgentConnectionID) -> String? {
        modelCatalog(agent) != nil ? state.claudeEffort : draftEffort
    }
    /// The project's own default for new chats of `agent`; empty when it follows the app default.
    func projectModelChoice(_ agent: AgentConnectionID, project: UUID?) -> ModelChoice {
        project.flatMap { self.project($0)?.chatModels?[agent.agent.rawValue] } ?? ModelChoice()
    }
    /// What a new chat of `agent` in `project` starts with before the app default: the composer's pick for the
    /// project's next chat, then the project default. A pick never changes any default.
    func newChatChoice(_ agent: AgentConnectionID, project: UUID?) -> ModelChoice {
        let picked = project.flatMap { newChatModelChoices[$0]?[agent.agent.rawValue] }
        return ModelChoice.resolve([picked, projectModelChoice(agent, project: project)])
    }
    /// Records the composer's pick for the selected project's next new chat only.
    func pickNewChatModel(_ change: (inout ModelChoice) -> Void) {
        guard let project = projectID else { return }
        var picks = newChatModelChoices[project] ?? [:]
        var choice = picks[currentAgent.agent.rawValue] ?? ModelChoice()
        change(&choice)
        picks[currentAgent.agent.rawValue] = choice.isEmpty ? nil : choice
        newChatModelChoices[project] = picks.isEmpty ? nil : picks
    }
    /// Saves the composer's current model and effort as the default of new chats: the project's, or the app's (which
    /// also clears the project's own, so the project follows it).
    func saveCurrentModelAsDefault(projectOnly: Bool) {
        let agent = currentAgent, choice = ModelChoice(model: currentModel, effort: currentEffort)
        guard let project = selectedChat?.projectID ?? projectID,
              let index = state.projects.firstIndex(where: { $0.id == project }) else { return }
        if projectOnly {
            state.projects[index].setChatModel(choice, agent: agent.agent.rawValue)
        } else {
            if modelCatalog(agent) != nil { state.claudeModel = choice.model; state.claudeEffort = choice.effort }
            else if traits(agent).contains(.sessionModels) { setDefaultModelSetting(choice.model ?? "", agent: agent) }
            else { state.model = choice.model ?? ""; draftEffort = choice.effort ?? "medium" }
            state.projects[index].setChatModel(ModelChoice(), agent: agent.agent.rawValue)
        }
        newChatModelChoices[project]?[agent.agent.rawValue] = nil
        persist()
    }
    /// The default model a new message uses (project default, else the app's); a catalog agent resolves an unset
    /// setting to the app default.
    func resolvedDefaultModel(_ agent: AgentConnectionID, project: UUID? = nil) -> String {
        let setting = projectModelChoice(agent, project: project).model ?? defaultModelSetting(agent)
        return modelCatalog(agent)?.resolveModel(setting) ?? setting
    }
    /// The effort sent to a session-models agent: only one the model lists, else none (the agent's own default).
    func sessionEffort(_ effort: String?, model: String, agent: AgentConnectionID?) -> String {
        guard let effort, let listed = agentState(agent).models.first(where: { $0.id == model })?.efforts, listed.contains(effort) else { return "" }
        return effort
    }
    /// The default effort of a new chat (project default, else the app's).
    func resolvedDefaultEffort(_ agent: AgentConnectionID, project: UUID? = nil) -> String {
        let setting = projectModelChoice(agent, project: project).effort ?? defaultEffortSetting(agent)
        return modelCatalog(agent)?.resolveEffort(setting) ?? setting ?? draftEffort
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
        let setting = selectedChat?.model ?? newChatChoice(currentAgent, project: projectID).model ?? defaultModelSetting(currentAgent)
        // A catalog agent has an app default, so a blank value never reaches the CLI as "its own choice".
        return modelCatalog(currentAgent)?.resolveModel(setting) ?? setting
    }
    /// The effort the composer sends with: the catalog level, the selected model's free-form effort, or for a
    /// session-models agent only an effort its model lists.
    var currentEffort: String {
        if modelCatalog(currentAgent) != nil { return claudeEffort }
        if traits(currentAgent).contains(.sessionModels) { return sessionEffort(effort, model: currentModel, agent: currentAgent) }
        return effort
    }
    /// In a new chat the pick holds for the project's next chat only; the defaults change through
    /// `saveCurrentModelAsDefault` and the project settings.
    func selectCurrentModel(_ value: String) {
        if modelCatalog(currentAgent) != nil {
            if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].model = value; saveAgentChoice() }
            else { pickNewChatModel { $0.model = value } }
        } else { selectModel(value) }
    }
    /// A catalog agent keeps its own effort so another agent's default never leaks into its session.
    /// An unset or blank value resolves to the app default level.
    var claudeEffort: String {
        let configured = selectedChat.map { $0.effort ?? state.claudeEffort }
            ?? newChatChoice(currentAgent, project: projectID).effort ?? state.claudeEffort
        return (modelCatalog(currentAgent) ?? modelCatalog(firstAgent(with: .catalogModels)))?.resolveEffort(configured) ?? configured ?? ""
    }
    func selectClaudeEffort(_ value: String) {
        guard let catalog = modelCatalog(currentAgent), catalog.isDispatchableEffort(value) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].effort = value; saveAgentChoice() }
        else { pickNewChatModel { $0.effort = value } }
    }
}
