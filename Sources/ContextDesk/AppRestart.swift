import AppKit
import AgentContract
import ContextCore

enum RestartFailure: LocalizedError {
    case unavailable
    var errorDescription: String? {
        L10n.text("Перезапуск доступен только из собранного приложения.", "Restart is available only from the built app bundle.")
    }
}

/// The chat whose agent requested a restart gets one fixed continuation message once the app is back.
/// Only session IDs travel: the app maps them to its own chats and never accepts text from the request.
struct RestartContinuation: Codable, Equatable {
    static let claudeSessionKey = "claudeSession", codexThreadKey = "codexThread"
    static let maximumAge: TimeInterval = 600
    static var file: URL { Locations.root.appendingPathComponent("restart-continuation.json") }
    static var message: String {
        L10n.text("Switchboard перезапущен по твоему запросу. Продолжай задачу с того места, где остановился.",
                  "Switchboard restarted at your request. Continue the task from where you left off.")
    }
    var chatIDs: [String]
    var requestedAt: Date

    /// Session IDs the agents export to their commands; read by the requesting CLI process.
    static func requesterInfo(environment: [String: String]) -> [String: String] {
        var info: [String: String] = [:]
        if let id = environment["CLAUDE_CODE_SESSION_ID"], valid(id) { info[claudeSessionKey] = id }
        if let id = environment["CODEX_THREAD_ID"], valid(id) { info[codexThreadKey] = id }
        return info
    }
    /// The requester must be an existing, unarchived chat of the matching agent.
    static func chatID(requestedBy info: [AnyHashable: Any]?, in chats: [Chat]) -> String? {
        for (key, connection) in [(claudeSessionKey, AgentConnectionID.appClaude), (codexThreadKey, .originalCodex)] {
            guard let id = info?[key] as? String, valid(id) else { continue }
            let session = AgentSessionReference(connection: connection, nativeID: id)
            if let chat = chats.first(where: { $0.nativeSession == session && !$0.isArchived }) { return chat.id }
        }
        return nil
    }
    private static func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 128 }

    func save(to url: URL = file) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Consumed once: if the file cannot be removed nothing is returned, so a continuation is never sent twice.
    static func take(from url: URL = file, now: Date = Date()) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard (try? FileManager.default.removeItem(at: url)) != nil,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              now.timeIntervalSince(value.requestedAt) <= maximumAge, value.requestedAt <= now.addingTimeInterval(60) else { return [] }
        return value.chatIDs
    }
}

/// A same-login-session request channel. It accepts no commands, paths or approval overrides.
@MainActor enum RestartCommand {
    /// Keeps the pre-rename id so a new build can still ask an older running instance to restart.
    static let notification = Notification.Name("local.daniil.contextdesk.restart-when-idle.v1")

    static func run(arguments: [String]) -> Bool {
        guard arguments.dropFirst().first == "--request-restart" else { return false }
        guard arguments.count == 2, Bundle.main.bundleURL.pathExtension == "app",
              NSWorkspace.shared.runningApplications.contains(where: {
                  $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                  $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
              }) else {
            fputs(L10n.text("Работающий экземпляр этого приложения не найден.\n", "No running instance of this app bundle was found.\n"), stderr)
            exit(1)
        }
        let requester = RestartContinuation.requesterInfo(environment: ProcessInfo.processInfo.environment)
        DistributedNotificationCenter.default().postNotificationName(notification,
            object: Bundle.main.bundleURL.standardizedFileURL.path, userInfo: requester.isEmpty ? nil : requester, deliverImmediately: true)
        print(L10n.text("Запрос отправлен. Приложение перезапустится после завершения задач. Доставка не подтверждена; не повторяйте запрос автоматически.",
                        "Request sent. The app will restart after tasks finish. Delivery is not acknowledged; do not automatically retry."))
        if !requester.isEmpty {
            print(L10n.text("Если этот чат принадлежит Switchboard, после перезапуска он получит сообщение о продолжении задачи.",
                            "If this chat belongs to Switchboard, it will receive a message to continue the task after the restart."))
        }
        return true
    }
}

@MainActor final class AppRestartController: NSObject, ObservableObject {
    private weak var delegate: AppDelegate?
    private var timer: Timer?
    @Published private(set) var requested = false
    var terminating = false
    /// True only while the idle timer calls terminate(); a user's Cmd+Q is a plain quit even with a request pending.
    private(set) var restartingNow = false
    @Published private(set) var continuationChatIDs: [String] = [] {
        didSet { delegate?.model?.restartWaitingChatIDs = continuationChatIDs }
    }
    /// Why the app is not idle yet; refreshed by the restart timer.
    @Published private(set) var blockers: [String] = []
    /// Titles captured at request time, shown in the restart menu.
    private(set) var continuationTitles: [String: String] = [:]

    // Positional arguments keep bundle paths out of shell source. Never kill or reopen a live owner.
    nonisolated static let helperScript = """
    count=0
    while /bin/kill -0 "$1" 2>/dev/null; do
        count=$((count + 1))
        if [ "$count" -ge 120 ]; then exit 1; fi
        /bin/sleep 1
    done
    /usr/bin/open "$2"
    """

    func start(delegate: AppDelegate) {
        self.delegate = delegate
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: RestartCommand.notification, object: Bundle.main.bundleURL.standardizedFileURL.path)
    }

    @objc private func receive(_ notification: Notification) {
        record(requester: notification.userInfo, chats: delegate?.model?.state.chats ?? [])
    }

    /// Several chats may ask before the app becomes idle; each one is continued after the single restart.
    func record(requester info: [AnyHashable: Any]?, chats: [Chat]) {
        guard !terminating else { return }
        if let chat = RestartContinuation.chatID(requestedBy: info, in: chats), !continuationChatIDs.contains(chat) {
            continuationTitles[chat] = chats.first { $0.id == chat }?.title
            continuationChatIDs.append(chat)
        }
        enqueueRestart()
    }

    func enqueueRestart() {
        guard !requested, !terminating else { return }
        requested = true
        // Leave the requesting tool time to return before examining the host's busy state.
        // terminate() must run from the run loop, not from a main-actor job: with .terminateLater it
        // spins a nested run loop until the delegate's Task replies, and that Task cannot start
        // while the serial main queue is still inside the job that called terminate().
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfIdle() }
        }
    }

    func cancel() {
        guard !terminating else { return }
        requested = false; timer?.invalidate(); timer = nil
        continuationChatIDs = []; continuationTitles = [:]; blockers = []
    }

    /// Written only once the restart is certain, so a cancelled request never continues a chat later.
    func saveContinuation() {
        guard !continuationChatIDs.isEmpty else { return }
        do { try RestartContinuation(chatIDs: continuationChatIDs, requestedAt: Date()).save() }
        catch { AppLog.lifecycle.error("Restart continuation not saved: \(error.localizedDescription, privacy: .public)") }
    }

    private func restartIfIdle() {
        guard requested, !terminating, let model = delegate?.model else { return }
        let reasons = model.restartBlockers
        if reasons != blockers { blockers = reasons }
        guard model.readyForRestart else { return }
        // applicationShouldTerminate runs synchronously inside terminate().
        restartingNow = true
        defer { restartingNow = false }
        NSApplication.shared.terminate(nil)
    }

    func launchHelper() throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", FileManager.default.isExecutableFile(
            atPath: bundle.appendingPathComponent("Contents/MacOS/Switchboard").path) else { throw RestartFailure.unavailable }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", Self.helperScript, "contextdesk-relaunch",
                            String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        timer?.invalidate(); timer = nil
    }
}

extension DeskModel {
    var readyForRestart: Bool {
        !isBootstrapping && !anyBusy && !connecting && !claudeConnecting && pending.isEmpty && !hasDeliverableQueue && backgroundWorkChatIDs.isEmpty
    }
    /// Idle chats whose agent still runs background tasks or sub-agents; a restart would end that work.
    /// Running sub-agents also cover the gap between a turn's completion and its background-wait report.
    var backgroundWorkChatIDs: Set<String> {
        Set(backgroundWaits.keys).union(subagents.filter { $0.value.contains { $0.status == .running } }.keys)
    }
}
