import Foundation
import AgentContract
import ContextCore

/// Native typed driver used by CodexIntegration and protocol diagnostics.
public actor CodexClient {
    let transport: CodexConnection
    public nonisolated let events: AsyncStream<CodexEvent>
    let eventSink: AsyncStream<CodexEvent>.Continuation
    var eventTask: Task<Void, Never>?
    var interactionEpoch = UUID()
    var requestGeneration: UUID?
    var seenRequestIDs = Set<JSONValue>()
    var knownSessions = Set<AgentSessionReference>()
    private var browserResources: URL?
    private var browserRoot = BrowserConfiguration.directory
    var interactions: [UUID: (pending: CodexPendingInteraction, generation: UUID, token: UUID)] = [:]

    public init() {
        let transport = CodexConnection()
        self.transport = transport
        let pair = AsyncStream<CodexEvent>.makeStream(); events = pair.stream; eventSink = pair.continuation
    }

    @_spi(NativeProtocol) public init(transport: CodexConnection) {
        self.transport = transport
        let pair = AsyncStream<CodexEvent>.makeStream(); events = pair.stream; eventSink = pair.continuation
    }

    public func start(executable: URL, home: URL, extraArguments: [String] = [],
                      browserResources: URL? = nil, browserRoot: URL = BrowserConfiguration.directory) async throws {
        self.browserResources = browserResources
        self.browserRoot = browserRoot
        observeEvents()
        try await transport.start(executable: executable, home: home, extraArguments: extraArguments)
    }
    public func stop() async { resetInteractions(); await transport.stop() }
    deinit { eventTask?.cancel(); eventSink.finish() }

    public func account() async throws -> CodexAccount {
        let result = try await transport.request("account/read", params: .object(["refreshToken": .bool(false)]))
        return CodexAccount(authenticated: result["account"] != .null, plan: result["account"]["planType"].string)
    }
    public func signInURL() async throws -> URL {
        let result = try await transport.request("account/login/start", params: .object(["type": .string("chatgpt")]))
        guard let text = result["authUrl"].string, let url = URL(string: text),
              url.scheme == "https", let host = url.host,
              host == "chatgpt.com" || host == "auth.openai.com" || host.hasSuffix(".openai.com") else {
            throw ClientFailure(L10n.text("Движок не вернул допустимую ссылку входа", "The engine did not return a valid sign-in link"))
        }
        return url
    }
    public func signOut() async throws { resetInteractions(); _ = try await transport.request("account/logout") }
    public func models() async throws -> [CodexModel] {
        let result = try await transport.request("model/list", params: .object(["limit": .number(100), "includeHidden": .bool(false)]))
        return result["data"].array.compactMap(CodexModel.init)
    }
    public func limits() async throws -> AccountLimits {
        CodexDecoding.accountLimits(response: try await transport.request("account/rateLimits/read"))
    }
    public func registerWorkflows(at directory: URL) async throws { try await registerWorkflows(at: [directory]) }
    func registerWorkflows(at directories: [URL]) async throws {
        _ = try await transport.request("skills/extraRoots/set", params: .object(["extraRoots": .array(directories.map { .string($0.path) })]))
    }

    public func createSession(projectPath: String, permissions: AgentPermissionProfile, model: String, route: RequestRoute,
                              browserProfile: AgentBrowserProfile? = nil) async throws -> AgentSessionReference {
        var params = permissions.codexThreadParameters
        let profiles = BrowserProfileStore(root: browserRoot)
        guard browserProfile == nil || browserResources != nil else { throw BrowserProfileError.scope }
        let grant = browserResources == nil ? nil : try profiles.prepareNew(project: projectPath, connection: .originalCodex, selection: browserProfile) { environment in
            try BrowserProfileControl.verifyClosed(environment: environment, runtime: browserResources!.appendingPathComponent("BrowserRuntime"))
        }
        params["config"] = permissions.codexThreadConfiguration(browser: try BrowserConfiguration.threadConfiguration(resources: browserResources, root: browserRoot, environment: grant?.environment, grant: grant))
        params["cwd"] = .string(projectPath)
        params["modelProvider"] = .string(route.providerID)
        params["developerInstructions"] = .string(AgentAutonomy.instructions())
        if !model.isEmpty { params["model"] = .string(model) }
        let result = try await transport.request("thread/start", params: .object(params))
        guard let id = result["thread"]["id"].string, !id.isEmpty else {
            throw ClientFailure(L10n.text("Не получен ID разговора", "No conversation ID received"))
        }
        let session = AgentSessionReference(connection: .originalCodex, nativeID: id)
        if let grant { try profiles.acknowledge(grant, session: session) }
        knownSessions.insert(session)
        return session
    }
    public func resume(_ session: AgentSessionReference, projectPath: String, permissions: AgentPermissionProfile, route: RequestRoute) async throws {
        var params = permissions.codexThreadParameters
        let id = try nativeID(session)
        let profiles = BrowserProfileStore(root: browserRoot)
        let grant = browserResources == nil ? nil : try profiles.prepare(session: session, project: projectPath)
        params["config"] = permissions.codexThreadConfiguration(browser: try BrowserConfiguration.threadConfiguration(resources: browserResources, root: browserRoot, environment: grant?.environment, grant: grant))
        params["threadId"] = .string(id)
        params["cwd"] = .string(projectPath)
        params["modelProvider"] = .string(route.providerID)
        params["developerInstructions"] = .string(AgentAutonomy.instructions())
        _ = try await transport.request("thread/resume", params: .object(params))
        if let grant { try profiles.acknowledge(grant, session: session) }
    }
    /// Acknowledges submission only. Never retries after any transport failure.
    public func send(_ text: String, to session: AgentSessionReference, projectPath: String,
                     permissions: AgentPermissionProfile, model: String, effort: String) async throws -> String? {
        var params: [String: JSONValue] = [
            "threadId": .string(try nativeID(session)),
            "input": .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])])
        ]
        params.merge(permissions.codexTurnParameters(projectPath: projectPath)) { _, new in new }
        if !model.isEmpty { params["model"] = .string(model) }
        if !effort.isEmpty { params["effort"] = .string(effort) }
        return try await transport.request("turn/start", params: .object(params), timeout: 60)["turn"]["id"].string
    }
    // Legacy entry points: the old access modes stand for the editor and operator roles.
    public func createSession(projectPath: String, access: AccessMode, model: String, route: RequestRoute,
                              browserProfile: AgentBrowserProfile? = nil) async throws -> AgentSessionReference {
        try await createSession(projectPath: projectPath, permissions: AgentRoleCatalog.preset(access.legacyRoleID).profile, model: model, route: route, browserProfile: browserProfile)
    }
    public func resume(_ session: AgentSessionReference, projectPath: String, access: AccessMode, route: RequestRoute) async throws {
        try await resume(session, projectPath: projectPath, permissions: AgentRoleCatalog.preset(access.legacyRoleID).profile, route: route)
    }
    public func send(_ text: String, to session: AgentSessionReference, projectPath: String,
                     access: AccessMode, model: String, effort: String) async throws -> String? {
        try await send(text, to: session, projectPath: projectPath, permissions: AgentRoleCatalog.preset(access.legacyRoleID).profile, model: model, effort: effort)
    }
    public func interrupt(_ session: AgentSessionReference, turn: String) async throws {
        _ = try await transport.request("turn/interrupt", params: .object([
            "threadId": .string(try nativeID(session)), "turnId": .string(turn)
        ]))
    }
    public func rename(_ session: AgentSessionReference, title: String) async throws {
        _ = try await transport.request("thread/name/set", params: .object([
            "threadId": .string(try nativeID(session)), "name": .string(title)
        ]))
    }
    public func setArchived(_ archived: Bool, session: AgentSessionReference) async throws {
        _ = try await transport.request(archived ? "thread/archive" : "thread/unarchive",
                                       params: .object(["threadId": .string(try nativeID(session))]))
    }
    public func delete(_ session: AgentSessionReference) async throws {
        _ = try await transport.request("thread/delete", params: .object(["threadId": .string(try nativeID(session))]))
    }
    public func history(_ session: AgentSessionReference) async throws -> [CodexHistoryTurn] {
        try await read(session)["turns"].array.map(CodexHistoryTurn.init)
    }
    public func summarySource(_ session: AgentSessionReference) async throws -> SummarySource {
        try await CodexDecoding.summarySource(thread: read(session))
    }
    private func read(_ session: AgentSessionReference) async throws -> JSONValue {
        let id = try nativeID(session)
        let result = try await transport.request("thread/read", params: .object([
            "threadId": .string(id), "includeTurns": .bool(true)
        ]))
        guard result["thread"]["id"].string == id else {
            throw ClientFailure(L10n.text("Получена история другого чата", "Received history for a different chat"))
        }
        guard case .array = result["thread"]["turns"] else {
            throw ClientFailure(L10n.text("История чата недоступна", "Conversation history is unavailable"))
        }
        return result["thread"]
    }
    private func nativeID(_ session: AgentSessionReference) throws -> String {
        guard session.connection == .originalCodex, !session.nativeID.isEmpty else { throw ConversationIdentity.unavailable }
        knownSessions.insert(session); observeEvents()
        return session.nativeID
    }


}

extension AgentModelInfo {
    init?(_ value: JSONValue) {
        guard let id = value["model"].string, !id.isEmpty else { return nil }
        self.init(id: id, displayName: value["displayName"].string ?? id,
                  isDefault: value["isDefault"].bool == true,
                  defaultEffort: value["defaultReasoningEffort"].string ?? "",
                  efforts: value["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string })
    }
}
extension AgentHistoryTurn {
    init(_ turn: JSONValue) {
        let complete: Bool
        if case .array(let entries) = turn["items"] {
            complete = turn["id"].string != nil && ["completed", "failed", "interrupted"].contains(turn["status"].string ?? "") && entries.allSatisfy { entry in
                guard entry["id"].string != nil else { return false }
                if entry["type"].string == "agentMessage" { return entry["text"].string != nil }
                if entry["type"].string == "userMessage", case .array(let content) = entry["content"] {
                    return content.allSatisfy { $0["type"].string == "text" && $0["text"].string != nil }
                }
                // Tool details, attachments and unknown native items are not fully represented.
                return false
            }
        } else { complete = false }
        self.init(id: turn["id"].string, items: turn["items"].array.compactMap(CodexDecoding.transcriptItem),
                  startedAt: turn["startedAt"].int.map { Date(timeIntervalSince1970: Double($0)) },
                  completedAt: turn["completedAt"].int.map { Date(timeIntervalSince1970: Double($0)) },
                  duration: turn["durationMs"].int.flatMap { $0 >= 0 ? Double($0) / 1_000 : nil }, isComplete: complete)
    }
}

public typealias CodexAccount = AgentAccountInfo
public typealias CodexModel = AgentModelInfo
public typealias CodexHistoryTurn = AgentHistoryTurn
