import Foundation
import Testing
import AgentContract
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
                                  limitsScope: { "Third limits" }, limitsSignIn: { "Sign in to see limits" }, handoffSignIn: nil))

@MainActor private func model(root: URL, third: ThirdAgent) -> DeskModel {
    let agents = AgentIntegrationFactory.registrations(summaryHome: root.appendingPathComponent("codex"), claudeHome: root.appendingPathComponent("claude"))
        + [AgentRegistration(profile: thirdProfile, integration: third, home: root.appendingPathComponent("third"),
                             generationHome: root.appendingPathComponent("third"), generationExecutable: nil)]
    return DeskModel(agents: agents, store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                     capabilityLedger: CapabilityLedger(file: root.appendingPathComponent("ledger.sqlite")),
                     pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil,
                     summaryHome: root.appendingPathComponent("codex"), jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
}

@Test @MainActor func registryKeepsTheFactoryOrderAndProfiles() {
    let model = DeskModel(summaryResources: nil)
    #expect(model.agentIDs == [.originalCodex, .appClaude])
    #expect(model.agentIDs == AgentIntegrationFactory.profiles.map(\.connection))
    #expect(model.agentName(.originalCodex) == "Codex" && model.agentName(.appClaude) == "Claude")
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
    #expect(model.agentIDs == [.originalCodex, .appClaude, thirdConnection])
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
