import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications
import ContextCore

extension AppLog {
    static let pullRequests = Logger(subsystem: subsystem, category: "pull-requests")
}

/// Pull request status per folder + branch for the branch badges, and the opt-in per-chat PR watch.
///
/// No free-running timer for the badges: a branch is looked up when its git status changes in a way that matters
/// for a PR (branch, commit, upstream, ahead/behind, e.g. after a push), and on explicit occasions (selection,
/// app activation, turn end), at most once per 60 s per folder + branch. Only watched PRs are polled, every
/// 3 minutes by the wall clock, and polling stops once nothing is watched. `gh` runs off the main actor; without
/// `gh`, a GitHub remote or a sign-in there is simply no badge (logged once).
@MainActor @Observable final class PullRequestStore {
    private(set) var statuses: [String: PullRequestStatus] = [:]
    private(set) var watchState = PullRequestWatchState()
    /// Alerts whose "Send to agent" is collecting logs.
    private(set) var sending: Set<UUID> = []

    @ObservationIgnored private let store: PullRequestWatchStore
    @ObservationIgnored private let gitHub: () -> GitRunner?
    @ObservationIgnored private(set) var throttle = RefreshThrottle(interval: 60)
    /// The git state each branch was last looked up at; an unchanged one needs no new lookup.
    @ObservationIgnored private var fingerprints: [String: String] = [:]
    @ObservationIgnored private var latestGit: [String: (folder: String, git: GitStatus)] = [:]
    @ObservationIgnored private var trailing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var notGitHubUntil: [String: Date] = [:]
    @ObservationIgnored private var signedOutUntil: Date?
    @ObservationIgnored private var logged: Set<String> = []
    @ObservationIgnored private var viewer: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollGeneration = UUID()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Receives the alerts each poll creates (notifications, dock badge).
    @ObservationIgnored var onAlerts: ([PullRequestAlert]) -> Void = { _ in }
    @ObservationIgnored var chatExists: (String) -> Bool = { _ in true }
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Tests drive `pollDue` themselves.
    @ObservationIgnored var pollsAutomatically = true
    /// Lookups started, for tests.
    @ObservationIgnored private(set) var lookups = 0

    init(file: URL, gitHub: @escaping () -> GitRunner? = { GitRunner.gitHub() }, interval: TimeInterval = 60) {
        store = PullRequestWatchStore(file: file)
        self.gitHub = gitHub
        throttle = RefreshThrottle(interval: interval)
    }

    static func key(folder: String, branch: String) -> String { folder + "\n" + branch }

    func status(folder: String?, branch: String?) -> PullRequestStatus? {
        guard let folder, let branch else { return nil }
        return statuses[Self.key(folder: folder, branch: branch)]
    }

    var openAlerts: [PullRequestAlert] { watchState.openAlerts.filter { chatExists($0.chatID) } }
    func watch(chatID: String?) -> PullRequestWatch? { chatID.flatMap { watchState.watch(chatID: $0) } }

    // MARK: Badge lookups

    /// Looks the folder's branch up. `explicit` occasions (selection, activation, turn end) look up whenever
    /// the throttle allows; a git status read does so only when the branch, commit, upstream or ahead/behind
    /// changed, and if that happens inside the throttle window one trailing lookup follows at its end.
    func considerLookup(folder: String, git: GitStatus, explicit: Bool) {
        // A branch without an upstream was never pushed, so it cannot have a PR yet.
        guard let branch = git.branch, git.upstream != nil else { return }
        let key = Self.key(folder: folder, branch: branch), current = now()
        let fingerprint = [branch, git.upstream ?? "", git.commit ?? "", "\(git.ahead)", "\(git.behind)"].joined(separator: "|")
        let changed = fingerprints[key] != fingerprint
        guard explicit || changed else { return }
        if let until = notGitHubUntil[folder], until > current { return }
        if let until = signedOutUntil, until > current { return }
        latestGit[key] = (folder, git)
        if throttle.admit(key, now: current) {
            fingerprints[key] = fingerprint
            trailing.removeValue(forKey: key)?.cancel()
            lookup(folder: folder, branch: branch, key: key)
        } else if changed, trailing[key] == nil, let next = throttle.nextAllowed(key, now: current) {
            let delay = max(0, next.timeIntervalSince(current)) + 0.1
            trailing[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.trailing[key] = nil
                if let latest = self.latestGit[key] { self.considerLookup(folder: latest.folder, git: latest.git, explicit: true) }
            }
        }
    }

    private func lookup(folder: String, branch: String, key: String) {
        guard let runner = gitHub() else {
            logOnce("gh-missing", "GitHub CLI (gh) not found; pull request status is off")
            return
        }
        lookups += 1
        Task { [weak self] in
            let outcome = await Task.detached { await PullRequestLookup.view(branch, in: folder, runner: runner) }.value
            self?.apply(outcome, key: key, folder: folder)
        }
    }

    func apply(_ outcome: PullRequestLookup.Outcome, key: String, folder: String) {
        switch outcome {
        case .found(let status, _):
            if statuses[key] != status { statuses[key] = status }
        case .none:
            if statuses[key] != nil { statuses[key] = nil }
        case .notGitHub:
            notGitHubUntil[folder] = now().addingTimeInterval(30 * 60)
            if statuses[key] != nil { statuses[key] = nil }
            logOnce("not-github:" + folder, "No GitHub remote in a project folder; pull request status is off for it")
        case .signedOut:
            signedOutUntil = now().addingTimeInterval(10 * 60)
            logOnce("signed-out", "gh is not signed in; pull request status is off")
        case .failed(let message):
            AppLog.pullRequests.debug("PR lookup failed: \(message, privacy: .public)")
        }
    }

    private func logOnce(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        AppLog.pullRequests.notice("\(message, privacy: .public)")
    }

    // MARK: Watch

    func load() async {
        do { watchState = try await store.load() }
        catch { AppLog.pullRequests.error("Could not read the PR watch file: \(error.localizedDescription, privacy: .public)") }
        schedulePolling()
    }

    func startWatching(chatID: String, folder: String, status: PullRequestStatus) async {
        let started = now()
        await update { $0.startWatching(chatID: chatID, folder: folder, status: status, now: started) }
        schedulePolling()
    }

    func stopWatching(chatID: String) async {
        await update { $0.stopWatching(chatID: chatID) }
        schedulePolling()
    }

    func resolve(_ id: UUID) async { await update { $0.resolve(id) } }
    func clearResolved() async { await update { $0.clearResolved() } }
    func forget(chatID: String) async { await update { $0.forget(chatID: chatID) }; schedulePolling() }
    func markSent(_ id: UUID) async -> Bool { await update { $0.markSent(id) } ?? false }
    func setSending(_ id: UUID, _ value: Bool) { if value { sending.insert(id) } else { sending.remove(id) } }

    @discardableResult
    private func update<T: Sendable>(_ change: @escaping @Sendable (inout PullRequestWatchState) -> T) async -> T? {
        do {
            let (state, result) = try await store.update(change)
            if watchState != state { watchState = state }
            return result
        } catch {
            AppLog.pullRequests.error("Could not save the PR watch file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Polls only while something is watched; the loop sleeps until the earliest due poll by the wall clock,
    /// so a poll missed during sleep runs right after wake.
    private func schedulePolling() {
        guard pollsAutomatically else { return }
        guard !watchState.watches.isEmpty else {
            pollTask?.cancel(); pollTask = nil
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
            return
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // Give the network a moment after wake, then look at what is due.
                Task { @MainActor in self?.restartPolling(after: .seconds(15)) }
            }
        }
        if pollTask == nil { restartPolling(after: .zero) }
    }

    private func restartPolling(after delay: Duration) {
        pollTask?.cancel()
        guard !watchState.watches.isEmpty else { pollTask = nil; return }
        let generation = UUID()
        pollGeneration = generation
        pollTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await self?.pollLoop()
            if let self, self.pollGeneration == generation { self.pollTask = nil }
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            guard let next = watchState.nextPoll else { return }
            let wait = next.timeIntervalSince(now())
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(min(wait, PullRequestWatchState.pollInterval))) } catch { return }
                continue
            }
            await pollDue()
        }
    }

    func pollDue() async {
        let current = now()
        let due = watchState.due(now: current)
        guard !due.isEmpty else { return }
        guard let runner = gitHub() else {
            logOnce("gh-missing", "GitHub CLI (gh) not found; pull request status is off")
            for watch in due { await update { $0.pollFailed(chatID: watch.chatID, now: current) } }
            return
        }
        for watch in due {
            guard chatExists(watch.chatID), FileManager.default.fileExists(atPath: watch.folder) else {
                await update { $0.stopWatching(chatID: watch.chatID) }
                continue
            }
            let folder = watch.folder
            if viewer == nil { viewer = await Task.detached { await PullRequestLookup.viewer(in: folder, runner: runner) }.value }
            let viewer = viewer, number = String(watch.number)
            let outcome = await Task.detached {
                await PullRequestLookup.view(number, in: folder, runner: runner, activity: true, viewer: viewer)
            }.value
            let polled = now()
            switch outcome {
            case .found(let status, let activity):
                let created = await update { $0.apply(chatID: watch.chatID, status: status, activity: activity ?? [], now: polled) } ?? []
                if !status.headRefName.isEmpty { apply(outcome, key: Self.key(folder: folder, branch: status.headRefName), folder: folder) }
                if !created.isEmpty { onAlerts(created) }
            default:
                AppLog.pullRequests.debug("Watched PR #\(watch.number, privacy: .public) poll failed: \(String(describing: outcome), privacy: .public)")
                await update { $0.pollFailed(chatID: watch.chatID, now: polled) }
            }
        }
        if watchState.watches.isEmpty { schedulePolling() }
    }
}

extension DeskModel {
    /// The folder whose pull request a chat shows and watches. Today it is the chat's project folder; the one
    /// place to point at a chat's own working directory.
    func pullRequestFolder(forChat threadID: String) -> String? { projectPath(forChat: threadID) }

    /// The composer's folder: the selected chat's, or the selected project's for a new chat.
    var composerPullRequestFolder: String? {
        chatID.flatMap(pullRequestFolder(forChat:)) ?? selectedProject?.path
    }

    func pullRequestStatus(folder: String?) -> PullRequestStatus? {
        pullRequests.status(folder: folder, branch: gitStatus.status(for: folder)?.branch)
    }

    /// The sidebar project header's tooltip lines: git status, then the branch's PR (the header is display-only,
    /// so the sidebar badge has no popover).
    func projectHeaderDetails(_ path: String) -> String? {
        let lines = [gitStatus.status(for: path).map { GitBranchText.summary($0) }, pullRequestStatus(folder: path).map { PullRequestText.summary($0) }]
            .compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// Wires the PR store to git status reads and loads the watches; called once at launch.
    func startPullRequests() async {
        pullRequests.chatExists = { [weak self] id in self?.state.chats.contains { $0.id == id } ?? false }
        pullRequests.onAlerts = { [weak self] alerts in self?.notifyPullRequestAlerts(alerts) }
        gitStatus.didRead = { [weak self] path, status in self?.pullRequests.considerLookup(folder: path, git: status, explicit: false) }
        // Folders read before this hook existed.
        for (path, status) in gitStatus.statuses { pullRequests.considerLookup(folder: path, git: status, explicit: false) }
        await pullRequests.load()
        refreshDockBadge()
    }

    /// An explicit occasion (selection, activation, turn end) for one folder; throttled per folder + branch.
    func refreshPullRequest(folder: String?) {
        guard let folder, let git = gitStatus.status(for: folder) else { return }
        pullRequests.considerLookup(folder: folder, git: git, explicit: true)
    }

    func togglePullRequestWatch(chatID: String) async {
        if pullRequests.watch(chatID: chatID) != nil {
            await pullRequests.stopWatching(chatID: chatID); return
        }
        guard let folder = pullRequestFolder(forChat: chatID), let status = pullRequestStatus(folder: folder), status.isOpen else { return }
        await pullRequests.startWatching(chatID: chatID, folder: folder, status: status)
    }

    func resolvePullRequestAlert(_ id: UUID) async {
        await pullRequests.resolve(id)
        removePullRequestNotifications([id])
        refreshDockBadge()
    }

    func clearResolvedPullRequestAlerts() async { await pullRequests.clearResolved() }

    /// Whether "Send to agent" can queue into the alert's chat now.
    func canSendPullRequestAlert(_ alert: PullRequestAlert) -> Bool {
        alert.canSendToAgent && !pullRequests.sending.contains(alert.id) && !isArchived(alert.chatID) && chatIsAvailable(alert.chatID)
    }

    /// Queues ONE message to the alert's chat through the normal queue: the failing checks with an excerpt of the
    /// failed steps' log, or the new reviews and comments, framed as data. Only on the user's click.
    func sendPullRequestAlertToAgent(_ alert: PullRequestAlert) async {
        guard canSendPullRequestAlert(alert) else { return }
        pullRequests.setSending(alert.id, true)
        defer { pullRequests.setSending(alert.id, false) }
        let text: String
        switch alert.kind {
        case .checksFailed:
            var runIDs: [String] = []
            for id in (alert.checks ?? []).compactMap(\.runID) where !runIDs.contains(id) { runIDs.append(id) }
            let folder = alert.folder, wanted = Array(runIDs.prefix(3))
            let logs: [String]
            if let runner = GitRunner.gitHub(timeout: 60) {
                logs = await Task.detached {
                    var collected: [String] = []
                    for id in wanted { if let log = await PullRequestLookup.failedLog(runID: id, in: folder, runner: runner) { collected.append(log) } }
                    return collected
                }.value
            } else { logs = [] }
            text = PullRequestAgentMessage.failingChecks(alert, logs: logs)
        case .newActivity:
            text = PullRequestAgentMessage.activity(alert)
        default:
            return
        }
        // Marking first makes a second click (or a stale copy of the alert) queue nothing.
        guard !isArchived(alert.chatID), chatIsAvailable(alert.chatID), await pullRequests.markSent(alert.id) else { return }
        removePullRequestNotifications([alert.id])
        refreshDockBadge()
        if !queueContinuation(alert.chatID, text: text) {
            error = L10n.text("Не удалось поставить сообщение в очередь этого чата.", "Could not queue the message in this chat.")
        } else {
            AppLog.pullRequests.notice("PR #\(alert.number, privacy: .public) \(alert.kind.rawValue, privacy: .public) sent to its chat on request")
        }
    }

    private func notifyPullRequestAlerts(_ alerts: [PullRequestAlert]) {
        refreshDockBadge()
        // System notifications need an app bundle; headless hosts (tests) keep the "Needs you" item only.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for alert in alerts {
            let chat = state.chats.first { $0.id == alert.chatID }
            let content = UNMutableNotificationContent()
            content.title = "#\(alert.number) \(alert.title)"
            if let chat { content.subtitle = chat.title }
            content.body = PullRequestText.alert(alert)
            content.sound = .default
            // Opens "Needs you", where the alert offers its actions.
            content.userInfo = ["attentionID": alert.id.uuidString, "threadID": alert.chatID]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pull-request:" + alert.id.uuidString, content: content, trigger: nil),
                                                   withCompletionHandler: nil)
        }
    }

    private func removePullRequestNotifications(_ ids: [UUID]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map { "pull-request:" + $0.uuidString })
    }
}
