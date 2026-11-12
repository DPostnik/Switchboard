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
    private var providerClients: [AgentRoute: CodexClient] = [:]
    private var providerObservers: [AgentRoute: Task<Void, Never>] = [:]
    private var observer: Task<Void, Never>?
    private struct ChromeScope: Equatable {
        let grant: AgentUserChromeGrant?
        let project: String
        let permissions: AgentPermissionProfile
        let route: AgentRoute
        let scheduled: Bool
        let chatDirectory: [String]?
        /// The project's skill link folder (`ProjectSkills`); its appearance or removal changes the worker's grants.
        let projectSkills: URL?
    }
    private var chromeWorkers: [AgentSessionReference: CodexClient] = [:]
    private var chromeObservers: [AgentSessionReference: Task<Void, Never>] = [:]
    private var chromeScopes: [AgentSessionReference: ChromeScope] = [:]
    private var chromeInteractions: [AgentSessionReference: Set<UUID>] = [:]
    private var routes: Set<AgentRoute> = [.direct]
    private var browserProfilesEnabled = false
    private var resources: URL?
    /// Reasons already logged for running a worker natively instead of under the external boundary.
    private var loggedBoundaryReasons = Set<String>()
    /// The fallback notice last shown per chat: once per session and reason.
    private var boundaryNotices = CodexBoundaryNotices()
    /// The nono helper a worker runs under; tests inject one.
    private let boundaryHelper: @Sendable () -> Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>
    private var providerArguments: [String] = []
    private var dispatched = Set<UUID>()
    private var turnContexts: [AgentSessionReference: [String: AgentContext]] = [:]
    private var finishedTurns: [AgentSessionReference: Set<String>] = [:]
    private var sessionRoutes: [AgentSessionReference: (AgentRoute, AgentContext)] = [:]
    private var cancelledGenerations = Set<UUID>()
    private var generations: [UUID: ArchiveSummaryRunner] = [:]
    private var interactionContexts: [UUID: AgentContext] = [:]
    /// The last model list `models()` returned; it names the choices of the model and effort config options.
    private var knownModels: [AgentModelInfo] = []
    /// The user's own skill folder (`~/.codex/skills` in the app), registered read-only next to the app's workflows.
    private let userSkills: URL?
    /// Where the app keeps the projects' skill link folders (`ProjectSkills.directory`; tests use their own).
    private let projectSkillLinks: URL
    public init(client: CodexClient = CodexClient(), userSkills: URL? = nil, projectSkillLinks: URL = ProjectSkills.directory,
                boundaryHelper: @escaping @Sendable () -> Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure> = { ExternalSandboxHelper.bundled() }) {
        self.client = client; self.userSkills = userSkills; self.projectSkillLinks = projectSkillLinks; self.boundaryHelper = boundaryHelper
        let pair = AsyncStream<AgentEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    deinit { for task in chromeObservers.values { task.cancel() }; observer?.cancel(); for task in providerObservers.values { task.cancel() }; sink.finish() }

    private func listen() {
        guard observer == nil else { return }
        observer = Task { [weak self, client] in
            for await event in client.events { await self?.receive(event) }
        }
    }
    private func receive(_ event: AgentEvent, from worker: CodexClient, route: AgentRoute) async {
        guard providerClients[route] === worker else { return }
        await receive(event)
    }

    private func worker(for route: AgentRoute) throws -> CodexClient {
        if route == .direct { return client }
        guard let worker = providerClients[route] else { throw IntegrationRejection(.routeUnavailable) }
        return worker
    }

    private func worker(for session: AgentSessionReference) throws -> CodexClient {
        if let worker = chromeWorkers[session] { return worker }
        return try worker(for: sessionRoutes[session]?.0 ?? .direct)
    }

    private func receive(_ event: AgentEvent) async {
        switch event.payload {
        case .accountChanged, .disconnected:
            await stopChromeWorkers()
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
            let executable = try configuration.executable ?? Locations.codexExecutable()
            try await client.start(executable: executable, home: configuration.home,
                                   extraArguments: RequestRoute.direct.launchArguments,
                                   diagnosticsResources: configuration.resources, browserResources: configuration.browserEnabled ? configuration.resources : nil,
                                   userChromeEnabled: configuration.userChromeEnabled)
            let primary = await descriptor()
            guard case .success = primary else { await disconnect(); return primary }
            // Each provider has immutable process-level selection and the same app-owned account home.
            for optimizer in configuration.optimizers {
                let route = AgentRoute.optimizer(id: optimizer.id)
                let worker = await CodexClient(transport: client.transport.sibling())
                providerClients[route] = worker
                let selection = RequestRoute(rawValue: optimizer.id)
                let flags = try CodexOptimizerConfiguration.arguments(id: optimizer.id, endpoint: optimizer.endpoint)
                try await worker.start(executable: executable, home: configuration.home,
                    extraArguments: flags + selection.launchArguments,
                    diagnosticsResources: configuration.resources, browserResources: configuration.browserEnabled ? configuration.resources : nil,
                                   userChromeEnabled: configuration.userChromeEnabled)
                guard await worker.transport.serverUserAgent == client.transport.serverUserAgent else {
                    throw IntegrationRejection(.incompatibleContract)
                }
                providerObservers[route] = Task { [weak self] in
                    for await event in worker.events {
                        guard !Task.isCancelled else { return }
                        await self?.receive(event, from: worker, route: route)
                    }
                }
            }
            providerArguments = arguments
            browserProfilesEnabled = configuration.browserEnabled
            resources = configuration.resources
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
        guard let engine = CodexProtocolCompatibility.engine(userAgent: version, verifiedInstall: await client.transport.verifiedInstallVersion) else {
            let token = CodexProtocolCompatibility.version(userAgent: version).flatMap { value in
                value.count <= 80 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) } ? value : nil
            }
            return .rejected(.unverifiedEngineVersion(token))
        }
        if !engine.verified { CompatibilityDrift.shared.noteUnverified(.codex, version: engine.version) }
        let epoch = await client.transport.accountEpoch
        return .success(AgentDescriptor(context: .init(connection: .originalCodex, accountRevision: epoch), identityMode: .appOwnedHome,
            capabilities: Set<AgentCapability>([.interactiveSessions, .scheduledExecution, .isolatedGeneration, .history, .archive, .streaming,
                           .approvals, .userQuestions, .interruption, .authenticationManagement, .modelDiscovery,
                           .usage, .accountLimits, .workflowRegistration]).union(browserProfilesEnabled ? [.browserProfiles] : []), permissions: .codexProjectPolicy, routes: routes, engine: engine))
    }
    public func disconnect() async {
        interactionContexts.removeAll(); turnContexts.removeAll(); finishedTurns.removeAll()
        for runner in generations.values { await runner.stop() }
        for task in providerObservers.values { task.cancel() }
        providerObservers.removeAll()
        let workers = providerClients.values
        providerClients.removeAll()
        for worker in workers { await worker.stop() }
        await stopChromeWorkers()
        await client.stop()
        routes = [.direct]; providerArguments = []; sessionRoutes.removeAll(); knownModels = []
        browserProfilesEnabled = false
    }
    private func stopChromeWorkers() async {
        let workers = Array(chromeWorkers.values)
        for session in chromeWorkers.keys { sink.yield(.init(session: session, payload: .subagents([]))) }
        for session in Array(chromeInteractions.keys) { resolveChromeInteractions(session) }
        for task in chromeObservers.values { task.cancel() }
        chromeObservers.removeAll(); chromeScopes.removeAll(); chromeWorkers.removeAll(); chromeInteractions.removeAll()
        for worker in workers { await worker.stop() }
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
            await stopChromeWorkers()
            let result: AgentResult<AgentAuthenticationStep> = await perform(verifyAfter: false) {
                try await self.client.signOut(); return .complete
            }
            if case .success(let descriptor) = await descriptor() { sink.yield(.init(session: nil, payload: .descriptor(descriptor))) }
            return result
        }
    }
    public func models() async -> AgentResult<[AgentModelInfo]> {
        let result = await perform(readOnly: true) { try await self.client.models() }
        if case .success(let models) = result { knownModels = models }
        return result
    }
    public func limits() async -> AgentResult<AccountLimits> { await perform(readOnly: true) { try await self.client.limits() } }
    public func configure(_ tools: AgentToolConfiguration, context: AgentContext) async -> AgentResult<Void> {
        guard tools.servers.isEmpty else { return .rejected(.unsupported(.toolRegistration)) }
        // `skills/extraRoots/set` replaces the whole list, so the user's folder rides along with every registration.
        var isDirectory: ObjCBool = false
        let user = userSkills.flatMap { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
        let roots = tools.workflowDirectories + (user.map { tools.workflowDirectories.contains($0) ? [] : [$0] } ?? [])
        return await perform(context) {
            try await self.client.registerWorkflows(at: roots)
            for worker in self.providerClients.values { try await worker.registerWorkflows(at: roots) }
            for worker in self.chromeWorkers.values { try await worker.registerWorkflows(at: roots) }
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
    private func chromeScope(_ request: AgentExecutionRequest) throws -> ChromeScope {
        ChromeScope(grant: request.userChromeGrant, project: request.projectPath, permissions: try access(request.permissions),
                    route: request.route, scheduled: request.kind == .scheduled, chatDirectory: request.chatDirectory,
                    projectSkills: projectSkills(request.projectPath)?.folder)
    }
    /// The project's skills from `.agents/skills` and `.claude/skills` as the app's link folder, read at every turn; a folder
    /// the app cannot update leaves the chat without project skills rather than failing the turn.
    private func projectSkills(_ project: String) -> (folder: URL, skills: [ProjectSkills.Skill])? {
        do { return try ProjectSkills.linkFolder(projectPath: project, root: projectSkillLinks) }
        catch {
            ExternalSandboxLog.logger.error("Project skills for \(project, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    private func bindChromeWorker(_ worker: CodexClient, session: AgentSessionReference, scope: ChromeScope) async {
        let old = chromeWorkers[session]
        resolveChromeInteractions(session)
        chromeObservers.removeValue(forKey: session)?.cancel()
        chromeWorkers[session] = worker; chromeScopes[session] = scope
        chromeObservers[session] = Task { [weak self] in
            for await event in worker.events { await self?.receiveChrome(event, session: session, worker: worker) }
        }
        if let old {
            // The old process owns its background children. Dropping its observer must not leave
            // their last running snapshot in the UI after the authority scope is replaced.
            sink.yield(.init(session: session, payload: .subagents([])))
            await old.stop()
        }
    }
    /// A dedicated process is a session resource, not the connection itself. Its resets cannot
    /// invalidate approvals or running turns belonging to other workers on the same account.
    private func resolveChromeInteractions(_ session: AgentSessionReference) {
        for id in chromeInteractions.removeValue(forKey: session) ?? [] {
            interactionContexts[id] = nil
            sink.yield(.init(session: session, payload: .resolved(id)))
        }
    }
    private func receiveChrome(_ event: AgentEvent, session: AgentSessionReference, worker: CodexClient) async {
        guard chromeWorkers[session] === worker else { return }
        switch event.payload {
        case .accountChanged:
            // Only the primary process reports changes to the shared account.
            return
        case .interactionsReset:
            resolveChromeInteractions(session)
            return
        case .interaction(let interaction):
            chromeInteractions[session, default: []].insert(interaction.id)
        case .resolved(let id):
            chromeInteractions[session]?.remove(id)
        case .disconnected:
            // No replay: an interrupted worker cannot establish whether its last action completed.
            chromeWorkers[session] = nil; chromeScopes[session] = nil
            chromeObservers.removeValue(forKey: session)?.cancel()
            resolveChromeInteractions(session)
            let message = L10n.text("Процесс этого чата отключился. Результат действия неизвестен; повторной отправки не было.",
                                    "This chat's process disconnected. The action outcome is unknown; nothing was resent.")
            for turn in Array((turnContexts[session] ?? [:]).keys) where finishedTurns[session]?.contains(turn) != true {
                await receive(.init(session: session, payload: .completed(.init(id: turn, status: .uncertain,
                    hasError: true, error: message,
                    history: .init(id: turn, items: [], startedAt: nil, completedAt: Date(), duration: nil)))))
            }
            sink.yield(.init(session: session, payload: .diagnostic(message)))
            await worker.stop()
            return
        default: break
        }
        await receive(event)
        // Keep the owner after the parent completes: background children and their stop/history
        // operations still belong to this process. Scope changes and disconnect release it.
    }
    /// The planner input for a Codex worker: the same planner path as Claude (invariant 14). The worker's own settings
    /// proposal folder is writable (only it, not the whole inbox), so "one refusal, one request" works inside the boundary
    /// and the app knows the author; `pgrep` is mediated (inside, it sees only sandboxed processes); a trusted project
    /// command the boundary cannot run keeps the worker on the native sandbox.
    public static func boundaryInput(project: String, permissions: AgentPermissionProfile, home: URL, executable: URL, resources: URL?,
                              workflowDirectories: [URL], inbox: URL?) -> ExternalSandboxPlanner.Input {
        var input = ExternalSandboxPlanner.Input(project: project, profile: permissions, providerHome: home, providerExecutable: executable,
                                                 resources: resources, workflowDirectories: workflowDirectories)
        if let inbox {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            input.extraWrites = [inbox.path]
        }
        input.mediateProcessList = true; input.commandInventory = true
        return input
    }
    /// The boundary decision for a planner input. Role-defined reasons come first, as for Claude, so an Operator chat is never
    /// reported as a missing helper. `inbox` is the folder `input` grants; the launch exports it.
    static func boundaryDecision(_ input: ExternalSandboxPlanner.Input, inbox: URL? = nil,
                                 helper: () -> Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>) -> Result<ExternalSandboxLaunch, ExternalSandboxPlanner.Ineligible> {
        if let reason = ExternalSandboxPlanner.eligibility(input.profile) { return .failure(reason) }
        let helper = helper()
        switch ExternalSandboxPlanner.plan(input, helper: helper) {
        case .success(let plan):
            guard case .success(let verified) = helper else { return .failure(.helper(.missing(""))) }
            return .success(ExternalSandboxLaunch(plan: plan, helper: verified, settingsInbox: inbox))
        case .failure(let reason): return .failure(reason)
        }
    }
    /// The settings proposal folder of a worker that serves one chat for its whole life (`bindChromeWorker`): the thread ID
    /// when the worker starts for an existing thread, else an app token that `recordAuthor` maps to the new thread's ID.
    static func inboxFolderName(for session: AgentSessionReference?) -> String {
        session.map(\.nativeID).flatMap { SettingsProposalInbox.isFolderName($0) ? $0 : nil } ?? "codex-" + UUID().uuidString.lowercased()
    }
    /// The external boundary for a worker, or nil (native sandbox and prompts) with the reason logged once. The reason is
    /// returned for the chat notice; nil when the boundary is used or not attempted (no launch info).
    private func boundary(project: String, permissions: AgentPermissionProfile, route: AgentRoute, inboxFolder: String) async throws
        -> (launch: ExternalSandboxLaunch?, fallback: ExternalSandboxPlanner.Ineligible?) {
        let base = try worker(for: route)
        guard let launch = await base.launchInfo else { return (nil, nil) }
        let inbox = SettingsProposalInbox.chatFolder(inboxFolder)
        // The project's skill link folder is read like the workflows; its links resolve inside the project, which is granted.
        let skills = projectSkills(project).map { [$0.folder] } ?? []
        let input = Self.boundaryInput(project: project, permissions: permissions, home: launch.home, executable: launch.executable,
                                       resources: resources, workflowDirectories: await base.registeredWorkflowDirectories + skills, inbox: inbox)
        switch Self.boundaryDecision(input, inbox: inbox, helper: boundaryHelper) {
        case .success(let launch): return (launch, nil)
        case .failure(let reason):
            // The native path has no inbox (invariant 6); an empty folder made for this attempt goes.
            if let inbox { SettingsProposalInbox.removeEmptyFolder(inbox) }
            let text = reason.description(language: .english)
            if loggedBoundaryReasons.insert(project + "\n" + text).inserted {
                ExternalSandboxLog.logger.notice("Native Codex sandbox for \(project, privacy: .public): \(text, privacy: .public)")
            }
            return (nil, reason)
        }
    }
    /// Shows the fallback notice in the chat once per session and reason; a worker under the boundary resets it.
    private func noteFallback(_ reason: ExternalSandboxPlanner.Ineligible?, session: AgentSessionReference) {
        if let text = boundaryNotices.note(reason, session: session) { sink.yield(.init(session: session, payload: .diagnostic(text))) }
    }
    private func refreshChromeWorker(_ request: AgentExecutionRequest, session: AgentSessionReference) async throws {
        let scope = try chromeScope(request)
        guard chromeScopes[session] != scope else { return }
        let decision = try await boundary(project: scope.project, permissions: scope.permissions, route: request.route,
                                          inboxFolder: Self.inboxFolderName(for: session))
        let fresh = try await worker(for: request.route).isolatedSibling(
            permissionArguments: scope.permissions.codexProcessArguments(projectPath: scope.project),
            boundary: decision.launch, projectSkills: projectSkills(scope.project))
        do {
            // The process that loaded the thread holds its writer lock; the cold worker cannot resume it until it is released.
            try await (chromeWorkers[session] ?? worker(for: request.route)).release(session)
            try await fresh.resume(session, projectPath: request.projectPath, permissions: scope.permissions,
                                   route: route(request.route), scheduled: scope.scheduled, userChromeGrant: request.userChromeGrant,
                                   chatDirectory: request.chatDirectory)
        } catch { await fresh.stop(); throw error }
        await bindChromeWorker(fresh, session: session, scope: scope)
        noteFallback(decision.fallback, session: session)
    }
    public func prepare(_ request: AgentExecutionRequest) async -> AgentResult<AgentSessionReference> {
        do {
            try await validate(request)
            return await perform(request.model.context, session: request.session) {
                let access = try self.access(request.permissions), route = try self.route(request.route)
                if let session = request.session {
                    try await self.refreshChromeWorker(request, session: session)
                    self.sessionRoutes[session] = (request.route, request.model.context)
                    return session
                }
                let chosen = try self.worker(for: request.route)
                // A new thread has no ID before its worker starts: the worker gets an app token folder, mapped to the thread below.
                let folder = Self.inboxFolderName(for: nil)
                let decision = try await self.boundary(project: request.projectPath, permissions: access, route: request.route, inboxFolder: folder)
                let worker = try await chosen.isolatedSibling(
                    permissionArguments: access.codexProcessArguments(projectPath: request.projectPath),
                    boundary: decision.launch, projectSkills: self.projectSkills(request.projectPath))
                let session: AgentSessionReference
                do {
                    session = try await worker.createSession(projectPath: request.projectPath, permissions: access, model: request.model.model, route: route,
                                                             browserProfile: request.browserProfile, scheduled: request.kind == .scheduled,
                                                             userChromeGrant: request.userChromeGrant, chatDirectory: request.chatDirectory)
                } catch { await worker.stop(); throw error }
                if decision.launch?.settingsInbox != nil { SettingsProposalInbox.recordAuthor(folder: folder, session: session.nativeID) }
                await self.bindChromeWorker(worker, session: session, scope: try self.chromeScope(request))
                self.noteFallback(decision.fallback, session: session)
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
                try await self.refreshChromeWorker(request, session: session)
                // A skill added, removed or edited away inside the same folder: the worker rescans, the process stays.
                if let worker = self.chromeWorkers[session] {
                    try? await worker.refreshProjectSkills(self.projectSkills(request.projectPath), projectPath: request.projectPath)
                }
                let turn = try await self.worker(for: session).send(request.prompt, to: session, projectPath: request.projectPath,
                    permissions: self.access(request.permissions), model: request.model.model, effort: request.model.effort ?? "", userChromeGrant: request.userChromeGrant)
                guard let turn, !turn.isEmpty else { throw ClientFailure(L10n.text("Не получен ID запуска", "No turn ID received")) }
                self.turnContexts[session, default: [:]][turn] = request.model.context
                // The turn's model and effort as the session's settings; no request is made for them.
                self.sink.yield(.init(session: session, payload: .configOptions(AgentConfigOption.modelAndEffort(
                    models: self.knownModels, model: request.model.model, effort: request.model.effort))))
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
            try await self.worker(for: session).interrupt(session, turn: turn); return .requested
        }
    }
    public func stopTasks(_ task: String?, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) {
            try await self.worker(for: session).stopSubagents(task, session: session)
        }
    }
    public func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void> {
        guard interactionContexts[id] == context else { return .rejected(.unknownRequest) }
        // The native client consumes valid answers before writing; invalid input remains editable.
        return await perform(context, session: session) { try await self.worker(for: session).answer(id, session: session, response: response) }
    }
    public func rejectInteraction(_ id: UUID) async {
        interactionContexts[id] = nil
        await client.rejectInteraction(id)
        for worker in providerClients.values { await worker.rejectInteraction(id) }
        for worker in chromeWorkers.values { await worker.rejectInteraction(id) }
    }
    public func history(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<[AgentHistoryTurn]> {
        await perform(context, session: session) { try await self.worker(for: session).history(session) }
    }
    public func summarySource(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<AgentSummarySource> {
        await perform(context, session: session) {
            let source = try await self.worker(for: session).summarySource(session)
            return AgentSummarySource(digest: source.digest, fragments: source.chunks.flatMap(\.fragments).map {
                AgentSummaryFragment(reference: $0.reference, kind: $0.kind, text: $0.text)
            }, turnDates: source.turnDates, omittedDetails: source.omittedDetails)
        }
    }
    public func rename(_ session: AgentSessionReference, title: String, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) { try await self.worker(for: session).rename(session, title: title) }
    }
    public func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) { try await self.worker(for: session).setArchived(archived, session: session) }
    }
    public func delete(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session) { try await self.worker(for: session).delete(session) }
    }
    /// `thread/resume` and `turn/start` carry the folder each time; nothing stored names the old one.
    public func relocate(_ session: AgentSessionReference, to directory: String, context: AgentContext) async -> AgentResult<Void> {
        await perform(context, session: session, delivery: .notSent, verifyAfter: false, readOnly: true) { () }
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
                case .commitMessageV1:
                    let text = try await runner.structured(input: request.historicalInput, instructions: GitGeneration.commitInstructions,
                        schema: GitGeneration.commitSchema, model: request.model.model, route: route, executable: executable,
                        home: environment.home, workspace: environment.workspace, providerArguments: providerArguments, willStart: start)
                    do { output = .commitMessage(try GitGeneration.commitMessage(from: text)) }
                    catch { throw SummaryRunFailure(uncertain: false, message: error.localizedDescription) }
                case .pullRequestV1:
                    let text = try await runner.structured(input: request.historicalInput, instructions: GitGeneration.pullRequestInstructions,
                        schema: GitGeneration.pullRequestSchema, model: request.model.model, route: route, executable: executable,
                        home: environment.home, workspace: environment.workspace, providerArguments: providerArguments, willStart: start)
                    do {
                        let draft = try GitGeneration.pullRequest(from: text)
                        output = .pullRequest(title: draft.title, body: draft.body)
                    } catch { throw SummaryRunFailure(uncertain: false, message: error.localizedDescription) }
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

extension AgentPermissionSupport {
    /// Codex runs role profiles through its sandbox and approval policy. It has no shell-off mode, command text
    /// inspection, per-connector control, writable folder inside a read-only sandbox or writable folder exceptions beyond its sandbox.
    public static let codexProjectPolicy = Self(roleProfiles: true, enforced: [.sandboxedShell, .networkOffWithShell, .promptsWithoutSandbox, .userChrome])
}

private struct IntegrationRejection: LocalizedError {
    let reason: AgentRejection
    init(_ reason: AgentRejection) { self.reason = reason }
    var errorDescription: String? { L10n.text("Подключение или запрос больше недействительны. Действие не повторено.", "The connection or request is no longer valid. The action was not retried.") }
}
