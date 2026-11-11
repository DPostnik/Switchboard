import Foundation
import os
import ContextCore

/// One process and one ordered JSONL stream. Never retries model turns.
@_spi(NativeProtocol) public actor CodexConnection {
    /// Diagnostic/isolated-runner view. A connection has exactly one event consumer.
    public nonisolated var events: AsyncStream<JSONValue> {
        AsyncStream { continuation in
            let task = Task { [scopedEvents] in
                for await event in scopedEvents { continuation.yield(event.message) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    nonisolated let scopedEvents: AsyncStream<CodexWireEvent>
    private let scopedSink: AsyncStream<CodexWireEvent>.Continuation
    private var process: Process?
    /// Process group of a worker under the external boundary; revocation signals the whole group.
    private var boundaryGroup: Int32?
    /// Last diagnostics of a boundary launch; logged when the process ends, so a refused grant is visible in the app log.
    private let boundaryDiagnostics = OSAllocatedUnfairLock<Data>(initialState: Data())
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer: JSONLineBuffer
    private let maximumLineBytes: Int
    private var sequence = 0
    private var generation = UUID()
    // All provider processes for one account invalidate the same dispatch context.
    private let revision: OSAllocatedUnfairLock<UUID>
    private let preservesAccountRevision: Bool
    var accountEpoch: UUID { revision.withLock { $0 } }
    func sibling(preservingAccountRevision: Bool = false) -> CodexConnection { CodexConnection(revision: revision, preservesAccountRevision: preservingAccountRevision) }
    var isRunning: Bool { process?.isRunning == true }
    private struct PendingRequest { let epoch: UUID; let token: UUID; let thread: String?; let turn: String? }
    private var approvalRequests: [JSONValue: PendingRequest] = [:]
    private var seenApprovalIDs = Set<JSONValue>()
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var reader: Task<Void, Never>?
    /// Routes a notice about a skipped message whose head names no thread; a dedicated worker serves one chat.
    private var lastThreadID: String?
    public private(set) var serverUserAgent: String?
    private(set) var verifiedInstallVersion: String?
    private(set) var activeHome: URL?

    public init(maximumLineBytes: Int = 32 * 1024 * 1024) {
        self.init(maximumLineBytes: maximumLineBytes, revision: OSAllocatedUnfairLock(initialState: UUID()))
    }
    private init(maximumLineBytes: Int = 32 * 1024 * 1024, revision: OSAllocatedUnfairLock<UUID>, preservesAccountRevision: Bool = false) {
        self.revision = revision; self.preservesAccountRevision = preservesAccountRevision
        self.maximumLineBytes = maximumLineBytes; buffer = JSONLineBuffer(maximumLineBytes: maximumLineBytes)
        let scoped = AsyncStream<CodexWireEvent>.makeStream()
        scopedEvents = scoped.stream; scopedSink = scoped.continuation
    }

    public func start(executable: URL, home: URL, extraArguments: [String] = [], boundary: ExternalSandboxLaunch? = nil) async throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let token = UUID(); generation = token
        if !preservesAccountRevision { revision.withLock { $0 = UUID() } }
        // Pin the managed pointer for this process. Other launchers may dispatch by their symlink name.
        let managed = Locations.agentsHome.appendingPathComponent("codex/bin/codex").standardizedFileURL
        let binary = executable.standardizedFileURL == managed ? executable.resolvingSymlinksInPath() : executable
        verifiedInstallVersion = CodexVerifiedInstall.version(of: binary, selected: executable)
        // A thread's writer lock belongs to one process. With no unload delay, `CodexClient.release` hands it to another at once.
        let serverArguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"",
                               "-c", "analytics.enabled=false", "-c", "thread_unload_delay_secs=0"] + extraArguments
        if let boundary {
            // The whole tree (launcher, helper, Codex, its tools) forms one process group under the external boundary.
            let launch = boundary.command(provider: binary, arguments: serverArguments)
            child.executableURL = launch.executable; child.arguments = launch.arguments
        } else {
            child.executableURL = binary; child.arguments = serverArguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        if let boundary { environment.merge(boundary.plan.environment) { _, new in new } }
        // Account login belongs to this app, even when started from a configured shell.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
            environment.removeValue(forKey: key)
        }
        // An app-server serves multiple chats, so only the instance label applies (swept at quit and next launch).
        environment.merge(ProcessLabels.environment()) { _, new in new }
        child.environment = environment
        child.currentDirectoryURL = home
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let chunks = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { chunks.continuation.finish() }
            else { chunks.continuation.yield(data) }
        }
        // Drain diagnostics without storing prompts, credentials or raw server logs. Under the boundary the helper's
        // own refusals arrive here, so a bounded tail is kept for the termination log line.
        let diagnostics = boundaryDiagnostics
        boundaryDiagnostics.withLock { $0 = Data() }
        stderr.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard boundary != nil, !data.isEmpty else { return }
            diagnostics.withLock { tail in tail.append(data); if tail.count > 4096 { tail = tail.suffix(4096) } }
        }
        child.terminationHandler = { [weak self] child in
            Task { await self?.terminated(token: token, status: child.terminationStatus) }
        }
        do { try child.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        activeHome = home.standardizedFileURL
        boundaryGroup = boundary == nil ? nil : child.processIdentifier
        process = child; input = stdin.fileHandleForWriting; outputPipe = stdout; errorPipe = stderr
        reader = Task { [weak self] in
            for await data in chunks.stream { await self?.ingest(data, token: token) }
        }
        do {
            let initialized = try await request("initialize", params: .object([
                "clientInfo": .object(["name": .string("context_desk"), "title": .string("Switchboard"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            serverUserAgent = initialized["userAgent"].string
            try send(.object(["method": .string("initialized"), "params": .object([:])]))
        } catch { stop(); throw error }
    }

    public func request(_ method: String, params: JSONValue = .object([:]), timeout: UInt64 = 30) async throws -> JSONValue {
        guard process?.isRunning == true else { throw ClientFailure(L10n.text("Codex не подключён", "Codex is not connected")) }
        if let expected = CodexDispatchContext.epoch, expected != accountEpoch { throw CodexDispatchRejection.stale }
        if method == "turn/start" || method == "thread/start" { try Task.checkCancellation() }
        sequence += 1; let id = String(sequence)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.object(["id": .string(id), "method": .string(method), "params": params]))
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                    await self?.expired(id, method: method)
                }
            } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    func invalidateAccount() { revision.withLock { $0 = UUID() }; approvalRequests.removeAll() }
    func isCurrent(_ token: UUID) -> Bool { token == generation }
    func answer(id: JSONValue, result: JSONValue, generation token: UUID, requestToken: UUID) throws {
        if let expected = CodexDispatchContext.epoch, expected != accountEpoch { throw CodexDispatchRejection.stale }
        guard token == generation, approvalRequests[id]?.epoch == accountEpoch, approvalRequests[id]?.token == requestToken else { throw CodexPendingInteraction.invalidResponse }
        approvalRequests[id] = nil
        try answer(id: id, result: result)
    }
    func rejectUnknown(id: JSONValue, generation token: UUID) throws {
        guard token == generation else { return }
        try rejectUnknown(id: id)
    }
    private func emit(_ value: JSONValue) {
        let method = value["method"].string ?? "", p = value["params"]
        if let thread = p["threadId"].string, !thread.isEmpty { lastThreadID = thread }
        // Names only; the message itself is delivered unchanged.
        CodexProtocolSurface.record(value, userAgent: serverUserAgent)
        var requestToken: UUID?
        if value["id"] != .null {
            let id = value["id"]
            if seenApprovalIDs.insert(id).inserted {
                let token = UUID(); requestToken = token
                approvalRequests[id] = PendingRequest(epoch: accountEpoch, token: token, thread: p["threadId"].string, turn: p["turnId"].string)
            } else { approvalRequests[id] = nil }
        } else if ["account/updated", "account/login/completed", "client/disconnected"].contains(method) {
            // Every app-server announces `account/updated` right after `initialize`. An isolated worker serves the
            // primary process's account, so its start or exit must not invalidate sends that are in flight.
            if !preservesAccountRevision { revision.withLock { $0 = UUID() } }
            approvalRequests.removeAll()
        } else if method == "serverRequest/resolved" {
            let id = p["requestId"]
            if approvalRequests[id]?.thread == p["threadId"].string { approvalRequests[id] = nil }
        } else if method == "turn/completed", p["turn"]["id"].string != nil {
            approvalRequests = approvalRequests.filter { _, request in
                request.thread != p["threadId"].string || request.turn != p["turn"]["id"].string
            }
        }
        scopedSink.yield(CodexWireEvent(generation: generation, message: value, requestToken: requestToken))
    }
    public func answer(id: JSONValue, result: JSONValue) throws {
        approvalRequests[id] = nil
        try send(.object(["id": id, "result": result]))
    }
    public func rejectUnknown(id: JSONValue) throws {
        approvalRequests[id] = nil
        try send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported client request")])]))
    }
    private func send(_ value: JSONValue) throws {
        guard let input else { throw ClientFailure(L10n.text("Соединение закрыто", "Connection closed")) }
        var bytes = try JSONEncoder().encode(value); bytes.append(10)
        try revision.withLock { [bytes] epoch in
            if let expected = CodexDispatchContext.epoch, expected != epoch { throw CodexDispatchRejection.stale }
            try input.write(contentsOf: bytes)
        }
    }
    private func ingest(_ data: Data, token: UUID) {
        guard token == generation else { return }
        for entry in buffer.append(data) {
            let line: Data
            switch entry {
            case .complete(let complete): line = complete
            case .oversized(let head, let bytes): skipOversized(OversizedLineHead(head), bytes: bytes); continue
            }
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            if message["method"].string != nil { emit(message); continue }
            guard let id = message["id"].string, let c = pending.removeValue(forKey: id) else { continue }
            timeouts.removeValue(forKey: id)?.cancel()
            if message["error"] != .null {
                c.resume(throwing: ClientFailure(message["error"]["message"].string ?? L10n.text("Ошибка протокола", "Protocol error")))
            } else { c.resume(returning: message["result"]) }
        }
    }
    /// One message over the limit (for example a large tool result) is skipped; the process and its turn keep
    /// running. A reply the app waits for fails at once, a server request is declined, and the chat gets a notice.
    private func skipOversized(_ head: OversizedLineHead, bytes: Int) {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(maximumLineBytes), countStyle: .file)
        if head.method == nil, let id = head.id?.string, let c = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            c.resume(throwing: ClientFailure(L10n.text("Ответ Codex (\(size)) больше лимита \(limit) и пропущен; запрос не повторён.",
                                                       "The Codex reply (\(size)) exceeds the \(limit) limit and was skipped; the request was not retried.")))
            return
        }
        if head.method != nil, let id = head.id {
            try? send(.object(["id": id, "error": .object(["code": .number(-32600), "message": .string("Request exceeds the client size limit")])]))
        }
        var params: [String: JSONValue] = ["message": .string(L10n.text(
            "Codex прислал сообщение размером \(size), больше лимита \(limit). Switchboard пропустил его, ход продолжается; результат этого шага может не показаться в чате.",
            "Codex sent a \(size) message, over the \(limit) limit. Switchboard skipped it and the turn continues; the result of this step may be missing from the chat."))]
        if let thread = head.threadID ?? lastThreadID { params["threadId"] = .string(thread) }
        emit(.object(["method": .string("client/error"), "params": .object(params)]))
    }
    private func expired(_ id: String, method: String) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: ClientFailure(L10n.text("Истекло время ожидания \(method). Запрос не повторён автоматически.", "\(method) timed out. The request was not retried automatically.")))
        if method == "turn/start" || method == "turn/steer" {
            stop()
            emit(.object(["method": .string("client/disconnected"), "params": .object([:])]))
        }
    }
    private func terminated(token: UUID, status: Int32) {
        guard generation == token else { return }
        if boundaryGroup != nil {
            let tail = boundaryDiagnostics.withLock { String(decoding: $0, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
            ExternalSandboxLog.logger.error("Boundary worker ended with status \(status, privacy: .public): \(tail.isEmpty ? "no diagnostics" : tail, privacy: .public)")
        }
        cleanUp()
        emit(.object(["method": .string("client/disconnected"), "params": .object(["status": .number(Double(status))])]))
    }
    public func stop() {
        let child = process, group = boundaryGroup
        generation = UUID()
        if !preservesAccountRevision { revision.withLock { $0 = UUID() } }
        cleanUp()
        if let group {
            // Revocation ends the helper, Codex and every tool process it started, not only the launcher.
            ProcessGroupTerminator.terminate(group: group)
        } else if child?.isRunning == true { child?.terminate() }
    }
    private func cleanUp() {
        approvalRequests.removeAll(); seenApprovalIDs.removeAll()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil; buffer = JSONLineBuffer(maximumLineBytes: maximumLineBytes)
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        let waiting = pending.values; pending.removeAll()
        for c in waiting { c.resume(throwing: ClientFailure(L10n.text("Соединение с Codex закрыто", "The connection to Codex is closed"))) }
        activeHome = nil; lastThreadID = nil
        process = nil; outputPipe = nil; errorPipe = nil; boundaryGroup = nil
    }
}

struct CodexWireEvent: Sendable { let generation: UUID; let message: JSONValue; var requestToken: UUID? = nil }
