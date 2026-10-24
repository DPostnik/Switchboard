import Foundation

public struct AgentExecutionRequest: Sendable {
    /// App-generated correlation ID; it is NOT permission to replay a request.
    public let id: UUID
    public let conversation: ConversationID
    public let session: AgentSessionReference?
    public let kind: Kind
    public let prompt: String
    public let projectPath: String
    public let permissions: AgentPermissionIntent
    public let model: AgentModelSelection
    public let route: AgentRoute
    public let browserProfile: AgentBrowserProfile?

    public enum Kind: Sendable {
        case interactive, scheduled
        public var capability: AgentCapability { self == .interactive ? .interactiveSessions : .scheduledExecution }
    }
    public init(id: UUID = UUID(), conversation: ConversationID, session: AgentSessionReference? = nil,
                kind: Kind, prompt: String, projectPath: String, permissions: AgentPermissionIntent,
                model: AgentModelSelection, route: AgentRoute, browserProfile: AgentBrowserProfile? = nil) {
        self.id = id; self.conversation = conversation; self.session = session; self.kind = kind
        self.prompt = prompt; self.projectPath = projectPath; self.permissions = permissions
        self.model = model; self.route = route
        self.browserProfile = browserProfile
    }
}

/// Deliberately closed recipes; JSON schemas and native tool-disabling flags live in adapters.
public struct AgentGenerationRequest: Sendable {
    public static let maximumInputBytes = 128 * 1024
    public enum Recipe: String, Sendable { case chatTitleV1, archiveSummaryV1, contextHandoffV1 }
    public let id: UUID
    public let source: AgentSessionReference
    public let recipe: Recipe
    public let historicalInput: String
    public let model: AgentModelSelection
    public let route: AgentRoute
    public let language: String
    public init(id: UUID = UUID(), source: AgentSessionReference, recipe: Recipe, historicalInput: String,
                model: AgentModelSelection, route: AgentRoute, language: String) {
        self.id = id; self.source = source; self.recipe = recipe; self.historicalInput = historicalInput
        self.model = model; self.route = route; self.language = language
    }
}

public enum AgentGenerationOutput: Sendable {
    case title(String)
    case handoff(String)
    case summary(AgentSummary, usage: AgentUsage?, seconds: Double)
}

public struct AgentSummary: Codable, Equatable, Sendable {
    public struct Activity: Codable, Equatable, Sendable {
        public let goal: String
        public let actions: [String]
        public let outcome: String
        public let unfinished: [String]
        public let reusableSteps: [String]
        public let variableInputs: [String]
        public let evidence: [String]
        public init(goal: String, actions: [String], outcome: String, unfinished: [String],
                    reusableSteps: [String], variableInputs: [String], evidence: [String]) {
            self.goal = goal; self.actions = actions; self.outcome = outcome; self.unfinished = unfinished
            self.reusableSteps = reusableSteps; self.variableInputs = variableInputs; self.evidence = evidence
        }
    }
    public let overview: String
    public let activities: [Activity]
    public init(overview: String, activities: [Activity]) {
        self.overview = overview; self.activities = activities
    }
}

public enum AgentAvailability<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable
    case unsupported
}

public struct AgentAccount: Sendable {
    public enum Status: Sendable { case authenticated, signedOut, unknown }
    public let context: AgentContext
    public let status: Status
    public let displayName: String?
    public init(context: AgentContext, status: Status, displayName: String?) {
        self.context = context; self.status = status; self.displayName = displayName
    }
}

public struct AgentModel: Sendable {
    public let selection: AgentModelSelection
    public let displayName: String
    public let efforts: [String]
    public init(selection: AgentModelSelection, displayName: String, efforts: [String]) {
        self.selection = selection; self.displayName = displayName; self.efforts = efforts
    }
}

public struct AgentUsage: Codable, Equatable, Sendable {
    /// Missing counters are unavailable, never zero. Cached input is a subset of input.
    public let input: Int?
    public let cachedInput: Int?
    public let output: Int?
    public init(input: Int?, cachedInput: Int?, output: Int?) {
        self.input = input; self.cachedInput = cachedInput; self.output = output
    }
}

public struct AgentLimitWindow: Sendable {
    public let name: String
    public let usedFraction: Double?
    public let resetsAt: Date?
    public init(name: String, usedFraction: Double?, resetsAt: Date?) {
        self.name = name; self.usedFraction = usedFraction; self.resetsAt = resetsAt
    }
}

public struct AgentToolConfiguration: Sendable {
    public struct Server: Sendable {
        public let id: String
        public let executable: URL
        public let arguments: [String]
        public init(id: String, executable: URL, arguments: [String]) {
            self.id = id; self.executable = executable; self.arguments = arguments
        }
    }
    public let servers: [Server]
    public let workflowDirectories: [URL]
    public init(servers: [Server], workflowDirectories: [URL]) {
        self.servers = servers; self.workflowDirectories = workflowDirectories
    }
}

public enum AgentResult<Value: Sendable>: Sendable {
    case success(Value)
    /// Rejected before dispatch; not an execution failure and not an automatic retry instruction.
    case rejected(AgentRejection)
    case unavailable
    case failed(AgentFailure)
}

public struct AgentFailure: Sendable {
    public enum Delivery: String, Codable, Sendable { case notSent, confirmed, uncertain }
    public let delivery: Delivery
    /// Provider diagnostic data. The application owns localized surrounding copy.
    public let diagnostic: String?
    public init(delivery: Delivery, diagnostic: String? = nil) {
        self.delivery = delivery; self.diagnostic = diagnostic
    }
}

public struct AgentExecutionHandle: Codable, Hashable, Sendable {
    public let context: AgentContext
    public let requestID: UUID
    public let session: AgentSessionReference?
    public let turnID: String?
    public init(context: AgentContext, requestID: UUID, session: AgentSessionReference?, turnID: String? = nil) {
        self.context = context; self.requestID = requestID; self.session = session; self.turnID = turnID
    }
}

public enum AgentAuthenticationAction: Sendable { case beginSignIn, signOut }
public enum AgentAuthenticationStep: Sendable { case complete, openURL(URL), openLocalSignIn(URL), externalCLIRequired }
public enum AgentCancellation: Sendable { case confirmed, requested, uncertain, alreadyFinished }

/// One adapter instance per connection. Implementations must validate immediately before dispatch.
/// A successful submit acknowledges delivery, not completion. Completion arrives through events.
/// No implementation may retry execution after uncertain delivery or change agent/account/route.
public protocol AgentIntegration: Sendable {
    var events: AsyncStream<AgentEvent> { get }
    /// Environment required by the existing optimizer process protocol; no credentials are copied.
    func optimizerEnvironment(home: URL) async -> AgentResult<[String: String]>
    func connect(_ configuration: AgentConnectionConfiguration) async -> AgentResult<AgentDescriptor>
    func descriptor() async -> AgentResult<AgentDescriptor>
    func disconnect() async
    func observe(sessions: [AgentSessionReference]) async
    func account() async -> AgentResult<AgentAccountInfo>
    func authenticate(_ action: AgentAuthenticationAction) async -> AgentResult<AgentAuthenticationStep>
    func models() async -> AgentResult<[AgentModelInfo]>
    func limits() async -> AgentResult<AccountLimits>
    func configure(_ tools: AgentToolConfiguration, context: AgentContext) async -> AgentResult<Void>
    /// Session preparation is separate so the app can durably link a job before sending work.
    func prepare(_ request: AgentExecutionRequest) async -> AgentResult<AgentSessionReference>
    func submit(_ request: AgentExecutionRequest) async -> AgentResult<AgentExecutionHandle>
    func cancel(_ execution: AgentExecutionHandle) async -> AgentResult<AgentCancellation>
    /// Stops one running background task or sub-agent (`task`), or all of the session's running ones (`nil`).
    /// The turn itself keeps running. Each stop request is sent once; an uncertain delivery is not retried.
    func stopTasks(_ task: String?, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void>
    func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void>
    func rejectInteraction(_ id: UUID) async
    func history(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<[AgentHistoryTurn]>
    func summarySource(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<AgentSummarySource>
    func rename(_ session: AgentSessionReference, title: String, context: AgentContext) async -> AgentResult<Void>
    func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void>
    func delete(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void>
    /// Callback records the durable dispatch claim after isolation is verified, before any model turn.
    func generate(_ request: AgentGenerationRequest, environment: AgentGenerationEnvironment,
                  willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentGenerationOutput>
    func cancelGeneration(_ id: UUID) async
}
extension AgentIntegration {
    public func stopTasks(_ task: String?, session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        .rejected(.unsupported(.interruption))
    }
}
