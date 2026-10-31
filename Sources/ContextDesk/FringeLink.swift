import AppKit
import Combine
import Darwin
import Foundation
import os
import AgentContract
import ContextCore
import FringeProtocol

/// Maps island state to the Fringe wire format. Kept pure for tests.
enum FringeLinkMapping {
    /// Details are evidence for the user, not a transcript; long ones are cut.
    static let detailsLimit = 4_000

    static func chat(_ chat: NotchChat) -> FringeChat {
        let phase: FringeChat.Phase = switch chat.phase {
        case .waiting: .waiting
        case .working: .working
        case .finished: .finished
        }
        return FringeChat(id: chat.id, title: chat.title, project: chat.project, phase: phase,
                          activity: chat.activity, since: chat.since, updated: chat.updated)
    }

    static func request(_ action: PendingAction) -> FringeRequest {
        let interaction = action.interaction
        let kind: FringeRequest.Kind, canAllow: Bool
        switch interaction.kind {
        case .approval(let allow): kind = .approval; canAllow = allow
        case .questions, .form: kind = .question; canAllow = false
        case .link, .unsupported: kind = .other; canAllow = false
        }
        return FringeRequest(id: action.id, chatID: action.threadID, kind: kind, title: action.title, reason: interaction.reason,
                             details: String(interaction.details.prefix(detailsLimit)), canAllow: canAllow,
                             canAllowTurn: canAllow && interaction.canAllowTurn)
    }

    /// Sub-agents sent per chat: the panel is a glance, not the chat's sub-agent list.
    static let subagentsLimit = 6

    static func subagent(_ agent: AgentSubagent, chatID: String) -> FringeSubagent {
        let status: FringeSubagent.Status = switch agent.status {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        }
        return FringeSubagent(id: agent.id, chatID: chatID, title: agent.title, type: agent.type, background: agent.background,
                              status: status, activity: agent.activity, since: agent.startedAt, ended: agent.endedAt)
    }

    /// Running sub-agents first, then the most recently started; cut at `subagentsLimit` per chat.
    static func subagents(_ agents: [AgentSubagent], chatID: String, limit: Int = subagentsLimit) -> [FringeSubagent] {
        let running = agents.filter { $0.status == .running }.sorted { $0.startedAt < $1.startedAt }
        let done = agents.filter { $0.status != .running }.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        return (running + done).prefix(limit).map { subagent($0, chatID: chatID) }
    }

    static func snapshot(_ snapshot: NotchIslandController.Snapshot) -> FringeSnapshot {
        let subagents = snapshot.ordered.flatMap { chat in
            self.subagents(snapshot.subagents[chat.id] ?? [], chatID: chat.id)
        }
        return FringeSnapshot(chats: snapshot.ordered.map(chat), requests: snapshot.actions.map(request), subagents: subagents)
    }

    /// Only approvals are answered from the panel, and "allow" only when the agent offers it.
    static func response(for answer: FringeAnswer, to action: PendingAction) -> AgentInteractionResponse? {
        guard case .approval(let canAllow) = action.interaction.kind else { return nil }
        switch answer {
        case .deny: return .deny
        case .allowOnce: return canAllow ? .allowOnce : nil
        case .allowTurn: return canAllow && action.interaction.canAllowTurn ? .allowTurn : nil
        }
    }
}

/// Serves the Fringe notch app over `~/Library/Application Support/Switchboard/fringe.sock`.
/// Only a peer signed as `local.daniil.fringe` by the same team is accepted. While Fringe is
/// connected the built-in island steps aside; when the connection ends it returns.
@MainActor final class FringeLinkServer {
    private static var running: FringeLinkServer?
    private static let log = Logger(subsystem: "local.daniil.switchboard", category: "fringe")

    static func start(model: DeskModel, showMainWindow: @escaping () -> Void) {
        guard running == nil else { return }
        let server = FringeLinkServer(model: model, showMainWindow: showMainWindow)
        guard server.listen() else { return }
        running = server
    }

    private let model: DeskModel
    private let showMainWindow: () -> Void
    private let queue = DispatchQueue(label: "local.daniil.switchboard.fringe")
    private var acceptSource: DispatchSourceRead?
    private var client: FringeClientConnection?
    private var greeted = false
    private var tracker = NotchTracker()
    private var lastSnapshot: FringeSnapshot?
    /// Requests answered from the panel in this session; a second answer is refused, never resent.
    private var answered: Set<String> = []
    private var observer: AnyCancellable?

    private init(model: DeskModel, showMainWindow: @escaping () -> Void) {
        self.model = model
        self.showMainWindow = showMainWindow
    }

    private func listen() -> Bool {
        let path = FringeProtocol.socketURL().path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Self.log.error("socket() failed: \(errno)"); return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); Self.log.error("Socket path too long"); return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        // Created owner-only from the start, then confirmed with chmod.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            Self.log.error("Cannot listen on the Fringe socket: \(errno)")
            close(fd); return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            var on: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard FringePeer.isTrusted(socket: peer, bundleID: FringeProtocol.clientBundleID) else {
                Self.log.error("Rejected a Fringe socket peer with an unexpected signature")
                close(peer); return
            }
            Task { @MainActor in self?.adopt(peer) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        // Read now, while the bundle on disk is still the running one; a later rebuild would make the read fail.
        if let team = FringePeer.currentTeamID() { Self.log.info("Listening for Fringe signed by team \(team, privacy: .public)") }
        else { Self.log.error("Listening for Fringe, but this build has no Team ID; every peer will be rejected") }
        return true
    }

    private func adopt(_ fd: Int32) {
        // One Fringe at a time; a new connection replaces a stale one.
        client?.close()
        let connection = FringeClientConnection(fd: fd, queue: queue)
        connection.onLine = { [weak self, weak connection] line in
            Task { @MainActor in
                guard let self, let connection, connection === self.client else { return }
                self.receive(line)
            }
        }
        connection.onClose = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, let connection, connection === self.client else { return }
                self.disconnected()
            }
        }
        client = connection
        greeted = false
        connection.start()
    }

    private func receive(_ line: Data) {
        let message: FringeMessage
        do { message = try FringeCodec.decode(line) } catch {
            // Fail closed: another version or an unknown message ends the session.
            Self.log.error("Fringe protocol error: \(String(describing: error), privacy: .public)")
            return drop()
        }
        switch message {
        case .hello where !greeted:
            greeted = true
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            send(.hello(FringeHello(app: "Switchboard", appVersion: version, capabilities: [.answer, .allowTurn])))
            tracker = NotchTracker()
            lastSnapshot = nil
            answered = []
            NotchIslandController.setHandedOff(true)
            observer = model.objectWillChange
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.publish() }
            publish()
            Self.log.info("Fringe connected; the island is handed off")
        case .openChat(let chatID) where greeted:
            showMainWindow()
            Task { await model.focusAction(threadID: chatID) }
        case .answer(let requestID, let response) where greeted:
            answer(requestID: requestID, response)
        default:
            // A second hello, a message before hello, or one only Switchboard sends.
            Self.log.error("Unexpected Fringe message \(message.type, privacy: .public)")
            drop()
        }
    }

    private func answer(requestID: String, _ answer: FringeAnswer) {
        func fail(_ message: String) { send(.answerResult(FringeAnswerResult(requestID: requestID, outcome: .failed, message: message))) }
        guard !answered.contains(requestID) else {
            return fail(L10n.text("Ответ на этот запрос уже отправлен.", "This request was already answered."))
        }
        guard let action = model.pending.first(where: { $0.id == requestID }) else {
            return fail(L10n.text("Запрос уже закрыт.", "The request is already closed."))
        }
        guard let response = FringeLinkMapping.response(for: answer, to: action) else {
            return fail(L10n.text("Этот запрос нельзя так подтвердить из шторки. Ответь в чате.",
                                  "This request cannot be answered this way from the notch. Answer in the chat."))
        }
        answered.insert(requestID)
        Task {
            let failure = await model.answer(action, result: response)
            send(.answerResult(FringeAnswerResult(requestID: requestID, outcome: failure == nil ? .sent : .failed, message: failure)))
        }
    }

    private func publish() {
        guard greeted else { return }
        let snapshot = NotchIslandController.snapshot(model: model)
        let wire = FringeLinkMapping.snapshot(snapshot)
        if wire != lastSnapshot {
            lastSnapshot = wire
            send(.snapshot(wire))
        }
        let transition = tracker.update(working: snapshot.working, waitingRequests: Set(model.pending.map(\.id)), waitingChats: snapshot.waitingChats)
        let titles = Dictionary(model.state.chats.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for requestID in transition.newlyWaiting {
            guard let action = model.pending.first(where: { $0.id == requestID }) else { continue }
            send(.announce(FringeAnnouncement(kind: .request, chatID: action.threadID, requestID: requestID, chatTitle: titles[action.threadID] ?? "")))
        }
        for chatID in transition.finished {
            send(.announce(FringeAnnouncement(kind: .done, chatID: chatID, chatTitle: titles[chatID] ?? "")))
        }
    }

    private func send(_ message: FringeMessage) {
        guard let client, let data = try? FringeCodec.encode(message) else { return }
        client.send(data)
    }

    private func drop() {
        client?.close()
        disconnected()
    }

    private func disconnected() {
        client = nil
        greeted = false
        observer = nil
        lastSnapshot = nil
        NotchIslandController.setHandedOff(false)
        Self.log.info("Fringe disconnected; the island is back")
    }
}

/// One accepted socket. All I/O runs on the server's serial queue.
private final class FringeClientConnection: @unchecked Sendable {
    var onLine: (Data) -> Void = { _ in }
    var onClose: () -> Void = {}
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = FringeLineBuffer()
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                return closeOnQueue()
            }
        }
    }

    func close() { queue.async { [self] in closeOnQueue(notify: false) } }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            return closeOnQueue()
        }
        do {
            for line in try buffer.append(Data(chunk[0..<count])) { onLine(line) }
        } catch {
            closeOnQueue()
        }
    }

    private func closeOnQueue(notify: Bool = true) {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        if notify { onClose() }
    }
}
