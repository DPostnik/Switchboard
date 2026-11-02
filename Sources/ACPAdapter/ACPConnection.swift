import Foundation
import AgentContract
import ContextCore

/// Splits stdout into lines, scanning each byte once and capping one message. Same rules as the Codex adapter's buffer.
struct ACPLineBuffer {
    private var partial = Data()
    let maximumLineBytes: Int
    enum Failure: Error { case lineTooLarge }

    init(maximumLineBytes: Int = 32 * 1024 * 1024) { self.maximumLineBytes = maximumLineBytes }

    mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            for index in bytes.indices where bytes[index] == 10 {
                try appendSegment(bytes[start..<index])
                lines.append(partial)
                partial = Data()
                start = index + 1
            }
            try appendSegment(bytes[start..<bytes.count])
        }
        return lines
    }

    private mutating func appendSegment(_ bytes: Slice<UnsafeRawBufferPointer>) throws {
        guard bytes.count <= maximumLineBytes - partial.count else { throw Failure.lineTooLarge }
        partial.append(contentsOf: bytes)
    }
}

/// Why a request produced no result. `delivery` tells the caller whether the agent may have acted on it.
enum ACPTransportError: Error, LocalizedError, Equatable {
    /// No process; nothing was written.
    case notConnected
    /// Writing the request failed part-way; the agent may have read it.
    case writeFailed
    /// The process ended or the connection was closed before the response arrived.
    case closed
    /// No response within the deadline. The request is not retried.
    case timedOut(String)
    /// The agent answered with a JSON-RPC error.
    case remote(code: Int, message: String)

    var delivery: AgentFailure.Delivery {
        switch self {
        case .notConnected: .notSent
        case .remote: .confirmed
        case .writeFailed, .closed, .timedOut: .uncertain
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConnected: L10n.text("Агент не подключён", "The agent is not connected")
        case .writeFailed, .closed: L10n.text("Соединение с агентом закрыто", "The connection to the agent is closed")
        case .timedOut(let method):
            L10n.text("Истекло время ожидания \(method). Запрос не повторён автоматически.", "\(method) timed out. The request was not retried automatically.")
        case .remote(_, let message): message
        }
    }
}

/// One agent process and its ordered JSON-RPC 2.0 stream over stdio (ACP transports: one message per line, stdout carries
/// only protocol messages, stderr is the agent's log). Requests in both directions; never retries anything.
actor ACPConnection {
    enum Event: Sendable {
        /// A request (has `id` and `method`) or a notification (only `method`) from the agent, unchanged.
        case message(JSONValue)
        /// A stdout line that is not a JSON-RPC message; counted as drift by name only.
        case malformed(String)
        /// The response to a request dispatched with `ordered: true`, in stream order: every notification the agent sent
        /// before it (a turn's `session/update`s before its `session/prompt` result) has already been delivered.
        case response(id: JSONValue, result: Result<JSONValue, ACPTransportError>)
        /// The process ended or the connection was stopped. `status` is the exit status when the process exited.
        case closed(status: Int32?, reason: String?)
    }

    nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer: ACPLineBuffer
    private let maximumLineBytes: Int
    private var sequence = 0
    private var generation = UUID()
    private var pending: [JSONValue: CheckedContinuation<JSONValue, any Error>] = [:]
    /// Responses that arrived before their caller started waiting (`dispatch` then `response`).
    private var early: [JSONValue: Result<JSONValue, ACPTransportError>] = [:]
    private var dispatchedIDs = Set<JSONValue>()
    /// Requests whose response is delivered as an ordered `.response` event instead of to a waiting caller.
    private var orderedIDs = Set<JSONValue>()
    private var timeouts: [JSONValue: Task<Void, Never>] = [:]
    private var reader: Task<Void, Never>?
    /// Last stderr line before the process exited during startup, for the failure diagnostic only; never logged or stored.
    private var lastErrorLine: String?
    private var finished = false

    init(maximumLineBytes: Int = 32 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes; buffer = ACPLineBuffer(maximumLineBytes: maximumLineBytes)
        let pair = AsyncStream<Event>.makeStream(); events = pair.stream; sink = pair.continuation
    }

    var isRunning: Bool { process?.isRunning == true && !finished }
    var startupError: String? { lastErrorLine }

    func start(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        guard process == nil, !finished else { return }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let token = generation
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = directory
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let chunks = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { chunks.continuation.finish() } else { chunks.continuation.yield(data) }
        }
        // Agent logs are drained, not stored; only the tail of the last line is kept for a startup failure message.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(decoding: data.suffix(400), as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) else { return }
            Task { await self?.noteError(line, token: token) }
        }
        child.terminationHandler = { [weak self] child in
            Task { await self?.terminated(token: token, status: child.terminationStatus) }
        }
        do { try child.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child; input = stdin.fileHandleForWriting; outputPipe = stdout; errorPipe = stderr
        reader = Task { [weak self] in
            for await data in chunks.stream { await self?.ingest(data, token: token) }
        }
    }

    /// Sends a request and waits for its response. `timeout` nil waits until the response or the end of the process.
    /// `closeOnTimeout` stops the process when the deadline passes, for requests whose outcome would stay ambiguous.
    func request(_ method: String, params: JSONValue, timeout: Duration?, closeOnTimeout: Bool = false) async throws -> JSONValue {
        let id = try dispatch(method, params: params, timeout: timeout, closeOnTimeout: closeOnTimeout)
        return try await response(id)
    }

    /// Writes a request and returns its id once the bytes are written; `response(_:)` then waits for the answer, or with
    /// `ordered` the answer arrives as a `.response` event after everything the agent sent before it. A closed connection
    /// sends no `.response` for ordered requests: its `.closed` event settles them.
    func dispatch(_ method: String, params: JSONValue, timeout: Duration?, closeOnTimeout: Bool = false, ordered: Bool = false) throws -> JSONValue {
        guard isRunning else { throw ACPTransportError.notConnected }
        sequence += 1
        let id = JSONValue.number(Double(sequence))
        if ordered { orderedIDs.insert(id) } else { dispatchedIDs.insert(id) }
        do { try send(.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": params])) }
        catch { dispatchedIDs.remove(id); orderedIDs.remove(id); throw ACPTransportError.writeFailed }
        if let timeout {
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.expired(id, method: method, close: closeOnTimeout)
            }
        }
        return id
    }

    func response(_ id: JSONValue) async throws -> JSONValue {
        if let result = early.removeValue(forKey: id) { dispatchedIDs.remove(id); return try result.get() }
        guard dispatchedIDs.contains(id) else { throw ACPTransportError.closed }
        return try await withCheckedThrowingContinuation { continuation in pending[id] = continuation }
    }

    func notify(_ method: String, params: JSONValue) throws {
        guard isRunning else { throw ACPTransportError.notConnected }
        do { try send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])) }
        catch { throw ACPTransportError.writeFailed }
    }

    func respond(id: JSONValue, result: JSONValue) throws {
        guard isRunning else { throw ACPTransportError.notConnected }
        do { try send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])) } catch { throw ACPTransportError.writeFailed }
    }

    func respondError(id: JSONValue, code: Int, message: String) throws {
        guard isRunning else { throw ACPTransportError.notConnected }
        do {
            try send(.object(["jsonrpc": .string("2.0"), "id": id,
                              "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
        } catch { throw ACPTransportError.writeFailed }
    }

    private func send(_ value: JSONValue) throws {
        guard let input else { throw ACPTransportError.notConnected }
        var bytes = try JSONEncoder().encode(value); bytes.append(10)
        try input.write(contentsOf: bytes)
    }

    private func noteError(_ line: String, token: UUID) {
        guard token == generation else { return }
        lastErrorLine = String(line.prefix(300))
    }

    private func ingest(_ data: Data, token: UUID) {
        guard token == generation, !finished else { return }
        let lines: [Data]
        do { lines = try buffer.append(data) } catch {
            close(reason: L10n.text("Сообщение агента превышает допустимый размер", "An agent message exceeds the size limit"))
            return
        }
        for line in lines {
            guard !line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: line), case .object = message else {
                sink.yield(.malformed("invalid-json")); continue
            }
            if message["method"].string != nil { sink.yield(.message(message)); continue }
            let id = message["id"]
            guard id != .null, dispatchedIDs.contains(id) || orderedIDs.contains(id) else {
                sink.yield(.malformed(id == .null ? "frame-without-method-or-id" : "response-to-unknown-id")); continue
            }
            timeouts.removeValue(forKey: id)?.cancel()
            let result: Result<JSONValue, ACPTransportError>
            if message["error"] != .null {
                result = .failure(.remote(code: message["error"]["code"].int ?? 0,
                                          message: message["error"]["message"].string ?? L10n.text("Ошибка протокола", "Protocol error")))
            } else { result = .success(message["result"]) }
            resolve(id, result)
        }
    }

    private func resolve(_ id: JSONValue, _ result: Result<JSONValue, ACPTransportError>) {
        if orderedIDs.remove(id) != nil { sink.yield(.response(id: id, result: result)); return }
        if let continuation = pending.removeValue(forKey: id) {
            dispatchedIDs.remove(id)
            continuation.resume(with: result.mapError { $0 as any Error })
        } else if dispatchedIDs.contains(id) { early[id] = result }
    }

    private func expired(_ id: JSONValue, method: String, close shouldClose: Bool) {
        guard timeouts.removeValue(forKey: id) != nil else { return }
        resolve(id, .failure(.timedOut(method)))
        if shouldClose { close(reason: ACPTransportError.timedOut(method).errorDescription) }
    }

    private func terminated(token: UUID, status: Int32) {
        guard token == generation, !finished else { return }
        finish(status: status, reason: nil)
    }

    /// Stops the process; pending requests fail as `closed` (their outcome is unknown) and one `closed` event is sent.
    func stop() { close(reason: nil) }

    private func close(reason: String?) {
        guard !finished else { return }
        let child = process
        finish(status: nil, reason: reason)
        if child?.isRunning == true { child?.terminate() }
    }

    private func finish(status: Int32?, reason: String?) {
        finished = true
        generation = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil
        buffer = ACPLineBuffer(maximumLineBytes: maximumLineBytes)
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let waiting = pending; pending.removeAll()
        for id in dispatchedIDs where waiting[id] == nil && early[id] == nil { early[id] = .failure(.closed) }
        for (id, continuation) in waiting { dispatchedIDs.remove(id); continuation.resume(throwing: ACPTransportError.closed) }
        orderedIDs.removeAll()
        process = nil; outputPipe = nil; errorPipe = nil
        sink.yield(.closed(status: status, reason: reason))
        sink.finish()
    }
}
