import Foundation
import Network

public struct RemoteSnapshotPatch: Encodable, Sendable {
    public let device_id: String
    public let device_name: String
    public let project_list: [RemoteProject]
    public let chat_order: [String]
    public let changed_chats: [RemoteChat]
    public init(device: RemoteDevice, previous: RemoteSnapshot?) {
        device_id = device.id; device_name = device.name; project_list = device.snapshot.projects
        chat_order = device.snapshot.chats.map(\.id)
        changed_chats = device.snapshot.chats.filter { chat in
            previous?.chats.first(where: { $0.id == chat.id }) != chat
        }
    }
}

public struct RemoteSnapshotDelta: Decodable, Sendable {
    public var device: RemoteDevice
    public var chats: [RemoteChat]
    public var order: [String]
    public func applying(to previous: RemoteDevice?) -> RemoteDevice {
        guard (device.revision ?? 0) >= (previous?.revision ?? -1) else { return previous! }
        var result = device
        let available = Dictionary((previous?.snapshot.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            .merging(Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }), uniquingKeysWith: { _, b in b })
        result.snapshot.chats = order.compactMap { available[$0] }
        return result
    }
}

public enum RemoteConnectionState: Equatable, Sendable {
    case stopped, connecting, subscribing, syncing, connected, offline, retrying, authenticationRequired, failed
    public var text: String {
        switch self {
        case .stopped: L10n.text("Соединение приостановлено", "Connection paused")
        case .connecting: L10n.text("Подключаемся к серверу…", "Connecting to server…")
        case .subscribing: L10n.text("Подписываемся на события…", "Subscribing to events…")
        case .syncing: L10n.text("Обновляем данные…", "Synchronizing…")
        case .connected: L10n.text("Сервер на связи", "Server connected")
        case .offline: L10n.text("Нет сети. Подключимся после её восстановления.", "Offline. Will reconnect when the network returns.")
        case .retrying: L10n.text("Восстанавливаем соединение…", "Reconnecting…")
        case .authenticationRequired: L10n.text("Войди в Supabase заново.", "Sign in to Supabase again.")
        case .failed: L10n.text("Соединение недоступно. Проверь настройки.", "Connection unavailable. Check settings.")
        }
    }
}

public struct RemoteRealtimeCredentials: Sendable {
    public let url: URL
    public let owner: String
    public let token: String
    public init(url: URL, owner: String, token: String) { self.url = url; self.owner = owner; self.token = token }
}

public struct RemoteInvalidation: Sendable, Equatable {
    public let entity: String
    public let device: String
    public let command: String?
    public let status: String?
}

/// Only identifiers and role are retained; Presence is advisory, never command authorization.
public struct RemotePresence: Equatable, Sendable {
    public var macs: Set<String> = []
    public var phones: Set<String> = []
}

@MainActor public protocol RemoteSocket: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

@MainActor private final class NativeRemoteSocket: RemoteSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 256 * 1024
        task.resume()
    }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data: throw RemoteFailure.realtimeProtocol // Pinned JSON protocol 1.0.0.
        @unknown default: throw RemoteFailure.realtimeProtocol
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

/// Coalesces work caused by events, including events received during an await.
/// No timer exists when clean. Cancellation/generation guards prevent stale workers
/// from clearing or applying work belonging to a newer connection.
/// Requests made while a delay is pending are merged into that run; a request with a
/// shorter delay cuts the pending wait short, so an immediate request never waits.
@MainActor public final class RemoteEventWork {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var dirty = false
    /// Delay before the next run, nil when none is pending.
    private var pendingDelay: Duration?
    private var timer: Task<Void, Error>?
    public init() {}
    public func cancel() {
        generation = UUID(); task?.cancel(); task = nil; timer?.cancel(); timer = nil; dirty = false; pendingDelay = nil
    }
    public func enqueue(delay: Duration = .zero, operation: @escaping @MainActor () async throws -> Void,
                        failure: @escaping @MainActor (Error) -> Void) {
        dirty = true
        if let pending = pendingDelay {
            if delay < pending { pendingDelay = delay; timer?.cancel() }
        } else { pendingDelay = delay }
        guard task == nil else { return }
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == ticket { task = nil; pendingDelay = nil } }
            do {
                while dirty, generation == ticket {
                    try await wait(ticket)
                    try Task.checkCancellation()
                    dirty = false
                    try await operation()
                }
            } catch {
                guard generation == ticket, !Task.isCancelled else { return }
                failure(error)
            }
        }
    }
    private func wait(_ ticket: UUID) async throws {
        while generation == ticket, let delay = pendingDelay, delay > .zero {
            let sleep = Task { try await Task.sleep(for: delay) }
            timer = sleep
            do { try await sleep.value; break } catch { try Task.checkCancellation() }
            // The timer was cut short by a sooner request: wait out the shorter delay, if any.
        }
        if generation == ticket { pendingDelay = nil; timer = nil }
    }
}

/// Phoenix/Supabase JSON v1.0.0. Socket lifecycle owns no command submission.
@MainActor public final class RemoteRealtime {
    public private(set) var state: RemoteConnectionState = .stopped
    public private(set) var presence = RemotePresence()
    public private(set) var receivedBytes = 0
    public private(set) var sentBytes = 0
    public var onState: (RemoteConnectionState) -> Void = { _ in }
    public var onPresence: (RemotePresence) -> Void = { _ in }
    public var onChange: (RemoteInvalidation) -> Void = { _ in }
    public var onError: (Error) -> Void = { _ in }
    private let credentials: @MainActor () async throws -> RemoteRealtimeCredentials
    private let ready: @MainActor () async throws -> Void
    private let factory: @MainActor (URL) -> any RemoteSocket
    private let role: String
    private let device: String
    private var worker: Task<Void, Never>?
    private var retrySleep: Task<Void, Error>?
    private var socket: (any RemoteSocket)?
    private var monitor: NWPathMonitor?
    private var online = true
    private var networkRoute: String?
    private var networkRevision = 0
    private var generation = UUID()
    private var ref = 0
    private var heartbeatRef: String?
    private var peers: [String: [[String: String]]] = [:]
    private var injectedError: Error?
    private let heartbeatInterval: Duration
    private let deadline: Duration
    private let monitorNetwork: Bool

    public init(role: String, device: String,
                credentials: @escaping @MainActor () async throws -> RemoteRealtimeCredentials,
                ready: @escaping @MainActor () async throws -> Void,
                factory: (@MainActor (URL) -> any RemoteSocket)? = nil,
                heartbeatInterval: Duration = .seconds(15), deadline: Duration = .seconds(8),
                monitorNetwork: Bool = true) {
        self.role = role; self.device = device; self.credentials = credentials; self.ready = ready
        self.factory = factory ?? { NativeRemoteSocket(url: $0) }
        self.heartbeatInterval = heartbeatInterval; self.deadline = deadline; self.monitorNetwork = monitorNetwork
    }
    public static func retryDelay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> Double {
        min(30, pow(2, Double(min(max(attempt, 0), 5))) * max(0.8, min(jitter, 1.2)))
    }
    public static func terminalState(for error: Error) -> RemoteConnectionState? {
        guard let error = error as? RemoteFailure else { return nil }
        switch error {
        case .signedOut, .request(401): return .authenticationRequired
        case .configuration, .realtimeSetup, .realtimeProtocol, .request(403), .keychain: return .failed
        default: return nil
        }
    }
    private func setState(_ value: RemoteConnectionState) { state = value; onState(value) }
    public func start() {
        guard worker == nil else { return }
        let ticket = UUID(); generation = ticket
        online = !monitorNetwork
        networkRoute = nil
        if monitorNetwork {
            let monitor = NWPathMonitor(); self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                let route = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
                Task { @MainActor in
                    guard let self, self.generation == ticket else { return }
                    self.networkChanged(available: available, route: route)
                }
            }
            monitor.start(queue: DispatchQueue(label: "ContextDesk.remote.network"))
        }
        worker = Task { [weak self] in await self?.run(ticket: ticket) }
    }
    /// A satisfied path can change from Wi-Fi to cellular without becoming offline.
    /// Only the transport is replaced; durable commands are never resubmitted here.
    func networkChanged(available: Bool, route: String) {
        guard worker != nil else { return }
        let changed = online != available || (networkRoute != nil && networkRoute != route)
        online = available; networkRoute = route
        guard changed else { return }
        networkRevision += 1
        socket?.close(); retrySleep?.cancel()
        peers = [:]; updatePresence()
        setState(available ? .retrying : .offline)
    }
    public func stop() {
        generation = UUID(); worker?.cancel(); worker = nil; retrySleep?.cancel(); retrySleep = nil
        monitor?.cancel(); monitor = nil; socket?.close(); socket = nil
        peers = [:]; updatePresence(); setState(.stopped)
    }
    /// A failed read/publish reconnects and reconciles. It never retries an execution.
    public func recover(from error: Error) {
        guard worker != nil else { return }
        injectedError = error; socket?.close(); retrySleep?.cancel()
    }
    private func run(ticket: UUID) async {
        var attempt = 0
        defer { if generation == ticket { worker = nil; monitor?.cancel(); monitor = nil } }
        while generation == ticket, !Task.isCancelled {
            let revision = networkRevision
            do {
                guard online else { throw URLError(.notConnectedToInternet) }
                setState(.connecting)
                let auth = try await credentials()
                try Task.checkCancellation()
                guard generation == ticket else { return }
                guard revision == networkRevision, online else { continue }
                let connection = factory(auth.url); socket = connection
                let began = ContinuousClock.now
                do { try await connected(connection, auth: auth, ticket: ticket) }
                catch {
                    if ContinuousClock.now - began > .seconds(60) { attempt = 0 }
                    throw error
                }
            } catch {
                guard generation == ticket, !Task.isCancelled else { return }
                socket?.close(); socket = nil; peers = [:]; updatePresence()
                let cause = injectedError ?? error; injectedError = nil
                if let terminal = Self.terminalState(for: cause) { setState(terminal); onError(cause); return }
                setState(online ? .retrying : .offline)
                if online, revision != networkRevision { attempt = 0; continue }
                onError(cause)
                let delay = Self.retryDelay(attempt: attempt); attempt = min(attempt + 1, 6)
                let sleep = Task { try await Task.sleep(for: .seconds(delay)) }; retrySleep = sleep
                _ = try? await sleep.value
                retrySleep = nil
            }
        }
    }
    private func send(_ connection: any RemoteSocket, topic: String, event: String,
                      payload: [String: Any], join: String? = nil, reference: String? = nil) async throws -> String {
        ref += 1; let id = reference ?? String(ref)
        var object: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": id]
        if let join { object["join_ref"] = join }
        let data = try JSONSerialization.data(withJSONObject: object)
        sentBytes += data.count
        try await connection.send(String(decoding: data, as: UTF8.self))
        return id
    }
    private func connected(_ connection: any RemoteSocket, auth: RemoteRealtimeCredentials, ticket: UUID) async throws {
        let topic = "realtime:remote:" + auth.owner.lowercased()
        let join = UUID().uuidString
        heartbeatRef = nil; injectedError = nil
        setState(.subscribing)
        var subscribed = false
        var replicationReady = false
        var synchronized = false
        let timeout = Task {
            try? await Task.sleep(for: deadline)
            if !Task.isCancelled { connection.close() }
        }
        var heartbeat: Task<Void, Never>?
        defer { timeout.cancel(); heartbeat?.cancel(); connection.close() }
        _ = try await send(connection, topic: topic, event: "phx_join", payload: [
            "config": ["private": true, "broadcast": ["ack": false, "self": false, "replication_ready": true],
                       "presence": ["enabled": true, "key": role + ":" + device]],
            "access_token": auth.token
        ], join: join, reference: join)
        var token = auth.token
        while generation == ticket, !Task.isCancelled {
            let text = try await connection.receive()
            try Task.checkCancellation()
            guard generation == ticket else { return }
            receivedBytes += text.utf8.count
            guard text.utf8.count <= 256 * 1024,
                  let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let event = message["event"] as? String,
                  let payload = message["payload"] as? [String: Any] else { throw RemoteFailure.realtimeProtocol }
            let messageTopic = message["topic"] as? String
            let reference = message["ref"] as? String
            if messageTopic == "phoenix", event == "phx_reply", reference == heartbeatRef,
               payload["status"] as? String == "ok" { heartbeatRef = nil; continue }
            guard messageTopic == topic else { continue }
            if let incomingJoin = message["join_ref"] as? String, incomingJoin != join { continue }
            switch event {
            case "phx_reply" where reference == join:
                guard !subscribed else { continue }
                guard payload["status"] as? String == "ok" else { throw RemoteFailure.realtimeProtocol }
                subscribed = true
                heartbeat = Task { [weak self] in
                    guard let self else { return }
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: heartbeatInterval)
                            let current = try await credentials()
                            try Task.checkCancellation()
                            guard generation == ticket else { return }
                            if current.token != token {
                                _ = try await send(connection, topic: topic, event: "access_token",
                                                   payload: ["access_token": current.token], join: join)
                                token = current.token
                            }
                            let beat = UUID().uuidString
                            heartbeatRef = beat
                            _ = try await send(connection, topic: "phoenix", event: "heartbeat", payload: [:], reference: beat)
                            try await Task.sleep(for: deadline)
                            guard heartbeatRef == nil else { throw RemoteFailure.realtimeTimeout }
                        }
                    } catch {
                        guard !Task.isCancelled, generation == ticket else { return }
                        injectedError = error; connection.close()
                    }
                }
                _ = try await send(connection, topic: topic, event: "presence", payload: [
                    "type": "presence", "event": "track", "payload": ["role": role, "device": device]
                ], join: join)
            case "phx_error", "phx_close": throw URLError(.networkConnectionLost)
            case "system":
                if ["error", "timeout"].contains(payload["status"] as? String ?? "") { throw URLError(.networkConnectionLost) }
                if payload["extension"] as? String == "system", payload["status"] as? String == "ok" { replicationReady = true }
            case "broadcast" where subscribed:
                guard payload["event"] as? String == "changed", let data = payload["payload"] as? [String: Any],
                      let entity = data["entity"] as? String, ["device", "command"].contains(entity),
                      let id = data["device"] as? String, UUID(uuidString: id) != nil else { continue }
                onChange(RemoteInvalidation(entity: entity, device: id, command: data["id"] as? String, status: data["status"] as? String))
            case "presence_state" where subscribed:
                peers = payload.compactMapValues { ($0 as? [String: Any])?["metas"] as? [[String: String]] }
                updatePresence()
            case "presence_diff" where subscribed:
                let joins = payload["joins"] as? [String: [String: Any]] ?? [:]
                let leaves = payload["leaves"] as? [String: [String: Any]] ?? [:]
                for (key, value) in joins { peers[key, default: []] += value["metas"] as? [[String: String]] ?? [] }
                for (key, value) in leaves {
                    let refs = Set((value["metas"] as? [[String: String]] ?? []).compactMap { $0["phx_ref"] })
                    peers[key]?.removeAll { $0["phx_ref"].map(refs.contains) == true }
                }
                updatePresence()
            default: break // Data, never executable instructions or command approval.
            }
            if subscribed, replicationReady, !synchronized {
                synchronized = true; timeout.cancel()
                setState(.syncing)
                try await ready()
                try Task.checkCancellation()
                guard generation == ticket else { return }
                setState(.connected)
            }
        }
    }
    private func updatePresence() {
        var value = RemotePresence()
        for meta in peers.values.flatMap({ $0 }) {
            guard let id = meta["device"] else { continue }
            if meta["role"] == "mac" { value.macs.insert(id.lowercased()) }
            if meta["role"] == "phone" { value.phones.insert(id) }
        }
        if value != presence { presence = value; onPresence(value) }
    }
}
