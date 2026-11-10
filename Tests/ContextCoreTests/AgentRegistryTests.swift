import Foundation
import Testing
import AgentContract
import ClaudeAdapter
@testable import ContextCore
@testable import ContextDesk

// Stage B: the app holds N agent connections. A third agent is one more registration; routing, state and events
// reach it without any change to the app's code.

private let thirdConnection = AgentConnectionID(agent: AgentID(rawValue: "third-agent"), id: UUID())

/// A minimal per-chat agent: connects, reports a signed-in account and records the interactions it is told to reject.
private actor ThirdAgent: AgentIntegration {
    nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation
    private let context = AgentContext(connection: thirdConnection, accountRevision: UUID())
    private(set) var connects = 0
    private(set) var rejected: [UUID] = []
    init() { (events, sink) = AsyncStream.makeStream() }
    func emit(_ event: AgentEvent) { sink.yield(event) }
    private var descriptorValue: AgentDescriptor {
        AgentDescriptor(context: context, identityMode: .appOwnedHome, capabilities: [.interactiveSessions],
                        permissions: AgentPermissionSupport(roleProfiles: true), routes: [.direct])
    }
    func optimizerEnvironment(home: URL) async -> AgentResult<[String: String]> { .success([:]) }
    func connect(_ configuration: AgentConnectionConfiguration) async -> AgentResult<AgentDescriptor> { connects += 1; return .success(descriptorValue) }
    func descriptor() async -> AgentResult<AgentDescriptor> { .success(descriptorValue) }
    func disconnect() async {}
    func observe(sessions: [AgentSessionReference]) async {}
    func account() async -> AgentResult<AgentAccountInfo> { .success(.init(authenticated: true, plan: nil)) }
    func authenticate(_ action: AgentAuthenticationAction) async -> AgentResult<AgentAuthenticationStep> { .rejected(.unsupported(.authenticationManagement)) }
    func models() async -> AgentResult<[AgentModelInfo]> { .success([]) }
    func limits() async -> AgentResult<AccountLimits> { .rejected(.unsupported(.accountLimits)) }
    func configure(_ tools: AgentToolConfiguration, context: AgentContext) async -> AgentResult<Void> { .rejected(.unsupported(.toolRegistration)) }
    func prepare(_ request: AgentExecutionRequest) async -> AgentResult<AgentSessionReference> { .unavailable }
    func submit(_ request: AgentExecutionRequest) async -> AgentResult<AgentExecutionHandle> { .unavailable }
    func cancel(_ execution: AgentExecutionHandle) async -> AgentResult<AgentCancellation> { .unavailable }
    func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void> { .unavailable }
    func rejectInteraction(_ id: UUID) async { rejected.append(id) }
    func history(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<[AgentHistoryTurn]> { .success([]) }
    func summarySource(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<AgentSummarySource> { .unavailable }
    func rename(_ session: AgentSessionReference, title: String, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func delete(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func generate(_ request: AgentGenerationRequest, environment: AgentGenerationEnvironment,
                  willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentGenerationOutput> { .unavailable }
    func cancelGeneration(_ id: UUID) async {}
}

private let thirdProfile = AgentProfile(
    connection: thirdConnection, engine: JobEngine(rawValue: "third"), name: "Third", productName: "Third CLI", traits: [],
    accountLine: { $0.authenticated ? "Third · on" : "Third · off" }, accountLabel: { _ in "Third account" }, signInPrompt: { "Sign in to Third" },
    noLimitsNotice: nil, browserImportTool: "browser_import_session", remoteAgent: "third",
    restartRequester: (key: "thirdSession", environment: "THIRD_SESSION_ID"), routineCapabilities: nil,
    accountCopy: AgentAccountCopy(section: { "Third" }, signIn: { "Sign in" }, signOut: { "Sign out" }, note: nil,
                                  limitsScope: { "Third limits" }, limitsSignIn: { "Sign in to see limits" }, handoffSignIn: nil),
    modelCatalog: nil)

@MainActor private func model(root: URL, third: ThirdAgent) -> DeskModel {
    let agents = AgentIntegrationFactory.registrations(summaryHome: root.appendingPathComponent("codex"), claudeHome: root.appendingPathComponent("claude"),
                                                       geminiHome: root.appendingPathComponent("gemini"))
        + [AgentRegistration(profile: thirdProfile, integration: third, home: root.appendingPathComponent("third"),
                             generationHome: root.appendingPathComponent("third"), generationExecutable: nil)]
    return DeskModel(agents: agents, store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                     capabilityLedger: CapabilityLedger(file: root.appendingPathComponent("ledger.sqlite")),
                     pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil,
                     summaryHome: root.appendingPathComponent("codex"), jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
}

@Test @MainActor func registryKeepsTheFactoryOrderAndProfiles() {
    let model = DeskModel(summaryResources: nil)
    let gemini = AgentIntegrationFactory.geminiProfile.connection
    #expect(model.agentIDs == [.originalCodex, .appClaude, gemini])
    #expect(model.agentIDs == AgentIntegrationFactory.profiles.map(\.connection))
    #expect(model.agentName(.originalCodex) == "Codex" && model.agentName(.appClaude) == "Claude" && model.agentName(gemini) == "Gemini")
    #expect(model.traits(gemini) == [.sharedEngine, .sessionModels] && model.profile(gemini)?.productName == "Gemini CLI")
    #expect(model.profile(gemini)?.systemImage != nil && model.profile(gemini)?.remoteAgent == nil && model.profile(gemini)?.restartRequester == nil)
    #expect(model.connection(for: .codex) == .originalCodex && model.connection(for: .claude) == .appClaude)
    #expect(model.connection(for: JobEngine(rawValue: "unknown")) == nil)
    // Only the factory's traits tell agents apart.
    #expect(model.traits(.originalCodex).isSuperset(of: [.connectsAtLaunch, .sharedEngine, .optimizerPlugins, .remoteChatSettings]))
    #expect(model.traits(.appClaude).isSuperset(of: [.catalogModels, .chatDirectory, .adapterHistory]))
    #expect(model.traits(.appClaude).isDisjoint(with: [.connectsAtLaunch, .sharedEngine, .optimizerPlugins]))
    #expect(model.optimizerHost == .originalCodex && model.chatSearchAgent == .appClaude)
    // An unknown connection is never served, never named as another agent and has no traits.
    let unknown = AgentConnectionID(agent: AgentID(rawValue: "other"), id: UUID())
    #expect(!model.isRegistered(unknown) && model.client(unknown) == nil && model.traits(unknown).isEmpty && model.agentName(unknown) == "other")
    #expect(Set(AgentIntegrationFactory.scheduled.keys) == [.codex, .claude] && Set(AgentIntegrationFactory.scheduledReadiness.keys) == [.codex, .claude])
}

@Test @MainActor func connectionStatePublishesTheModel() {
    let model = DeskModel(summaryResources: nil)
    var changes = 0
    let observation = model.objectWillChange.sink { changes += 1 }
    defer { observation.cancel() }
    model.agentStates[.appClaude]?.authenticated = true
    model.agentStates[.originalCodex]?.connected = true
    #expect(changes == 2)
    #expect(model.claudeAuthenticated && model.connected && !model.claudeConnected && !model.authenticated)
}

@Test @MainActor func aThirdAgentConnectsRoutesAndReceivesEventsThroughTheRegistry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let third = ThirdAgent()
    let model = model(root: root, third: third)
    #expect(model.agentIDs == [.originalCodex, .appClaude, AgentIntegrationFactory.geminiProfile.connection, thirdConnection])
    model.state.model = "codex-default"

    await model.connect(thirdConnection)
    #expect(await third.connects == 1)
    #expect(model.agentState(thirdConnection).connected && model.agentState(thirdConnection).authenticated)
    #expect(model.agentState(thirdConnection).descriptor?.context.connection == thirdConnection)
    // The other connections are untouched, and the third agent's empty model list leaves Codex's default model alone.
    #expect(!model.agentState(.originalCodex).connected && !model.agentState(.appClaude).connected)
    #expect(model.state.model == "codex-default")

    let project = Project(path: root.path)
    let chat = Chat(session: AgentSessionReference(connection: thirdConnection, nativeID: "session-1"), projectID: project.id, title: "T", model: "")
    model.state.projects = [project]; model.state.chats = [chat]
    #expect(try model.clientForChat(chat.id) === model.client(thirdConnection))
    #expect(model.chatIsAvailable(chat.id) && model.chatConnected(chat.id) && model.chatAuthenticated(chat.id))
    #expect(model.supportsSummaries(chat) && model.canGenerateSummary(chat))
    #expect(model.generationRunner(for: chat.id) === model.generationRunner(connection: thirdConnection))
    #expect(model.generationEnvironment(for: chat.id, workspace: "w").home == root.appendingPathComponent("third"))

    // Events arrive through the connection's own loop: an interaction for an unknown session is rejected on it.
    model.chatID = chat.id
    await model.startEventLoops()
    let stray = AgentSessionReference(connection: thirdConnection, nativeID: "unknown")
    let strayID = UUID()
    await third.emit(AgentEvent(session: stray, payload: .interaction(AgentInteraction(id: strayID, session: stray, turn: nil,
        kind: .approval(canAllow: true), reason: nil, details: "ls"))))
    for _ in 0..<200 where await third.rejected.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await third.rejected == [strayID])

    let session = try #require(chat.nativeSession)
    let requestID = UUID()
    await model.receive(AgentEvent(session: session, payload: .interaction(AgentInteraction(id: requestID, session: session, turn: nil,
        kind: .approval(canAllow: true), reason: nil, details: "ls"))), from: thirdConnection)
    #expect(model.pending.map(\.interaction.id) == [requestID])
    await model.receive(AgentEvent(session: session, payload: .delta(turn: "t1", item: "a1", text: "hi")), from: thirdConnection)

    // Losing a per-chat engine signs only that connection out and clears only its requests.
    await model.receive(AgentEvent(session: nil, payload: .disconnected), from: thirdConnection)
    #expect(!model.agentState(thirdConnection).connected && !model.agentState(thirdConnection).authenticated)
    #expect(model.pending.isEmpty)
    await model.shutdown()
}

@Test @MainActor func claudeCatalogReachesTheAppInNeutralForm() throws {
    let model = DeskModel(summaryResources: nil)
    #expect(model.modelCatalog(.originalCodex) == nil)
    let catalog = try #require(model.modelCatalog(.appClaude))
    #expect(catalog.entries.map(\.id) == ClaudeModel.catalog.map(\.id))
    #expect(catalog.entries.map(\.menuTitle) == ClaudeModel.catalog.map(\.menuTitle))
    #expect(catalog.runnable.map(\.id) == ClaudeModel.catalog.filter { $0.isSupported() }.map(\.id))
    #expect(catalog.current.map(\.id) == ClaudeModel.current.map(\.id) && catalog.previous.map(\.id) == ClaudeModel.previous.map(\.id))
    #expect(catalog.defaultModel == ClaudeModel.defaultID && catalog.resolveModel(" ") == ClaudeModel.defaultID && catalog.resolveModel("custom") == "custom")
    #expect(catalog.efforts.map(\.id) == ClaudeEffort.allCases.map(\.rawValue) && catalog.defaultEffort.id == ClaudeEffort.defaultLevel.rawValue)
    #expect(catalog.resolveEffort("bogus") == "medium" && catalog.isDispatchableEffort("") && !catalog.isDispatchableEffort("bogus"))
    #expect(catalog.advisors.map(\.id) == ClaudeAdvisor.options.map(\.id))
    #expect(catalog.advisor("opus", "claude-sonnet-5-5") == "opus" && catalog.advisor("opus", "claude-opus-5-5") == nil)
    #expect(catalog.title("") == ClaudeModel.title(for: "") && catalog.requirementNote("claude-opus-5-5") == nil)
    // The composer's catalog values for a Claude chat and the Codex defaults stay apart.
    model.state.claudeModel = nil; model.state.model = "codex-default"
    #expect(model.resolvedDefaultModel(.appClaude) == ClaudeModel.defaultID && model.resolvedDefaultModel(.originalCodex) == "codex-default")
    #expect(model.defaultModelSetting(.appClaude) == "" && model.defaultModelSetting(.originalCodex) == "codex-default")
}

/// Counts connects; stands in for Gemini when its CLI is missing.
private actor CountingAgent: AgentIntegration {
    nonisolated let events: AsyncStream<AgentEvent>
    private(set) var connects = 0
    init() { events = AsyncStream { $0.finish() } }
    func optimizerEnvironment(home: URL) async -> AgentResult<[String: String]> { .rejected(.routeUnavailable) }
    func connect(_ configuration: AgentConnectionConfiguration) async -> AgentResult<AgentDescriptor> { connects += 1; return .unavailable }
    func descriptor() async -> AgentResult<AgentDescriptor> { .unavailable }
    func disconnect() async {}
    func observe(sessions: [AgentSessionReference]) async {}
    func account() async -> AgentResult<AgentAccountInfo> { .unavailable }
    func authenticate(_ action: AgentAuthenticationAction) async -> AgentResult<AgentAuthenticationStep> { .unavailable }
    func models() async -> AgentResult<[AgentModelInfo]> { .unavailable }
    func limits() async -> AgentResult<AccountLimits> { .unavailable }
    func configure(_ tools: AgentToolConfiguration, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func prepare(_ request: AgentExecutionRequest) async -> AgentResult<AgentSessionReference> { .unavailable }
    func submit(_ request: AgentExecutionRequest) async -> AgentResult<AgentExecutionHandle> { .unavailable }
    func cancel(_ execution: AgentExecutionHandle) async -> AgentResult<AgentCancellation> { .unavailable }
    func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void> { .unavailable }
    func rejectInteraction(_ id: UUID) async {}
    func history(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<[AgentHistoryTurn]> { .unavailable }
    func summarySource(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<AgentSummarySource> { .unavailable }
    func rename(_ session: AgentSessionReference, title: String, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func delete(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> { .unavailable }
    func generate(_ request: AgentGenerationRequest, environment: AgentGenerationEnvironment,
                  willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentGenerationOutput> { .unavailable }
    func cancelGeneration(_ id: UUID) async {}
}

private final class Flag: @unchecked Sendable { var value = false }

@Test @MainActor func geminiIsListedInSettingsButStartsNothingWithoutItsCLI() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let installed = Flag(), counting = CountingAgent()
    var profile = AgentIntegrationFactory.geminiProfile
    let copy = try #require(profile.installation)
    profile.installation = AgentInstallation(isInstalled: { installed.value }, missing: copy.missing, hint: copy.hint)
    let gemini = profile.connection
    let agents = AgentIntegrationFactory.registrations(gemini: counting, geminiProfile: profile, summaryHome: root.appendingPathComponent("codex"),
                                                       claudeHome: root.appendingPathComponent("claude"), geminiHome: root.appendingPathComponent("gemini"))
    let model = DeskModel(agents: agents, store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          capabilityLedger: CapabilityLedger(file: root.appendingPathComponent("ledger.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil,
                          summaryHome: root.appendingPathComponent("codex"), jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    // Registered (Settings lists it and stored chats keep routing to it) but not selectable, and nothing starts.
    #expect(model.agentIDs.contains(gemini) && !model.selectableAgentIDs.contains(gemini) && !model.agentState(gemini).installed)
    #expect(copy.missing() == L10n.text("Gemini CLI не установлен", "Gemini CLI not installed"))
    #expect(copy.hint().contains("gemini-cli") && profile.accountLine(model.agentState(gemini)).contains("Gemini"))
    model.state.defaultConnection = gemini
    #expect(model.currentAgent == .originalCodex)
    model.selectAgent(gemini)
    await model.connect(gemini)
    await model.login(gemini)
    #expect(await counting.connects == 0 && !model.agentState(gemini).connected)
    // Gemini runs no scheduled jobs yet.
    #expect(!profile.scheduledJobs && AgentIntegrationFactory.scheduled[profile.engine] == nil)
    // Once the CLI appears, a check lists it and a connect starts it.
    installed.value = true
    model.refreshInstallations()
    #expect(model.selectableAgentIDs.contains(gemini) && model.currentAgent == gemini)
    await model.connect(gemini)
    #expect(await counting.connects == 1)
    await model.shutdown()
}

@Test @MainActor func permissionPresentationIsProviderNeutralAndDeduplicated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-presentation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let third = ThirdAgent()
    let model = model(root: root, third: third)
    await model.connect(thirdConnection)
    let project = Project(path: root.path)
    let session = AgentSessionReference(connection: thirdConnection, nativeID: "permission-session")
    let chat = Chat(session: session, projectID: project.id, title: "Permissions", model: "")
    model.state.projects = [project]; model.state.chats = [chat]
    let interaction = AgentInteraction(id: UUID(), session: session, turn: "t1",
        kind: .form(message: "Private MCP prompt", fields: []), reason: nil, details: "Private diagnostic payload",
        auditSource: "mcpServer/elicitation/request", origin: .tool)
    let event = AgentEvent(session: session, payload: .interaction(interaction))
    await model.receive(event, from: thirdConnection)
    await model.receive(event, from: thirdConnection)
    #expect(model.pending.count == 1)
    #expect(model.permissionExplanation(for: try #require(model.pending.first)) != nil)
    var rows: [CapabilityDecision] = []
    for _ in 0..<100 {
        rows = try await model.capabilityLedger.recent(days: 1)
        if !rows.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.stage == .presented && row.requestID == interaction.id.uuidString)
    #expect(row.source == "mcpServer/elicitation/request" && row.target == nil)
    #expect(try await model.capabilityLedger.interruptions(days: 1) == 1)
    #expect(model.pending.count == 1) // Observation never accepts a request.
    model.state.projects[0].sandboxCommands = ["zsh scripts/test.sh"]
    model.state.chats[0].roleID = AgentRoleID.developer
    func commandAction(cwd: String, command: String = "zsh scripts/test.sh") -> PendingAction {
        PendingAction(interaction: AgentInteraction(id: UUID(), session: session, turn: "t1",
            kind: .approval(canAllow: true), reason: nil, details: "display-only",
            command: command, workingDirectory: cwd), threadID: chat.id)
    }
    let matching = commandAction(cwd: root.path)
    #expect(model.commandAssessment(for: matching)?.decision == .unsupportedGrant)
    #expect(model.permissionExplanation(for: matching) != nil)
    #expect(model.commandAssessment(for: commandAction(cwd: root.path, command: "/bin/zsh -lc 'zsh scripts/test.sh'"))?.decision == .unsupportedGrant)
    #expect(model.commandAssessment(for: commandAction(cwd: "/another-project")) == nil)
    #expect(model.pending.count == 1)
    await model.shutdown()
}
