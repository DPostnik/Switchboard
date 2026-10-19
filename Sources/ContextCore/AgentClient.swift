import Foundation
@_exported import AgentContract

public struct AgentOperationFailure: LocalizedError, Sendable {
    public let rejection: AgentRejection?
    public let failure: AgentFailure?
    public var uncertain: Bool { failure?.delivery == .uncertain }
    public var errorDescription: String? {
        if let diagnostic = failure?.diagnostic { return diagnostic }
        switch rejection {
        case .incompatibleContract: return L10n.text("Версия движка не поддерживается этим адаптером. Подключение остановлено.", "This adapter does not support the engine version. Connection stopped.")
        case .staleContext: return L10n.text("Аккаунт или подключение изменились. Действие не повторено.", "The account or connection changed. The action was not retried.")
        case .routeUnavailable: return L10n.text("Выбранный маршрут недоступен", "The selected route is unavailable")
        case .unsupportedPermissions: return L10n.text("Движок не поддерживает запрошенные ограничения", "The engine does not support the requested restrictions")
        case .unsupported: return L10n.text("Движок не поддерживает это действие", "The engine does not support this operation")
        case .wrongConnection: return L10n.text("Этот разговор принадлежит другому подключению", "This conversation belongs to a different connection")
        case .unknownRequest, .invalidResponse, .invalidInput: return L10n.text("Запрос устарел или недопустим. Действие не повторено.", "The request is stale or invalid. The action was not retried.")
        case nil: return L10n.text("Движок недоступен. Подключись заново.", "The engine is unavailable. Reconnect.")
        }
    }
    public func result<T: Sendable>() -> AgentResult<T> {
        if let rejection { return .rejected(rejection) }
        if let failure { return .failed(failure) }
        return .unavailable
    }
}
extension AgentResult {
    public func value() throws -> Value {
        switch self {
        case .success(let value): return value
        case .rejected(let reason): throw AgentOperationFailure(rejection: reason, failure: nil)
        case .failed(let failure): throw AgentOperationFailure(rejection: nil, failure: failure)
        case .unavailable: throw AgentOperationFailure(rejection: nil, failure: nil)
        }
    }
}

/// Application-facing conveniences use only the common integration contract.
public actor AgentClient {
    public nonisolated let integration: any AgentIntegration
    public nonisolated var events: AsyncStream<AgentEvent> { integration.events }
    private var sessionContexts: [AgentSessionReference: AgentContext] = [:]
    private var sessionRoutes: [AgentSessionReference: RequestRoute] = [:]
    public init(integration: any AgentIntegration) { self.integration = integration }
    public func observeEvents(sessions: [AgentSessionReference] = []) async { await integration.observe(sessions: sessions) }
    public func start(_ configuration: AgentConnectionConfiguration) async throws -> AgentDescriptor {
        try await integration.connect(configuration).value()
    }
    public func descriptor() async throws -> AgentDescriptor { try await integration.descriptor().value() }
    public func stop() async { sessionContexts.removeAll(); sessionRoutes.removeAll(); await integration.disconnect() }
    public func account() async throws -> AgentAccountInfo { try await integration.account().value() }
    public func signInURL() async throws -> URL {
        guard case .openURL(let url) = try await integration.authenticate(.beginSignIn).value() else {
            throw AgentOperationFailure(rejection: .unsupported(.authenticationManagement), failure: nil)
        }
        return url
    }
    public func signOut() async throws { _ = try await integration.authenticate(.signOut).value() }
    public func models() async throws -> [AgentModelInfo] { try await integration.models().value() }
    public func limits() async throws -> AccountLimits { try await integration.limits().value() }
    public func registerWorkflows(at directory: URL) async throws {
        let context = try await descriptor().context
        try await integration.configure(.init(servers: [], workflowDirectories: [directory]), context: context).value()
    }
    private func request(prompt: String, session: AgentSessionReference?, projectPath: String, permissions profile: AgentPermissionProfile,
                         model: String, effort: String = "", route: RequestRoute, kind: AgentExecutionRequest.Kind = .interactive,
                         conversation: ConversationID = ConversationID(), context suppliedContext: AgentContext? = nil,
                         browserProfile: AgentBrowserProfile? = nil) async throws -> AgentExecutionRequest {
        let context: AgentContext
        if let suppliedContext { context = suppliedContext } else { context = try await descriptor().context }
        return AgentExecutionRequest(conversation: conversation, session: session, kind: kind, prompt: prompt, projectPath: projectPath,
            permissions: .profile(profile, root: projectPath),
            model: .init(context: context, model: model, effort: effort), route: route.agentRoute, browserProfile: browserProfile)
    }
    public func createSession(projectPath: String, permissions: AgentPermissionProfile, model: String, route: RequestRoute,
                              context: AgentContext? = nil, browserProfile: AgentBrowserProfile? = nil) async throws -> AgentSessionReference {
        let request = try await request(prompt: "", session: nil, projectPath: projectPath, permissions: permissions, model: model, route: route, context: context, browserProfile: browserProfile)
        let session = try await integration.prepare(request).value(); sessionRoutes[session] = route; sessionContexts[session] = request.model.context; return session
    }
    public func resume(_ session: AgentSessionReference, projectPath: String, permissions: AgentPermissionProfile, route: RequestRoute) async throws {
        let request = try await request(prompt: "", session: session, projectPath: projectPath, permissions: permissions, model: "", route: route)
        _ = try await integration.prepare(request).value(); sessionRoutes[session] = route; sessionContexts[session] = request.model.context
    }
    public func send(_ text: String, to session: AgentSessionReference, projectPath: String, permissions: AgentPermissionProfile,
                     model: String, effort: String, kind: AgentExecutionRequest.Kind = .interactive,
                     conversation: ConversationID = ConversationID()) async throws -> String? {
        guard let route = sessionRoutes[session], let context = sessionContexts[session] else {
            throw AgentOperationFailure(rejection: .staleContext, failure: nil)
        }
        let request = try await request(prompt: text, session: session, projectPath: projectPath, permissions: permissions, model: model,
            effort: effort, route: route, kind: kind, conversation: conversation, context: context)
        return try await integration.submit(request).value().turnID
    }
    // Legacy entry points: the old access modes stand for the editor and operator roles.
    public func createSession(projectPath: String, access: AccessMode, model: String, route: RequestRoute,
                              context: AgentContext? = nil, browserProfile: AgentBrowserProfile? = nil) async throws -> AgentSessionReference {
        try await createSession(projectPath: projectPath, permissions: AgentRoleCatalog.preset(access.legacyRoleID).profile, model: model, route: route, context: context, browserProfile: browserProfile)
    }
    public func resume(_ session: AgentSessionReference, projectPath: String, access: AccessMode, route: RequestRoute) async throws {
        try await resume(session, projectPath: projectPath, permissions: AgentRoleCatalog.preset(access.legacyRoleID).profile, route: route)
    }
    public func send(_ text: String, to session: AgentSessionReference, projectPath: String, access: AccessMode,
                     model: String, effort: String, kind: AgentExecutionRequest.Kind = .interactive,
                     conversation: ConversationID = ConversationID()) async throws -> String? {
        try await send(text, to: session, projectPath: projectPath, permissions: AgentRoleCatalog.preset(access.legacyRoleID).profile,
                       model: model, effort: effort, kind: kind, conversation: conversation)
    }
    public func interrupt(_ session: AgentSessionReference, turn: String) async throws {
        let context = try await descriptor().context
        _ = try await integration.cancel(.init(context: context, requestID: UUID(), session: session, turnID: turn)).value()
    }
    public func answer(_ id: UUID, session: AgentSessionReference, response: AgentInteractionResponse) async throws {
        try await integration.answer(id, session: session, context: descriptor().context, response: response).value()
    }
    public func rejectInteraction(_ id: UUID) async { await integration.rejectInteraction(id) }
    public func history(_ session: AgentSessionReference) async throws -> [AgentHistoryTurn] {
        try await integration.history(session, context: descriptor().context).value()
    }
    public func summarySource(_ session: AgentSessionReference) async throws -> SummarySource {
        let source = try await integration.summarySource(session, context: descriptor().context).value()
        return try SummarySource(digest: source.digest, fragments: source.fragments.map { .init(reference: $0.reference, kind: $0.kind, text: $0.text) }, turnDates: source.turnDates, omittedDetails: source.omittedDetails)
    }
    public func rename(_ session: AgentSessionReference, title: String) async throws { try await integration.rename(session, title: title, context: descriptor().context).value() }
    public func setArchived(_ archived: Bool, session: AgentSessionReference) async throws { try await integration.setArchived(archived, session: session, context: descriptor().context).value() }
    public func delete(_ session: AgentSessionReference) async throws { try await integration.delete(session, context: descriptor().context).value() }
}
extension RequestRoute {
    public var agentRoute: AgentRoute { self == .direct ? .direct : .optimizer(id: rawValue) }
}

/// Separate cancellable generation handles preserve parallel title/summary lifetimes.
public actor AgentGenerationRunner {
    private let integration: any AgentIntegration
    private var active: UUID?
    public init(integration: any AgentIntegration) { self.integration = integration }
    public func stop() async { if let active { await integration.cancelGeneration(active) } }
    public func title(source: AgentSessionReference, firstMessage: String, model: String, route: RequestRoute,
                      environment: AgentGenerationEnvironment) async throws -> String {
        let context = try await integration.descriptor().value().context
        let request = AgentGenerationRequest(source: source, recipe: .chatTitleV1, historicalInput: firstMessage,
            model: .init(context: context, model: model), route: route.agentRoute, language: L10n.language.rawValue)
        active = request.id; defer { active = nil }
        guard case .title(let title) = try await integration.generate(request, environment: environment, willStart: {}).value() else {
            throw AgentOperationFailure(rejection: .invalidResponse, failure: nil)
        }
        return title
    }
    public func handoff(source: AgentSessionReference, input: String, model: String, route: RequestRoute,
                        environment: AgentGenerationEnvironment, language: AppLanguage) async throws -> HandoffSummary {
        let context = try await integration.descriptor().value().context
        let request = AgentGenerationRequest(source: source, recipe: .contextHandoffV1, historicalInput: input,
            model: .init(context: context, model: model), route: route.agentRoute, language: language.rawValue)
        active = request.id; defer { active = nil }
        guard case .handoff(let output) = try await integration.generate(request, environment: environment, willStart: {}).value() else {
            throw AgentOperationFailure(rejection: .invalidResponse, failure: nil)
        }
        return try HandoffSummary.validate(output)
    }
    public func summarize(source: AgentSessionReference, chunk: SummarySource.Chunk, model: String, route: RequestRoute,
                          environment: AgentGenerationEnvironment, language: AppLanguage,
                          willStart: @escaping @Sendable () async throws -> Void) async throws -> SummaryPart {
        let context = try await integration.descriptor().value().context
        let request = AgentGenerationRequest(source: source, recipe: .archiveSummaryV1, historicalInput: chunk.json,
            model: .init(context: context, model: model), route: route.agentRoute, language: language.rawValue)
        active = request.id; defer { active = nil }
        guard case .summary(let summary, let usage, let seconds) = try await integration.generate(request, environment: environment, willStart: willStart).value() else {
            throw AgentOperationFailure(rejection: .invalidResponse, failure: nil)
        }
        let content = try JSONDecoder().decode(SummaryContent.self, from: JSONEncoder().encode(summary))
        let tokens = usage.flatMap { usage -> TokenCounters? in
            guard let input = usage.input, let cached = usage.cachedInput, let output = usage.output else { return nil }
            return TokenCounters(input: input, cached: cached, output: output)
        }
        return SummaryPart(sourceDigest: chunk.digest, content: content, tokens: tokens, seconds: seconds)
    }
}
