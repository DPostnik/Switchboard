import Foundation
import AgentContract
import ContextCore

/// A generic Agent Client Protocol v1 client behind the common contract; Gemini CLI (`GeminiProfile`) is the first agent.
///
/// Process model: one agent process per connection serves every chat of that connection (ACP sessions are multiplexed
/// over one stdio stream by `sessionId`). Losing the process ends its running turns as uncertain and reports
/// `.disconnected`; the app reconnects, and a chat continues in the new process through `session/resume` or
/// `session/load`, only when the agent advertises them.
/// History: the app keeps its own record per session (`ACPSessionStore`) in the agent's app home, because v1 agents need
/// not list or replay sessions. Turn content outside a running turn (for example a `session/load` replay) is not surfaced;
/// session state is: commands (`AgentCommand`) and config options (`AgentConfigOption`, also from the older `models` list
/// Gemini CLI 0.66.0 reports, changed through `session/set_model`) whenever the agent reports them, repeated when a turn starts.
/// Permissions: role profiles whose prompts the app can answer (`ask`, or `blocked`, which refuses every prompt) and the
/// external policy with prompts denied. The agent applies its own rules first; the app never selects `allow_always` or
/// `reject_always`, which would persist decisions inside the agent beyond the role.
/// Never retries a request after uncertain delivery and never answers a request it does not recognize except with -32601.
public actor ACPIntegration: AgentIntegration {
    public nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation
    private let profile: ACPLaunchProfile
    private let drift: CompatibilityDrift
    private let clientInfo: ACPImplementation
    private var transport: ACPConnection?
    private var reader: Task<Void, Never>?
    private var context: AgentContext
    private var home: URL?
    private var engine: AgentEngineVersion?
    private var capabilities = ACPAgentCapabilities()
    private var authMethods: [ACPAuthMethod] = []
    private var authenticated = false
    private var records: [String: ACPSessionRecord] = [:]
    /// Sessions attached to the running process (created, resumed or loaded in it).
    private var live = Set<String>()
    private var turns: [String: ACPTurn] = [:]
    private var handles: [String: AgentExecutionHandle] = [:]
    private var busy = Set<String>()
    private var consumed = Set<UUID>()
    /// Sessions whose `session/load` history replay is still arriving; their updates are dropped.
    private var replaying: [String: Date] = [:]
    private var lastUpdate: [String: Date] = [:]
    /// The commands each session last offered (`available_commands_update`); repeated when a turn starts, because the
    /// first list arrives right after `session/new`, before the app knows the chat.
    private var commands: [String: [AgentCommand]] = [:]
    private struct Permission {
        let request: JSONValue
        let session: String
        let turn: String
        let options: [ACPPermissionOption]
        let tool: ACPTurn.ACPToolState?
        let call: String
    }
    private var permissions: [UUID: Permission] = [:]
    /// The role of each session's running turn, for prompts the role refuses without asking.
    private var sessionProfiles: [String: AgentPermissionProfile] = [:]
    private var finishedTurns = Set<String>()
    /// Running `session/prompt` requests by JSON-RPC id: session and turn. Their responses arrive in stream order.
    private var prompts: [JSONValue: (session: String, turn: String)] = [:]
    /// A prompt response processed while `submit` was still between dispatch and registering it (actor reentrancy).
    private var unclaimed: [JSONValue: Result<JSONValue, ACPTransportError>] = [:]
    /// Known updates and requests that the current contract cannot carry yet, by `update:<kind>` or `request:<method>`.
    private(set) var unsurfaced: [String: Int] = [:]

    public init(profile: ACPLaunchProfile, drift: CompatibilityDrift = .shared, clientVersion: String? = nil) {
        self.profile = profile; self.drift = drift
        let version = clientVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        clientInfo = ACPImplementation(name: "switchboard", title: "Switchboard", version: version)
        context = AgentContext(connection: profile.connection, accountRevision: UUID())
        let pair = AsyncStream<AgentEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    deinit { reader?.cancel(); sink.finish() }

    // MARK: connection

    public func optimizerEnvironment(home: URL) -> AgentResult<[String: String]> { .rejected(.routeUnavailable) }
    public func observe(sessions: [AgentSessionReference]) {}

    public func connect(_ configuration: AgentConnectionConfiguration) async -> AgentResult<AgentDescriptor> {
        guard configuration.optimizers.isEmpty else { return .rejected(.routeUnavailable) }
        await disconnect()
        let home = configuration.home
        let connection = ACPConnection()
        do {
            try profile.prepareHome(home)
            let executable = try configuration.executable ?? profile.executable(home: home)
            let environment = profile.environment(home, executable, ProcessInfo.processInfo.environment)
            try await connection.start(executable: executable, arguments: profile.arguments, environment: environment, directory: home)
        } catch { await connection.stop(); return .failed(.init(delivery: .notSent, diagnostic: error.localizedDescription)) }
        transport = connection
        reader = Task { [weak self] in
            for await event in connection.events { await self?.receive(event, from: connection) }
        }
        let response: ACPInitializeResponse
        do {
            let request = ACPInitializeRequest(protocolVersion: ACPProtocolSurface.protocolVersion, clientCapabilities: .honest, clientInfo: clientInfo)
            let raw = try await connection.request("initialize", params: ACPCodec.encode(request), timeout: profile.startupTimeout, closeOnTimeout: true)
            if raw["agentInfo"]["version"].string == nil { drift.record(profile.agent, version: nil, .missingField, "initialize:agentInfo.version") }
            response = try ACPCodec.decode(ACPInitializeResponse.self, from: raw)
        } catch {
            let startup = await connection.startupError
            await stop(connection)
            let detail = [error.localizedDescription, startup].compactMap { $0 }.joined(separator: ": ")
            return .failed(.init(delivery: .notSent, diagnostic: detail))
        }
        // Version negotiation: a different protocol version, or a build outside the version policy, is never used.
        guard transport === connection, response.protocolVersion == ACPProtocolSurface.protocolVersion,
              let version = response.agentInfo?.version, let engine = Self.engine(version, verified: profile.verifiedVersions) else {
            await stop(connection); return .rejected(.incompatibleContract)
        }
        if !engine.verified { drift.noteUnverified(profile.agent, version: engine.version) }
        self.home = home; self.engine = engine
        capabilities = response.agentCapabilities; authMethods = response.authMethods
        authenticated = ACPAccountState.load(home: home)?.authenticated ?? false
        context = AgentContext(connection: profile.connection, accountRevision: UUID())
        let result = descriptor()
        if case .success(let value) = result { sink.yield(.init(session: nil, payload: .descriptor(value))) }
        return result
    }

    static func engine(_ version: String, verified: [String]) -> AgentEngineVersion? {
        switch AgentVersionPolicy.evaluate(version, verified: verified) {
        case .verified: AgentEngineVersion(version: version, verified: true)
        case .sameMinor(let nearest): AgentEngineVersion(version: version, verified: false, nearestVerified: nearest)
        case .rejected: nil
        }
    }

    public func descriptor() -> AgentResult<AgentDescriptor> {
        guard transport != nil, home != nil, let engine else { return .unavailable }
        var capabilities: Set<AgentCapability> = [.interactiveSessions, .history, .archive, .streaming, .approvals, .interruption, .usage]
        if signInMethod() != nil || self.capabilities.auth.logout != nil { capabilities.insert(.authenticationManagement) }
        return .success(AgentDescriptor(context: context, identityMode: .appOwnedHome, capabilities: capabilities,
                                        permissions: .acpPromptPolicy, routes: [.direct], engine: engine))
    }

    public func disconnect() async {
        if let transport { await stop(transport) }
        reader?.cancel(); reader = nil
        home = nil; engine = nil; capabilities = ACPAgentCapabilities(); authMethods = []; authenticated = false
        records.removeAll(); replaying.removeAll(); lastUpdate.removeAll(); sessionProfiles.removeAll(); commands.removeAll()
        context = AgentContext(connection: profile.connection, accountRevision: UUID())
    }

    /// Stops a process and settles everything that depended on it (once; later events of that process are ignored).
    private func stop(_ connection: ACPConnection) async {
        guard transport === connection else { await connection.stop(); return }
        transport = nil
        await connection.stop()
        lost(reason: nil)
    }

    private func lost(reason: String?) {
        let error = reason ?? L10n.text("Процесс агента завершился. Проверь историю перед новой отправкой; повторов не было.",
                                        "The agent process ended. Review history before sending again; nothing was retried.")
        prompts.removeAll(); unclaimed.removeAll()
        for id in Array(turns.keys) { finish(id, outcome: .uncertain, error: error) }
        for id in Array(permissions.keys) { permissions[id] = nil; sink.yield(.init(session: nil, payload: .resolved(id))) }
        live.removeAll(); busy.removeAll()
    }

    // MARK: inbound

    private func receive(_ event: ACPConnection.Event, from connection: ACPConnection) async {
        guard transport === connection else { return }
        switch event {
        case .closed(_, let reason):
            transport = nil
            lost(reason: reason)
            sink.yield(.init(session: nil, payload: .disconnected))
        case .malformed(let name):
            drift.record(profile.agent, version: engine?.version, .frameType, name)
        case .response(let id, let result):
            guard let prompt = prompts.removeValue(forKey: id) else { unclaimed[id] = result; return }
            completed(prompt.session, turn: prompt.turn, result: result.mapError { $0 as any Error })
        case .message(let message):
            ACPProtocolSurface.record(message, agent: profile.agent, version: engine?.version, into: drift)
            let method = message["method"].string ?? ""
            if message["id"] != .null { await request(message, method: method, connection: connection) }
            else { notification(message["params"], method: method) }
        }
    }

    private func request(_ message: JSONValue, method: String, connection: ACPConnection) async {
        let id = message["id"]
        switch method {
        case "session/request_permission": await permission(id: id, params: message["params"], connection: connection)
        default:
            // Unknown methods are drift (recorded above); known ones are capabilities this client does not advertise.
            if ACPProtocolSurface.clientMethods.contains(method) { count("request:" + method) }
            try? await connection.respondError(id: id, code: -32601, message: "Method not found")
        }
    }

    private func notification(_ params: JSONValue, method: String) {
        switch method {
        case "session/update": update(params)
        case "$/cancel_request":
            // The agent withdrew one of its own requests: a permission prompt the user has not answered yet.
            let request = params["requestId"]
            for (token, value) in permissions where value.request == request {
                permissions[token] = nil; sink.yield(.init(session: reference(value.session), payload: .resolved(token)))
                mark(value.call, nil, session: value.session)
            }
        default: if ACPProtocolSurface.clientMethods.contains(method) { count("notification:" + method) }
        }
    }

    private func update(_ params: JSONValue) {
        guard let session = params["sessionId"].string else { return }
        let update = params["update"], kind = update["sessionUpdate"].string ?? ""
        guard ACPProtocolSurface.sessionUpdates.contains(kind) else { return } // Drift, counted by name above.
        let now = Date()
        lastUpdate[session] = now
        // Session state, current even during a history replay and outside turns. The title has no place in the contract
        // (the app names its chats), so it stays in the record.
        switch kind {
        case "config_option_update":
            if let options = ACPConfigOption.list(update["configOptions"]) { setOptions(options, session: session); return }
        case "available_commands_update":
            let list = ACPCommand.list(update["availableCommands"])
            commands[session] = list
            sink.yield(.init(session: reference(session), payload: .commands(list)))
            return
        case "session_info_update":
            if let title = update["title"].string { records[session]?.title = title }
        default: break
        }
        guard replaying[session] == nil, var turn = turns[session] else { count("update:" + kind + (replaying[session] == nil ? ":idle" : ":replay")); return }
        guard let payloads = turn.apply(kind, update, at: now) else { turns[session] = turn; count("update:" + kind); return }
        turns[session] = turn
        for payload in payloads { sink.yield(.init(session: reference(session), payload: payload)) }
    }

    private func permission(id: JSONValue, params: JSONValue, connection: ACPConnection) async {
        guard let request = try? ACPCodec.decode(ACPPermissionRequest.self, from: params), var turn = turns[request.sessionId], !turn.cancelRequested else {
            // Outside a running turn nothing can be approved.
            try? await connection.respond(id: id, result: ACPPermissionOutcome.cancelled)
            return
        }
        let session = request.sessionId, call = request.toolCall.toolCallId
        for payload in turn.observe(permission: request.toolCall) { sink.yield(.init(session: reference(session), payload: payload)) }
        let tool = turn.tool(call)
        let state = tool ?? ACPTurn.ACPToolState(title: request.toolCall.title ?? call, started: Date())
        if Self.refusal(state, turn: turn, profile: sessionProfiles[session]) != nil {
            turns[session] = turn
            mark(call, .rejected, session: session)
            record(ACPTurn.capability(state, cwd: turn.cwd, decision: .denied, turn: turn.id), session: session)
            try? await connection.respond(id: id, result: Self.reject(request.options))
            return
        }
        turns[session] = turn
        mark(call, .awaitingApproval, session: session)
        let token = UUID()
        permissions[token] = Permission(request: id, session: session, turn: turn.id, options: request.options, tool: tool, call: call)
        record(ACPTurn.capability(state, cwd: turn.cwd, decision: .asked, turn: turn.id), session: session)
        let canAllow = request.options.contains { $0.kind == "allow_once" }
        sink.yield(.init(session: reference(session), payload: .interaction(.init(
            id: token, session: reference(session), turn: turn.id, kind: .approval(canAllow: canAllow),
            reason: state.title, details: ACPTurn.callText(state), canAllowTurn: false))))
    }

    /// Why the turn's role refuses a prompt without asking, or nil to ask the user.
    static func refusal(_ state: ACPTurn.ACPToolState, turn: ACPTurn, profile: AgentPermissionProfile?) -> String? {
        guard turn.attended else { return "unattended" }
        guard let profile else { return nil }
        switch state.kind {
        case "edit", "delete", "move":
            if profile.filesystem == .readOnly { return "read-only" }
            if case .project = profile.filesystem, !state.locations.allSatisfy({ location in
                ACPTurn.isInside(location.path, turn.cwd) || profile.extraRoots.contains { $0.writable && ACPTurn.isInside(location.path, $0.path) }
            }) { return "outside" }
        case "execute": if profile.shell == .off { return "shell" }
        case "fetch": if !profile.network { return "network" }
        default: break
        }
        return nil
    }

    static func reject(_ options: [ACPPermissionOption]) -> JSONValue {
        options.first { $0.kind == "reject_once" }.map { ACPPermissionOutcome.selected($0.optionId) } ?? ACPPermissionOutcome.cancelled
    }

    /// Shows the app's state of a call of the session's running turn (nil returns to the agent's own status).
    private func mark(_ call: String, _ status: AgentToolCall.Status?, session: String) {
        guard var turn = turns[session] else { return }
        let payloads = turn.mark(call, status)
        turns[session] = turn
        for payload in payloads { sink.yield(.init(session: reference(session), payload: payload)) }
    }

    /// New settings of a session: kept in its record and in the connection's model cache, and reported to the app.
    private func setOptions(_ options: [ACPConfigOption], session: String) {
        records[session]?.configOptions = options
        if let home { ACPOptionCache(options: options.filter { ["model", "thought_level"].contains($0.category) }).save(home: home) }
        sink.yield(.init(session: reference(session), payload: .configOptions(options.compactMap(\.contract))))
    }

    private func record(_ value: AgentCapabilityRecord, session: String) {
        sink.yield(.init(session: reference(session), payload: .capability(value)))
    }

    private func count(_ key: String) { unsurfaced[key, default: 0] += 1 }

    // MARK: account

    private func signInMethod() -> ACPAuthMethod? {
        let agentMethods = authMethods.filter(\.isAgentFlow)
        if let preferred = profile.signInMethod, let method = agentMethods.first(where: { $0.id == preferred }) { return method }
        return agentMethods.count == 1 ? agentMethods[0] : nil
    }

    public func account() -> AgentResult<AgentAccountInfo> {
        guard transport != nil, home != nil else { return .unavailable }
        return .success(.init(authenticated: authenticated, plan: nil, canSignOut: capabilities.auth.logout != nil))
    }

    /// Records the sign-in state. An explicit sign-in or a lost sign-in starts a new account revision; a session that simply
    /// works (the CLI found its stored credentials) only updates the remembered state.
    private func setAuthenticated(_ value: Bool, error: String? = nil, rotate: Bool = true) {
        let changed = value != authenticated
        authenticated = value
        if let home { try? ACPAccountState(authenticated: value).save(home: home) }
        guard rotate, changed || value else { return }
        context = AgentContext(connection: profile.connection, accountRevision: UUID())
        sink.yield(.init(session: nil, payload: .accountChanged(error: error)))
        if case .success(let value) = descriptor() { sink.yield(.init(session: nil, payload: .descriptor(value))) }
    }

    /// The agent answered auth-required (-32000): shown to the user instead of the agent's own text.
    private var signInRequired: String {
        L10n.text("\(profile.productName) просит войти. Войди в Настройки → Аккаунты; запрос не отправлен повторно.",
                  "\(profile.productName) asks you to sign in. Sign in under Settings → Accounts; nothing was sent again.")
    }

    public func authenticate(_ action: AgentAuthenticationAction) async -> AgentResult<AgentAuthenticationStep> {
        guard let transport, turns.isEmpty, busy.isEmpty else { return .unavailable }
        switch action {
        case .beginSignIn:
            // Terminal-type methods need the client to run the agent in a terminal; not supported yet.
            guard let method = signInMethod() else { return .rejected(.unsupported(.authenticationManagement)) }
            do {
                _ = try await transport.request("authenticate", params: .object(["methodId": .string(method.id)]), timeout: profile.signInTimeout)
                setAuthenticated(true)
                return .success(.complete)
            } catch { return failure(error) }
        case .signOut:
            guard capabilities.auth.logout != nil else { return .rejected(.unsupported(.authenticationManagement)) }
            do {
                _ = try await transport.request("logout", params: .object([:]), timeout: profile.sessionTimeout)
                live.removeAll()
                setAuthenticated(false)
                return .success(.complete)
            } catch { return failure(error) }
        }
    }

    public func models() -> AgentResult<[AgentModelInfo]> {
        // Models are a per-session config option in ACP; a loaded session that reported one stands for the connection.
        // Without one, the options the last session reported (cached in the home) stand for it until a session reports them.
        let cached = home.flatMap(ACPOptionCache.load)?.options ?? []
        let sources = records.values.compactMap(\.configOptions) + [cached]
        guard let option = sources.lazy.compactMap({ $0.first { $0.category == "model" && $0.type == "select" } }).first else {
            return .rejected(.unsupported(.modelDiscovery))
        }
        let efforts = sources.lazy.compactMap { $0.first { $0.category == "thought_level" && $0.type == "select" } }.first
        return .success(option.options.map {
            AgentModelInfo(id: $0.value, displayName: $0.name, isDefault: option.currentValue.string == $0.value,
                           defaultEffort: efforts?.currentValue.string ?? "", efforts: efforts?.options.map(\.value) ?? [])
        })
    }

    public func limits() -> AgentResult<AccountLimits> { .rejected(.unsupported(.accountLimits)) }
    public func configure(_ tools: AgentToolConfiguration, context: AgentContext) -> AgentResult<Void> { .rejected(.unsupported(.toolRegistration)) }

    // MARK: execution

    private func validate(_ request: AgentExecutionRequest) -> AgentRejection? {
        guard case .success(let descriptor) = descriptor() else { return .staleContext }
        if let rejection = descriptor.validate(request) { return rejection }
        // Prompts can be answered or refused, never approved silently: a role without prompts would need auto-approval.
        if let profile = request.permissions.profile?.effective, profile.approvals == .never { return .unsupportedPermissions }
        return nil
    }

    private func attended(_ intent: AgentPermissionIntent) -> Bool {
        if case .profile(let profile, _) = intent { return profile.effective.approvals == .ask }
        return false
    }

    public func prepare(_ request: AgentExecutionRequest) async -> AgentResult<AgentSessionReference> {
        if let rejection = validate(request) { return .rejected(rejection) }
        guard let transport, let home else { return .unavailable }
        if let session = request.session {
            do {
                let record = try load(session.nativeID)
                guard record.cwd == request.projectPath else { return .rejected(.invalidInput) }
                return .success(session)
            } catch { return .failed(.init(delivery: .notSent, diagnostic: error.localizedDescription)) }
        }
        let epoch = context
        do {
            let raw = try await transport.request("session/new", params: ACPCodec.encode(ACPSessionRequest(cwd: request.projectPath)),
                                                  timeout: profile.sessionTimeout)
            let response = try ACPCodec.decode(ACPNewSessionResponse.self, from: raw)
            guard self.transport === transport, context == epoch else { return .rejected(.staleContext) }
            let record = ACPSessionRecord(id: response.sessionId, cwd: request.projectPath)
            records[record.id] = record
            if let options = ACPConfigOption.session(raw) { setOptions(options, session: record.id) }
            try ACPSessionStore(home: home).save(records[record.id] ?? record)
            live.insert(record.id)
            if !authenticated { setAuthenticated(true, rotate: false) }
            return .success(reference(record.id))
        } catch let error as ACPTransportError {
            if case .remote(-32000, _) = error { setAuthenticated(false, error: signInRequired) }
            return failure(error)
        } catch { return failure(error) }
    }

    public func submit(_ request: AgentExecutionRequest) async -> AgentResult<AgentExecutionHandle> {
        if let rejection = validate(request) { return .rejected(rejection) }
        guard consumed.insert(request.id).inserted else { return .rejected(.unknownRequest) }
        let session: AgentSessionReference
        if let existing = request.session { session = existing } else {
            switch await prepare(request) {
            case .success(let value): session = value
            case .rejected(let reason): return .rejected(reason)
            case .unavailable: return .unavailable
            case .failed(let failure): return .failed(failure)
            }
        }
        let id = session.nativeID
        guard session.connection == profile.connection, turns[id] == nil, busy.insert(id).inserted else { return .rejected(.invalidInput) }
        defer { busy.remove(id) }
        guard let transport, let home else { return .unavailable }
        let store = ACPSessionStore(home: home)
        var delivered = false
        do {
            var record = try load(id)
            guard record.cwd == request.projectPath else { return .rejected(.invalidInput) }
            if let stale = record.active {
                // A turn from an earlier process: its outcome is unknown and it is never resent.
                record.turns.append(AgentHistoryTurn(id: stale, items: record.current, startedAt: nil, completedAt: nil, duration: nil))
                record.active = nil; record.current = []
                records[id] = record; try store.save(record)
            }
            try await attach(id, cwd: record.cwd, transport: transport)
            try await configure(id, model: request.model, transport: transport)
            guard self.transport === transport, context == request.model.context, turns[id] == nil else { return .rejected(.staleContext) }
            let turn = request.id.uuidString
            let prompt = ACPTurn.userItem(turn: turn, text: request.prompt)
            record = records[id] ?? record
            record.active = turn; record.current = [prompt]
            records[id] = record
            try store.save(record) // Durable uncertain claim, including the prompt, before a byte of the turn is sent.
            if let profile = request.permissions.profile { sessionProfiles[id] = profile } else { sessionProfiles[id] = nil }
            turns[id] = ACPTurn(id: turn, cwd: record.cwd, prompt: prompt, attended: attended(request.permissions))
            let handle = AgentExecutionHandle(context: request.model.context, requestID: request.id, session: session, turnID: turn)
            handles[id] = handle
            sink.yield(.init(session: session, payload: .started(turn: turn)))
            sink.yield(.init(session: session, payload: .item(prompt)))
            // Session state reported before the app knew the chat (right after `session/new` or a load).
            if let list = commands[id] { sink.yield(.init(session: session, payload: .commands(list))) }
            if let options = records[id]?.configOptions { sink.yield(.init(session: session, payload: .configOptions(options.compactMap(\.contract)))) }
            delivered = true
            let params = try ACPCodec.encode(ACPPromptRequest(sessionId: id, prompt: [.text(request.prompt)]))
            // A turn has no deadline; a cancelled one that does not answer is closed by `cancel`. The response comes as an
            // ordered event, so every update the agent sent for the turn is applied before it completes.
            let requestID = try await transport.dispatch("session/prompt", params: params, timeout: nil, ordered: true)
            if let early = unclaimed.removeValue(forKey: requestID), transport === self.transport {
                completed(id, turn: turn, result: early.mapError { $0 as any Error })
            } else { prompts[requestID] = (id, turn) }
            return .success(handle)
        } catch {
            guard delivered else { return failure(error) }
            if turns[id] != nil {
                finish(id, outcome: .uncertain, error: L10n.text("Не удалось подтвердить отправку. Проверь историю; повторов не было.",
                                                                 "Delivery could not be confirmed. Review history; nothing was retried."))
            }
            return .failed(.init(delivery: .uncertain, diagnostic: error.localizedDescription))
        }
    }

    /// Makes a stored session usable in the running process. Never sends work; a failure leaves the session idle.
    private func attach(_ id: String, cwd: String, transport: ACPConnection) async throws {
        guard !live.contains(id) else { return }
        let params = try ACPCodec.encode(ACPSessionRequest(sessionId: id, cwd: cwd))
        if capabilities.sessionCapabilities.resume != nil {
            let raw = try await transport.request("session/resume", params: params, timeout: profile.sessionTimeout)
            if let options = ACPConfigOption.session(raw) { setOptions(options, session: id) }
        } else if capabilities.loadSession {
            // The agent replays the whole conversation as updates; the app already has it, so they are dropped until quiet.
            replaying[id] = Date()
            defer { replaying[id] = nil }
            let raw = try await transport.request("session/load", params: params, timeout: profile.sessionTimeout)
            if let options = ACPConfigOption.session(raw) { setOptions(options, session: id) }
            let settle = profile.replaySettle
            let seconds = Double(settle.components.seconds) + Double(settle.components.attoseconds) / 1e18
            for _ in 0..<50 {
                try await Task.sleep(for: settle)
                guard let last = lastUpdate[id], Date().timeIntervalSince(last) < seconds else { break }
            }
        } else {
            throw ClientFailure(L10n.text("\(profile.productName) не умеет продолжать сохранённые сессии. Начни новый чат.",
                                          "\(profile.productName) cannot continue saved sessions. Start a new chat."))
        }
        guard self.transport === transport else { throw ACPTransportError.closed }
        live.insert(id)
    }

    /// Selects the requested model and effort through the session's config options before the prompt. An empty model keeps
    /// the agent's default; a model the session does not offer is refused instead of silently ignored. An effort is applied
    /// only when the session has a thought-level option, and refused when that option does not offer it.
    private func configure(_ id: String, model: AgentModelSelection, transport: ACPConnection) async throws {
        for (category, value) in [("model", model.model), ("thought_level", model.effort ?? "")] where !value.isEmpty {
            let option = records[id]?.configOptions?.first(where: { $0.category == category && $0.type == "select" })
            if option == nil, category == "thought_level" { continue }
            guard let option, option.options.contains(where: { $0.value == value }) else { throw RejectedInput() }
            guard option.currentValue.string != value else { continue }
            if option.setModel == true {
                // The older session model API (Gemini CLI 0.66.0): the answer is empty, so the record follows the request.
                _ = try await transport.request("session/set_model", params: .object([
                    "sessionId": .string(id), "modelId": .string(value)]), timeout: profile.sessionTimeout)
                var changed = option; changed.currentValue = .string(value)
                setOptions((records[id]?.configOptions ?? []).map { $0.id == option.id ? changed : $0 }, session: id)
                continue
            }
            let raw = try await transport.request("session/set_config_option", params: .object([
                "sessionId": .string(id), "configId": .string(option.id), "value": .string(value)]), timeout: profile.sessionTimeout)
            if let options = ACPConfigOption.list(raw["configOptions"]) { setOptions(options, session: id) }
        }
    }
    private struct RejectedInput: Error {}

    private func completed(_ id: String, turn: String, result: Result<JSONValue, any Error>) {
        guard turns[id]?.id == turn else { return }
        switch result {
        case .success(let value):
            let reason = value["stopReason"].string ?? ""
            if !ACPStopReason.all.contains(reason) {
                drift.record(profile.agent, version: engine?.version, .missingField, "session/prompt:stopReason=" + reason)
            }
            let stop = ACPStopReason.contract(reason)
            switch reason {
            case ACPStopReason.endTurn: finish(id, outcome: .completed, error: nil, stopReason: stop)
            case ACPStopReason.cancelled: finish(id, outcome: .cancelled, error: nil, stopReason: stop)
            case ACPStopReason.refusal:
                finish(id, outcome: .failed, error: L10n.text("Агент отказался выполнять запрос.", "The agent refused the request."), stopReason: stop)
            case ACPStopReason.maxTokens:
                finish(id, outcome: .failed, error: L10n.text("Ответ остановлен: достигнут предел токенов.", "The response stopped at the token limit."), stopReason: stop)
            case ACPStopReason.maxTurnRequests:
                finish(id, outcome: .failed, error: L10n.text("Ход остановлен: достигнут предел запросов к модели.", "The turn stopped at the model request limit."),
                       stopReason: stop)
            default: finish(id, outcome: .failed, error: L10n.text("Неизвестная причина остановки хода.", "Unknown reason for the end of the turn."))
            }
        case .failure(let error as ACPTransportError):
            if case .remote(let code, let message) = error {
                if code == -32000 { setAuthenticated(false, error: signInRequired) }
                finish(id, outcome: .failed, error: code == -32000 ? signInRequired : message)
            } else {
                finish(id, outcome: .uncertain, error: error.localizedDescription)
            }
        case .failure(let error): finish(id, outcome: .uncertain, error: error.localizedDescription)
        }
    }

    private func finish(_ id: String, outcome: AgentExecutionOutcome, error: String?, stopReason: AgentStopReason? = nil) {
        guard var turn = turns.removeValue(forKey: id) else { return }
        handles[id] = nil; sessionProfiles[id] = nil; finishedTurns.insert(turn.id)
        let session = reference(id)
        for payload in turn.close(outcome: outcome) { sink.yield(.init(session: session, payload: payload)) }
        for (token, value) in permissions where value.session == id {
            permissions[token] = nil; sink.yield(.init(session: session, payload: .resolved(token)))
        }
        let now = Date()
        let history = AgentHistoryTurn(id: turn.id, items: turn.items, startedAt: turn.startedAt, completedAt: now,
                                       duration: now.timeIntervalSince(turn.startedAt), isComplete: outcome == .completed)
        if var record = records[id] {
            record.turns.append(history); record.active = nil; record.current = []
            records[id] = record
            if let home {
                do { try ACPSessionStore(home: home).save(record) }
                catch { sink.yield(.init(session: session, payload: .diagnostic(error.localizedDescription))) }
            }
        }
        sink.yield(.init(session: session, payload: .status(turn: turn.id, text: nil)))
        sink.yield(.init(session: session, payload: .completed(.init(id: turn.id, status: outcome, hasError: outcome != .completed && outcome != .cancelled,
                                                                    error: error, history: history, stopReason: stopReason))))
    }

    public func cancel(_ execution: AgentExecutionHandle) async -> AgentResult<AgentCancellation> {
        guard let session = execution.session, session.connection == profile.connection else { return .rejected(.unknownRequest) }
        let id = session.nativeID
        guard let turn = turns[id], turn.id == execution.turnID else {
            return execution.turnID.map(finishedTurns.contains) == true ? .success(.alreadyFinished) : .rejected(.unknownRequest)
        }
        guard handles[id] == execution else { return .rejected(.unknownRequest) }
        guard let transport else { return .success(.uncertain) }
        if turn.cancelRequested { return .success(.requested) }
        turns[id]?.cancelRequested = true
        // Pending prompts of the turn are answered `cancelled`, as the protocol requires.
        for (token, value) in permissions where value.session == id {
            permissions[token] = nil
            try? await transport.respond(id: value.request, result: ACPPermissionOutcome.cancelled)
            sink.yield(.init(session: session, payload: .resolved(token)))
        }
        do { try await transport.notify("session/cancel", params: .object(["sessionId": .string(id)])) }
        catch { return .success(.uncertain) }
        let grace = profile.cancelGrace, turnID = turn.id
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.cancelExpired(id, turn: turnID, transport: transport)
        }
        return .success(.requested)
    }

    /// The agent did not end a cancelled turn in time: its state is ambiguous, so the process is stopped.
    private func cancelExpired(_ id: String, turn: String, transport: ACPConnection) async {
        guard turns[id]?.id == turn, self.transport === transport else { return }
        await stop(transport)
        sink.yield(.init(session: nil, payload: .disconnected))
    }

    public func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void> {
        guard let pending = permissions[id], reference(pending.session) == session, context == self.context else { return .rejected(.unknownRequest) }
        guard let transport else { return .unavailable }
        let result: JSONValue, decision: AgentCapabilityRecord.Decision
        switch response {
        case .allowOnce:
            guard let option = pending.options.first(where: { $0.kind == "allow_once" }) else { return .rejected(.invalidResponse) }
            result = ACPPermissionOutcome.selected(option.optionId); decision = .allowed
        case .deny: result = Self.reject(pending.options); decision = .denied
        // ACP has no turn-scoped grant, and `allow_always` would outlive the role inside the agent.
        case .allowTurn, .answers, .completed: return .rejected(.invalidResponse)
        }
        permissions[id] = nil
        sink.yield(.init(session: session, payload: .resolved(id)))
        mark(pending.call, decision == .allowed ? .inProgress : .rejected, session: pending.session)
        if let tool = pending.tool, let cwd = records[pending.session]?.cwd {
            record(ACPTurn.capability(tool, cwd: cwd, decision: decision, turn: pending.turn), session: pending.session)
        }
        do { try await transport.respond(id: pending.request, result: result); return .success(()) }
        catch { return .failed(.init(delivery: .uncertain, diagnostic: error.localizedDescription)) }
    }

    public func rejectInteraction(_ id: UUID) async {
        guard let pending = permissions[id] else { return }
        _ = await answer(id, session: reference(pending.session), context: context, response: .deny)
    }

    // MARK: history

    private func reference(_ id: String) -> AgentSessionReference { .init(connection: profile.connection, nativeID: id) }

    private func load(_ id: String) throws -> ACPSessionRecord {
        if let record = records[id] { return record }
        guard let home else { throw ConversationIdentity.unavailable }
        let record = try ACPSessionStore(home: home).load(id)
        records[id] = record
        return record
    }

    private func checked(_ session: AgentSessionReference, context: AgentContext) -> Bool {
        session.connection == profile.connection && context == self.context && home != nil
    }

    public func history(_ session: AgentSessionReference, context: AgentContext) -> AgentResult<[AgentHistoryTurn]> {
        guard checked(session, context: context) else { return .rejected(.wrongConnection) }
        do {
            let record = try load(session.nativeID)
            let current = turns[session.nativeID]?.items ?? record.current
            return .success(record.turns + (record.active.map { [AgentHistoryTurn(id: $0, items: current, startedAt: nil, completedAt: nil, duration: nil)] } ?? []))
        } catch { return .failed(.init(delivery: .notSent, diagnostic: error.localizedDescription)) }
    }

    public func summarySource(_ session: AgentSessionReference, context: AgentContext) -> AgentResult<AgentSummarySource> {
        guard checked(session, context: context) else { return .rejected(.wrongConnection) }
        do {
            let record = try load(session.nativeID)
            guard record.active == nil, turns[session.nativeID] == nil else {
                throw ClientFailure(L10n.text("История содержит незавершённый запрос", "History contains an active turn"))
            }
            return .success(try Self.summarySource(turns: record.turns))
        } catch { return .failed(.init(delivery: .notSent, diagnostic: error.localizedDescription)) }
    }

    static func summarySource(turns: [AgentHistoryTurn]) throws -> AgentSummarySource {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        var fragments: [AgentSummaryFragment] = [], seen = Set<String>(), dates: [String: Double] = [:], omitted = false
        for (index, turn) in turns.enumerated() {
            let turnID = turn.id ?? "turn-\(index)"
            if let completed = turn.timing(fallback: nil)?.completedAt { dates[turnID] = completed.timeIntervalSince1970 }
            for item in turn.items where item.kind != ActivityDetail.thinkingKind {
                let kind = item.kind == "user" ? "userMessage" : item.kind == "assistant" ? "agentMessage" : "toolActivity"
                var text = item.text
                if kind == "toolActivity", text.count > 3000 { text = String(text.prefix(3000)); omitted = true }
                let characters = Array(text)
                for offset in stride(from: 0, to: max(1, characters.count), by: 6000) {
                    let reference = "\(turnID)/\(item.id)/\(offset / 6000)"
                    guard seen.insert(reference).inserted else {
                        throw ClientFailure(L10n.text("Повторяющийся идентификатор в истории", "Duplicate history identifier"))
                    }
                    fragments.append(.init(reference: reference, kind: kind, text: String(characters[offset..<min(offset + 6000, characters.count)])))
                }
            }
        }
        return AgentSummarySource(digest: SummarySource.hash(try encoder.encode(turns)), fragments: fragments, turnDates: dates, omittedDetails: omitted)
    }

    /// Titles and archive state belong to the app; the agent keeps its own session files in its isolated home.
    public func rename(_ session: AgentSessionReference, title: String, context: AgentContext) -> AgentResult<Void> {
        checked(session, context: context) ? .success(()) : .rejected(.wrongConnection)
    }
    public func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) -> AgentResult<Void> {
        checked(session, context: context) ? .success(()) : .rejected(.wrongConnection)
    }
    /// Hides the chat only: the app's record and the agent's own files stay.
    public func delete(_ session: AgentSessionReference, context: AgentContext) -> AgentResult<Void> {
        guard checked(session, context: context), turns[session.nativeID] == nil else { return .rejected(.wrongConnection) }
        records[session.nativeID] = nil
        return .success(())
    }

    public func generate(_ request: AgentGenerationRequest, environment: AgentGenerationEnvironment,
                         willStart: @escaping @Sendable () async throws -> Void) -> AgentResult<AgentGenerationOutput> {
        .rejected(.unsupported(.isolatedGeneration))
    }
    public func cancelGeneration(_ id: UUID) {}

    private func failure<T>(_ error: any Error) -> AgentResult<T> {
        if error is RejectedInput { return .rejected(.invalidInput) }
        if let error = error as? ACPTransportError { return .failed(.init(delivery: error.delivery, diagnostic: error.localizedDescription)) }
        return .failed(.init(delivery: .notSent, diagnostic: error.localizedDescription))
    }
}

extension AgentPermissionSupport {
    /// ACP agents apply their own tool policy; the app answers their permission prompts. Role profiles are accepted when every
    /// prompt can be asked or refused, and the external policy runs with every prompt refused. Prompts outside a read-only,
    /// shell-off or network-off role are refused, but tools the agent runs without asking are not limited, so no rule is
    /// enforced exactly and every one a role asks for is shown as an approximation.
    public static let acpPromptPolicy = Self(roleProfiles: true, externalPolicy: true, enforced: [])
}
