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
    private var diagnosticScopes: [AgentSessionReference: (project: String, shell: AgentPermissionProfile.Shell, route: RequestRoute, scheduled: Bool, browser: AgentPermissionProfile.Browser, userChromeGrant: AgentUserChromeGrant?)] = [:]
    private var diagnosticsResources: URL?
    private var browserResources: URL?
    private var userChromeEnabled = false
    private var launch: (executable: URL, home: URL, arguments: [String])?
    private var workflowDirectories: [URL] = []
    private var browserRoot = BrowserConfiguration.directory
    var interactions: [UUID: (pending: CodexPendingInteraction, generation: UUID, token: UUID)] = [:]
    var compactions = CodexCompactionMeter()
    var reasoning = CodexReasoningStream()
    var subagentTracker = CodexSubagentTracker()
    var subagentHistoryTasks: [String: Task<Void, Never>] = [:]

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
                      diagnosticsResources: URL? = nil, browserResources: URL? = nil, browserRoot: URL = BrowserConfiguration.directory,
                      userChromeEnabled: Bool = false) async throws {
        self.launch = (executable, home, extraArguments)
        diagnosticScopes.removeAll()
        self.diagnosticsResources = diagnosticsResources
        self.browserResources = browserResources
        self.browserRoot = browserRoot
        self.userChromeEnabled = userChromeEnabled
        observeEvents()
        try await transport.start(executable: executable, home: home, extraArguments: extraArguments)
    }
    /// A cold worker applies thread MCP overrides without changing other chats or the account epoch.
    func isolatedSibling() async throws -> CodexClient {
        guard let launch else { throw ClientFailure(L10n.text("Codex не подключён", "Codex is not connected")) }
        let worker = CodexClient(transport: await transport.sibling(preservingAccountRevision: true))
        try await worker.start(executable: launch.executable, home: launch.home, extraArguments: launch.arguments,
                               diagnosticsResources: diagnosticsResources, browserResources: browserResources,
                               browserRoot: browserRoot, userChromeEnabled: userChromeEnabled)
        let expectedAgent = await transport.serverUserAgent
        guard await worker.transport.serverUserAgent == expectedAgent else {
            await worker.stop()
            throw ClientFailure(L10n.text("Версия Codex изменилась. Подключи движок заново.", "The Codex version changed. Reconnect the engine."))
        }
        do {
            if !workflowDirectories.isEmpty { try await worker.registerWorkflows(at: workflowDirectories) }
        } catch { await worker.stop(); throw error }
        return worker
    }
    public func stop() async { resetInteractions(); await transport.stop() }
    deinit { for task in subagentHistoryTasks.values { task.cancel() }; eventTask?.cancel(); eventSink.finish() }

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
        workflowDirectories = directories
    }

    public func createSession(projectPath: String, permissions: AgentPermissionProfile, model: String, route: RequestRoute,
                              browserProfile: AgentBrowserProfile? = nil, scheduled: Bool = false, userChromeGrant: AgentUserChromeGrant? = nil) async throws -> AgentSessionReference {
        var params = permissions.codexThreadParameters
        let profiles = BrowserProfileStore(root: browserRoot)
        guard browserProfile == nil || browserResources != nil else { throw BrowserProfileError.scope }
        let grant = browserResources == nil ? nil : try profiles.prepareNew(project: projectPath, connection: .originalCodex, selection: browserProfile) { environment in
            try BrowserProfileControl.verifyClosed(environment: environment, runtime: browserResources!.appendingPathComponent("BrowserRuntime"))
        }
        params["config"] = permissions.codexThreadConfiguration(browser: try BrowserConfiguration.threadConfiguration(resources: browserResources, root: browserRoot, environment: grant?.environment, grant: grant,
                                                                                                                     policy: BrowserLaunchPolicy(permissions, scheduled: scheduled)))
        params["config"] = diagnosticsConfiguration(params["config"] ?? .object([:]), project: projectPath, permissions: permissions)
        params["config"] = try userChromeConfiguration(params["config"] ?? .object([:]), permissions: permissions, scheduled: scheduled, grant: userChromeGrant)
        params["cwd"] = .string(projectPath)
        params["modelProvider"] = .string(route.providerID)
        params["developerInstructions"] = .string(AgentAutonomy.instructions() + (UserChromeConfiguration.allowed(enabled: userChromeEnabled, permissions: permissions, scheduled: scheduled, grant: userChromeGrant) ? "\n" + UserChromeConfiguration.instructions : ""))
        if !model.isEmpty { params["model"] = .string(model) }
        let result = try await transport.request("thread/start", params: .object(params))
        guard let id = result["thread"]["id"].string, !id.isEmpty else {
            throw ClientFailure(L10n.text("Не получен ID разговора", "No conversation ID received"))
        }
        let session = AgentSessionReference(connection: .originalCodex, nativeID: id)
        try await verifyUserChromeDiscovery(session: session, permissions: permissions, scheduled: scheduled, grant: userChromeGrant)
        if let grant { try profiles.acknowledge(grant, session: session) }
        diagnosticScopes[session] = (projectPath, permissions.shell, route, scheduled, permissions.effective.browser, userChromeGrant)
        knownSessions.insert(session)
        return session
    }
    public func resume(_ session: AgentSessionReference, projectPath: String, permissions: AgentPermissionProfile, route: RequestRoute,
                       scheduled: Bool = false, userChromeGrant: AgentUserChromeGrant? = nil) async throws {
        var params = permissions.codexThreadParameters
        let id = try nativeID(session)
        let profiles = BrowserProfileStore(root: browserRoot)
        let grant = browserResources == nil ? nil : try profiles.prepare(session: session, project: projectPath)
        params["config"] = permissions.codexThreadConfiguration(browser: try BrowserConfiguration.threadConfiguration(resources: browserResources, root: browserRoot, environment: grant?.environment, grant: grant,
                                                                                                                     policy: BrowserLaunchPolicy(permissions, scheduled: scheduled)))
        params["threadId"] = .string(id)
        params["config"] = diagnosticsConfiguration(params["config"] ?? .object([:]), project: projectPath, permissions: permissions)
        params["config"] = try userChromeConfiguration(params["config"] ?? .object([:]), permissions: permissions, scheduled: scheduled, grant: userChromeGrant)
        params["cwd"] = .string(projectPath)
        params["modelProvider"] = .string(route.providerID)
        params["developerInstructions"] = .string(AgentAutonomy.instructions() + (UserChromeConfiguration.allowed(enabled: userChromeEnabled, permissions: permissions, scheduled: scheduled, grant: userChromeGrant) ? "\n" + UserChromeConfiguration.instructions : ""))
        _ = try await transport.request("thread/resume", params: .object(params))
        try await verifyUserChromeDiscovery(session: session, permissions: permissions, scheduled: scheduled, grant: userChromeGrant)
        if let grant { try profiles.acknowledge(grant, session: session) }
        diagnosticScopes[session] = (projectPath, permissions.shell, route, scheduled, permissions.effective.browser, userChromeGrant)
    }
    /// Unloads an idle thread from this process so another app-server can take its writer lock.
    /// Does not touch the rollout; a later `resume` in any process loads it again.
    func release(_ session: AgentSessionReference) async throws {
        let id = try nativeID(session)
        let status = try await transport.request("thread/unsubscribe", params: .object(["threadId": .string(id)]))["status"].string
        diagnosticScopes[session] = nil
        guard status == "unsubscribed" else { return }
        for _ in 0..<50 {
            let loaded = try await transport.request("thread/loaded/list", params: .object([:]))["data"].array
            if !loaded.contains(.string(id)) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClientFailure(L10n.text("Codex не освободил чат: в нём ещё идёт ход. Отправь сообщение после его завершения.",
                                     "Codex did not release the chat: a turn is still running. Send the message after it finishes."))
    }
    private func userChromeConfiguration(_ base: JSONValue, permissions: AgentPermissionProfile, scheduled: Bool, grant: AgentUserChromeGrant?) throws -> JSONValue {
        var config = base.object
        config.merge(try UserChromeConfiguration.configuration(enabled: userChromeEnabled, permissions: permissions,
                                                               scheduled: scheduled, resources: diagnosticsResources, grant: grant).object) { _, new in new }
        return .object(config)
    }
    /// A launch payload is not proof that Codex discovered the server. Fail before a model turn if missing.
    private func verifyUserChromeDiscovery(session: AgentSessionReference, permissions: AgentPermissionProfile,
                                           scheduled: Bool, grant: AgentUserChromeGrant?) async throws {
        guard UserChromeConfiguration.allowed(enabled: userChromeEnabled, permissions: permissions, scheduled: scheduled, grant: grant) else { return }
        var cursor: JSONValue = .null
        for _ in 0..<20 {
            var params: [String: JSONValue] = ["threadId": .string(session.nativeID), "detail": .string("toolsAndAuthOnly")]
            if cursor != .null { params["cursor"] = cursor }
            let response = try await transport.request("mcpServerStatus/list", params: .object(params), timeout: 45)
            if let server = response["data"].array.first(where: { $0["name"].string == UserChromeConfiguration.server }),
               !server["tools"].object.isEmpty, server["toolsError"].string == nil { return }
            let next = response["nextCursor"]
            guard next != .null, next != cursor else { break }
            cursor = next
        }
        throw ClientFailure(L10n.text("Codex не обнаружил инструменты «Мой Chrome». Проверь подключение расширения в настройках браузера.",
                                     "Codex did not discover My Chrome tools. Check the extension connection in browser settings."))
    }
    private func diagnosticsConfiguration(_ base: JSONValue, project: String, permissions: AgentPermissionProfile) -> JSONValue {
        var config = base.object
        let script = diagnosticsResources?.appendingPathComponent("ChatDirectoryRuntime/server.py")
        let enabled = permissions.shell != .off && script.map { FileManager.default.fileExists(atPath: $0.path) } == true
        config["mcp_servers.switchboard_diagnostics"] = .object([
            "command": .string(enabled ? "/usr/bin/python3" : "/usr/bin/false"),
            "args": .array(enabled ? ["-I", script!.path, "--diagnostics-project", project, "--language", L10n.language.rawValue].map(JSONValue.string) : []),
            "enabled": .bool(enabled), "required": .bool(false), "tool_timeout_sec": .number(15)
        ])
        return .object(config)
    }
    /// Acknowledges submission only. Never retries after any transport failure.
    public func send(_ text: String, to session: AgentSessionReference, projectPath: String,
                     permissions: AgentPermissionProfile, model: String, effort: String, userChromeGrant: AgentUserChromeGrant? = nil) async throws -> String? {
        if diagnosticsResources != nil || userChromeEnabled {
            guard let scope = diagnosticScopes[session] else {
                throw ClientFailure(L10n.text("Сначала возобнови чат для обновления диагностики.", "Resume this chat before updating diagnostics."))
            }
            if scope.project != projectPath || scope.shell != permissions.shell || scope.browser != permissions.effective.browser || scope.userChromeGrant != userChromeGrant {
                try await resume(session, projectPath: projectPath, permissions: permissions, route: scope.route, scheduled: scope.scheduled, userChromeGrant: userChromeGrant)
            }
        }
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
    /// Stops only children observed under this parent on this exact connection. No uncertain retries.
    public func stopSubagents(_ task: String?, session: AgentSessionReference) async throws {
        let parent = try nativeID(session)
        let running = subagentTracker.runningIDs(parent: parent)
        if let task, !running.contains(task) {
            throw ClientFailure(L10n.text("Этот подагент больше не работает в данном чате.", "This sub-agent is no longer running in this chat."))
        }
        for child in running where task == nil || task == child {
            let result = try await transport.request("thread/read", params: .object([
                "threadId": .string(child), "includeTurns": .bool(true)
            ]))
            let turn = try CodexSubagentTracker.interruptTarget(result, child: child)
            guard let turn else {
                for event in subagentTracker.history(result, child: child) { eventSink.yield(event) }
                if subagentTracker.runningIDs(parent: parent).contains(child) {
                    throw ClientFailure(L10n.text("У подагента пока нет активного хода для остановки.", "The sub-agent has no active turn to stop yet."))
                }
                continue
            }
            do {
                _ = try await transport.request("turn/interrupt", params: .object([
                    "threadId": .string(child), "turnId": .string(turn)
                ]))
            }
            if let event = subagentTracker.stopped(child, parent: parent) { eventSink.yield(event) }
        }
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
        self.init(id: turn["id"].string, items: turn["items"].array.flatMap(CodexDecoding.transcriptItems),
                  startedAt: turn["startedAt"].int.map { Date(timeIntervalSince1970: Double($0)) },
                  completedAt: turn["completedAt"].int.map { Date(timeIntervalSince1970: Double($0)) },
                  duration: turn["durationMs"].int.flatMap { $0 >= 0 ? Double($0) / 1_000 : nil }, isComplete: complete)
    }
}

public typealias CodexAccount = AgentAccountInfo
public typealias CodexModel = AgentModelInfo
public typealias CodexHistoryTurn = AgentHistoryTurn
