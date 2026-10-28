import AppKit
import Foundation
import SwiftUI
import UserNotifications
import ContextCore
import AgentContract

struct PendingAction: Identifiable {
    let interaction: AgentInteraction
    let threadID: String
    var id: String { interaction.id.uuidString }
    var title: String {
        if case .questions = interaction.kind { return L10n.text("Нужен твой ответ", "Your input is needed") }
        return L10n.text("Требуется действие", "Action required")
    }
}

struct DeskNotice: Identifiable {
    let id = UUID()
    let threadID: String
    let title: String
    let detail: String
    var completionID: String? = nil
    var actionID: String? = nil
}

private struct ChatRunState {
    var running = false
    var sending = false
    var stopRequested = false
    var turnID: String?
    var queuePaused = true
    var priorityMessageID: String?
    /// The queued message whose "Interrupt and send" stopped the last turn; it goes out with `InterruptedTurnNote`.
    var interruptedFor: String?
    /// Live activity label for the running turn; never persisted.
    var status: String?
}

@MainActor final class DeskModel: ObservableObject {
    let mobileRemote = MobileRemoteHost()
    /// Stops processes that chats leave behind (labelled through the launch environment).
    let orphanProcesses = OrphanProcessController()
    private var remoteDeliveryResults: [String: Bool] = [:]
    private var configuringRemoteChats: Set<String> = []
    /// Chat ID -> last stored messages sent to the phone, keyed by store revision and native session.
    private var remoteHistoryCache: [String: (revision: Int, session: AgentSessionReference?, messages: [TranscriptItem])] = [:]
    @Published var configuringBrowserChats: Set<String> = []
    @Published var newChatBrowserProfiles: [UUID: UUID] = [:]
    /// Chat ID -> PID of its running Chrome for Testing; refreshed by `startBrowserActivityMonitor`.
    @Published var runningBrowserChats: [String: Int32] = [:]
    @Published private(set) var composerFocusRequest: UUID?
    @Published private(set) var plugins: [ProviderPlugin] = []
    @Published private(set) var pluginIssues: [String] = []
    @Published private(set) var pluginStatuses: [String: PluginStatus] = [:]
    @Published private(set) var pluginMessages: [String: String] = [:]
    let pluginDirectory: URL
    private var pluginRuntimes: [String: ProviderPluginRuntime] = [:]
    private var pluginTask: Task<Void, Never>?
    @Published var notices: [DeskNotice] = []
    @Published private(set) var unreadResponseItems: [String: String] = [:]
    private var notifiedTurns: Set<String> = []
    /// The latest answer text per chat during a turn; it becomes the chat's recap when the turn ends.
    private var latestAnswers: [String: String] = [:]
    /// Sends "needs you" waits to the user's Telegram notifier and brings Reply answers back.
    let telegram = TelegramBridge()
    /// Latest messages per chat for the chat directory, reloaded when the chat changes.
    private var directoryHistoryCache: [String: (updated: Date, messages: [TranscriptItem])] = [:]
    @Published var state = SavedState()
    @Published var projectID: UUID?
    @Published var chatID: String? {
        didSet { if chatID != oldValue { transcript.cancelPending() } }
    }
    @Published var showingArchive = false
    @Published var archiveViewingChat = false
    @Published var showingJobs = false
    @Published var jobs: [ScheduledJob] = []
    @Published var jobLedger = JobLedger()
    @Published var schedulerReady = false
    let jobStore: JobStore
    @Published var attention = AttentionLedger()
    @Published var showingAttention = false
    /// Lives next to the job ledger, so tests with a temporary job store never touch the user's file.
    let attentionStore: AttentionStore
    var schedulerTask: Task<Void, Never>?
    /// Earliest time the watchdog retries a scheduler that stopped after an error.
    var schedulerRecoveryAfter = Date.distantPast
    var jobTasks: [UUID: Task<Void, Never>] = [:]
    var jobExecutorFactories = AgentIntegrationFactory.scheduled
    var jobExecutors: [UUID: any AgentScheduledExecutor] = [:]
    var schedulerStopping = false
    @Published var archiveSummaries: [String: ArchiveSummaryRecord] = [:]
    @Published var summaryActiveThread: String?
    var summaryTask: Task<Void, Never>?
    let summaryRunner: AgentGenerationRunner
    let claudeSummaryRunner: AgentGenerationRunner
    var titleTasks: [String: Task<Void, Never>] = [:]
    private var titleRunners: [String: AgentGenerationRunner] = [:]
    private var manuallyNamedChatIDs: Set<String> = []
    let summaryResources: URL?
    let summaryExecutable: URL?
    let summaryHome: URL
    let claudeHome: URL
    let transcript = TranscriptPresentation()
    var items: [TranscriptItem] {
        get { transcript.items }
        set { transcript.replace(newValue) }
    }
    @Published var localHistoryNotice: String?
    @Published var routines: [PortableRoutine] = []
    @Published var creatingHandoff = false
    @Published var preparingHandoff = false
    @Published var handoffProgress = ""
    var handoffRunner: AgentGenerationRunner?
    var handoffCancelled = false
    private var historyBackfillTask: Task<Void, Never>?
    private var claudeHistoryBackfillTask: Task<Void, Never>?
    private var historyRefreshTasks: [String: Task<Void, Never>] = [:]
    private var historyEventRevisions: [String: Int] = [:]
    @Published var pending: [PendingAction] = []
    /// Chats that asked for the pending restart; mirrored from AppRestartController for the sidebar.
    @Published var restartWaitingChatIDs: [String] = []
    @Published var usage: [String: UsageSnapshot] = [:]
    @Published var models: [AgentModelInfo] = []
    @Published var draftEffort = "medium"
    var effort: String {
        get {
            guard let chat = selectedChat else { return draftEffort }
            return chat.effort ?? "medium"
        }
        set {
            if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
                state.chats[index].effort = newValue
                persist()
            } else { draftEffort = newValue }
        }
    }
    private var newChatDrafts: [UUID: String] = [:]
    private var chatDrafts: [String: String] = [:]
    @Published var draft = "" {
        didSet {
            if let chatID {
                chatDrafts[chatID] = draft.isEmpty ? nil : draft
            } else if let projectID {
                newChatDrafts[projectID] = draft.isEmpty ? nil : draft
            }
        }
    }
    @Published var agentDescriptor: AgentDescriptor?
    @Published var connected = false
    @Published var authenticated = false
    @Published var connecting = false
    @Published private(set) var isBootstrapping = true
    @Published private var runs: [String: ChatRunState] = [:]
    /// Idle chats whose agent still runs background tasks and will resume on its own; thread ID -> task count.
    @Published private(set) var backgroundWaits: [String: Int] = [:]
    /// Thread ID -> sub-agents its agent delegated to (running ones and those finished since the last user message).
    @Published private(set) var subagents: [String: [AgentSubagent]] = [:]
    /// Stop requests in flight, keyed by `stopKey`; their buttons stay disabled until the engine answers.
    @Published private(set) var stoppingTasks: Set<String> = []
    @Published private(set) var deletingChatIDs: Set<String> = []
    @Published private(set) var archivingChatIDs: Set<String> = []
    func isChangingChat(_ id: String) -> Bool { deletingChatIDs.contains(id) || archivingChatIDs.contains(id) || configuringRemoteChats.contains(id) || configuringBrowserChats.contains(id) }
    func isArchived(_ id: String) -> Bool { state.chats.first { $0.id == id }?.isArchived == true }
    var selectedChatIsArchived: Bool { selectedChat?.isArchived == true }
    private var completedTurns: [String: (status: AgentExecutionOutcome, hasError: Bool)] = [:]
    private var currentRunKey: String { chatID ?? "new:" + selectionGeneration.uuidString }
    var sending: Bool { runs[currentRunKey]?.sending == true }
    var busy: Bool { runs[currentRunKey]?.running == true }
    var workingStatus: String? { busy ? runs[currentRunKey]?.status : nil }
    var workingSince: Date? { busy ? runs[currentRunKey]?.turnID.flatMap { turnStarts[currentRunKey + ":" + $0] } : nil }
    var queuePaused: Bool { runs[currentRunKey]?.queuePaused ?? true }
    var priorityMessageID: String? { runs[currentRunKey]?.priorityMessageID }
    var anyBusy: Bool { preparingHandoff || creatingHandoff || jobLedger.runs.contains { $0.status.active } || summaryTask != nil || !deletingChatIDs.isEmpty || !archivingChatIDs.isEmpty || runs.values.contains { $0.running || $0.sending } }
    func isBusy(threadID: String) -> Bool { runs[threadID]?.running == true }
    /// Live activity label and start of a chat's running turn, for the notch island.
    func runActivity(threadID: String) -> (status: String?, since: Date?) {
        guard let run = runs[threadID], run.running else { return (nil, nil) }
        return (run.status, run.turnID.flatMap { turnStarts[threadID + ":" + $0] })
    }
    /// An idle chat whose agent will continue on its own once its background tasks finish.
    func backgroundWaitNotice(_ threadID: String) -> String? {
        guard !isBusy(threadID: threadID), let count = backgroundWaits[threadID] else { return nil }
        return L10n.text("Агент ждёт фоновые задачи (\(count)) и продолжит сам, когда они завершатся. Писать можно как обычно.",
                         "The agent is waiting for background tasks (\(count)) and will continue on its own when they finish. You can still write as usual.")
    }
    static func stopKey(threadID: String, task: String?) -> String { threadID + ":" + (task ?? "*") }
    /// Stops one background task or sub-agent of a chat (`task`), or all of them (`nil`). The request is sent once.
    func stopBackgroundTasks(threadID: String, task: String? = nil) async {
        let key = Self.stopKey(threadID: threadID, task: task)
        guard stoppingTasks.insert(key).inserted else { return }
        defer { stoppingTasks.remove(key) }
        do { try await clientForChat(threadID).stopTasks(task, session: sessionForChat(threadID)) }
        catch { self.error = error.localizedDescription }
    }
    private var turnStarts: [String: Date] = [:]
    private var tokenTotals: [String: TokenCounters] = [:]
    private var turnTokens: [String: ResponseTokenTracker] = [:]
    private func resetRuns() {
        runs.removeAll(); turnStarts.removeAll(); tokenTotals.removeAll(); turnTokens.removeAll()
    }
    @Published var loadingChat = false
    @Published var accountLabel = L10n.text("Вход не выполнен", "Not signed in")
    @Published var error: String?
    @Published private(set) var accountLimits: AccountLimits?
    @Published private(set) var limitsError: String?
    @Published private(set) var refreshingLimits = false
    private var limitsRequestID: UUID?
    @Published private(set) var claudeLimits: AccountLimits?
    @Published private(set) var claudeLimitsError: String?
    @Published private(set) var refreshingClaudeLimits = false
    private var claudeLimitsRequestID: UUID?
    @Published var notificationStatus = L10n.text("Уведомления не включены", "Notifications are off")
    private var loadedThreads: Set<String> = []
    private var eventTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var booted = false
    let connection: AgentClient
    let claudeConnection: AgentClient
    @Published var claudeConnected = false
    @Published var claudeAuthenticated = false
    @Published var claudeConnecting = false
    @Published var claudeDescriptor: AgentDescriptor?
    private var claudeEventTask: Task<Void, Never>?
    let store: AppStore
    /// Every capability use and permission decision (roles plan, Phase 0); writes never block a decision.
    let capabilityLedger: CapabilityLedger
    init(connection: any AgentIntegration = AgentIntegrationFactory.codex(), claudeIntegration: any AgentIntegration = AgentIntegrationFactory.claude(), store: AppStore = AppStore(file: Locations.root.appendingPathComponent("metadata.sqlite")),
         capabilityLedger: CapabilityLedger = CapabilityLedger(file: Locations.root.appendingPathComponent("capability-ledger.sqlite")),
         pluginDirectory: URL = PluginCatalog.defaultDirectory,
         summaryResources: URL? = Bundle.main.resourceURL?.appendingPathComponent("Skills"),
         summaryExecutable: URL? = nil, summaryHome: URL = Locations.codexHome, claudeHome: URL = Locations.claudeHome,
         jobStore: JobStore = JobStore(file: Locations.root.appendingPathComponent("scheduled-jobs.json"))) {
        self.jobStore = jobStore
        self.attentionStore = AttentionStore(file: jobStore.file.deletingLastPathComponent().appendingPathComponent("attention.json"))
        self.connection = AgentClient(integration: connection)
        self.claudeConnection = AgentClient(integration: claudeIntegration)
        self.summaryRunner = AgentGenerationRunner(integration: connection)
        self.claudeSummaryRunner = AgentGenerationRunner(integration: claudeIntegration)
        self.claudeHome = claudeHome
        self.store = store
        self.capabilityLedger = capabilityLedger
        self.pluginDirectory = pluginDirectory
        self.summaryResources = summaryResources; self.summaryExecutable = summaryExecutable; self.summaryHome = summaryHome
        refreshPlugins()
    }

    var selectedProject: Project? { state.projects.first { $0.id == projectID } }
    var selectedChat: Chat? { state.chats.first { $0.id == chatID } }
    var chats: [Chat] { projectID.map { state.orderedChats(projectID: $0, archived: false) } ?? [] }
    var currentAction: PendingAction? { pending.first { $0.threadID == chatID } }
    var currentUsage: UsageSnapshot? { chatID.flatMap { usage[$0] } }
    var canSend: Bool { (selectedChat?.isScheduledRecord != true || !busy) && !creatingHandoff && (chatID.map { chatIsAvailable($0) } ?? ([.originalCodex, .appClaude].contains(currentAgent))) && !selectedChatIsArchived && !isChangingChat(currentRunKey) && routeIsAvailable(currentRoute) && currentAgentConnected && currentAgentAuthenticated && selectedProject != nil && !sending && !loadingChat && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var supportedEfforts: [String] {
        models.first { $0.id == currentModel }?.efforts ?? []
    }

    private var photoCleanupTask: Task<Void, Never>?
    private func cleanTemporaryPhotos() {
        guard photoCleanupTask != nil else { return }
        let active = Set(runs.filter { $0.value.running || $0.value.sending }.map(\.key))
            .union(pending.map(\.threadID))
        do { try MobilePhotoRetention.sweep(root: Locations.root.appendingPathComponent("mobile-photos"), activeChats: active) }
        catch { self.error = L10n.text("Не удалось очистить временные фотографии: ", "Could not clean up temporary photos: ") + error.localizedDescription }
    }
    func boot() async {
        guard !booted else { return }; booted = true
        // Each step's duration is logged so a slow launch names the step that held it up.
        let clock = ContinuousClock(); var mark = clock.now
        func step(_ name: String) {
            let elapsed = mark.duration(to: clock.now); mark = clock.now
            AppLog.lifecycle.notice("Boot step: \(name, privacy: .public) took \(Int(elapsed / .milliseconds(1)), privacy: .public) ms")
        }
        defer { isBootstrapping = false; step("rest") }
        do { state = try await store.load(); usage = try await store.loadUsage(); projectID = state.visibleProjects.first?.id } catch { self.error = error.localizedDescription; return }
        if state.migrateRoles() { persist() }
        // Sign the cookie-import consent files once, when the signing key is first created (audit H2).
        do {
            let signed = try ChromeSessionImportPolicy.adoptExistingPolicies()
            if !signed.isEmpty { AppLog.browser.notice("Signed \(signed.count, privacy: .public) existing cookie-import permission files") }
        } catch { AppLog.browser.error("Could not sign cookie-import permission files: \(error.localizedDescription, privacy: .public)") }
        Task { [capabilityLedger] in try? await capabilityLedger.sweep() }
        photoCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.cleanTemporaryPhotos()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        step("state"); startBrowserActivityMonitor()
        orphanProcesses.start()
        await restoreSummaryQueue(); step("summary queue")
        for chat in state.chats where chat.hasUnreadResponse {
            let project = state.projects.first { $0.id == chat.projectID }
            notices.append(DeskNotice(threadID: chat.id, title: L10n.text("Непрочитанный ответ", "Unread response"),
                                      detail: [project?.name, chat.title].compactMap { $0 }.joined(separator: " · "),
                                      completionID: chat.unreadCompletionID))
        }
        await refreshJobs(); step("jobs")
        await loadAttention()
        await connection.observeEvents(sessions: state.chats.compactMap(\.nativeSession))
        eventTask = Task { [weak self, connection] in
            for await event in connection.events { await self?.receive(event) }
        }
        claudeEventTask = Task { [weak self, claudeConnection] in
            for await event in claudeConnection.events { await self?.receiveClaude(event) }
        }
        await connect(); step("Codex")
        // Claude scheduled tasks run in the app's Claude profile, so enabled ones need it connected too.
        let claudeJobs = (try? await jobStore.load())?.jobs.contains { $0.engine == .claude && $0.enabled } == true
        if state.defaultConnection == .appClaude || claudeJobs || state.chats.contains(where: { $0.nativeSession?.connection == .appClaude }) { await connectClaude() }
        step("Claude"); await startScheduler(); step("scheduler")
        Task { await mobileRemote.restoreOnLaunch(model: self) } // Network sign-in must not hold up boot.
        continueAfterRestart(RestartContinuation.take())
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? L10n.text("Уведомления включены", "Notifications are on") : L10n.text("Уведомления не включены", "Notifications are off")
    }
    var defaultRoute: RequestRoute { state.defaultRoute ?? .direct }
    var currentRoute: RequestRoute { selectedChat.map { $0.route ?? .direct } ?? (currentAgent == .appClaude ? .direct : defaultRoute) }
    var neededPluginIDs: Set<String> {
        Set(((state.defaultConnection == .originalCodex ? [defaultRoute] : []) + state.chats.filter { chatIsAvailable($0.id) }.compactMap(\.route)).filter { $0 != .direct }.map(\.rawValue))
    }
    var availableRoutes: [RequestRoute] {
        [.direct] + Set(plugins.map(\.route) + [defaultRoute, currentRoute] + state.chats.compactMap(\.route))
            .filter { $0 != .direct }.sorted { $0.rawValue < $1.rawValue }
    }
    func routeTitle(_ route: RequestRoute, language: AppLanguage = L10n.language) -> String {
        if route == .direct { return L10n.text("Без плагина", "No plugin", language: language) }
        return plugins.first(where: { $0.id == route.rawValue })?.manifest.localizedTitle(language: language)
            ?? L10n.text("\(route.rawValue) (не установлен)", "\(route.rawValue) (not installed)", language: language)
    }
    func routeCompatibilityIssue(_ route: RequestRoute, agent: AgentID = .codex) -> String? {
        if route == .direct { return nil }
        guard let plugin = plugins.first(where: { $0.id == route.rawValue }) else {
            return L10n.text("Плагин не установлен. Сохранённый маршрут не заменён.", "Plugin is not installed. The saved route has not been replaced.")
        }
        return OptimizerCompatibility.issue(agent: agent, requirements: plugin.manifest.requirements)
    }
    func routeIsAvailable(_ route: RequestRoute) -> Bool {
        route == .direct || (routeCompatibilityIssue(route) == nil && pluginStatuses[route.rawValue] != nil)
    }
    func routeMessage(_ route: RequestRoute, language: AppLanguage = L10n.language) -> String {
        if route == .direct { return L10n.text("Codex работает напрямую, без обработки запросов плагином.", "Codex works directly, without a plugin processing requests.", language: language) }
        if let plugin = plugins.first(where: { $0.id == route.rawValue }),
           let issue = OptimizerCompatibility.issue(agent: .codex, requirements: plugin.manifest.requirements, language: language) { return issue }
        if connecting && neededPluginIDs.contains(route.rawValue) {
            return L10n.text("Подключение…", "Connecting…", language: language)
        }
        if let status = pluginStatuses[route.rawValue] { return status.localizedDetail(language: language) }
        if let message = pluginMessages[route.rawValue] { return message }
        guard plugins.contains(where: { $0.id == route.rawValue }) else {
            return L10n.text("Плагин не установлен. Выбор для этого чата сохранён.", "Plugin is not installed. This chat's selection has been preserved.", language: language)
        }
        return neededPluginIDs.contains(route.rawValue)
            ? L10n.text("Установлен. Нажми «Применить выбор», чтобы подключить.", "Installed. Click Apply selection to connect.", language: language)
            : L10n.text("Установлен, но не используется.", "Installed, but not in use.", language: language)
    }
    func refreshPlugins() {
        guard !anyBusy, !connecting else { return }
        let catalog = PluginCatalog.scan(directory: pluginDirectory)
        plugins = catalog.plugins; pluginIssues = catalog.issues
    }
    func selectDefaultRoute(_ route: RequestRoute) { state.defaultRoute = route; persist() }
    func selectBrowserEnabled(_ enabled: Bool) { state.browserEnabled = enabled; persist() }
    /// Applied by reconnecting Claude; while a Claude chat is busy it waits for the next reconnect.
    /// Read at every send; a changed advisor relaunches the chat's CLI on its next message.
    func selectClaudeAdvisor(_ advisor: String) {
        state.claudeAdvisor = advisor.isEmpty ? nil : advisor; persist()
    }
    func selectUserChromeEnabled(_ enabled: Bool) {
        state.userChromeEnabled = enabled; persist()
        if claudeConnected { Task { await connectClaude() } }
    }
    private func stopPlugins() async {
        pluginTask?.cancel(); pluginTask = nil
        for runtime in pluginRuntimes.values { await runtime.stop() }
        pluginRuntimes.removeAll(); pluginStatuses.removeAll()
    }
    func connect() async {
        guard !connecting, !anyBusy else { return }
        refreshPlugins()
        connecting = true; connected = false
        clearLimits()
        defer { connecting = false }
        await connection.stop(); resetAgentState(.originalCodex)
        await stopPlugins()
        pluginMessages.removeAll()
        let optimizerEnvironment: [String: String]
        do { optimizerEnvironment = try await connection.integration.optimizerEnvironment(home: Locations.codexHome).value() }
        catch { self.error = error.localizedDescription; return }
        var optimizers: [AgentOptimizerEndpoint] = []
        for id in neededPluginIDs.sorted() {
            guard let plugin = plugins.first(where: { $0.id == id }) else {
                pluginMessages[id] = L10n.text("Плагин не установлен. Установи его и нажми «Применить выбор».", "Plugin is not installed. Install it, then click Apply selection.")
                continue
            }
            let runtime = ProviderPluginRuntime(plugin: plugin, environment: optimizerEnvironment)
            if let issue = OptimizerCompatibility.issue(agent: .codex, requirements: plugin.manifest.requirements) {
                pluginMessages[id] = issue; continue
            }
            do {
                let endpoint = try await runtime.start()
                let status = try await runtime.status()
                optimizers.append(.init(id: plugin.id, endpoint: endpoint))
                pluginStatuses[id] = status
                pluginRuntimes[id] = runtime
            } catch {
                await runtime.stop()
                pluginMessages[id] = error.localizedDescription
            }
        }
        do {
            agentDescriptor = try await connection.start(.init(home: Locations.codexHome, resources: Bundle.main.resourceURL,
                browserEnabled: state.browserEnabled == true, optimizers: optimizers))
            connected = true
            if summaryResources != nil {
                do {
                    try prepareSummarySkills()
                    try await connection.registerWorkflows(at: summarySkillsDirectory)
                } catch { self.error = L10n.text("Не удалось подключить навыки рутин: ", "Could not load routine skills: ") + error.localizedDescription }
            }
            clearConnectionError()
            await refreshAccount()
            startHistoryBackfill()
            if !pluginRuntimes.isEmpty {
                pluginTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self else { return }
                        for id in self.pluginRuntimes.keys.sorted() {
                            guard let runtime = self.pluginRuntimes[id] else { continue }
                            do {
                                let status = try await runtime.status()
                                guard !Task.isCancelled else { return }
                                self.pluginStatuses[id] = status
                            } catch {
                                guard !Task.isCancelled else { return }
                                self.pluginStatuses[id] = nil
                                self.pluginMessages[id] = error.localizedDescription
                                await runtime.stop()
                                self.pluginRuntimes[id] = nil
                                let affected = self.state.chats.filter { $0.route?.rawValue == id }
                                for chat in affected { self.runs[chat.id, default: ChatRunState()].queuePaused = true }
                                if affected.contains(where: { self.isBusy(threadID: $0.id) }) {
                                    await self.connection.stop()
                                    self.connected = false
                                    self.resetAgentState(.originalCodex)
                                    self.error = L10n.text("Плагин отключился. Запрос не повторён.", "The plugin disconnected. The request was not retried.")
                                    return
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            connected = false; self.error = error.localizedDescription
            await stopPlugins()
        }
    }
    func refreshAccount() async {
        do {
            let result = try await connection.account()
            clearConnectionError()
            authenticated = result.authenticated
            accountLabel = authenticated ? L10n.text("ChatGPT · \(result.plan ?? "подключён")", "ChatGPT · \(result.plan ?? "connected")") : L10n.text("Вход не выполнен", "Not signed in")
            if authenticated { await refreshModels(); await refreshLimits(); startSummaryQueue() }
            else { clearLimits() }
        } catch let failure as AgentOperationFailure where failure.rejection == .staleContext {
            // An account event superseded this metadata request. Never publish its obsolete result.
            return
        } catch { self.error = error.localizedDescription }
    }
    // A successful server response makes an earlier transport warning obsolete.
    // Keep unrelated errors (for example, persistence failures) visible.
    private func clearConnectionError() {
        guard let error else { return }
        let transportErrors = [
            L10n.text("Движок недоступен. Подключись заново.", "The engine is unavailable. Reconnect."),
            L10n.text("Codex не подключён", "Codex is not connected"),
            L10n.text("Соединение закрыто", "Connection closed"),
            L10n.text("Соединение с Codex закрыто", "The connection to Codex is closed"),
            L10n.text("Codex отключился. Подключись заново; отправка не будет повторена автоматически.", "Codex disconnected. Reconnect; the message will not be sent again automatically.")
        ]
        if transportErrors.contains(error) { self.error = nil }
    }
    func login() async {
        do {
            let url = try await connection.signInURL()
            NSWorkspace.shared.open(url)
            accountLabel = L10n.text("Заверши вход в браузере", "Finish signing in in your browser")
        } catch { self.error = error.localizedDescription }
    }
    func logout() async {
        guard !anyBusy else { return }
        do { try await connection.signOut(); authenticated = false; clearLimits(); await refreshAccount() }
        catch { self.error = error.localizedDescription }
    }
    func refreshModels() async {
        do {
            models = try await connection.models()
            if !models.contains(where: { $0.id == state.model }) {
                state.model = (models.first { $0.isDefault } ?? models.first)?.id ?? ""
            }
            persist()
        } catch let failure as AgentOperationFailure where failure.rejection == .staleContext {
            return
        } catch { self.error = error.localizedDescription }
    }
    func selectModel(_ model: String) {
        guard !isChangingChat(currentRunKey) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
            state.chats[index].model = model
            state.chats[index].effort = "medium"
        } else {
            state.model = model
            draftEffort = "medium"
        }
        persist()
    }
    func refreshLimits() async {
        guard connected, authenticated, !refreshingLimits else { return }
        let requestID = UUID()
        limitsRequestID = requestID
        refreshingLimits = true
        limitsError = nil
        defer {
            if limitsRequestID == requestID { refreshingLimits = false; limitsRequestID = nil }
        }
        do {
            let result = try await connection.limits()
            guard limitsRequestID == requestID, authenticated, connected else { return }
            accountLimits = result
        } catch let failure as AgentOperationFailure where failure.rejection == .staleContext {
            return
        } catch {
            guard limitsRequestID == requestID else { return }
            limitsError = accountLimits == nil
                ? L10n.text("Не удалось получить лимиты. Попробуй обновить ещё раз.", "Could not fetch limits. Try refreshing again.")
                : L10n.text("Не удалось обновить лимиты. Показаны последние полученные данные.", "Could not refresh limits. Showing the last available data.")
        }
    }
    private func clearLimits() {
        limitsRequestID = nil
        refreshingLimits = false
        accountLimits = nil
        limitsError = nil
    }
    func refreshClaudeLimits() async {
        guard claudeConnected, claudeAuthenticated, !refreshingClaudeLimits else { return }
        let requestID = UUID()
        claudeLimitsRequestID = requestID
        refreshingClaudeLimits = true
        claudeLimitsError = nil
        defer {
            if claudeLimitsRequestID == requestID { refreshingClaudeLimits = false; claudeLimitsRequestID = nil }
        }
        do {
            let result = try await claudeConnection.limits()
            guard claudeLimitsRequestID == requestID, claudeAuthenticated, claudeConnected else { return }
            claudeLimits = result
        } catch let failure as AgentOperationFailure where failure.rejection == .staleContext {
            return
        } catch let failure as AgentOperationFailure where failure.rejection == .unsupported(.accountLimits) {
            guard claudeLimitsRequestID == requestID else { return }
            claudeLimits = nil
            claudeLimitsError = L10n.text("Claude Code не сообщает лимиты для этого аккаунта. Они доступны только для подписки Claude.", "Claude Code reports no limits for this account. They are available only with a Claude subscription.")
        } catch {
            guard claudeLimitsRequestID == requestID else { return }
            claudeLimitsError = claudeLimits == nil
                ? L10n.text("Не удалось получить лимиты. Попробуй обновить ещё раз.", "Could not fetch limits. Try refreshing again.")
                : L10n.text("Не удалось обновить лимиты. Показаны последние полученные данные.", "Could not refresh limits. Showing the last available data.")
        }
    }
    private func clearClaudeLimits() {
        claudeLimitsRequestID = nil
        refreshingClaudeLimits = false
        claudeLimits = nil
        claudeLimitsError = nil
    }
    func moveProject(_ id: UUID, to targetID: UUID) -> Bool {
        guard state.moveProject(id, to: targetID) else { return false }
        persist()
        return true
    }

    func moveChat(_ id: String, to targetID: String) -> Bool {
        guard !isChangingChat(id), !isChangingChat(targetID), state.moveChat(id, to: targetID) else { return false }
        persist()
        return true
    }

    func toggleChatPin(_ id: String) {
        if state.toggleChatPin(id) { persist() }
    }

    func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = L10n.text("Добавить проект", "Add project")
        panel.message = L10n.text("Выбери папку проекта. Можно выбрать несколько. Повторное добавление скрытого проекта вернёт его чаты.", "Choose a project folder. You can select more than one. Adding a hidden project again restores its chats.")
        guard panel.runModal() == .OK else { return }
        var firstID: UUID?
        for url in panel.urls {
            let id = state.addProject(path: url.path)
            if firstID == nil { firstID = id }
        }
        persist()
        if let firstID { selectProject(firstID) }
    }
    func renameProject(_ id: UUID, to name: String) {
        if state.renameProject(id, to: name) { persist() }
    }
    func hideProject(_ id: UUID) async {
        guard state.hideProject(id) else { return }
        if projectID == id {
            projectID = state.visibleProjects.first?.id
            newChat()
        }
        do { try await store.save(state) } catch { self.error = error.localizedDescription }
    }
    func openArchive() {
        showingJobs = false; showingAttention = false
        archiveViewingChat = false
        showingArchive = true
    }
    func closeArchive() {
        showingArchive = false
        archiveViewingChat = false
        if selectedChatIsArchived { newChat() }
    }
    func selectProject(_ id: UUID) {
        showingArchive = false; showingAttention = false
        guard projectID != id || chatID != nil else { showingJobs = false; return }
        projectID = id; showingJobs = false
        newChat()
    }
    func newChat() {
        showingArchive = false
        selectionGeneration = UUID(); chatID = nil; items = []; localHistoryNotice = nil
        draft = projectID.flatMap { newChatDrafts[$0] } ?? ""
        showingJobs = false; showingAttention = false; loadingChat = false
        composerFocusRequest = UUID()
    }
    /// A document preview fills the window; the sidebar hides until it collapses.
    @Published var documentExpanded = false
    /// Files dropped anywhere on the chat go into the draft as paths, then the editor takes focus.
    /// Temporary files (a screenshot thumbnail's) are copied first, because their source deletes them after the drop.
    /// Returns keyboard focus to the composer, e.g. after a drag that ended without a drop.
    func focusComposer() { composerFocusRequest = UUID() }
    func addDroppedFiles(_ urls: [URL]) {
        let updated = DroppedFiles.appending(DroppedFiles.preserving(urls, in: DroppedFiles.directory), to: draft)
        guard updated != draft else { return }
        draft = updated
        composerFocusRequest = UUID()
    }
    func openChat(_ chat: Chat) async {
        guard !isChangingChat(chat.id), state.chats.contains(where: { $0.id == chat.id }) else { return }
        transcript.cancelPending()
        showingArchive = isArchived(chat.id)
        archiveViewingChat = showingArchive
        showingJobs = false; showingAttention = false; projectID = chat.projectID; chatID = chat.id; composerFocusRequest = nil
        draft = chatDrafts[chat.id] ?? ""
        let generation = UUID(); selectionGeneration = generation
        defer { if selectionGeneration == generation { loadingChat = false } }
        loadingChat = true; items = []; localHistoryNotice = nil
        do {
            let saved = try await store.loadTranscript(conversationID: chat.id)
            guard selectionGeneration == generation else { return }
            items = saved.map(LocalHistory.items) ?? []
            localHistoryNotice = LocalHistory.notice(saved)
            if saved != nil { loadingChat = false }
        } catch {
            if selectionGeneration == generation { self.error = error.localizedDescription }
        }
        guard selectionGeneration == generation else { return }
        // A scheduled-run record has no engine session; local history is its complete source.
        if chat.isScheduledRecord { localHistoryNotice = nil; return }
        do {
            let eventRevision = historyEventRevisions[chat.id, default: 0]
            let capturedAt = Date()
            let turns = try await clientForChat(chat.id).history(sessionForChat(chat.id))
            guard selectionGeneration == generation else { return }
            let timings = try await store.loadTimings(threadID: chat.id)
            guard selectionGeneration == generation else { return }
            guard historyEventRevisions[chat.id, default: 0] == eventRevision else { return }
            items = turns.flatMap { turn in
                var entries = turn.items
                for index in entries.indices { entries[index].turnID = turn.id }
                ResponseTiming.apply(turn.timing(fallback: timings[turn.id ?? ""]), to: &entries)
                return entries
            }
            let snapshot = try LocalHistory.snapshot(conversation: ConversationID(chat.id),
                source: sessionForChat(chat.id), turns: turns, timings: timings, capturedAt: capturedAt)
            try await store.saveTranscript(snapshot)
            guard selectionGeneration == generation else { return }
            localHistoryNotice = snapshot.completeness == .complete ? nil : LocalHistory.notice(snapshot)
            if let completion = state.chats.first(where: { $0.id == chat.id })?.unreadCompletionID,
               let turn = turns.first(where: { "turn:" + chat.id + ":" + ($0.id ?? "") == completion }) {
                unreadResponseItems[chat.id] = turn.items.last(where: { $0.kind == "assistant" })?.id
            }
        } catch { if selectionGeneration == generation { self.error = error.localizedDescription } }
        if selectionGeneration == generation { loadingChat = false }
    }

    /// Read-only backfill: never resumes sessions, dispatches work or changes the selected chat.
    func backfillHistory(_ chats: [Chat]) async {
        for chat in chats {
            guard !Task.isCancelled else { return }
            guard !chat.isScheduledRecord, chatConnected(chat.id) else { continue }
            guard chatIsAvailable(chat.id), !isBusy(threadID: chat.id),
                  state.chats.contains(where: { $0.id == chat.id }), !isChangingChat(chat.id) else { continue }
            do {
                let capturedAt = Date()
                let session = try sessionForChat(chat.id)
                let turns = try await clientForChat(chat.id).history(session)
                guard !Task.isCancelled else { return }
                let timings = try await store.loadTimings(threadID: chat.id)
                let snapshot = try LocalHistory.snapshot(conversation: ConversationID(chat.id), source: session,
                    turns: turns, timings: timings, capturedAt: capturedAt)
                try await store.saveTranscript(snapshot)
            } catch {
                // Keep the last readable revision; opening the chat exposes any read error.
            }
        }
    }
    private func startHistoryBackfill() {
        historyBackfillTask?.cancel()
        let chats = state.chats
        historyBackfillTask = Task { [weak self] in await self?.backfillHistory(chats) }
    }
    func cancelHandoffPreparation() async {
        handoffCancelled = true
        await handoffRunner?.stop()
    }
    func prepareHandoff(_ chat: Chat) async -> ContextHandoff? {
        guard !preparingHandoff, !creatingHandoff else { return nil }
        preparingHandoff = true; handoffCancelled = false; error = nil
        handoffProgress = L10n.text("Читаю историю чата…", "Reading chat history…")
        defer { preparingHandoff = false; handoffRunner = nil; handoffProgress = "" }
        do {
            if chat.isScheduledRecord { return try await scheduledRecordHandoff(chat, goal: "") }
            guard let source = chat.nativeSession, !isBusy(threadID: chat.id), !isChangingChat(chat.id),
                  runs[chat.id]?.sending != true else {
                throw ClientFailure(L10n.text("Дождись завершения текущего запроса перед передачей контекста.", "Wait for the current request to finish before handing off context."))
            }
            guard chatConnected(chat.id), chatAuthenticated(chat.id) else {
                throw ClientFailure(L10n.text("Агент этого чата не подключён. Подключись и войди, затем повтори.", "This chat's agent is not connected. Connect and sign in, then try again."))
            }
            let client = try clientForChat(chat.id)
            let descriptor = try await client.descriptor()
            guard descriptor.capabilities.contains(.isolatedGeneration) else {
                throw ClientFailure(L10n.text("Этот агент не поддерживает автоматическую подготовку контекста.", "This agent does not support automatic context preparation."))
            }
            let language = L10n.language
            let turns = try await client.history(source)
            let snapshot = try LocalHistory.snapshot(conversation: chat.conversationID, source: source, turns: turns)
            let chunks = try HandoffSummary.chunks(snapshot)
            let runner = AgentGenerationRunner(integration: client.integration)
            handoffRunner = runner
            var summary: HandoffSummary?
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                guard !handoffCancelled else { throw CancellationError() }
                guard try await client.descriptor().context == descriptor.context else { throw ConversationIdentity.unavailable }
                handoffProgress = L10n.text("Готовлю контекст: часть \(index + 1) из \(chunks.count)…", "Preparing context: part \(index + 1) of \(chunks.count)…", language: language)
                summary = try await runner.handoff(source: source,
                    input: HandoffSummary.input(chunk: chunk, previous: summary, completeness: snapshot.completeness),
                    model: generationModel(for: chat), route: chat.route ?? .direct,
                    environment: generationEnvironment(for: chat.id, workspace: ".handoff-workspace"), language: language)
            }
            try Task.checkCancellation()
            guard !handoffCancelled else { throw CancellationError() }
            guard state.chats.contains(where: { $0.id == chat.id && $0.nativeSession == source }),
                  !isBusy(threadID: chat.id), runs[chat.id]?.sending != true, !isChangingChat(chat.id) else {
                throw ClientFailure(L10n.text("Исходный чат изменился во время подготовки контекста. Запрос не повторён.", "The source chat changed during context preparation. The request was not retried."))
            }
            let latest = try LocalHistory.snapshot(conversation: chat.conversationID, source: source, turns: await client.history(source))
            guard latest.revision == snapshot.revision else {
                throw ClientFailure(L10n.text("Переписка изменилась во время подготовки контекста. Запусти передачу ещё раз, когда чат закончит работу.", "The conversation changed during context preparation. Start a new handoff when the chat finishes working."))
            }
            guard !handoffCancelled else { throw CancellationError() }
            guard try await client.descriptor().context == descriptor.context else { throw ConversationIdentity.unavailable }
            return try summary?.applying(to: snapshot, language: language)
        } catch {
            if !handoffCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
            return nil
        }
    }
    /// `model`, `effort`, `role` and `title` override the new chat's defaults (a run record's follow-up keeps its settings).
    func createHandoffChat(_ handoff: ContextHandoff, project: Project, route: RequestRoute, agent: AgentConnectionID = .originalCodex,
                           model: String? = nil, effort: String? = nil, role: String? = nil, title: String? = nil) async -> Bool {
        guard !creatingHandoff else { return false }
        creatingHandoff = true; defer { creatingHandoff = false }
        do {
            guard [.originalCodex, .appClaude].contains(agent),
                  agent == .appClaude ? claudeConnected && claudeAuthenticated : connected && authenticated,
                  state.projects.contains(where: { $0 == project }), routeIsAvailable(route) else {
                throw ConversationIdentity.unavailable
            }
            let client = agent == .appClaude ? claudeConnection : connection
            let descriptor = try await client.descriptor()
            guard descriptor.context.connection == agent, descriptor.capabilities.contains(.interactiveSessions),
                  descriptor.routes.contains(route.agentRoute) else { throw ConversationIdentity.unavailable }
            let prompt = try handoff.prompt()
            let selectedModel = model ?? (agent == .appClaude ? state.claudeModel ?? "" : state.model)
            try await store.saveHandoff(handoff)
            let current = state.projects.first { $0.id == project.id } ?? project
            let resolvedRole = roleCatalog.role(role) ?? current.chatRole(roleCatalog)
            let session = try await client.createSession(projectPath: project.path, permissions: resolvedRole.profile(for: current),
                                                             model: selectedModel, route: route, context: descriptor.context)
            var chat = Chat(session: session, projectID: project.id, title: title ?? String(handoff.goal.prefix(100)), model: selectedModel)
            chat.route = route; chat.handoffOrigin = handoff.origin; chat.effort = effort
            chat.roleID = roleCatalog.role(role)?.id; chat.accessMode = roleCatalog.role(role)?.legacyAccessMode; chat.inheritsProjectAccess = role == nil
            guard !state.chats.contains(where: { $0.nativeSession == session }) else { throw ConversationIdentity.invalidStorage }
            state.chats.append(chat)
            do { try await store.save(state) }
            catch { state.chats.removeAll { $0.id == chat.id }; throw error }
            chatDrafts[chat.id] = prompt
            await openChat(chat)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func loadRoutines() async {
        do { routines = try await store.loadRoutines() } catch { self.error = error.localizedDescription }
    }
    func restoreHandoffDraft() async {
        guard let chat = selectedChat, let origin = chat.handoffOrigin, draft.isEmpty else { return }
        do {
            guard let saved = try await store.loadHandoff(origin.id), saved.origin == origin else { throw ConversationIdentity.invalidStorage }
            let prompt = try saved.prompt()
            guard chatID == chat.id, draft.isEmpty else { return }
            draft = prompt
        } catch { self.error = error.localizedDescription }
    }
    func saveRoutine(_ routine: PortableRoutine) async -> Bool {
        do { routines = try await store.saveRoutine(routine); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func removeRoutine(_ id: UUID) async {
        do { routines = try await store.removeRoutine(id) } catch { self.error = error.localizedDescription }
    }
    private func refreshHistoryAfterTurn(_ id: String) {
        guard let chat = state.chats.first(where: { $0.id == id }) else { return }
        historyRefreshTasks[id]?.cancel()
        historyRefreshTasks[id] = Task { [weak self] in await self?.backfillHistory([chat]) }
    }
    func renameChat(_ id: String, title: String) async {
        guard !isChangingChat(id) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        manuallyNamedChatIDs.insert(id)
        await cancelChatTitle(id)
        do {
            if !isScheduledRecord(id) { try await clientForChat(id).rename(sessionForChat(id), title: title) }
            if let i = state.chats.firstIndex(where: { $0.id == id }) { state.chats[i].title = title; persist() }
        } catch { self.error = error.localizedDescription }
    }
    func canDeleteChat(_ id: String) -> Bool {
        (chatConnected(id) || isScheduledRecord(id)) && state.chats.contains(where: { $0.id == id }) &&
        !isChangingChat(id) && summaryActiveThread != id && !isBusy(threadID: id) &&
        runs[id]?.sending != true && !pending.contains(where: { $0.threadID == id })
    }
    /// Confirms all chats with their agents concurrently, then commits the confirmed ones in one save.
    /// Failures keep the remaining chats and are reported once.
    func archiveChats(_ ids: [String]) async {
        let ids = ids.filter { !isArchived($0) }
        var failures: [String?] = []
        var targets: [(id: String, client: AgentClient, session: AgentSessionReference, record: Bool)] = []
        for id in ids {
            guard canDeleteChat(id), let client = try? clientForChat(id), let session = try? sessionForChat(id) else { failures.append(nil); continue }
            targets.append((id, client, session, isScheduledRecord(id)))
        }
        let targetIDs = Set(targets.map(\.id))
        archivingChatIDs.formUnion(targetIDs)
        for id in targetIDs { runs[id, default: ChatRunState()].queuePaused = true }
        defer { archivingChatIDs.subtract(targetIDs) }
        let results = await withTaskGroup(of: (String, String?).self) { group in
            for target in targets {
                group.addTask {
                    // Scheduled-run records have no engine session to confirm with.
                    if target.record { return (target.id, nil) }
                    do { try await target.client.setArchived(true, session: target.session); return (target.id, nil) }
                    catch { return (target.id, error.localizedDescription) }
                }
            }
            var results: [String: String?] = [:]
            for await (id, failure) in group { results[id] = failure }
            return results
        }
        var confirmed: [String] = []
        for target in targets {
            if let failure = results[target.id] ?? nil {
                failures.append(L10n.text("Не удалось подтвердить архивирование: ", "Could not confirm archiving: ") + failure)
            } else { confirmed.append(target.id) }
        }
        applyArchived(confirmed, archived: true, revealArchive: false)
        await saveArchived(confirmed)
        if selectedChatIsArchived { newChat() }
        if !failures.isEmpty {
            let first = failures.compactMap { $0 }.first
            error = L10n.text("Не удалось заархивировать чатов: \(failures.count) из \(ids.count).", "Could not archive \(failures.count) of \(ids.count) chats.") + (first.map { " " + $0 } ?? "")
        }
    }
    @discardableResult
    func setChatArchived(_ id: String, archived: Bool, revealArchive: Bool = true) async -> Bool {
        guard canDeleteChat(id), isArchived(id) != archived else { return false }
        archivingChatIDs.insert(id)
        runs[id, default: ChatRunState()].queuePaused = true
        defer { archivingChatIDs.remove(id) }
        do {
            if !isScheduledRecord(id) { try await clientForChat(id).setArchived(archived, session: sessionForChat(id)) }
        } catch {
            self.error = (archived ? L10n.text("Не удалось подтвердить архивирование: ", "Could not confirm archiving: ") : L10n.text("Не удалось подтвердить восстановление: ", "Could not confirm restoring: ")) + error.localizedDescription
            return false
        }
        guard state.chats.contains(where: { $0.id == id }) else { return false }
        applyArchived([id], archived: archived, revealArchive: revealArchive)
        await saveArchived([id])
        return true
    }
    /// Applies agent-confirmed status changes in memory. Summaries are never queued here:
    /// they are generated only on explicit request from the archive.
    private func applyArchived(_ ids: [String], archived: Bool, revealArchive: Bool) {
        for id in ids {
            guard let index = state.chats.firstIndex(where: { $0.id == id }) else { continue }
            state.chats[index].archived = archived
            if chatID == id {
                if !archived { archiveViewingChat = false }
                else if revealArchive { openArchive() }
            }
            state.chats[index].sidebarOrder = nil
            loadedThreads.remove(id)
            // A summary from an earlier archive may no longer match the conversation.
            if archived, var record = archiveSummaries[id], record.status == .ready {
                record.status = .stale
                record.issue = L10n.text("Чат восстанавливали из архива, итог может быть устаревшим", "The chat was restored from the archive; the summary may be outdated")
                archiveSummaries[id] = record
            }
        }
    }
    private func saveArchived(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do { try await store.saveArchivingChats(state, summaries: ids.compactMap { archiveSummaries[$0] }) }
        catch { self.error = L10n.text("Статус чата изменён у агента, но не удалось сохранить его в приложении: ", "The chat status changed in the agent, but could not be saved in the app: ") + error.localizedDescription }
    }
    func deleteChat(_ id: String) async {
        guard canDeleteChat(id) else { return }
        deletingChatIDs.insert(id)
        await cancelChatTitle(id)
        let wasPaused = runs[id]?.queuePaused ?? true
        runs[id, default: ChatRunState()].queuePaused = true
        defer { deletingChatIDs.remove(id) }
        do {
            if !isScheduledRecord(id) { try await clientForChat(id).delete(sessionForChat(id)) }
        } catch {
            // Keep the chat and queue on any unconfirmed server result. Never retry deletion.
            runs[id, default: ChatRunState()].queuePaused = true
            self.error = L10n.text("Не удалось подтвердить удаление чата: ", "Could not confirm chat deletion: ") + error.localizedDescription +
                (wasPaused ? "" : L10n.text(" Очередь этого чата приостановлена.", " This chat’s queue is paused."))
            return
        }
        state.chats.removeAll { $0.id == id }
        state.queuedMessages = queuedMessages.filter { $0.threadID != id }
        usage.removeValue(forKey: id)
        archiveSummaries.removeValue(forKey: id)
        chatDrafts.removeValue(forKey: id)
        loadedThreads.remove(id)
        runs.removeValue(forKey: id)
        let notificationIDs = notifiedTurns.filter { $0.hasPrefix(id + ":") }.map { "turn:" + $0 }
        notifiedTurns = notifiedTurns.filter { !$0.hasPrefix(id + ":") }
        completedTurns = completedTurns.filter { !$0.key.hasPrefix(id + ":") }
        notices.removeAll { $0.threadID == id }
        if !notificationIDs.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notificationIDs)
        }
        if chatID == id { newChat() }
        do { try await store.saveDeletingChat(state, threadID: id) }
        catch { self.error = L10n.text("Чат удалён у агента, но не удалось сохранить изменения в приложении: ", "The chat was deleted in the agent, but the change could not be saved in the app: ") + error.localizedDescription }
    }
    var roleCatalog: AgentRoleCatalog { state.roleCatalog }
    /// The role the selected chat runs with, or the project's chat default for a new chat.
    var currentRole: AgentRole {
        guard let project = state.projects.first(where: { $0.id == projectID }) else { return AgentRoleCatalog.preset(AgentRoleID.editor) }
        return selectedChat?.resolvedRole(in: project, catalog: roleCatalog) ?? project.chatRole(roleCatalog)
    }
    var accessMode: AccessMode { currentRole.legacyAccessMode }
    /// nil while the selected chat follows the project default.
    var roleSelection: String? { selectedChat?.inheritsProjectRole == true ? nil : currentRole.id }
    var accessSelection: AccessMode? { roleSelection.map { _ in accessMode } }
    var projectRoleTitle: String {
        let role = state.projects.first { $0.id == projectID }?.chatRole(roleCatalog) ?? AgentRoleCatalog.preset(AgentRoleID.editor)
        return L10n.text("По умолчанию проекта", "Project default") + ": " + role.title
    }
    var projectAccessTitle: String { projectRoleTitle }
    /// Dimensions the current agent can only approximate for the current role; shown, never silently downgraded.
    var roleApproximations: [AgentPermissionDimension] {
        guard let project = state.projects.first(where: { $0.id == projectID }) else { return [] }
        let descriptor = currentAgent == .appClaude ? claudeDescriptor : agentDescriptor
        return descriptor?.permissions.approximations(currentRole.profile(for: project)) ?? []
    }
    var roleApproximationNotice: String {
        let names = roleApproximations.map(Self.dimensionTitle).joined(separator: ", ")
        let agent = currentAgent == .appClaude ? "Claude" : "Codex"
        return L10n.text("\(agent) не может точно применить для роли «\(currentRole.title)»: \(names). Ограничение приближено, не снято.",
                         "\(agent) cannot enforce for the \(currentRole.title) role: \(names). The restriction is approximated, not dropped.")
    }
    static func dimensionTitle(_ dimension: AgentPermissionDimension) -> String {
        switch dimension {
        case .filesystem: L10n.text("файлы", "files")
        case .network: L10n.text("сеть без команд", "network off with shell on")
        case .webSearch: L10n.text("веб-поиск", "web search")
        case .shell: L10n.text("команды", "shell")
        case .projectWrites: L10n.text("запись в проекте", "project writes")
        case .browser: L10n.text("браузер", "browser")
        case .connectors: L10n.text("коннекторы", "connectors")
        case .cookieImport: L10n.text("импорт cookie", "cookie import")
        case .approvals: L10n.text("подтверждения", "approvals")
        case .commandInspection: L10n.text("проверка команд", "command inspection")
        case .subagents: L10n.text("подагенты", "subagents")
        case .scratch: L10n.text("папка research", "research folder")
        }
    }
    /// A chat's role (nil follows the project); for a new chat, the project's chat default. The legacy mode stays in step for the phone.
    func selectRole(_ id: String?) {
        guard !busy, !sending, !isChangingChat(currentRunKey) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
            guard id == nil || roleCatalog.role(id) != nil else { return }
            state.chats[index].roleID = id
            state.chats[index].inheritsProjectAccess = id == nil
            state.chats[index].accessMode = roleCatalog.role(id)?.legacyAccessMode
        } else if let id, let role = roleCatalog.role(id), let index = state.projects.firstIndex(where: { $0.id == projectID }) {
            state.projects[index].chatRoleID = id
            state.projects[index].defaultChatAccessMode = role.legacyAccessMode
        } else { return }
        persist()
    }
    func selectAccessMode(_ mode: AccessMode?) { selectRole(mode?.legacyRoleID) }
    /// Project defaults for chats and jobs plus the declared extra roots; the agent never changes these.
    func updateProjectRoles(_ id: UUID, chatRole: String?, jobRole: String?, extraRoots: [AgentPermissionProfile.Root]?, cookieSites: [String]?,
                            mcpServers: [String: String]? = nil) {
        guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
        if let chatRole, let role = roleCatalog.role(chatRole) {
            state.projects[index].chatRoleID = chatRole; state.projects[index].defaultChatAccessMode = role.legacyAccessMode
        }
        if let jobRole, let role = roleCatalog.role(jobRole), role.id != AgentRoleID.fullOperator {
            state.projects[index].jobRoleID = jobRole; state.projects[index].accessMode = role.legacyAccessMode
        }
        if let extraRoots { state.projects[index].extraRoots = extraRoots.filter { $0.path.hasPrefix("/") } }
        if let cookieSites { state.projects[index].cookieSites = cookieSites.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
        if let mcpServers { state.projects[index].mcpServers = mcpServers.isEmpty ? nil : mcpServers }
        persist()
    }
    var queuedMessages: [QueuedMessage] { state.queuedMessages ?? [] }
    var visibleQueue: [QueuedMessage] { queuedMessages.filter { $0.threadID == chatID } }
    func removeQueuedMessage(_ id: String) {
        guard !runs.values.contains(where: { $0.priorityMessageID == id }) else { return }
        state.queuedMessages = queuedMessages.filter { $0.id != id }
        persist()
    }
    func sendQueuedMessageNow(_ id: String) async {
        guard let message = queuedMessages.first(where: { $0.id == id }), chatIsAvailable(message.threadID), chatConnected(message.threadID),
              !isChangingChat(message.threadID), !isArchived(message.threadID) else { return }
        let thread = message.threadID
        let run = runs[thread] ?? ChatRunState()
        guard !run.sending, run.priorityMessageID == nil,
              !run.running || run.turnID != nil else { return }
        state.queuedMessages = [message] + queuedMessages.filter { $0.id != id }
        persist()
        if !run.running {
            runs[thread, default: ChatRunState()].queuePaused = false
            scheduleQueue(threadID: thread)
            return
        }
        guard let turn = run.turnID else { return }
        runs[thread, default: ChatRunState()].priorityMessageID = id
        runs[thread, default: ChatRunState()].queuePaused = true
        do {
            try await clientForChat(thread).interrupt(sessionForChat(thread), turn: turn)
            // Only matching turn/completed releases this chat's next message.
        } catch {
            if runs[thread]?.priorityMessageID == id {
                runs[thread, default: ChatRunState()].priorityMessageID = nil
                runs[thread, default: ChatRunState()].queuePaused = true
                self.error = error.localizedDescription
            }
        }
    }
    /// Queues the fixed continuation message for chats that requested the restart; it is
    /// delivered like any queued message, with the chat's own model, route and failure handling.
    func continueAfterRestart(_ chatIDs: [String]) {
        var queued: [String] = []
        for id in chatIDs {
            guard let chat = state.chats.first(where: { $0.id == id }), !chat.isArchived, chatIsAvailable(id) else { continue }
            let claude = chat.nativeSession?.connection == .appClaude
            state.queuedMessages = queuedMessages + [QueuedMessage(id: "local-user:" + UUID().uuidString, threadID: id,
                projectID: chat.projectID, text: RestartContinuation.message,
                model: claude ? ClaudeModel.resolved(chat.model) : chat.model,
                effort: claude ? ClaudeEffort.resolved(chat.effort ?? state.claudeEffort) : chat.effort ?? "medium")]
            runs[id, default: ChatRunState()].queuePaused = false
            queued.append(id)
        }
        guard !queued.isEmpty else { return }
        AppLog.lifecycle.notice("Restart continuation queued for \(queued.count, privacy: .public) chat(s)")
        persist()
        for id in queued { scheduleQueue(threadID: id) }
    }
    /// The chat directory server's command line for a chat the user opted in (Claude chats only, plan Phase 5).
    func chatDirectoryArguments(for id: String) -> [String]? {
        guard let chat = state.chats.first(where: { $0.id == id }), chat.chatDirectoryAccess == true,
              chat.nativeSession?.connection == .appClaude,
              let script = Bundle.main.resourceURL?.appendingPathComponent("ChatDirectoryRuntime/server.py"),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return ChatDirectory.serverArguments(script: script.path, snapshot: chatDirectoryFile.path, chat: id)
    }
    var chatDirectoryFile: URL { Locations.root.appendingPathComponent(ChatDirectory.fileName) }
    /// Gives or takes a chat's access to the other chats; it applies from the chat's next message.
    func toggleChatDirectory(_ id: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
        state.chats[index].chatDirectoryAccess = state.chats[index].chatDirectoryAccess == true ? nil : true
        persist()
        Task { await refreshChatDirectory() }
    }
    /// Rewrites the snapshot the chat directory server reads; removes it when no chat has access.
    func refreshChatDirectory(now: Date = Date()) async {
        let file = chatDirectoryFile
        guard state.chats.contains(where: { $0.chatDirectoryAccess == true && !$0.isArchived }) else {
            try? FileManager.default.removeItem(at: file); return
        }
        let attention = Dictionary(attentionChats.map { ($0.chat.id, $0.attention) }, uniquingKeysWith: { first, _ in first })
        var entries: [ChatDirectory.Entry] = []
        for chat in state.chats where !chat.isArchived && !chat.isScheduledRecord {
            let messages: [TranscriptItem]
            if let cached = directoryHistoryCache[chat.id], cached.updated == chat.updated { messages = cached.messages }
            else {
                let history = try? await store.loadTranscript(conversationID: chat.id)
                messages = Array((history.map(LocalHistory.items) ?? []).filter { ["user", "assistant"].contains($0.kind) }.suffix(ChatDirectory.messageCount))
                directoryHistoryCache[chat.id] = (chat.updated, messages)
            }
            let running = isBusy(threadID: chat.id)
            entries.append(.init(id: chat.id, title: chat.title, project: state.projects.first { $0.id == chat.projectID }?.name ?? "",
                                 agent: chat.nativeSession?.connection == .appClaude ? "Claude" : "Codex",
                                 state: ChatDirectory.state(attention[chat.id], running: running), detail: attentionDetail(chat),
                                 activity: running ? runActivity(threadID: chat.id).status : nil, updated: chat.updated,
                                 messages: messages.map { .init(role: $0.kind, text: $0.text) }))
        }
        do { try ChatDirectory.write(.init(generatedAt: now, chats: entries), to: file) }
        catch { AppLog.delivery.error("Chat directory snapshot failed: \(error.localizedDescription, privacy: .public)") }
    }
    /// What waits for the user in a form the Telegram notifier accepts: requests and failed unread turns.
    /// Request details are cut short; the transcript itself never leaves the Mac.
    func telegramWaits() -> [TelegramAlerts.Waiting] {
        var result: [TelegramAlerts.Waiting] = []
        for action in pending {
            guard let chat = state.chats.first(where: { $0.id == action.threadID }), !chat.isArchived else { continue }
            var question = action.title
            if case .questions(let fields) = action.interaction.kind {
                question += "\n" + fields.map { field in
                    field.text + (field.options.isEmpty ? "" : "\n" + field.options.map { "• " + $0.label }.joined(separator: "\n"))
                }.joined(separator: "\n\n")
            } else {
                if let reason = action.interaction.reason, !reason.isEmpty { question += ": " + reason }
                question += "\n" + String(action.interaction.details.prefix(600))
                question += "\n\n" + L10n.text("Одобрить можно только в Switchboard или в приложении на iPhone. Ответ через Reply встанет в очередь чата.",
                                                 "Approve only in Switchboard or the iPhone app. A Reply answer is queued in the chat.")
            }
            result.append(.init(key: TelegramAlerts.key(chatID: chat.id, wait: action.id), chatID: chat.id, job: chat.title, question: question))
        }
        for chat in state.chats where chat.lastTurnFailed == true && chat.hasUnreadResponse && !chat.isArchived {
            let question = L10n.text("Ход завершился ошибкой.", "The turn ended with an error.") + (chat.recap.map { "\n" + $0 } ?? "")
            result.append(.init(key: TelegramAlerts.key(chatID: chat.id, wait: "failed-" + (chat.unreadCompletionID ?? "")),
                                chatID: chat.id, job: chat.title, question: question))
        }
        return result
    }
    /// A Reply from Telegram: answers a single open question it fits, otherwise waits in the chat's queue.
    /// Approvals are never answered from Telegram. Returns false when the reply was not placed.
    func acceptTelegramReply(_ reply: TelegramNotifier.Reply) async -> Bool {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chat = state.chats.first(where: { $0.id == reply.thread }), !chat.isArchived, chatIsAvailable(chat.id) else { return false }
        if let action = pending.first(where: { $0.threadID == chat.id }), case .questions(let fields) = action.interaction.kind,
           fields.count == 1, let field = fields.first, !field.secret,
           let value = field.options.isEmpty ? text : field.options.first(where: { $0.label.caseInsensitiveCompare(text) == .orderedSame })?.label {
            return await answer(action, result: .answers([field.id: value])) == nil
        }
        let claude = chat.nativeSession?.connection == .appClaude
        let message = QueuedMessage(id: "local-user:telegram:" + String(reply.id), threadID: chat.id, projectID: chat.projectID,
            text: L10n.text("Ответ пользователя из Telegram:", "The user's reply from Telegram:") + "\n\n" + text,
            model: claude ? ClaudeModel.resolved(chat.model) : chat.model,
            effort: claude ? ClaudeEffort.resolved(chat.effort ?? state.claudeEffort) : chat.effort ?? "medium")
        guard !queuedMessages.contains(where: { $0.id == message.id }) else { return true }
        state.queuedMessages = queuedMessages + [message]
        do { try await store.save(state) } catch {
            state.queuedMessages = queuedMessages.filter { $0.id != message.id }
            return false
        }
        runs[chat.id, default: ChatRunState()].queuePaused = false
        scheduleQueue(threadID: chat.id)
        return true
    }
    /// A chat whose unpaused queue will send next; a restart in that gap would leave it paused.
    var hasDeliverableQueue: Bool {
        queuedMessages.contains { message in runs[message.threadID].map { !$0.queuePaused } ?? false }
    }
    /// What keeps the app from being idle, listed in the Restart menu while a restart waits.
    var restartBlockers: [String] {
        func title(_ id: String) -> String { state.chats.first { $0.id == id }?.title ?? L10n.text("новый чат", "new chat") }
        var reasons: Set<String> = []
        if isBootstrapping || connecting || claudeConnecting { reasons.insert(L10n.text("Подключение к агентам", "Connecting to agents")) }
        for (id, run) in runs where run.running || run.sending {
            reasons.insert(id.hasPrefix("job:") ? L10n.text("Запуск задания", "Scheduled run starting") : L10n.text("Выполняется: ", "Running: ") + title(id))
        }
        for action in pending { reasons.insert(L10n.text("Ждёт твоего действия: ", "Waiting for your action: ") + title(action.threadID)) }
        for id in backgroundWorkChatIDs { reasons.insert(L10n.text("Ждёт фоновые задачи: ", "Waiting for background tasks: ") + title(id)) }
        for message in queuedMessages where runs[message.threadID].map({ !$0.queuePaused }) ?? false {
            reasons.insert(L10n.text("Сообщение в очереди: ", "Queued message: ") + title(message.threadID))
        }
        for run in jobLedger.runs where run.status.active { reasons.insert(L10n.text("Задание: ", "Scheduled task: ") + run.name) }
        if summaryTask != nil { reasons.insert(L10n.text("Сводка архива", "Archive summary")) }
        if preparingHandoff || creatingHandoff { reasons.insert(L10n.text("Передача контекста", "Context handoff")) }
        if !deletingChatIDs.isEmpty || !archivingChatIDs.isEmpty { reasons.insert(L10n.text("Архивирование или удаление чатов", "Archiving or deleting chats")) }
        return reasons.sorted()
    }
    func resumeQueue() {
        guard let thread = chatID, chatIsAvailable(thread), !isChangingChat(thread), !isArchived(thread) else { return }
        runs[thread, default: ChatRunState()].queuePaused = false
        scheduleQueue(threadID: thread)
    }
    private func drainQueue(threadID: String) async {
        let run = runs[threadID] ?? ChatRunState()
        guard chatIsAvailable(threadID), !isChangingChat(threadID), !isArchived(threadID), !run.queuePaused, !run.running, !run.sending, chatConnected(threadID), chatAuthenticated(threadID),
              let next = queuedMessages.first(where: { $0.threadID == threadID }),
              let project = state.projects.first(where: { $0.id == next.projectID }) else { return }
        let route = state.chats.first(where: { $0.id == threadID })?.route ?? .direct
        if !routeIsAvailable(route) {
            runs[threadID, default: ChatRunState()].queuePaused = true
            error = routeMessage(route); return
        }
        runs[threadID, default: ChatRunState()].sending = true
        defer {
            runs[threadID, default: ChatRunState()].sending = false
            scheduleQueue(threadID: threadID)
        }
        let afterInterrupt = run.interruptedFor == next.id
        runs[threadID, default: ChatRunState()].interruptedFor = nil
        state.queuedMessages = queuedMessages.filter { $0.id != next.id }
        do { try await store.save(state) }
        catch {
            state.queuedMessages = [next] + queuedMessages
            runs[threadID, default: ChatRunState()].queuePaused = true
            self.error = error.localizedDescription
            return
        }
        await deliver(text: next.text, project: project, threadID: threadID, localID: next.id,
                      selectedModel: next.model, selectedEffort: next.effort, afterInterrupt: afterInterrupt)
    }
    private func scheduleQueue(threadID: String) {
        let run = runs[threadID] ?? ChatRunState()
        guard !run.queuePaused, !run.running, !run.sending,
              queuedMessages.contains(where: { $0.threadID == threadID }) else { return }
        Task { await drainQueue(threadID: threadID) }
    }
    func send() async {
        guard canSend, let project = selectedProject else { return }
        if let record = selectedChat, record.isScheduledRecord {
            await followUpScheduledRecord(record, text: draft, project: project); return
        }
        let text = draft; draft = ""
        let localID = "local-user:" + UUID().uuidString
        if let thread = chatID, busy || !visibleQueue.isEmpty {
            if visibleQueue.isEmpty { runs[thread, default: ChatRunState()].queuePaused = false }
            state.queuedMessages = queuedMessages + [QueuedMessage(id: localID, threadID: thread,
                projectID: project.id, text: text, model: currentModel, effort: currentAgent == .appClaude ? claudeEffort : effort)]
            persist()
            scheduleQueue(threadID: thread)
            return
        }
        await deliver(text: text, project: project, threadID: chatID, localID: localID,
                      selectedModel: currentModel, selectedEffort: currentAgent == .appClaude ? claudeEffort : effort)
    }
    private func deliver(text: String, project: Project, threadID: String?, localID: String,
                         selectedModel: String, selectedEffort: String, scheduledRun: UUID? = nil, scheduledRoute: RequestRoute? = nil, scheduledBrowserImport: ChromeSessionImportPolicy? = nil,
                         scheduledAgent: AgentConnectionID = .originalCodex, scheduledRole: AgentRole? = nil, afterInterrupt: Bool = false) async {
        let selection = selectionGeneration
        let visible = scheduledRun == nil && threadID == chatID && project.id == projectID
        if visible { items.append(TranscriptItem(id: localID, kind: "user", text: text, phase: L10n.text("Отправляется…", "Sending…"))) }
        let initialKey = scheduledRun.map { "job:" + $0.uuidString } ?? threadID ?? currentRunKey
        var runKey = initialKey
        let priorTurn = runs[runKey]?.turnID
        runs[runKey, default: ChatRunState()].running = true
        runs[runKey, default: ChatRunState()].sending = true
        defer {
            runs[runKey, default: ChatRunState()].sending = false
            if initialKey != runKey { runs.removeValue(forKey: initialKey) }
            scheduleQueue(threadID: runKey)
        }
        // Capture the target's policy before suspension; selection can change while sending.
        let role: AgentRole
        if scheduledRun != nil { role = scheduledRole ?? project.jobRole(roleCatalog) }
        else if let threadID { role = state.chats.first { $0.id == threadID }?.resolvedRole(in: project, catalog: roleCatalog) ?? project.chatRole(roleCatalog) }
        else { role = project.chatRole(roleCatalog) }
        let access = role.profile(for: project)
        let newConnection = scheduledRun == nil ? currentAgent : scheduledAgent
        let route = scheduledRoute ?? (threadID == nil ? (newConnection == .appClaude ? .direct : defaultRoute) : (state.chats.first { $0.id == threadID }?.route ?? .direct))
        do {
            if let threadID {
                guard !isScheduledRecord(threadID) else { throw ClientFailure(Self.scheduledRecordReadOnly) }
                _ = try nativeThread(threadID)
            } else if ![.originalCodex, .appClaude].contains(newConnection) { throw ConversationIdentity.unavailable }
            let client = try threadID.map { try clientForChat($0) } ?? (newConnection == .appClaude ? claudeConnection : connection)
            if route != .direct {
                guard let runtime = pluginRuntimes[route.rawValue], routeIsAvailable(route) else { throw ClientFailure(routeMessage(route)) }
                pluginStatuses[route.rawValue] = try await runtime.status()
            }
            var id = threadID
            if id == nil {
                let browserProfile = scheduledRun == nil && state.browserEnabled == true
                    ? newChatBrowserProfiles[project.id].map { AgentBrowserProfile(id: $0) } : nil
                let session = try await client.createSession(projectPath: project.path, permissions: access,
                                                                 model: selectedModel, route: route, browserProfile: browserProfile,
                                                                 kind: scheduledRun == nil ? .interactive : .scheduled)
                if let browserProfile, newChatBrowserProfiles[project.id] == browserProfile.id {
                    newChatBrowserProfiles.removeValue(forKey: project.id)
                }
                let nativeCreated = session.nativeID
                guard ConversationIdentity.appID(for: nativeCreated, in: state, connection: session.connection) == nil else { throw ConversationIdentity.invalidStorage }
                var chat = Chat(session: session, projectID: project.id, title: ChatTitle.placeholder(), model: selectedModel)
                chat.effort = selectedEffort
                chat.accessMode = scheduledRun == nil ? nil : role.legacyAccessMode
                chat.roleID = scheduledRun == nil ? nil : role.id
                chat.inheritsProjectAccess = scheduledRun == nil
                let created = chat.id
                id = created
                tokenTotals[created] = .zero
                runs[created] = runs[runKey]
                runs.removeValue(forKey: runKey)
                runKey = created
                if visible && selectionGeneration == selection {
                    chatID = created
                    chatDrafts[created] = draft.isEmpty ? nil : draft
                    newChatDrafts.removeValue(forKey: project.id)
                }
                loadedThreads.insert(created)
                chat.route = route
                if let scheduledRun, let run = jobLedger.runs.first(where: { $0.id == scheduledRun }) { chat.title = run.name }
                state.chats.append(chat)
                try await store.save(state)
            }
            guard let id else { throw ClientFailure(L10n.text("Не выбран разговор", "No conversation selected")) }
            if !loadedThreads.contains(id) {
                try await client.resume(sessionForChat(id), projectPath: project.path, permissions: access, route: route,
                                        kind: scheduledRun == nil ? .interactive : .scheduled)
                loadedThreads.insert(id)
            }
            if let scheduledRun {
                jobLedger = try await jobStore.attach(scheduledRun, thread: id)
                try Task.checkCancellation()
                guard !schedulerStopping else { throw CancellationError() }
            }
            var outgoing = afterInterrupt ? InterruptedTurnNote.applying(L10n.text(InterruptedTurnNote.russian, InterruptedTurnNote.english), to: text) : text
            if let scheduledBrowserImport, scheduledRun != nil, state.browserEnabled == true {
                let session = try sessionForChat(id)
                try ScheduledBrowserImport.install(scheduledBrowserImport, session: session, browserEnabled: state.browserEnabled == true)
                if let resources = Bundle.main.resourceURL {
                    let limit = UserDefaults.standard.object(forKey: "parallelBrowserLimit") as? Int ?? 2
                    let preflight = await Task.detached {
                        await ScheduledBrowserImport.preflight(scheduledBrowserImport, session: session,
                            runtime: resources.appendingPathComponent("BrowserRuntime"), maxBrowsers: limit,
                            sourceIsRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty })
                    }.value
                    AppLog.delivery.info("Scheduled sign-in preflight for chat \(id, privacy: .public): \(String(describing: preflight), privacy: .public)")
                    let tool = scheduledAgent == .appClaude ? ScheduledBrowserImport.claudeImportTool : "browser_import_session"
                    outgoing = ScheduledBrowserImport.applying(preflight, policy: scheduledBrowserImport, to: text, tool: tool)
                }
            }
            let submittedTurn = try await client.send(outgoing, to: sessionForChat(id), projectPath: project.path,
                                                          permissions: access, model: selectedModel, effort: selectedEffort,
                                                          advisor: ClaudeAdvisor.attached(state.claudeAdvisor, mainModel: selectedModel),
                                                          kind: scheduledRun == nil ? .interactive : .scheduled, conversation: ConversationID(id),
                                                          chatDirectory: chatDirectoryArguments(for: id))
            if threadID == nil && scheduledRun == nil {
                generateChatTitle(id, firstMessage: text, model: selectedModel, route: route)
            }
            if let scheduledRun {
                guard let turn = submittedTurn else { throw ClientFailure(L10n.text("Не получен ID запуска", "No turn ID received")) }
                jobLedger = try await jobStore.attach(scheduledRun, thread: id, turn: turn)
                if Task.isCancelled || schedulerStopping {
                    try await client.interrupt(sessionForChat(id), turn: turn)
                }
            }
            if localID.hasPrefix("local-user:remote:") { remoteDeliveryResults[localID] = submittedTurn != nil }
            clearConnectionError()
            setDelivery(localID, phase: L10n.text("Отправлено", "Sent"))
            if let turn = submittedTurn, runs[id]?.running == true {
                runs[id, default: ChatRunState()].turnID = turn
                if let completion = completedTurns[id + ":" + turn] {
                    finishActiveTurn(threadID: id, turnID: turn, status: completion.status, hasError: completion.hasError)
                } else if runs[id]?.stopRequested == true {
                    await interruptThread(id)
                }
            }
            if let i = state.chats.firstIndex(where: { $0.id == id }) { state.chats[i].updated = Date(); persist() }
        } catch {
            // The engine started a turn of its own while this send was in flight (Claude resuming after its background
            // tasks): that turn keeps the chat running. A definite rejection delivered nothing, so the message waits
            // in the queue for that turn to finish, exactly as if it had been sent while the chat was busy.
            let engineTurn = runs[runKey]?.turnID.flatMap { $0 == priorTurn ? nil : $0 }
            if let engineTurn, let threadID, scheduledRun == nil, !localID.hasPrefix("local-user:remote:"),
               (error as? AgentOperationFailure)?.rejection != nil {
                AppLog.delivery.notice("Engine turn \(engineTurn, privacy: .public) started in chat \(threadID, privacy: .public) during a send; message queued, nothing was delivered")
                items.removeAll { $0.id == localID }
                state.queuedMessages = [QueuedMessage(id: localID, threadID: threadID, projectID: project.id, text: text,
                                                      model: selectedModel, effort: selectedEffort)] + queuedMessages
                runs[threadID, default: ChatRunState()].queuePaused = false
                if afterInterrupt { runs[threadID, default: ChatRunState()].interruptedFor = localID }
                persist()
                return
            }
            if let scheduledRun { await finishJob(scheduledRun, status: .uncertain, output: error.localizedDescription) }
            AppLog.delivery.error("Delivery unconfirmed for chat \(runKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            setDelivery(localID, phase: L10n.text("Доставка не подтверждена", "Delivery unconfirmed"))
            self.error = error.localizedDescription + L10n.text(" Сообщение не отправлено повторно.", " The message was not sent again.")
            runs[runKey, default: ChatRunState()].queuePaused = true
            // An engine-started turn still runs; only its own completion releases the chat.
            if engineTurn == nil {
                runs[runKey, default: ChatRunState()].running = false
                runs[runKey, default: ChatRunState()].turnID = nil
            }
            if visible && selectionGeneration == selection && draft.isEmpty { draft = text }
        }
    }
    func scheduledAgentReady(_ agent: AgentConnectionID) -> Bool {
        agent == .appClaude ? claudeConnected && claudeAuthenticated : connected && authenticated
    }
    func deliverScheduled(_ job: ManagedJob, run: JobRun, project: Project, agent: AgentConnectionID = .originalCodex) async {
        do {
            let prompt = try job.browserExecutionPrompt() + "\n\n" + AttentionMarkers.instructions()
            await deliver(text: prompt, project: project, threadID: nil, localID: "local-user:" + run.id.uuidString,
                          selectedModel: job.model, selectedEffort: job.effort, scheduledRun: run.id, scheduledRoute: job.route,
                          scheduledBrowserImport: job.browserSessionImport, scheduledAgent: agent, scheduledRole: job.role(project: project, catalog: roleCatalog))
        } catch {
            await finishJob(run.id, status: .blocked, output: error.localizedDescription)
        }
    }
    func finishActiveTurn(threadID: String?, turnID: String?, status: AgentExecutionOutcome, hasError: Bool) {
        guard let threadID, let turnID else { return }
        completedTurns[threadID + ":" + turnID] = (status, hasError)
        if let run = jobLedger.runs.first(where: { $0.threadID == threadID && $0.status.active && ($0.turnID == nil || $0.turnID == turnID) }) {
            let outcome: JobRunStatus = status == .uncertain ? .uncertain : status == .completed && !hasError ? .completed : status == .cancelled ? .interrupted : .failed
            Task { await finishJob(run.id, status: outcome) }
        }
        guard runs[threadID]?.turnID == turnID else { return }
        runs[threadID, default: ChatRunState()].running = false
        runs[threadID, default: ChatRunState()].turnID = nil
        runs[threadID, default: ChatRunState()].stopRequested = false
        if let priority = runs[threadID]?.priorityMessageID, (status == .cancelled || status == .completed) && !hasError {
            runs[threadID, default: ChatRunState()].queuePaused = false
            runs[threadID, default: ChatRunState()].interruptedFor = status == .cancelled ? priority : nil
        } else if status != .completed || hasError {
            runs[threadID, default: ChatRunState()].queuePaused = true
        }
        runs[threadID, default: ChatRunState()].priorityMessageID = nil
        cleanTemporaryPhotos()
        scheduleQueue(threadID: threadID)
    }
    private func setDelivery(_ id: String, phase: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].phase = phase }
    }
    func interrupt() async {
        await interruptThread(currentRunKey)
    }
    private func interruptThread(_ thread: String) async {
        // Stopping a scheduled-run record stops its job; no engine turn exists to interrupt.
        if let runID = state.chats.first(where: { $0.id == thread })?.scheduledRecord {
            if let run = jobLedger.runs.first(where: { $0.id == runID && $0.status.active }) { await stopJob(run) }
            return
        }
        runs[thread, default: ChatRunState()].priorityMessageID = nil
        runs[thread, default: ChatRunState()].interruptedFor = nil
        runs[thread, default: ChatRunState()].queuePaused = true
        runs[thread, default: ChatRunState()].stopRequested = true
        guard let turn = runs[thread]?.turnID else { return }
        do { try await clientForChat(thread).interrupt(sessionForChat(thread), turn: turn) }
        catch { self.error = error.localizedDescription }
    }
    func refreshJobs() async {
        jobs = await Task.detached {
            ScheduledJobs.read(directory: Locations.automations) + ScheduledJobs.readClaude(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/scheduled-tasks"))
        }.value
    }
    func enableNotifications() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notificationStatus = allowed ? L10n.text("Уведомления включены", "Notifications are on") : L10n.text("Уведомления запрещены в настройках macOS", "Notifications are disabled in macOS Settings")
        } catch { self.error = error.localizedDescription }
    }
    /// The turn's answer (or error) as one short line; persisted with the chat by `recordUnreadCompletion`.
    private func recordRecap(threadID: String, failed: Bool, error: String?) {
        guard let index = state.chats.firstIndex(where: { $0.id == threadID }) else { return }
        let answer = latestAnswers.removeValue(forKey: threadID)
            ?? (chatID == threadID ? items.last(where: { $0.kind == "assistant" })?.text : nil)
        state.chats[index].lastTurnFailed = failed ? true : nil
        if let recap = TurnRecap.make((failed ? error : nil) ?? answer ?? "") { state.chats[index].recap = recap }
    }
    /// Chats that wait for the user: approvals and questions first, then failed and unread results.
    var attentionChats: [(chat: Chat, attention: ChatAttention)] {
        let hidden = Set(state.projects.filter(\.isHidden).map(\.id))
        return state.chats.compactMap { chat -> (Chat, ChatAttention)? in
            guard !chat.isArchived, !hidden.contains(chat.projectID) else { return nil }
            let requests = pending.filter { $0.threadID == chat.id }
            let approval = requests.contains { if case .approval = $0.interaction.kind { true } else { false } }
            guard let attention = ChatAttention.of(approval: approval, question: !requests.isEmpty && !approval, running: isBusy(threadID: chat.id),
                                                   unread: chat.hasUnreadResponse, failed: chat.lastTurnFailed == true) else { return nil }
            return (chat, attention)
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.updated > $1.0.updated }
    }
    /// Second line of a waiting chat: what the request asks, otherwise the turn's recap.
    func attentionDetail(_ chat: Chat) -> String? {
        if let request = pending.first(where: { $0.threadID == chat.id }) {
            let reason = (request.interaction.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? request.title : request.title + ": " + reason
        }
        return chat.recap
    }
    private func postNotice(threadID: String, title: String, identifier: String, completionID: String? = nil, actionID: String? = nil, body: String? = nil) {
        let chat = state.chats.first { $0.id == threadID }
        let project = state.projects.first { $0.id == chat?.projectID }
        let detail = [project?.name, chat?.title].compactMap { $0 }.joined(separator: " · ")
        notices.insert(DeskNotice(threadID: threadID, title: title, detail: detail, completionID: completionID, actionID: actionID), at: 0)
        notices = Array(notices.prefix(50))
        // System notifications need an app bundle; headless hosts (tests) keep the in-app notice only.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.subtitle = detail; content.body = body } else { content.body = detail }
        content.sound = .default; content.userInfo = ["threadID": threadID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil), withCompletionHandler: nil)
    }
    func recordUnreadCompletion(threadID: String, completionID: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == threadID }) else { return }
        state.chats[index].unreadCompletionID = completionID
        unreadResponseItems[threadID] = chatID == threadID ? items.last(where: { $0.kind == "assistant" })?.id : nil
        persist()
    }

    func markResponseRead(threadID: String, completionID: String) {
        // Incomplete history must contain the completed turn; a failed or stopped turn may have no assistant answer.
        if localHistoryNotice != nil && !items.contains(where: {
            $0.turnID.map { "turn:" + threadID + ":" + $0 } == completionID
        }) { return }
        guard chatID == threadID, !showingJobs, !showingAttention, (!showingArchive || archiveViewingChat), !loadingChat,
              let index = state.chats.firstIndex(where: { $0.id == threadID }),
              state.chats[index].unreadCompletionID == completionID else { return }
        state.chats[index].unreadCompletionID = nil
        unreadResponseItems[threadID] = nil
        // Approval/input notices are acknowledged separately when their request is visible.
        notices.removeAll { $0.threadID == threadID && $0.completionID != nil }
        let identifiers = notifiedTurns.filter { $0.hasPrefix(threadID + ":") }.map { "turn:" + $0 }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers + [completionID])
        }
        persist()
    }

    func notify(_ action: PendingAction) {
        postNotice(threadID: action.threadID, title: action.title, identifier: action.id, actionID: action.id)
        refreshDockBadge()
    }
    /// Acknowledging a notice never answers or approves the underlying request.
    func markActionRead(_ action: PendingAction) {
        guard chatID == action.threadID, !showingJobs, !showingAttention, (!showingArchive || archiveViewingChat), !loadingChat,
              currentAction?.id == action.id else { return }
        removeActionNotices([action])
    }
    private func removeActionNotices(_ actions: [PendingAction]) {
        notices.removeAll { notice in
            actions.contains { $0.id == notice.actionID && $0.threadID == notice.threadID }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: actions.map(\.id))
        }
    }
    func focusAction(threadID: String) async {
        guard let chat = state.chats.first(where: { $0.id == threadID }) else { return }
        await openChat(chat)
    }
    /// Returns a failure shown on the card itself; the answer is never retried automatically.
    @discardableResult
    func answer(_ action: PendingAction, result: AgentInteractionResponse) async -> String? {
        guard pending.contains(where: { $0.id == action.id }) else { return nil }
        guard chatIsAvailable(action.threadID), chatConnected(action.threadID) else {
            return L10n.text("Чат сейчас не подключён, ответ не отправлен.", "The chat is not connected; the answer was not sent.")
        }
        do {
            try await clientForChat(action.threadID).answer(action.interaction.id, session: action.interaction.session, response: result)
            pending.removeAll { $0.id == action.id }
            removeActionNotices([action])
            refreshDockBadge()
            return nil
        } catch {
            self.error = error.localizedDescription
            return L10n.text("Ответ не отправлен: ", "The answer was not sent: ") + error.localizedDescription
        }
    }
    func generateChatTitle(_ id: String, firstMessage: String, model: String, route: RequestRoute) {
        let log = AppLog.chatTitle
        let connection = state.chats.first { $0.id == id }?.nativeSession?.connection.agent.rawValue ?? "none"
        let skip: String? = !state.chats.contains(where: { $0.id == id }) ? "chat not found"
            : !supportsSummaries(id) ? "connection \(connection) does not support generation"
            : titleTasks[id] != nil ? "generation already running"
            : manuallyNamedChatIDs.contains(id) ? "chat was renamed manually" : nil
        if let skip { log.info("Skipped title for chat \(id, privacy: .public): \(skip, privacy: .public)"); return }
        let client: AgentClient
        do { client = try clientForChat(id) } catch {
            log.error("Skipped title for chat \(id, privacy: .public): no client: \(error.localizedDescription, privacy: .public)")
            return
        }
        let runner = AgentGenerationRunner(integration: client.integration)
        let environment = generationEnvironment(for: id, workspace: ".title-workspace")
        titleRunners[id] = runner
        log.info("Generating title for chat \(id, privacy: .public) on \(connection, privacy: .public), model \(model, privacy: .public)")
        titleTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.titleTasks[id] = nil; self.titleRunners[id] = nil }
            let started = Date()
            do {
                let title = try await runner.title(source: self.sessionForChat(id), firstMessage: firstMessage, model: model, route: route,
                    environment: environment)
                try Task.checkCancellation()
                guard let index = self.state.chats.firstIndex(where: { $0.id == id }) else {
                    log.info("Discarded title for chat \(id, privacy: .public): chat was removed")
                    return
                }
                self.state.chats[index].title = title
                self.persist()
                log.info("Title ready for chat \(id, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")
            } catch is CancellationError {
                log.info("Title cancelled for chat \(id, privacy: .public)")
            } catch {
                // Keep the neutral placeholder. Never retry an uncertain background request
                // or interrupt the user's main conversation with a naming failure.
                let rejection = (error as? AgentOperationFailure)?.rejection.map { String(describing: $0) } ?? "none"
                log.error("Title failed for chat \(id, privacy: .public) after \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s, rejection \(rejection, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func cancelChatTitle(_ id: String) async {
        let task = titleTasks[id]
        task?.cancel()
        await titleRunners[id]?.stop()
        await task?.value
    }

    func remoteSnapshot(projects: Set<String>) async -> RemoteSnapshot {
        let selected = state.projects.filter { projects.contains($0.id.uuidString) }
        var chats: [RemoteChat] = []
        let awaitingApproval = Set(pending.map(\.threadID))
        for chat in state.chats.filter({ projects.contains($0.projectID.uuidString) && !$0.isArchived }).sorted(by: {
            if awaitingApproval.contains($0.id) != awaitingApproval.contains($1.id) { return awaitingApproval.contains($0.id) }
            return $0.updated > $1.updated
        }).prefix(20) {
            let messages: [TranscriptItem]
            if chat.id == chatID { messages = items }
            else {
                // Publication runs on every model change; decode stored transcripts only when they changed.
                let revision = await store.transcriptRevision(conversationID: chat.id)
                if let cached = remoteHistoryCache[chat.id], cached.revision == revision, cached.session == chat.nativeSession {
                    messages = cached.messages
                } else {
                    let history = try? await store.loadTranscript(conversationID: chat.id)
                    messages = Array((history.map(LocalHistory.items) ?? []).filter { ["user", "assistant"].contains($0.kind) }.suffix(20))
                    remoteHistoryCache[chat.id] = (revision, chat.nativeSession, messages)
                }
            }
            let approvals = pending.filter { $0.threadID == chat.id }.compactMap { action -> RemoteApproval? in
                guard case .approval(let canAllow) = action.interaction.kind else { return nil }
                return RemoteApproval(id: action.id, details: String(action.interaction.details.prefix(8000)), canAllow: canAllow && action.interaction.details.count <= 8000)
            }
            var remote = RemoteChat(id: chat.id, project: chat.projectID.uuidString, title: chat.title,
                running: isBusy(threadID: chat.id), messages: messages.filter { ["user", "assistant"].contains($0.kind) }.suffix(20).map {
                    RemoteMessage(id: $0.id, role: $0.kind, fullText: $0.text)
                }, approvals: approvals, turn: runs[chat.id]?.turnID)
            if remote.running, let run = runs[chat.id] {
                // The host replaces this with the current tool call when it saw one.
                remote.activity = run.status.map { String($0.prefix(RemoteChat.activityLimit)) }
                remote.runningSince = run.turnID.flatMap { turnStarts[chat.id + ":" + $0] }.map { ISO8601DateFormatter().string(from: $0) }
            }
            if chat.isScheduledRecord { remote.readOnly = true; remote.supportsPhotos = false }
            if let project = selected.first(where: { $0.id == chat.projectID }), chat.nativeSession?.connection == .originalCodex {
                remote.settings = remoteSettings(chat, project: project)
            }
            chats.append(remote)
        }
        let codexOptions = models.map { RemoteModelOption(id: $0.id, name: $0.displayName) }
        let codexNew = codexRemoteReady && !models.isEmpty
            ? models.map { RemoteModelOption(id: $0.id, name: $0.displayName, agent: RemoteModelOption.codexAgent) } : []
        let claudeNew = claudeRemoteReady ? remoteClaudeModels.map { RemoteModelOption(id: $0.id, name: $0.name, agent: RemoteModelOption.claudeAgent) } : []
        let claudeFirst = (state.defaultConnection == .appClaude && !claudeNew.isEmpty) || codexNew.isEmpty
        let newChatModels = claudeFirst ? claudeNew + codexNew : codexNew + claudeNew
        let claudeDefault = ClaudeModel.resolved(state.claudeModel)
        let defaultModel = !claudeFirst ? state.model
            : claudeNew.contains(where: { $0.id == claudeDefault }) ? claudeDefault : claudeNew.first?.id ?? state.model
        return RemoteSnapshot(projects: selected.map {
            var project = RemoteProject(id: $0.id.uuidString, name: $0.name, canCreateChat: canCreateRemoteChat)
            project.models = codexOptions
            project.newChatModels = newChatModels
            let projectRole = $0.chatRole(roleCatalog)
            project.settings = RemoteChatSettings(options: RemoteChatOptions(model: defaultModel),
                projectAccess: RemoteAccessMode(rawValue: projectRole.legacyAccessMode.rawValue)!, canEdit: !newChatModels.isEmpty,
                projectRole: projectRole.id, roles: remoteRoles(project: $0))
            return project
        }, chats: chats)
    }
    /// Roles the phone may select for a project: never above the project's chat default (audit M3).
    private func remoteRoles(project: Project) -> [RemoteRoleOption] {
        let cap = project.chatRole(roleCatalog).rank
        return roleCatalog.interactive.filter { $0.rank <= cap }.map { RemoteRoleOption(id: $0.id, name: $0.title) }
    }
    /// The role a phone command asks for, or nil to inherit. `role` wins over the legacy `access`; both are capped.
    private func remoteRole(_ options: RemoteChatOptions?, project: Project) throws -> AgentRole? {
        let cap = project.chatRole(roleCatalog)
        if let id = options?.role {
            guard let role = roleCatalog.role(id), role.rank <= cap.rank else { throw RemoteFailure.invalidCommand }
            return role
        }
        guard let access = options?.access else { return nil }
        let role = AgentRoleCatalog.preset(AccessMode(rawValue: access.rawValue)!.legacyRoleID)
        guard role.rank <= cap.rank else { throw RemoteFailure.invalidCommand }
        return role
    }
    private func remoteSettings(_ chat: Chat, project: Project) -> RemoteChatSettings {
        let projectRole = project.chatRole(roleCatalog), role = chat.resolvedRole(in: project, catalog: roleCatalog)
        return RemoteChatSettings(options: RemoteChatOptions(model: chat.model,
            access: chat.inheritsProjectRole ? nil : RemoteAccessMode(rawValue: role.legacyAccessMode.rawValue), role: chat.inheritsProjectRole ? nil : role.id),
            projectAccess: RemoteAccessMode(rawValue: projectRole.legacyAccessMode.rawValue)!,
            canEdit: connected && authenticated && !models.isEmpty && !isChangingChat(chat.id) && !isBusy(threadID: chat.id)
                && !pending.contains(where: { $0.threadID == chat.id }) && !queuedMessages.contains(where: { $0.threadID == chat.id })
                && role.rank <= projectRole.rank,
            projectRole: projectRole.id, roles: remoteRoles(project: project))
    }
    private func remoteModel(_ options: RemoteChatOptions) throws -> AgentModelInfo {
        guard let model = models.first(where: { $0.id == options.model }) else { throw RemoteFailure.invalidCommand }
        return model
    }
    /// A phone may start a chat on either agent, independent of the desktop's default agent.
    private var codexRemoteReady: Bool { connected && authenticated && routeIsAvailable(defaultRoute) }
    private var claudeRemoteReady: Bool { claudeConnected && claudeAuthenticated }
    /// Catalog models the pinned Claude Code build can run.
    private var remoteClaudeModels: [ClaudeModel] { ClaudeModel.catalog.filter { $0.isSupported() } }
    private var canCreateRemoteChat: Bool {
        codexRemoteReady || claudeRemoteReady
    }
    private func createRemoteChat(_ command: RemoteCommand) async throws -> String {
        guard !state.chats.contains(where: { $0.id == command.chat }),
              let project = state.projects.first(where: { $0.id.uuidString == command.project }) else { throw RemoteFailure.invalidCommand }
        let options = command.settings?.options
        // The command carries only a model ID; the Mac resolves its agent. Older phones without options mean Codex.
        let claude = options.map { option in !models.contains { $0.id == option.model } && remoteClaudeModels.contains { $0.id == option.model } } ?? false
        guard claude ? claudeRemoteReady : codexRemoteReady else { throw RemoteFailure.invalidCommand }
        let model: String, effort: String, route: RequestRoute
        if claude, let options {
            model = options.model; effort = ClaudeEffort.resolved(state.claudeEffort); route = .direct
        } else {
            let chosen = try options.map { try remoteModel($0) }
            model = chosen?.id ?? state.model; effort = chosen?.defaultEffort ?? draftEffort; route = defaultRoute
        }
        let explicitRole = try remoteRole(options, project: project)
        let role = explicitRole ?? project.chatRole(roleCatalog)
        // Persist the stable app ID before sending. Native identity never comes from the phone.
        let session = try await (claude ? claudeConnection : connection).createSession(projectPath: project.path, permissions: role.profile(for: project), model: model, route: route)
        guard !state.chats.contains(where: { $0.id == command.chat }),
              ConversationIdentity.appID(for: session.nativeID, in: state, connection: session.connection) == nil else { throw RemoteFailure.invalidCommand }
        var chat = Chat(session: session, projectID: project.id, title: ChatTitle.placeholder(), model: model)
        chat.id = command.chat; chat.effort = effort; chat.route = route
        chat.roleID = explicitRole?.id; chat.accessMode = explicitRole?.legacyAccessMode; chat.inheritsProjectAccess = explicitRole == nil
        state.chats.append(chat)
        try await store.save(state)
        loadedThreads.insert(chat.id)
        let prompt = try command.photoPrompt(directory: Locations.root.appendingPathComponent("mobile-photos", isDirectory: true))
        await deliver(text: prompt, project: project, threadID: chat.id, localID: "local-user:remote:" + command.id,
                      selectedModel: model, selectedEffort: effort)
        let submitted = remoteDeliveryResults.removeValue(forKey: "local-user:remote:" + command.id) == true
        if submitted { generateChatTitle(chat.id, firstMessage: command.text, model: model, route: route) }
        return submitted ? "submitted" : "uncertain"
    }
    func executeRemote(_ command: RemoteCommand) async throws -> String {
        try command.validate()
        if command.createsChat { return try await createRemoteChat(command) }
        guard let chat = state.chats.first(where: { $0.id == command.chat && $0.projectID.uuidString == command.project && !$0.isArchived }),
              let project = state.projects.first(where: { $0.id == chat.projectID }),
              !isChangingChat(chat.id), chatIsAvailable(chat.id), chatConnected(chat.id), chatAuthenticated(chat.id) else { throw RemoteFailure.invalidCommand }
        switch command.kind {
        case "configure":
            guard chat.nativeSession?.connection == .originalCodex, let change = command.settings else { throw RemoteFailure.invalidCommand }
            let current = remoteSettings(chat, project: project)
            guard current.canEdit, change.expected == current.options, change.expectedProjectAccess == current.projectAccess else { throw RemoteFailure.invalidCommand }
            let selectedModel = try remoteModel(change.options)
            let role = try remoteRole(change.options, project: project)
            configuringRemoteChats.insert(chat.id)
            defer { configuringRemoteChats.remove(chat.id); objectWillChange.send() }
            guard let index = state.chats.firstIndex(where: { $0.id == chat.id }) else { throw RemoteFailure.invalidCommand }
            state.chats[index].model = selectedModel.id
            if chat.model != selectedModel.id { state.chats[index].effort = selectedModel.defaultEffort }
            state.chats[index].roleID = role?.id
            state.chats[index].accessMode = role?.legacyAccessMode
            state.chats[index].inheritsProjectAccess = role == nil
            do { try await store.save(state) }
            catch {
                if let index = state.chats.firstIndex(where: { $0.id == chat.id }) {
                    state.chats[index].model = chat.model; state.chats[index].effort = chat.effort
                    state.chats[index].accessMode = chat.accessMode; state.chats[index].inheritsProjectAccess = chat.inheritsProjectAccess
                    state.chats[index].roleID = chat.roleID
                }
                throw error
            }
            return "submitted"
        case "send":
            guard !isBusy(threadID: chat.id), runs[chat.id]?.sending != true,
                  !queuedMessages.contains(where: { $0.threadID == chat.id }), !pending.contains(where: { $0.threadID == chat.id }) else { throw RemoteFailure.invalidCommand }
            // Existing delivery preserves routing, project permissions and the desktop's selected chat.
            let prompt = try command.photoPrompt(directory: Locations.root.appendingPathComponent("mobile-photos", isDirectory: true))
            await deliver(text: prompt, project: project, threadID: chat.id,
                          localID: "local-user:remote:" + command.id, selectedModel: chat.model, selectedEffort: chat.effort ?? "")
            return remoteDeliveryResults.removeValue(forKey: "local-user:remote:" + command.id) == true ? "submitted" : "uncertain"
        case "stop":
            guard let turn = runs[chat.id]?.turnID, command.turn == turn else { throw RemoteFailure.invalidCommand }
            runs[chat.id, default: ChatRunState()].queuePaused = true
            runs[chat.id, default: ChatRunState()].stopRequested = true
            try await clientForChat(chat.id).interrupt(sessionForChat(chat.id), turn: turn)
            return "stop_requested"
        case "allow", "deny":
            guard let approvalID = command.approval.flatMap(UUID.init(uuidString:)),
                  let action = pending.first(where: { $0.threadID == chat.id && $0.interaction.id == approvalID }),
                  case .approval(let canAllow) = action.interaction.kind,
                  command.kind != "allow" || (canAllow && action.interaction.details.count <= 8000) else { throw RemoteFailure.invalidCommand }
            try await clientForChat(chat.id).answer(action.interaction.id, session: action.interaction.session,
                                                   response: command.kind == "allow" ? .allowOnce : .deny)
            pending.removeAll { $0.id == action.id }; removeActionNotices([action])
            refreshDockBadge()
            return "submitted"
        default: throw RemoteFailure.invalidCommand
        }
    }
    func shutdown() async {
        // Each awaited step is logged so a stalled quit names the step that never returned.
        let log = AppLog.lifecycle
        func step(_ name: String) { log.notice("Shutdown step: \(name, privacy: .public)") }
        flushDeltas()
        photoCleanupTask?.cancel(); photoCleanupTask = nil
        step("mobile remote"); await mobileRemote.disable()
        historyBackfillTask?.cancel(); claudeHistoryBackfillTask?.cancel()
        for task in historyRefreshTasks.values { task.cancel() }
        step("chat titles (\(titleTasks.count))")
        for id in Array(titleTasks.keys) { await cancelChatTitle(id) }
        step("scheduler"); await stopScheduler()
        summaryTask?.cancel()
        step("handoff"); await cancelHandoffPreparation()
        step("summary runners"); await summaryRunner.stop()
        await claudeSummaryRunner.stop()
        step("summary queue"); await summaryTask?.value
        step("Codex connection"); await connection.stop()
        step("Claude connection"); await claudeConnection.stop()
        claudeEventTask?.cancel()
        step("plugins"); await stopPlugins()
        step("orphan processes"); await orphanProcesses.shutdown()
        step("done")
    }
    func saveAgentChoice() { persist() }
    func selectAgent(_ agent: AgentConnectionID) {
        guard chatID == nil, !sending, [.originalCodex, .appClaude].contains(agent) else { return }
        // Browser profiles belong to one agent; a picked profile does not carry over.
        if state.defaultConnection != agent { newChatBrowserProfiles.removeAll() }
        state.defaultConnection = agent; persist()
        if agent == .appClaude && !claudeConnected { Task { await connectClaude() } }
    }
    func connectClaude() async {
        guard !claudeConnecting, !state.chats.contains(where: { $0.nativeSession?.connection == .appClaude && isBusy(threadID: $0.id) }) else { return }
        claudeConnecting = true; defer { claudeConnecting = false }
        claudeHistoryBackfillTask?.cancel()
        resetAgentState(.appClaude); claudeConnected = false; claudeAuthenticated = false; clearClaudeLimits()
        do {
            claudeDescriptor = try await claudeConnection.start(.init(home: claudeHome, resources: Bundle.main.resourceURL,
                                                                      browserEnabled: state.browserEnabled == true,
                                                                      userChromeEnabled: state.userChromeEnabled != false))
            claudeConnected = true
            await refreshClaudeAccount()
            // Reading every Claude history takes seconds with many long chats; it must not hold up launch.
            let chats = state.chats.filter { $0.nativeSession?.connection == .appClaude }
            claudeHistoryBackfillTask = Task { [weak self] in await self?.backfillHistory(chats) }
        } catch { self.error = error.localizedDescription }
    }
    func refreshClaudeAccount() async {
        do { claudeAuthenticated = try await claudeConnection.account().authenticated }
        catch { claudeAuthenticated = false; self.error = error.localizedDescription }
        if claudeAuthenticated { startSummaryQueue(); await refreshClaudeLimits() } else { clearClaudeLimits() }
    }
    func loginClaude() async {
        if !claudeConnected { await connectClaude() }
        do {
            guard case .openLocalSignIn(let url) = try await claudeConnection.integration.authenticate(.beginSignIn).value(),
                  NSWorkspace.shared.open(url) else { throw ConversationIdentity.unavailable }
        } catch { self.error = error.localizedDescription }
    }
    func logoutClaude() async {
        do { try await claudeConnection.signOut(); await refreshClaudeAccount() }
        catch { self.error = error.localizedDescription }
    }
    func loginCurrentAgent() async {
        if currentAgent == .appClaude { await loginClaude() }
        else if connected { await login() } else { await connect() }
    }
    private func resetAgentState(_ agent: AgentConnectionID) {
        let ids = Set(state.chats.filter { $0.nativeSession?.connection == agent }.map(\.id))
        clearAgentInteractions(agent)
        for id in ids { runs[id] = nil; backgroundWaits[id] = nil; subagents[id] = nil; loadedThreads.remove(id) }
    }
    private func clearAgentInteractions(_ agent: AgentConnectionID) {
        let actions = pending.filter { $0.interaction.session.connection == agent }
        removeActionNotices(actions); pending.removeAll { $0.interaction.session.connection == agent }
        refreshDockBadge()
    }
    func receiveClaude(_ event: AgentEvent) async {
        switch event.payload {
        case .descriptor(let descriptor): claudeDescriptor = descriptor
        case .accountChanged(let issue):
            resetAgentState(.appClaude); clearClaudeLimits()
            await interruptSummaries(.appClaude, issue: L10n.text("Аккаунт изменился. Проверь итог перед новым запуском.", "The account changed. Review the summary before starting again."))
            if let issue { error = issue }
            await refreshClaudeAccount()
        case .interactionsReset: clearAgentInteractions(.appClaude)
        case .disconnected:
            flushDeltas()
            claudeHistoryBackfillTask?.cancel()
            resetAgentState(.appClaude); claudeConnected = false; claudeAuthenticated = false; clearClaudeLimits()
            await interruptSummaries(.appClaude, issue: L10n.text("Claude отключился. Итог не повторён автоматически.", "Claude disconnected. The summary was not retried automatically."))
        case .limitsChanged: break
        default: await receive(event)
        }
    }
    private func persist() { let snapshot = state; Task { do { try await store.save(snapshot) } catch { self.error = error.localizedDescription } } }

    func receive(_ event: AgentEvent) async {
        let thread = event.session.flatMap { ConversationIdentity.appID(for: $0.nativeID, in: state, connection: $0.connection) }
        if event.session != nil && thread == nil {
            if case .interaction(let request) = event.payload { await (request.session.connection == .appClaude ? claudeConnection : connection).rejectInteraction(request.id) }
            return
        }
        defer { mobileRemote.observe(event, thread: thread) }
        switch event.payload {
        case .descriptor(let descriptor):
            if agentDescriptor?.context != descriptor.context { models = []; clearLimits() }
            agentDescriptor = descriptor
        case .interaction(let request):
            guard let thread else { await (request.session.connection == .appClaude ? claudeConnection : connection).rejectInteraction(request.id); return }
            let action = PendingAction(interaction: request, threadID: thread)
            if !pending.contains(where: { $0.id == action.id }) { pending.append(action); notify(action) }
        case .interactionsReset:
            clearAgentInteractions(.originalCodex)
        case .capability(let record):
            guard let thread, let chat = state.chats.first(where: { $0.id == thread }),
                  let project = state.projects.first(where: { $0.id == chat.projectID }) else { return }
            let role = chat.resolvedRole(in: project, catalog: roleCatalog)
            let run = jobLedger.runs.first { $0.threadID == thread && $0.status.active }?.id
            let decision = CapabilityDecision(chatID: thread, runID: run, projectID: project.id, roleID: role.id,
                                              agent: event.session?.connection == .appClaude ? "claude" : "codex", record: record, audit: role.profile.audit)
            Task { [capabilityLedger] in await capabilityLedger.record(decision) }
        case .accountChanged(let issue):
            for (id, task) in titleTasks where state.chats.first(where: { $0.id == id })?.nativeSession?.connection != .appClaude { task.cancel() }
            models = []; clearLimits(); resetAgentState(.originalCodex)
            await interruptSummaries(.originalCodex, issue: L10n.text("Аккаунт изменился. Проверь итог перед новым запуском.", "The account changed. Review the summary before starting again."))
            for run in jobLedger.runs where run.engine == .codex && run.status.active {
                await finishJob(run.id, status: .uncertain, output: L10n.text("Аккаунт изменился; запуск не повторён.", "The account changed; the run was not retried."))
            }
            if let issue { error = issue }
            await refreshAccount()
        case .limitsChanged: await refreshLimits()
        case .disconnected:
            flushDeltas()
            historyBackfillTask?.cancel()
            for task in historyRefreshTasks.values { task.cancel() }
            agentDescriptor = nil; models = []
            connected = false
            for run in jobLedger.runs where run.engine == .codex && run.status.active {
                await finishJob(run.id, status: .uncertain, output: L10n.text("Соединение потеряно; повторной отправки не было.", "Connection lost; the task was not sent again."))
            }
            resetAgentState(.originalCodex)
            connected = false
            error = L10n.text("Codex отключился. Подключись заново; отправка не будет повторена автоматически.", "Codex disconnected. Reconnect; the message will not be sent again automatically.")
        case .diagnostic(let message): error = message
        case .resolved(let requestID):
            let resolved = pending.filter { $0.interaction.id == requestID && $0.threadID == thread }
            pending.removeAll { action in resolved.contains { $0.id == action.id } }
            removeActionNotices(resolved)
            refreshDockBadge()
        case .usage(let turn, let total, let snapshot):
            if let id = thread {
                if let turn, let total {
                    let key = id + ":" + turn
                    // No baseline is assumed when attaching to a running turn.
                    if turnTokens[key] == nil { turnTokens[key] = ResponseTokenTracker(baseline: nil) }
                    turnTokens[key]?.observe(total)
                    tokenTotals[id] = total
                    // Some engines deliver the final usage notification after turn/completed.
                    if completedTurns[key] != nil,
                       var timing = try? await store.loadTimings(threadID: id)[turn] {
                        timing.tokens = turnTokens[key]?.result
                        if id == chatID, let index = items.lastIndex(where: { $0.kind == "assistant" && $0.turnID == turn }) {
                            items[index].timing = timing
                        }
                        try? await store.saveTiming(threadID: id, turnID: turn, timing: timing)
                    }
                } else if let total {
                    // A turn-less report is the engine's cumulative baseline before a turn starts.
                    tokenTotals[id] = total
                }
                // Turn-start and wake reports carry no request time; the cache age stays from the last call.
                var snapshot = snapshot
                if snapshot.lastRequestAt == nil, let previous = usage[id] {
                    snapshot.lastRequestAt = previous.lastRequestAt
                    snapshot.cacheTTL = snapshot.cacheTTL ?? previous.cacheTTL
                }
                usage[id] = snapshot
                try? await store.saveUsage(threadID: id, snapshot: snapshot)
            }
        case .started(let turn):
            if let thread,
               completedTurns[thread + ":" + turn] == nil {
                turnStarts[thread + ":" + turn] = turnStarts[thread + ":" + turn] ?? Date()
                if turnTokens[thread + ":" + turn] == nil {
                    turnTokens[thread + ":" + turn] = ResponseTokenTracker(baseline: tokenTotals[thread])
                }
                runs[thread, default: ChatRunState()].running = true
                runs[thread, default: ChatRunState()].turnID = turn
                runs[thread, default: ChatRunState()].status = nil
                backgroundWaits[thread] = nil
            }
        case .completed(let completion):
            flushDeltas()
            let turnID = completion.id
            if let threadID = thread,
               notifiedTurns.insert(threadID + ":" + turnID).inserted {
                let observed = ResponseTiming(startedAt: turnStarts.removeValue(forKey: threadID + ":" + turnID), completedAt: Date(),
                                              tokens: turnTokens[threadID + ":" + turnID]?.result)
                let timing = completion.timing(fallback: observed)
                if threadID == chatID, let index = items.lastIndex(where: { $0.kind == "assistant" && $0.turnID == turnID }) { items[index].timing = timing }
                try? await store.saveTiming(threadID: threadID, turnID: turnID, timing: timing)
                let status = completion.status
                let title = completion.hasError || (status != .completed && status != .cancelled) ? L10n.text("Ошибка в разговоре", "Conversation error") : status == .cancelled ? L10n.text("Ответ остановлен", "Response stopped") : L10n.text("Ответ готов", "Response ready")
                let completionID = "turn:" + threadID + ":" + turnID
                recordRecap(threadID: threadID, failed: completion.hasError || (status != .completed && status != .cancelled), error: completion.error)
                recordUnreadCompletion(threadID: threadID, completionID: completionID)
                postNotice(threadID: threadID, title: title, identifier: completionID, completionID: completionID,
                           body: state.chats.first { $0.id == threadID }?.recap)
            }
            finishActiveTurn(threadID: thread, turnID: turnID,
                             status: completion.status, hasError: completion.hasError)
            if let thread { refreshHistoryAfterTurn(thread) }
            let resolved = pending.filter { $0.threadID == thread && $0.interaction.turn == turnID }
            pending.removeAll { action in resolved.contains { $0.id == action.id } }
            removeActionNotices(resolved)
            refreshDockBadge()
            if completion.hasError { error = completion.error ?? L10n.text("Задача завершилась с ошибкой", "The task failed") }
        case .item(let item):
            if let thread { historyEventRevisions[thread, default: 0] += 1 }
            if let thread, item.kind == "assistant", !item.text.isEmpty { latestAnswers[thread] = item.text }
            if let thread, let source = event.session {
                do { try await store.recordTranscriptItem(item, conversationID: thread, source: source) }
                catch { self.error = error.localizedDescription }
            }
            guard thread == chatID else { return }
            flushDeltas()
            TranscriptItem.merge(item, into: &items)
        case .delta(let turn, let id, let text):
            if let thread { historyEventRevisions[thread, default: 0] += 1 }
            guard thread == chatID else { return }
            let agent = event.session?.connection == .appClaude ? "Claude" : "Codex"
            transcript.enqueue(id: id, text: text, turn: turn) { $0.agentName = agent }
        case .status(let turn, let text):
            guard let thread, runs[thread]?.running == true, turn == nil || runs[thread]?.turnID == turn else { return }
            runs[thread]?.status = text
        case .background(let tasks):
            if let thread { backgroundWaits[thread] = tasks > 0 ? tasks : nil }
        case .subagents(let list):
            if let thread { subagents[thread] = list.isEmpty ? nil : list }
        }
    }
    private func flushDeltas() { transcript.flush() }
}

// MARK: - Claude scheduled run records

/// Claude scheduled runs execute through the external print runner, which has no app-owned engine session.
/// Each run is shown as a read-only sidebar chat backed only by local history; it never dispatches,
/// resumes or retries anything, and a missing (deleted) record never affects the run's ledger entry.
@MainActor extension DeskModel {
    static var scheduledRecordReadOnly: String {
        L10n.text("Это запись запуска задания Claude. Она только для чтения: чтобы продолжить, начни новый чат.",
                  "This is a record of a Claude scheduled run. It is read-only: start a new chat to follow up.")
    }
    static var scheduledRecordFollowUpNotice: String {
        L10n.text("Запись запуска задания Claude. Ответ откроет новый чат с результатом этого запуска в контексте; сама запись не меняется.",
                  "A Claude scheduled run record. Replying opens a new chat with this run's result as context; the record itself stays unchanged.")
    }
    func isScheduledRecord(_ id: String) -> Bool { state.chats.first { $0.id == id }?.isScheduledRecord == true }

    /// Builds a handoff from the record's saved transcript. It never calls a model: the record holds the whole run.
    func scheduledRecordHandoff(_ chat: Chat, goal: String) async throws -> ContextHandoff {
        guard chat.isScheduledRecord, !isBusy(threadID: chat.id) else {
            throw ClientFailure(L10n.text("Дождись завершения запуска задания.", "Wait for the scheduled run to finish."))
        }
        guard let snapshot = try await store.loadTranscript(conversationID: chat.id), !snapshot.items.isEmpty else {
            throw ClientFailure(L10n.text("У этой записи нет сохранённой истории.", "This record has no saved history."))
        }
        var handoff = ContextHandoff(snapshot: snapshot)
        handoff.goal = goal
        handoff.instructions = L10n.text("Это продолжение запуска задания «\(chat.title)». Его запрос и результат приведены ниже как исторические данные; ответь на цель с их учётом.",
                                         "This continues the scheduled run “\(chat.title)”. Its prompt and result follow as historical evidence; address the goal with them in mind.")
        handoff.includeTranscript = true
        return handoff
    }

    /// Replying to a run record starts a new chat with the same agent, model, effort and permissions; the record stays read-only.
    /// The first message is sent once; a failed delivery is reported and never retried.
    func followUpScheduledRecord(_ record: Chat, text: String, project: Project) async {
        let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, let agent = record.nativeSession?.connection else { return }
        let model = currentModel, effort = claudeEffort, role = record.resolvedRole(in: project, catalog: roleCatalog).id
        do {
            let handoff = try await scheduledRecordHandoff(record, goal: goal)
            _ = try handoff.prompt()
            guard chatID == record.id else { return }
            let title = L10n.text("\(record.title) — продолжение", "\(record.title) — follow-up")
            guard await createHandoffChat(handoff, project: project, route: record.route ?? .direct, agent: agent,
                                          model: model, effort: agent == .appClaude ? effort : nil, role: role, title: title) else { return }
            chatDrafts[record.id] = nil
            await send()
        } catch { self.error = error.localizedDescription }
    }

    /// Creates the run's chat, then durably marks the run as running with the link. A record that cannot be saved
    /// is reported but does not block the run; the ledger write still gates dispatch.
    func attachScheduledRecord(_ run: JobRun, job: ManagedJob, prompt: String, project: Project) async throws {
        try Task.checkCancellation()
        guard !schedulerStopping else { throw CancellationError() }
        var thread: String?
        do { thread = try await createScheduledRecord(run, job: job, prompt: prompt, project: project) }
        catch {
            self.error = L10n.text("Не удалось создать чат запуска задания: ", "Could not create the scheduled run chat: ") + error.localizedDescription
        }
        jobLedger = try await jobStore.attach(run.id, thread: thread)
    }

    private func createScheduledRecord(_ run: JobRun, job: ManagedJob, prompt: String, project: Project) async throws -> String {
        if let existing = state.chats.first(where: { $0.scheduledRecord == run.id }) { return existing.id }
        let session = AgentSessionReference(connection: .appClaude, nativeID: "scheduled-" + run.id.uuidString.lowercased())
        guard !state.chats.contains(where: { $0.nativeSession == session }) else { throw ConversationIdentity.invalidStorage }
        var chat = Chat(session: session, projectID: project.id, title: run.name, model: job.model)
        chat.effort = job.effort; chat.route = .direct; chat.scheduledRecord = run.id
        let role = job.role(project: project, catalog: roleCatalog)
        chat.accessMode = role.legacyAccessMode; chat.roleID = role.id; chat.inheritsProjectAccess = false
        state.chats.append(chat)
        do { try await store.save(state) }
        catch { state.chats.removeAll { $0.id == chat.id }; throw error }
        let turn = run.id.uuidString
        var user = TranscriptItem(id: "user:" + turn, kind: "user", text: prompt); user.turnID = turn
        try await store.saveTranscript(LocalHistory.snapshot(conversation: chat.conversationID, source: session, items: [user]))
        runs[chat.id, default: ChatRunState()].running = true
        runs[chat.id, default: ChatRunState()].turnID = turn
        runs[chat.id, default: ChatRunState()].queuePaused = true
        if chatID == chat.id { items = [user] }
        return chat.id
    }

    /// Appends the confirmed outcome to the run's chat. Runs whose chat was deleted are left untouched.
    func finishScheduledRecord(_ id: UUID, status: JobRunStatus, output: String) async {
        guard let index = state.chats.firstIndex(where: { $0.scheduledRecord == id }) else { return }
        let chat = state.chats[index]
        runs[chat.id, default: ChatRunState()].running = false
        runs[chat.id, default: ChatRunState()].turnID = nil
        runs[chat.id, default: ChatRunState()].stopRequested = false
        guard let session = chat.nativeSession else { return }
        let turn = id.uuidString
        do {
            var entries = try await store.loadTranscript(conversationID: chat.id).map(LocalHistory.items) ?? []
            let started = jobLedger.runs.first { $0.id == id }?.started
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                var answer = TranscriptItem(id: "assistant:" + turn, kind: "assistant", text: text,
                                            timing: ResponseTiming(startedAt: started, completedAt: Date()))
                answer.turnID = turn; answer.agentName = "Claude"
                TranscriptItem.merge(answer, into: &entries)
            }
            if status != .completed {
                var note = TranscriptItem(id: "status:" + turn, kind: "activity", text: status.title); note.turnID = turn
                TranscriptItem.merge(note, into: &entries)
            }
            let snapshot = try LocalHistory.snapshot(conversation: chat.conversationID, source: session, items: entries, completeness: .complete)
            try await store.saveTranscript(snapshot)
            if chatID == chat.id && !loadingChat { items = LocalHistory.items(snapshot) }
        } catch { self.error = error.localizedDescription }
        state.chats[index].updated = Date()
        let title = status == .completed ? L10n.text("Ответ готов", "Response ready")
            : status == .interrupted ? L10n.text("Ответ остановлен", "Response stopped") : L10n.text("Ошибка в разговоре", "Conversation error")
        let completionID = "turn:" + chat.id + ":" + turn
        recordUnreadCompletion(threadID: chat.id, completionID: completionID)
        postNotice(threadID: chat.id, title: title, identifier: completionID, completionID: completionID)
    }
}
