import Foundation
import AgentContract
import ContextCore

/// Rechecked by the transport immediately before writing, including across actor suspension.
enum CodexDispatchContext { @TaskLocal static var epoch: UUID? }
enum CodexDispatchRejection: Error { case stale }

/// One connection, one account revision, one explicit route set. Never retries an operation.
public actor CodexIntegration: AgentIntegration {
    public nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation
    private let client: CodexClient
    private var observer: Task<Void, Never>?
    private var routes: Set<AgentRoute> = [.direct]
    private var browserProfilesEnabled = false
    private var providerArguments: [String] = []
    private var dispatched = Set<UUID>()
    private var turnContexts: [AgentSessionReference: [String: AgentContext]] = [:]
    private var finishedTurns: [AgentSessionReference: Set<String>] = [:]
    private var sessionRoutes: [AgentSessionReference: (AgentRoute, AgentContext)] = [:]
    private var cancelledGenerations = Set<UUID>()
    private var generations: [UUID: ArchiveSummaryRunner] = [:]
    private var interactionContexts: [UUID: AgentContext] = [:]
    public init(client: CodexClient = CodexClient()) {
        self.client = client
        let pair = AsyncStream<AgentEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    deinit { observer?.cancel(); sink.finish() }

    private func listen() {
        guard observer == nil else { return }
        observer = Task { [weak self, client] in
            for await event in client.events { await self?.receive(event) }
        }
    }
    private func receive(_ event: AgentEvent) async {
        switch event.payload {
        case .accountChanged, .disconnected:
            interactionContexts.removeAll(); turnContexts.removeAll(); finishedTurns.removeAll()
            for runner in generations.values { await runner.stop() }
            if case .success(let value) = await descriptor() { sink.yield(.init(session: nil, payload: .descriptor(value))) }
        case .started(let turn):
            if let session = event.session, case .success(let value) = await descriptor() {
                turnContexts[session, default: [:]][turn] = value.context
            }
        case .completed(let completion):
            if let session = event.session { finishedTurns[session, default: []].insert(completion.id) }
        case .interaction(let value):
            if case .success(let descriptor) = await descriptor() { interactionContexts[value.id] = descriptor.context }
        case .resolved(let id): interactionContexts[id] = nil
        case .interactionsReset: interactionContexts.removeAll()
        default: break
        }
        sink.yield(event)
    }
    public func observe(sessions: [AgentSessionReference]) async {
        listen(); await client.observeEvents(sessions: sessions)
    }
    public func optimizerEnvironment(home: URL) -> AgentResult<[String: String]> { .success(["CODEX_HOME": home.path]) }
    public func connect(_ configuration: AgentConnectionConfiguration) async -> AgentResult<AgentDescriptor> {
        listen()
        do {
            guard Set(configuration.optimizers.map(\.id)).count == configuration.optimizers.count else { return .rejected(.invalidInput) }
            await disconnect()
            let arguments = try configuration.optimizers.flatMap { try CodexOptimizerConfiguration.arguments(id: $0.id, endpoint: $0.endpoint) }
            _ = try BrowserConfiguration.arguments(enabled: configuration.browserEnabled, resources: configuration.resources)
            try await client.start(executable: configuration.executable ?? Locations.codexExecutable(), home: configuration.home,
                                   extraArguments: arguments,
                                   browserResources: configuration.browserEnabled ? configuration.resources : nil)
            providerArguments = arguments
            browserProfilesEnabled = configuration.browserEnabled
            routes = Set([.direct] + configuration.optimizers.map { .optimizer(id: $0.id) })
            let result = await descriptor()
            if case .success(let value) = result { sink.yield(.init(session: nil, payload: .descriptor(value))) }
            else { await disconnect() }
            return result
        } catch { await disconnect(); return failure(error, delivery: .notSent) }
    }
    public func descriptor() async -> AgentResult<AgentDescriptor> {
        guard await client.transport.isRunning else { return .unavailable }
        let version = await client.transport.serverUserAgent ?? ""
        guard CodexProtocolCompatibility.accepts(userAgent: version) else { return .rejected(.incompatibleContract) }
        let epoch = await client.transport.accountEpoch
        return .success(AgentDescriptor(context: .init(connection: .originalCodex, accountRevision: epoch), identityMode: .appOwnedHome,
            capabilities: Set<AgentCapability>([.interactiveSessions, .scheduledExecution, .isolatedGeneration, .history, .archive, .streaming,
                           .approvals, .userQuestions, .interruption, .authenticationManagement, .modelDiscovery,
                           .usage, .accountLimits, .workflowRegistration]).union(browserProfilesEnabled ? [.browserProfiles] : []), permissions: .codexProjectPolicy, routes: routes))
    }
    public func disconnect() async {
        interactionContexts.removeAll(); turnContexts.removeAll(); finishedTurns.removeAll()
        for runner in generations.values { await runner.stop() }
        await client.stop()
        routes = [.direct]; providerArguments = []; sessionRoutes.removeAll()
        browserProfilesEnabled = false
    }
    private func current() async throws -> AgentDescriptor {
        try await descriptor().value()
    }
    private func check(_ context: AgentContext, session: AgentSessionReference? = nil) async throws {
        let descriptor = try await current()
        guard descriptor.context == context else { throw IntegrationRejection(.staleContext) }
        if let session, session.connection != context.connection || session.nativeID.isEmpty { throw IntegrationRejection(.wrongConnection) }
    }
    private func perform<T: Sendable>(_ context: AgentContext? = nil, session: AgentSessionReference? = nil,
                                     delivery: AgentFailure.Delivery = .uncertain, verifyAfter: Bool = true, readOnly: Bool = false,
                                     _ body: () async throws -> T) async -> AgentResult<T> {
        do {
            let resolvedContext: AgentContext
            if let context { resolvedContext = context } else { resolvedContext = try await current().context }
            let context = resolvedContext
            try await check(context, session: session)
            let value = try await CodexDispatchContext.$epoch.withValue(context.accountRevision) { try await body() }
            if verifyAfter {
                do { try await check(context, session: session) }
                catch let rejection as IntegrationRejection where readOnly && rejection.reason == .staleContext {
                    // Discard obsolete metadata; the account event drives a fresh refresh.
                    return .rejected(.staleContext)
                }
                catch { return .failed(.init(delivery: delivery, diagnostic: error.localizedDescription)) }
            }
            return .success(value)
        } catch { return failure(error, delivery: delivery) }
    }
    private func failure<T>(_ error: any Error, delivery: AgentFailure.Delivery) -> AgentResult<T> {
        if let error = error as? IntegrationRejection { return .rejected(error.reason) }
        if error is CodexDispatchRejection { return .rejected(.staleContext) }
        if let error = error as? AgentOperationFailure { return error.result() }
        return .failed(.init(delivery: delivery, diagnostic: error.localizedDescription))
    }
    public func account() async -> AgentResult<AgentAccountInfo> { await perform(readOnly: true) { try await self.client.account() } }
    public func authenticate(_ action: AgentAuthenticationAction) async -> AgentResult<AgentAuthenticationStep> {
        switch action {
        case .beginSignIn: return await perform { .openURL(try await self.client.signInURL()) }
        case .signOut:
            // Invalidate before logout dispatch, even if no account event is returned.
            await client.transport.invalidateAccount()
            let result: AgentResult<AgentAuthenticationStep> = await perform(verifyAfter: false) {
                try await self.client.signOut(); return .complete
            }
            if case .success(let descriptor) = await descriptor() { sink.yield(.init(session: nil, payload: .descriptor(descriptor))) }
            return result
        }
    }
    public func models() async -> AgentResult<[AgentModelInfo]> { await perform(readOnly: true) { try await self.client.models() } }
    public func limits() async -> AgentResult<AccountLimits> { await perform(readOnly: true) { try await self.client.limits() } }
    public func configure(_ tools: AgentToolConfiguration, context: AgentContext) async -> AgentResult<Void> {
        guard tools.servers.isEmpty else { return .rejected(.unsupported(.toolRegistration)) }
        return await perform(context) {
            try await self.client.registerWorkflows(at: tools.workflowDirectories)
        }
    }
    private func access(_ permission: AgentPermissionIntent) throws -> AgentPermissionProfile {
        guard case .profile(let profile, _) = permission, AgentPermissionSupport.codexProjectPolicy.accepts(permission) else {
            throw IntegrationRejection(.unsupportedPermissions)
        }
        return profile
    }
    private func route(_ value: AgentRoute) throws -> RequestRoute {
        switch value {
        case .direct: return .direct
        case .optimizer(let id): return RequestRoute(rawValue: id)
        case .externalConfiguration: throw IntegrationRejection(.routeUnavailable)
        }
    }
    private func validate(_ request: AgentExecutionRequest) async throws {
        let descriptor = try await current()
        if let reason = descriptor.validate(request) { throw IntegrationRejection(reason) }
    }
    public func prepare(_ request: AgentExecutionRequest) async -> AgentResult<AgentSessionReference> {
        do {
            try await validate(request)
            return await perform(request.model.context, session: request.session) {
                let access = try self.access(request.permissions), route = try self.route(request.route)
                if let session = request.session {
                    try await self.client.resume(session, projectPath: request.projectPath, permissions: access, route: route,
                                                 scheduled: request.kind == .scheduled)
                    self.sessionRoutes[session] = (request.route, request.model.context)
                    return session
                }
                let session = try await self.client.createSession(projectPath: request.projectPath, permissions: access, model: request.model.model, route: route,
                                                                  browserProfile: request.browserProfile, scheduled: request.kind == .scheduled)
                self.sessionRoutes[session] = (request.route, request.model.context)
                return session
            }
        } catch { return failure(error, delivery: .notSent) }
    }
    public func submit(_ request: AgentExecutionRequest) async -> AgentResult<AgentExecutionHandle> {
        do {
            try await validate(request)
            guard dispatched.insert(request.id).inserted else { return .rejected(.unknownRequest) }
            return await perform(request.model.context, session: request.session) {
                let session: AgentSessionReference
                if let existing = request.session {
                    guard let binding = self.sessionRoutes[existing], binding.0 == request.route, binding.1 == request.model.context else {
                        throw IntegrationRejection(.staleContext)
                    }
                    session = existing
                } else { session = try await self.prepare(request).value() }
                let turn = try await self.client.send(request.prompt, to: session, projectPath: request.projectPath,
                    permissions: self.access(request.permissions), model: request.model.model, effort: request.model.effort ?? "")
                guard let turn, !turn.isEmpty else { throw ClientFailure(L10n.text("Не получен ID запуска", "No turn ID received")) }
                self.turnContexts[session, default: [:]][turn] = request.model.context
                let handle = AgentExecutionHandle(context: request.model.context, requestID: request.id, session: session, turnID: turn)
                return handle
            }
        } catch { return failure(error, delivery: .notSent) }
    }
    public func cancel(_ execution: AgentExecutionHandle) async -> AgentResult<AgentCancellation> {
        guard let session = execution.session, let turn = execution.turnID else { return .rejected(.unknownRequest) }
        guard turnContexts[session]?[turn] == execution.context else { return .rejected(.unknownRequest) }
        if finishedTurns[session]?.contains(turn) == true { return .success(.alreadyFinished) }
        return await perform(execution.context, session: session) {
            try await self.client.interrupt(session, turn: turn); return .requested
        }
    }
    public func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void> {
        guard interactionContexts[id] == context else { return .rejected(.unknownRequest) }
        // The native client consumes valid answers before writing; invalid input remains editable.
        return await perform(context, session: session) { try await self.client.answer(id, session: session, response: response) }
    }
    public func rejectInteraction(_ id: UUID) async { interactionContexts[id] = nil; await client.rejectInteraction(id) }
    public func history(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<[AgentHistoryTurn]> {
        await perform(context, session: session) { try await self.client.history(session) }
    }
    public func summarySource(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<AgentSummarySource> {
        await perform(context, session: session) {
            let source = try await self.client.summarySource(session)
            return AgentSummarySource(digest: source.digest, fragments: source.chunks.flatMap(\.fragments).map {
                AgentSummaryFragment(reference: $0.reference, kind: $0.kind, text: $0.text)
            }, turnDates: source.turnDates, omittedDetails: source.omittedDetails)
        }
    }
    public func rename(_ session: AgentSessionReference, title: String, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) { try await self.client.rename(session, title: title) }
    }
    public func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) { try await self.client.setArchived(archived, session: session) }
    }
    public func delete(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) { try await self.client.delete(session) }
    }
    public func generate(_ request: AgentGenerationRequest, environment: AgentGenerationEnvironment,
                         willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentGenerationOutput> {
        let runner = ArchiveSummaryRunner()
        do {
            try Task.checkCancellation()
            guard !cancelledGenerations.contains(request.id) else { throw CancellationError() }
            let descriptor = try await current()
            if let reason = descriptor.validate(request) { return .rejected(reason) }
            guard environment.home.standardizedFileURL == (await client.transport.activeHome) else { return .rejected(.wrongConnection) }
            guard dispatched.insert(request.id).inserted else { return .rejected(.unknownRequest) }
            generations[request.id] = runner
            defer { generations[request.id] = nil }
            let route = try route(request.route), executable = try environment.executable ?? Locations.codexExecutable()
            let context = request.model.context
            let start: @Sendable () async throws -> Void = { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.checkGeneration(request.id, context: context, source: request.source)
                try await willStart()
                try await self.checkGeneration(request.id, context: context, source: request.source)
            }
            return try await withTaskCancellationHandler {
                let output: AgentGenerationOutput
                switch request.recipe {
                case .chatTitleV1:
                    output = .title(try await runner.title(firstMessage: request.historicalInput, model: request.model.model,
                        route: route, executable: executable, home: environment.home, workspace: environment.workspace,
                        providerArguments: providerArguments, willStart: start))
                case .contextHandoffV1:
                    output = .handoff(try await runner.handoff(input: request.historicalInput, model: request.model.model,
                        route: route, executable: executable, home: environment.home, workspace: environment.workspace,
                        providerArguments: providerArguments, language: AppLanguage(rawValue: request.language) ?? .english,
                        willStart: start))
                case .archiveSummaryV1:
                    guard let directory = environment.recipeDirectory else { return .rejected(.invalidInput) }
                    let fragments = try JSONDecoder().decode([AgentSummaryFragment].self, from: Data(request.historicalInput.utf8))
                    let source = try SummarySource(digest: "", fragments: fragments.map { .init(reference: $0.reference, kind: $0.kind, text: $0.text) }, turnDates: [:], omittedDetails: false)
                    guard source.chunks.count == 1 else { return .rejected(.invalidInput) }
                    let part = try await runner.summarize(chunk: source.chunks[0], recipe: ArchiveSummaryRecipe(directory: directory),
                        model: request.model.model, route: route, executable: executable, home: environment.home,
                        workspace: environment.workspace, providerArguments: providerArguments,
                        language: AppLanguage(rawValue: request.language) ?? .english, willStart: start)
                    let summary = try JSONDecoder().decode(AgentSummary.self, from: JSONEncoder().encode(part.content))
                    output = .summary(summary, usage: part.tokens.map { .init(input: $0.input, cachedInput: $0.cached, output: $0.output) }, seconds: part.seconds)
                }
                try await checkGeneration(request.id, context: context, source: request.source)
                return .success(output)
            } onCancel: { Task { await runner.stop() } }
        } catch {
            if let failure = error as? SummaryRunFailure { return .failed(.init(delivery: failure.uncertain ? .uncertain : .confirmed, diagnostic: failure.message)) }
            return failure(error, delivery: .notSent)
        }
    }
    private func checkGeneration(_ id: UUID, context: AgentContext, source: AgentSessionReference) async throws {
        try Task.checkCancellation()
        guard !cancelledGenerations.contains(id) else { throw CancellationError() }
        try await check(context, session: source)
    }
    public func cancelGeneration(_ id: UUID) async {
        cancelledGenerations.insert(id)
        await generations[id]?.stop()
    }
}

private struct IntegrationRejection: LocalizedError {
    let reason: AgentRejection
    init(_ reason: AgentRejection) { self.reason = reason }
    var errorDescription: String? { L10n.text("Подключение или запрос больше недействительны. Действие не повторено.", "The connection or request is no longer valid. The action was not retried.") }
}
