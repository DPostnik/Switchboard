import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import ContextCore
import ContextTranscript
import AgentContract

/// What the app menu reads from the model. The App body holds the model without observing it, so the
/// menu commands observe this object instead; it publishes only when an item's enabled state flips.
@MainActor final class AppMenuState: ObservableObject {
    /// The model finished booting: Open Project is available.
    @Published private(set) var ready = false
    /// A project is selected: New Chat is available.
    @Published private(set) var hasProject = false
    func update(ready: Bool, hasProject: Bool) {
        if self.ready != ready { self.ready = ready }
        if self.hasProject != hasProject { self.hasProject = hasProject }
    }
}

/// Plugin metrics (request counters) change on most polls during a turn; only the plugin settings observe them.
@MainActor final class PluginMetricsState: ObservableObject {
    @Published private(set) var metrics: [String: [PluginMetric]] = [:]
    func update(_ pluginID: String, _ value: [PluginMetric]?) {
        if metrics[pluginID] != value { metrics[pluginID] = value }
    }
    func removeAll() { if !metrics.isEmpty { metrics.removeAll() } }
}

private extension PluginStatus {
    func sameIgnoringMetrics(_ other: PluginStatus) -> Bool {
        protocolVersion == other.protocolVersion && pluginID == other.pluginID && pluginVersion == other.pluginVersion
            && instance == other.instance && detail == other.detail && detailTranslations == other.detailTranslations
    }
}

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

/// What an edit or move of a queued message did.
enum QueueChange: Equatable {
    case applied, unchanged
    /// The message is claimed for delivery (or the chat cannot change now); nothing changed.
    case claimed
    /// The message is no longer queued: it was sent or removed.
    case gone
}

/// A queued message open in the in-place editor; `draft` is the editor's live text, so typing never publishes the model.
@MainActor final class QueueEditSession {
    let id: String
    let threadID: String
    let original: String
    let draft = ComposerState()
    /// Moves keyboard focus into the editor once it appears.
    let focus = UUID()
    init(_ message: QueuedMessage) {
        id = message.id; threadID = message.threadID; original = message.text
        draft.text = message.text
    }
}

/// ID -> position in `SavedState.chats` and `.projects`; the first position wins when an ID repeats.
struct StateLookup {
    let chats: [String: Int]
    let projects: [UUID: Int]
    init(_ state: SavedState) {
        chats = Dictionary(state.chats.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        projects = Dictionary(state.projects.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }
}

private struct ChatRunState: Equatable {
    var running = false
    var sending = false
    var stopRequested = false
    var turnID: String?
    var queuePaused = true
    var priorityMessageID: String?
    /// The queued message whose "Interrupt and send" stopped the last turn; it goes out with `InterruptedTurnNote`.
    var interruptedFor: String?
}

@MainActor final class DeskModel: ObservableObject {
    let mobileRemote = MobileRemoteHost()
    /// Stops processes that chats leave behind (labelled through the launch environment).
    let orphanProcesses = OrphanProcessController()
    /// Wall-clock checks for armed "continue after limit reset" requests (`LimitResumeScheduling`).
    let limitResumeClock = LimitResumeClock()
    /// Checks for sub-agents that stopped reporting (`SubagentWatching`).
    let subagentWatch = SubagentWatchClock()
    var remoteDeliveryResults: [String: Bool] = [:]
    private var configuringRemoteChats: Set<String> = []
    /// Chat ID -> last stored messages sent to the phone, keyed by store revision and native session.
    private var remoteHistoryCache: [String: (revision: Int, session: AgentSessionReference?, messages: [TranscriptItem])] = [:]
    /// Chat ID -> the latest stored messages of a web chat in full (`WebChats.messageLimit`), keyed the same way.
    private var webHistoryCache: [String: (revision: Int, session: AgentSessionReference?, messages: [TranscriptItem])] = [:]
    @Published var configuringBrowserChats: Set<String> = []
    @Published var newChatBrowserProfiles: [UUID: UUID] = [:]
    /// Project ID -> role picked in the composer for the project's next new chat; absent follows the project default.
    /// It applies to that chat only; the project default changes in the project settings.
    @Published var newChatRoles: [UUID: String] = [:]
    /// Project ID -> agent ID -> model and effort picked in the composer for the project's next new chat; absent
    /// follows the project default, then the app default. It never changes either default.
    @Published var newChatModelChoices: [UUID: [String: ModelChoice]] = [:]
    /// Project ID -> role add-ons picked for the project's next new chat; absent follows the project's add-ons.
    @Published var newChatAddOns: [UUID: Set<RoleAddOn>] = [:]
    /// Project ID -> where the project's next new chat works; absent is the project folder (`ChatWorktrees.swift`).
    @Published var newChatWorkspaces: [UUID: NewChatWorkspace] = [:]
    /// A new chat's worktree is being created; sending waits for it.
    @Published var creatingWorktree = false
    /// Worktrees of archived or deleted chats waiting for the user's answer.
    @Published var worktreeRemovalOffers: [WorktreeRemovalOffer] = []
    var worktrees = GitWorktrees()
    /// Chat ID -> PID of its running Chrome for Testing; refreshed by `startBrowserActivityMonitor`.
    @Published var runningBrowserChats: [String: Int32] = [:] {
        didSet { syncBrowsersMenu() }
    }
    /// Observed by the Browsers menu instead of the model (`ContextDeskApp`).
    let browsersMenu = RunningBrowsersState()
    @Published private(set) var composerFocusRequest: UUID?
    @Published private(set) var plugins: [ProviderPlugin] = []
    @Published private(set) var pluginIssues: [String] = []
    @Published private(set) var pluginStatuses: [String: PluginStatus] = [:]
    @Published private(set) var pluginMessages: [String: String] = [:]
    let pluginMetrics = PluginMetricsState()
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
    /// Branch and changes per project folder (`GitStatusStore`).
    let gitStatus = GitStatusStore()
    /// The ACP agent catalog and the agents installed from it (`<root>/agents`); no I/O until Settings asks.
    var agentCatalog = AgentCatalogController()
    /// Pull request badges and the per-chat PR watch (`PullRequestStore`).
    let pullRequests: PullRequestStore
    /// Latest messages per chat for the chat directory, reloaded when the chat changes.
    private var directoryHistoryCache: [String: (updated: Date, messages: [TranscriptItem])] = [:]
    @Published var state = SavedState() {
        // Any state change may add, remove or re-key a chat; the next event rebuilds the map.
        didSet { nativeSessionMap = nil; lookup = nil; sidebarChats = nil; syncMenu(); syncBrowsersMenu() }
    }
    /// Observed by the app menu instead of the model (`ContextDeskApp`).
    let menu = AppMenuState()
    /// Command palette and chat shortcuts (`ChatNavigation.swift`).
    let navigation = DeskNavigation()
    private func syncMenu() { menu.update(ready: !isBootstrapping, hasProject: selectedProject != nil) }
    private func syncBrowsersMenu() {
        guard !runningBrowserChats.isEmpty else { return browsersMenu.update([]) }
        browsersMenu.update(state.chats.compactMap { chat in
            runningBrowserChats[chat.id] == nil ? nil
                : RunningBrowsersState.Entry(id: chat.id, label: [chat.title, project(chat.projectID)?.name].compactMap { $0 }.joined(separator: " · "))
        })
    }
    /// (connection, native ID) -> chat ID for `receive`, built on demand after a state change instead of
    /// filtering every chat for every streamed delta.
    private var nativeSessionMap: NativeSessionMap?
    private func appID(for session: AgentSessionReference) -> String? {
        if nativeSessionMap == nil { nativeSessionMap = NativeSessionMap(chats: state.chats) }
        return nativeSessionMap?.appID(for: session)
    }
    /// Chat and project positions by ID, built on demand after a state change: views read chats by ID many times
    /// per render (`selectedChat`, `canDeleteChat`, row menus), and a scan of every chat for each read added up.
    private var lookup: StateLookup?
    private var stateLookup: StateLookup {
        if let lookup { return lookup }
        let built = StateLookup(state)
        lookup = built
        return built
    }
    /// The chat with this ID (the first one, as a scan would find it).
    func chat(_ id: String) -> Chat? {
        guard let index = stateLookup.chats[id], state.chats.indices.contains(index), state.chats[index].id == id else { return nil }
        return state.chats[index]
    }
    func project(_ id: UUID) -> Project? {
        guard let index = stateLookup.projects[id], state.projects.indices.contains(index), state.projects[index].id == id else { return nil }
        return state.projects[index]
    }
    func hasChat(_ id: String) -> Bool { chat(id) != nil }
    private var sidebarChats: [UUID: [Chat]]?
    /// Active chats per project in sidebar order, grouped once per state change instead of once per project row.
    var activeChatsByProject: [UUID: [Chat]] {
        if let sidebarChats { return sidebarChats }
        let grouped = state.activeChatsByProject()
        sidebarChats = grouped
        return grouped
    }
    func sidebarSections(_ listing: SidebarListing) -> SidebarSections {
        state.sidebarSections(listing, chatsByProject: activeChatsByProject)
    }
    @Published var projectID: UUID? {
        didSet { syncMenu() }
    }
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
    /// Full-text index of chat dialogue for the archive search and the chat-search tools (`ChatSearch.swift`).
    let chatSearchIndex: ChatSearchIndex
    var chatIndexTask: Task<Void, Never>?
    /// The chats as the last completed index run saw them; an unchanged list skips the run.
    var chatIndexedInfos: [ChatSearchIndex.ChatInfo]?
    var titleTasks: [String: Task<Void, Never>] = [:]
    private var titleRunners: [String: AgentGenerationRunner] = [:]
    private var manuallyNamedChatIDs: Set<String> = []
    let summaryResources: URL?
    /// The home whose parent holds the app's workflow skills (`summarySkillsDirectory`).
    let summaryHome: URL
    let transcript = TranscriptPresentation()
    /// Git checkpoints at turn start and end (`TurnCheckpointing.swift`).
    let turnCheckpoints = TurnCheckpointCoordinator()
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
    /// One-time launch pass that reduces the tool bodies of archived chats (`ActivityCleanup.swift`).
    var activityCleanupTask: Task<Void, Never>?
    /// The launch pass starts after this delay and, while any chat runs or sends, pauses before each chat so live turns
    /// keep most of the store and adapter actors; tests shorten both.
    var activityCleanupLaunchDelay: Duration = .seconds(60)
    var activityCleanupBusyPause: Duration = .seconds(1)
    /// Set by the app delegate once a quit or restart has started. Connections close in the next seconds, so a send
    /// in this window cannot be confirmed: `send` and a failing `deliver` keep the message in the persisted queue instead.
    var shuttingDown = false
    private var historyRefreshTasks: [String: Task<Void, Never>] = [:]
    private var historyEventRevisions: [String: Int] = [:]
    @Published var pending: [PendingAction] = []
    /// Chats that asked for the pending restart; mirrored from AppRestartController for the sidebar.
    @Published var restartWaitingChatIDs: [String] = []
    /// Thread ID -> context usage; lives in `activity`, so a usage report does not publish the model.
    var usage: [String: UsageSnapshot] {
        get { activity.usage }
        set { activity.replaceUsage(newValue) }
    }
    /// Models the current agent's engine listed; empty for catalog agents.
    var models: [AgentModelInfo] { agentState(currentAgent).models }
    @Published var draftEffort = "medium"
    var effort: String {
        get {
            // A catalog agent's pick is `claudeEffort`; it never leaks into this free-form effort.
            guard let chat = selectedChat else {
                return (modelCatalog(currentAgent) == nil ? newChatChoice(currentAgent, project: projectID).effort : nil) ?? draftEffort
            }
            return chat.effort ?? "medium"
        }
        set {
            if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
                state.chats[index].effort = newValue
                persist()
            } else { pickNewChatModel { $0.effort = newValue } }
        }
    }
    private var newChatDrafts: [UUID: String] = [:]
    private var chatDrafts: [String: String] = [:]
    /// The composer's live text. It is not part of the model's publication: the editor writes it on every
    /// keystroke, and only the views bound to it (editor, placeholder, send and restore buttons) follow it.
    let composer = ComposerState()
    /// The composer text as the model and its callers see it; a write reaches the editor through `composer`.
    var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }
    /// Every change, typed or set, is kept for the chat (or the project's new chat) it belongs to.
    private func storeDraft(_ draft: String) {
        if let chatID {
            chatDrafts[chatID] = draft.isEmpty ? nil : draft
        } else if let projectID {
            newChatDrafts[projectID] = draft.isEmpty ? nil : draft
        }
    }
    /// Registered agent connections in the factory's order (`AgentIntegrationFactory.profiles`).
    let agentIDs: [AgentConnectionID]
    private let slots: [AgentConnectionID: AgentConnectionSlot]
    /// Connection, sign-in, descriptor, models and limits of every registered connection. One dictionary of values, so
    /// every change publishes the model as the separate per-agent properties did.
    @Published var agentStates: [AgentConnectionID: AgentConnectionState]
    func agentState(_ id: AgentConnectionID?) -> AgentConnectionState { id.flatMap { agentStates[$0] } ?? AgentConnectionState() }
    func client(_ id: AgentConnectionID) -> AgentClient? { slots[id]?.client }
    /// The connection's runner for isolated generation (archive summaries).
    func generationRunner(connection id: AgentConnectionID) -> AgentGenerationRunner? { slots[id]?.generationRunner }
    func registration(_ id: AgentConnectionID) -> AgentRegistration? { slots[id]?.registration }
    func profile(_ id: AgentConnectionID?) -> AgentProfile? { id.flatMap { slots[$0]?.profile } }
    func traits(_ id: AgentConnectionID?) -> AgentAppTraits { profile(id)?.traits ?? [] }
    func isRegistered(_ id: AgentConnectionID?) -> Bool { id.map { slots[$0] != nil } ?? false }
    /// The registered connection that runs jobs stored with `engine`.
    func connection(for engine: JobEngine) -> AgentConnectionID? { agentIDs.first { slots[$0]?.profile.engine == engine } }
    /// The first registered connection with all of `traits`.
    func firstAgent(with traits: AgentAppTraits) -> AgentConnectionID? { agentIDs.first { self.traits($0).isSuperset(of: traits) } }
    func connectionOfChat(_ id: String) -> AgentConnectionID? { chat(id)?.nativeSession?.connection }
    /// Name of the agent that owns a session; an unknown agent shows its raw ID, never another agent's name.
    func agentName(_ connection: AgentConnectionID?) -> String { profile(connection)?.name ?? connection?.agent.rawValue ?? "" }
    var anyAgentConnecting: Bool { agentStates.values.contains { $0.connecting } }
    /// Agents new chats, jobs and limits may pick: every registered one whose CLI is present.
    var selectableAgentIDs: [AgentConnectionID] { agentIDs.filter { agentState($0).installed } }
    /// Looks for the CLIs the user installs (file checks only); a found or removed CLI updates its agent.
    func refreshInstallations() {
        for id in agentIDs {
            guard let installation = profile(id)?.installation else { continue }
            let installed = installation.isInstalled()
            if agentState(id).installed != installed { agentStates[id]?.installed = installed }
        }
    }
    /// Stops an agent's engine before its CLI is removed; its chats show it disconnected until it connects again.
    func stopAgent(_ id: AgentConnectionID) async {
        guard let slot = slots[id] else { return }
        slot.historyBackfillTask?.cancel()
        await slot.client.stop()
        agentStates[id]?.connected = false; agentStates[id]?.authenticated = false
        resetAgentState(id)
    }
    /// A connection serving optimizer plugins is connecting: plugin settings wait for it.
    var connecting: Bool { agentIDs.contains { traits($0).contains(.optimizerPlugins) && agentState($0).connecting } }
    @Published private(set) var isBootstrapping = true {
        didSet { syncMenu() }
    }
    /// Run flags per chat; they change at turn and send boundaries. The live activity line is in `activity.statuses`.
    @Published private var runs: [String: ChatRunState] = [:]
    /// Values that change many times per turn, observed per property by the views that show them (`ChatActivityStore`).
    let activity = ChatActivityStore()
    /// Every change Combine consumers (phone sync, notch island, Fringe) follow: the model's publications and `activity`'s.
    /// `objectWillChange` alone no longer covers status lines, usage, sub-agents and background waits.
    var changes: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.merge(with: activity.changes).eraseToAnyPublisher()
    }
    /// Idle chats whose agent still runs background tasks and will resume on its own; thread ID -> task count.
    private(set) var backgroundWaits: [String: Int] {
        get { activity.backgroundWaits }
        set { activity.replaceBackgroundWaits(newValue) }
    }
    /// Thread ID -> sub-agents its agent delegated to (running ones and those finished since the last user message).
    private(set) var subagents: [String: [AgentSubagent]] {
        get { activity.subagents }
        set { activity.replaceSubagents(newValue) }
    }
    /// Thread ID -> background commands and watchers of its agent (running ones and those finished since the last user message).
    private(set) var backgroundTasks: [String: [AgentBackgroundTask]] {
        get { activity.backgroundTasks }
        set { activity.replaceBackgroundTasks(newValue) }
    }
    /// Thread ID -> running sub-agents silent longer than `SubagentWatch` allows; set by `SubagentWatching`.
    var stalledSubagents: [String: Set<String>] {
        get { activity.stalledSubagents }
        set { activity.replaceStalledSubagents(newValue) }
    }
    /// Thread ID -> the commands and the settings its agent session last reported (ACP-shaped, stage C). Kept for the
    /// composer; not published because no view shows them yet (the composer has no command list, and the model and
    /// effort chips still come from the agent's model catalog).
    private(set) var sessionCommands: [String: [AgentCommand]] = [:]
    private(set) var sessionConfigOptions: [String: [AgentConfigOption]] = [:]
    /// Stop requests in flight, keyed by `stopKey`; their buttons stay disabled until the engine answers.
    @Published private(set) var stoppingTasks: Set<String> = []
    @Published private(set) var deletingChatIDs: Set<String> = []
    @Published private(set) var archivingChatIDs: Set<String> = []
    func isChangingChat(_ id: String) -> Bool { deletingChatIDs.contains(id) || archivingChatIDs.contains(id) || configuringRemoteChats.contains(id) || configuringBrowserChats.contains(id) }
    func isArchived(_ id: String) -> Bool { chat(id)?.isArchived == true }
    var selectedChatIsArchived: Bool { selectedChat?.isArchived == true }
    private var completedTurns: [String: (status: AgentExecutionOutcome, hasError: Bool)] = [:]
    private var currentRunKey: String { chatID ?? "new:" + selectionGeneration.uuidString }
    var sending: Bool { runs[currentRunKey]?.sending == true }
    /// Any chat with a running turn or a send in flight; background passes yield to them.
    var anyChatRunsOrSends: Bool { runs.values.contains { $0.running || $0.sending } }
    var busy: Bool { runs[currentRunKey]?.running == true }
    var workingStatus: String? { busy ? activity.statuses[currentRunKey] : nil }
    var workingSince: Date? { busy ? runs[currentRunKey]?.turnID.flatMap { turnStarts[currentRunKey + ":" + $0] } : nil }
    var queuePaused: Bool { runs[currentRunKey]?.queuePaused ?? true }
    var priorityMessageID: String? { runs[currentRunKey]?.priorityMessageID }
    var anyBusy: Bool { preparingHandoff || creatingHandoff || jobLedger.runs.contains { $0.status.active } || summaryTask != nil || !deletingChatIDs.isEmpty || !archivingChatIDs.isEmpty || runs.values.contains { $0.running || $0.sending } }
    func isBusy(threadID: String) -> Bool { runs[threadID]?.running == true }
    func isSending(threadID: String) -> Bool { runs[threadID]?.sending == true }
    /// Chats with a running or sending turn, without scanning every chat.
    var activeRunChatIDs: [String] { runs.compactMap { $0.value.running || $0.value.sending ? $0.key : nil } }
    /// Live activity label and start of a chat's running turn, for the notch island.
    func runActivity(threadID: String) -> (status: String?, since: Date?) {
        guard let run = runs[threadID], run.running else { return (nil, nil) }
        return (activity.statuses[threadID], run.turnID.flatMap { turnStarts[threadID + ":" + $0] })
    }
    /// An idle chat whose agent will continue on its own once its background tasks finish.
    func backgroundWaitNotice(_ threadID: String) -> String? {
        guard !isBusy(threadID: threadID), let count = backgroundWaits[threadID] else { return nil }
        return Self.backgroundWaitText(count)
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
    /// The end of a background task's output; read-only, so a panel may poll it.
    func taskOutput(threadID: String, task: String) async throws -> AgentTaskOutput {
        try await clientForChat(threadID).taskOutput(task, session: sessionForChat(threadID))
    }
    private var turnStarts: [String: Date] = [:]
    private var tokenTotals: [String: TokenCounters] = [:]
    private var turnTokens: [String: ResponseTokenTracker] = [:]
    private func resetRuns() {
        runs.removeAll(); activity.replaceStatuses([:]); turnStarts.removeAll(); tokenTotals.removeAll(); turnTokens.removeAll()
    }
    @Published var loadingChat = false
    @Published var error: String?
    /// Project settings changes agents proposed (`SettingsProposalInbox`), waiting for the user's decision.
    @Published private(set) var settingsProposals: [SettingsProposalReview] = []
    /// The queued message being edited in place, at most one at a time.
    @Published private(set) var queueEdit: QueueEditSession?
    @Published var notificationStatus = L10n.text("Уведомления не включены", "Notifications are off")
    /// macOS allows the app's notifications; the "Needs you" page offers to enable them otherwise.
    @Published var notificationsAllowed = false
    var loadedThreads: Set<String> = []
    private var selectionGeneration = UUID()
    private var booted = false
    let store: AppStore
    /// Every capability use and permission decision (roles plan, Phase 0); writes never block a decision.
    let capabilityLedger: CapabilityLedger
    /// `agents` comes from `AgentIntegrationFactory.registrations` (the convenience initializer there builds it).
    init(agents: [AgentRegistration], store: AppStore, capabilityLedger: CapabilityLedger, pluginDirectory: URL,
         summaryResources: URL?, summaryHome: URL, jobStore: JobStore) {
        self.jobStore = jobStore
        self.attentionStore = AttentionStore(file: jobStore.file.deletingLastPathComponent().appendingPathComponent("attention.json"))
        self.pullRequests = PullRequestStore(file: jobStore.file.deletingLastPathComponent().appendingPathComponent(PullRequestWatchStore.fileName))
        self.chatSearchIndex = ChatSearchIndex(file: jobStore.file.deletingLastPathComponent().appendingPathComponent(ChatSearchIndex.fileName))
        var ids: [AgentConnectionID] = [], slots: [AgentConnectionID: AgentConnectionSlot] = [:]
        for registration in agents where slots[registration.connection] == nil {
            ids.append(registration.connection); slots[registration.connection] = AgentConnectionSlot(registration)
        }
        self.agentIDs = ids; self.slots = slots
        self.agentStates = Dictionary(uniqueKeysWithValues: ids.map { id in
            var state = AgentConnectionState()
            state.installed = slots[id]?.profile.installation?.isInstalled() ?? true
            return (id, state)
        })
        self.store = store
        self.capabilityLedger = capabilityLedger
        self.pluginDirectory = pluginDirectory
        self.summaryResources = summaryResources; self.summaryHome = summaryHome
        composer.onChange = { [weak self] text in self?.storeDraft(text) }
        refreshPlugins()
        if Perf.enabled { publicationSignposts = observePublications { Perf.event("model.publish", $0) } }
    }
    /// `model.publish` signpost subscriptions, only with `PerfSignposts` on.
    private var publicationSignposts: [AnyCancellable] = []

    // Read the published IDs once: inside the predicate the @Published getter ran for every chat on every render.
    var selectedProject: Project? { guard let id = projectID else { return nil }; return project(id) }
    var selectedChat: Chat? { guard let id = chatID else { return nil }; return chat(id) }
    var chats: [Chat] { projectID.map { state.orderedChats(projectID: $0, archived: false) } ?? [] }
    var currentAction: PendingAction? { pending.first { $0.threadID == chatID } }
    var currentUsage: UsageSnapshot? { chatID.flatMap { usage[$0] } }
    var canSend: Bool { (selectedChat?.isScheduledRecord != true || !busy) && !creatingHandoff && (chatID.map { chatIsAvailable($0) } ?? isRegistered(currentAgent)) && !selectedChatIsArchived && !isChangingChat(currentRunKey) && routeIsAvailable(currentRoute) && currentAgentConnected && currentAgentAuthenticated && selectedProject != nil && !sending && !creatingWorktree && !loadingChat && composer.hasMessage }
    var supportedEfforts: [String] {
        models.first { $0.id == currentModel }?.efforts ?? []
    }

    private var photoCleanupTask: Task<Void, Never>?
    private func cleanTemporaryPhotos() {
        guard photoCleanupTask != nil else { return }
        // Queued messages (a phone's among them) may still point at their photos.
        let active = Set(runs.filter { $0.value.running || $0.value.sending }.map(\.key))
            .union(pending.map(\.threadID)).union(queuedMessages.map(\.threadID))
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
        if state.migrateAccessPresets() { persist() }
        // Sign the cookie-import consent files once, when the signing key is first created (audit H2).
        do {
            let signed = try ChromeSessionImportPolicy.adoptExistingPolicies()
            if !signed.isEmpty { AppLog.browser.notice("Signed \(signed.count, privacy: .public) existing cookie-import permission files") }
        } catch { AppLog.browser.error("Could not sign cookie-import permission files: \(error.localizedDescription, privacy: .public)") }
        Task { [capabilityLedger] in try? await capabilityLedger.sweep() }
        watchSettingsProposals()
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
        await startPullRequests()
        await startEventLoops()
        refreshInstallations()
        for id in agentIDs where traits(id).contains(.connectsAtLaunch) { await connect(id); step(agentName(id)) }
        // Scheduled tasks run as chats of their agent's connection, so enabled ones need it connected too.
        let jobEngines = Set((try? await jobStore.load())?.jobs.filter(\.enabled).map(\.engine) ?? [])
        for id in agentIDs where !traits(id).contains(.connectsAtLaunch) {
            if state.defaultConnection == id || profile(id).map({ jobEngines.contains($0.engine) }) == true
                || state.chats.contains(where: { $0.nativeSession?.connection == id }) { await connect(id) }
            step(agentName(id))
        }
        await startScheduler(); step("scheduler")
        startActivityCleanup()
        Task { await mobileRemote.restoreOnLaunch(model: self) } // Network sign-in must not hold up boot.
        continueAfterRestart(RestartContinuation.take())
        releaseQueueHeldForRestart()
        startLimitResumeClock()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
        notificationStatus = settings.authorizationStatus == .authorized ? L10n.text("Уведомления включены", "Notifications are on") : L10n.text("Уведомления не включены", "Notifications are off")
    }
    /// One event loop per registered connection; every event names the connection it came from.
    func startEventLoops() async {
        let sessions = state.chats.compactMap(\.nativeSession)
        for id in agentIDs {
            guard let slot = slots[id], slot.eventTask == nil else { continue }
            await slot.client.observeEvents(sessions: sessions.filter { $0.connection == id })
            slot.eventTask = Task { [weak self, client = slot.client] in
                for await event in client.events { await self?.receive(event, from: id) }
            }
        }
    }
    var defaultRoute: RequestRoute { state.defaultRoute ?? .direct }
    /// A new chat takes the default route only on an agent that runs optimizer plugins; others work directly.
    func newChatRoute(_ agent: AgentConnectionID) -> RequestRoute { traits(agent).contains(.optimizerPlugins) ? defaultRoute : .direct }
    var currentRoute: RequestRoute { selectedChat.map { $0.route ?? .direct } ?? newChatRoute(currentAgent) }
    var neededPluginIDs: Set<String> {
        Set(((traits(state.defaultConnection).contains(.optimizerPlugins) ? [defaultRoute] : []) + state.chats.filter { chatIsAvailable($0.id) }.compactMap(\.route)).filter { $0 != .direct }.map(\.rawValue))
    }
    /// The connection that starts and serves optimizer plugins.
    var optimizerHost: AgentConnectionID? { firstAgent(with: .optimizerPlugins) }
    /// The agent optimizer requirements are checked for; without a plugin host no route is compatible.
    private var optimizerAgent: AgentID { optimizerHost?.agent ?? AgentID(rawValue: "") }
    var availableRoutes: [RequestRoute] {
        [.direct] + Set(plugins.map(\.route) + [defaultRoute, currentRoute] + state.chats.compactMap(\.route))
            .filter { $0 != .direct }.sorted { $0.rawValue < $1.rawValue }
    }
    func routeTitle(_ route: RequestRoute, language: AppLanguage = L10n.language) -> String {
        if route == .direct { return L10n.text("Без плагина", "No plugin", language: language) }
        return plugins.first(where: { $0.id == route.rawValue })?.manifest.localizedTitle(language: language)
            ?? L10n.text("\(route.rawValue) (не установлен)", "\(route.rawValue) (not installed)", language: language)
    }
    /// `agent` nil checks the route for the optimizer plugin host.
    func routeCompatibilityIssue(_ route: RequestRoute, agent: AgentID? = nil) -> String? {
        if route == .direct { return nil }
        guard let plugin = plugins.first(where: { $0.id == route.rawValue }) else {
            return L10n.text("Плагин не установлен. Сохранённый маршрут не заменён.", "Plugin is not installed. The saved route has not been replaced.")
        }
        return OptimizerCompatibility.issue(agent: agent ?? optimizerAgent, requirements: plugin.manifest.requirements)
    }
    func routeIsAvailable(_ route: RequestRoute) -> Bool {
        route == .direct || (routeCompatibilityIssue(route) == nil && pluginStatuses[route.rawValue] != nil)
    }
    func routeMessage(_ route: RequestRoute, language: AppLanguage = L10n.language) -> String {
        if route == .direct {
            let name = agentName(optimizerHost)
            return L10n.text("\(name) работает напрямую, без обработки запросов плагином.", "\(name) works directly, without a plugin processing requests.", language: language)
        }
        if let plugin = plugins.first(where: { $0.id == route.rawValue }),
           let issue = OptimizerCompatibility.issue(agent: optimizerAgent, requirements: plugin.manifest.requirements, language: language) { return issue }
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
    /// Applied by reconnecting the connected agents that do not share one engine process (their reconnect waits only for
    /// their own chats); a shared engine picks it up at its next reconnect.
    func selectUserChromeEnabled(_ enabled: Bool) {
        state.userChromeEnabled = enabled; persist()
        for id in agentIDs where !traits(id).contains(.sharedEngine) && agentState(id).connected { Task { await connect(id) } }
    }
    private func stopPlugins() async {
        pluginTask?.cancel(); pluginTask = nil
        for runtime in pluginRuntimes.values { await runtime.stop() }
        pluginRuntimes.removeAll(); pluginStatuses.removeAll(); pluginMetrics.removeAll()
    }
    /// Connects one registered agent. A shared engine stops first and waits for the whole app to be idle, starting the
    /// optimizer plugins it serves; a per-chat engine waits only for its own chats and keeps their processes.
    func connect(_ id: AgentConnectionID) async {
        guard let slot = slots[id], !agentState(id).connecting else { return }
        // An agent whose CLI is missing starts no process.
        if let installation = slot.profile.installation {
            let installed = installation.isInstalled()
            if agentState(id).installed != installed { agentStates[id]?.installed = installed }
            guard installed else { return }
        }
        let traits = slot.profile.traits, shared = traits.contains(.sharedEngine)
        // A running shared engine (or the one serving optimizer plugins) restarts only when the whole app is idle; a first
        // connection of another shared engine has nothing to stop and waits only for its own chats.
        if shared && (agentState(id).connected || traits.contains(.optimizerPlugins)) { guard !anyBusy else { return } }
        else { guard !state.chats.contains(where: { $0.nativeSession?.connection == id && isBusy(threadID: $0.id) }) else { return } }
        if traits.contains(.optimizerPlugins) { refreshPlugins() }
        agentStates[id]?.connecting = true; agentStates[id]?.connected = false
        clearLimits(id)
        defer { agentStates[id]?.connecting = false }
        slot.historyBackfillTask?.cancel()
        if shared { await slot.client.stop() } else { agentStates[id]?.authenticated = false }
        resetAgentState(id)
        var optimizers: [AgentOptimizerEndpoint] = []
        if traits.contains(.optimizerPlugins) {
            await stopPlugins()
            pluginMessages.removeAll()
            let optimizerEnvironment: [String: String]
            do { optimizerEnvironment = try await slot.client.integration.optimizerEnvironment(home: slot.registration.home).value() }
            catch { self.error = error.localizedDescription; return }
            for pluginID in neededPluginIDs.sorted() {
                guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
                    pluginMessages[pluginID] = L10n.text("Плагин не установлен. Установи его и нажми «Применить выбор».", "Plugin is not installed. Install it, then click Apply selection.")
                    continue
                }
                let runtime = ProviderPluginRuntime(plugin: plugin, environment: optimizerEnvironment)
                if let issue = OptimizerCompatibility.issue(agent: id.agent, requirements: plugin.manifest.requirements) {
                    pluginMessages[pluginID] = issue; continue
                }
                do {
                    let endpoint = try await runtime.start()
                    let status = try await runtime.status()
                    optimizers.append(.init(id: plugin.id, endpoint: endpoint))
                    applyPluginStatus(status, for: pluginID)
                    pluginRuntimes[pluginID] = runtime
                } catch {
                    await runtime.stop()
                    pluginMessages[pluginID] = error.localizedDescription
                }
            }
        }
        do {
            let descriptor = try await slot.client.start(.init(home: slot.registration.home, resources: Bundle.main.resourceURL,
                browserEnabled: state.browserEnabled == true, userChromeEnabled: state.userChromeEnabled != false, optimizers: optimizers))
            agentStates[id]?.descriptor = descriptor
            agentStates[id]?.connected = true
            if descriptor.capabilities.contains(.workflowRegistration), summaryResources != nil {
                do {
                    try prepareSummarySkills()
                    try await slot.client.registerWorkflows(at: summarySkillsDirectory)
                } catch { self.error = L10n.text("Не удалось подключить навыки рутин: ", "Could not load routine skills: ") + error.localizedDescription }
            }
            if shared { clearConnectionError() }
            await refreshAccount(id)
            // Reading every history takes seconds with many long chats; it must not hold up launch.
            let chats = state.chats.filter { $0.nativeSession?.connection == id }
            slot.historyBackfillTask = Task { [weak self] in await self?.backfillHistory(chats) }
            if traits.contains(.optimizerPlugins) { monitorPlugins(host: id) }
        } catch {
            agentStates[id]?.connected = false; self.error = error.localizedDescription
            if traits.contains(.optimizerPlugins) { await stopPlugins() }
        }
    }
    /// Reconnects every connection whose single engine process reads app settings (the browser) only at start.
    /// One that connects on first use and is not connected yet starts nothing.
    func reconnectSharedEngines() async {
        for id in agentIDs where traits(id).contains(.sharedEngine) && (traits(id).contains(.connectsAtLaunch) || agentState(id).connected) {
            await connect(id)
        }
    }
    /// Every 5 s for every plugin. A plugin that stops pauses its chats' queues; with one of them busy the host
    /// connection is stopped too, and nothing is retried.
    /// Stores a plugin's status: the metrics go to `pluginMetrics`, and `pluginStatuses` publishes only when the
    /// rest changes, so a counter tick no longer redraws every view observing the model.
    func applyPluginStatus(_ status: PluginStatus?, for pluginID: String) {
        pluginMetrics.update(pluginID, status?.metrics)
        let current = pluginStatuses[pluginID]
        guard let status else {
            if current != nil { pluginStatuses[pluginID] = nil }
            return
        }
        if current.map({ !$0.sameIgnoringMetrics(status) }) ?? true { pluginStatuses[pluginID] = status }
    }
    /// A turn runs through a plugin: its health is checked every 5 s instead of every 30 s.
    private var pluginRouteInUse: Bool {
        activeRunChatIDs.contains { id in chat(id)?.route.map { pluginRuntimes[$0.rawValue] != nil } ?? false }
    }
    /// Each poll opens a loopback connection to every plugin; idle plugins are asked twice a minute.
    nonisolated static func pluginPollDue(routeInUse: Bool, sinceLastPoll: Duration) -> Bool {
        routeInUse || sinceLastPoll >= .seconds(30)
    }
    private func monitorPlugins(host id: AgentConnectionID) {
        guard !pluginRuntimes.isEmpty else { return }
        pluginTask = Task { [weak self] in
            var lastPoll = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                guard Self.pluginPollDue(routeInUse: self.pluginRouteInUse, sinceLastPoll: lastPoll.duration(to: .now)) else { continue }
                lastPoll = .now
                for pluginID in self.pluginRuntimes.keys.sorted() {
                    guard let runtime = self.pluginRuntimes[pluginID] else { continue }
                    do {
                        let status = try await runtime.status()
                        guard !Task.isCancelled else { return }
                        // An unchanged status must not redraw the window.
                        self.applyPluginStatus(status, for: pluginID)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.applyPluginStatus(nil, for: pluginID)
                        self.pluginMessages[pluginID] = error.localizedDescription
                        await runtime.stop()
                        self.pluginRuntimes[pluginID] = nil
                        let affected = self.state.chats.filter { $0.route?.rawValue == pluginID }
                        for chat in affected { self.runs[chat.id, default: ChatRunState()].queuePaused = true }
                        if affected.contains(where: { self.isBusy(threadID: $0.id) }) {
                            await self.client(id)?.stop()
                            self.agentStates[id]?.connected = false
                            self.resetAgentState(id)
                            self.error = L10n.text("Плагин отключился. Запрос не повторён.", "The plugin disconnected. The request was not retried.")
                            return
                        }
                    }
                }
            }
        }
    }
    func refreshAccount(_ id: AgentConnectionID) async {
        guard let slot = slots[id] else { return }
        let shared = slot.profile.traits.contains(.sharedEngine)
        do {
            let result = try await slot.client.account()
            if shared { clearConnectionError() }
            agentStates[id]?.authenticated = result.authenticated
            agentStates[id]?.canSignOut = result.canSignOut
            agentStates[id]?.accountLabel = slot.profile.accountLabel(result)
        } catch let failure as AgentOperationFailure where shared && failure.rejection == .staleContext {
            // An account event superseded this metadata request. Never publish its obsolete result.
            return
        } catch {
            // A per-chat engine that cannot confirm the account is treated as signed out; a shared engine keeps its state.
            if !shared { agentStates[id]?.authenticated = false }
            self.error = error.localizedDescription
            if shared { return }
        }
        if agentState(id).authenticated {
            if !slot.profile.traits.contains(.catalogModels) { await refreshModels(id) }
            await refreshLimits(id); startSummaryQueue()
        } else { clearLimits(id) }
    }
    // A successful server response makes an earlier transport warning obsolete.
    // Keep unrelated errors (for example, persistence failures) visible.
    private func clearConnectionError() {
        guard let error else { return }
        var transportErrors = [
            L10n.text("Движок недоступен. Подключись заново.", "The engine is unavailable. Reconnect."),
            L10n.text("Соединение закрыто", "Connection closed")
        ]
        for id in agentIDs where traits(id).contains(.sharedEngine) {
            let name = agentName(id)
            transportErrors += [
                L10n.text("\(name) не подключён", "\(name) is not connected"),
                L10n.text("Соединение с \(name) закрыто", "The connection to \(name) is closed"),
                Self.disconnectedNotice(name)
            ]
        }
        if transportErrors.contains(error) { self.error = nil }
    }
    static func disconnectedNotice(_ name: String) -> String {
        L10n.text("\(name) отключился. Подключись заново; отправка не будет повторена автоматически.",
                  "\(name) disconnected. Reconnect; the message will not be sent again automatically.")
    }
    /// Starts the agent's own sign-in: a browser page, or a terminal in the app's profile for a CLI sign-in.
    /// An agent that runs the sign-in itself (an ACP agent's `authenticate`) answers only when it is done; meanwhile the
    /// account shows that it waits for the browser.
    func login(_ id: AgentConnectionID) async {
        guard let slot = slots[id], !agentState(id).signingIn else { return }
        if !agentState(id).connected { await connect(id) }
        agentStates[id]?.signingIn = true
        defer { agentStates[id]?.signingIn = false }
        do {
            switch try await slot.client.integration.authenticate(.beginSignIn).value() {
            case .openURL(let url):
                NSWorkspace.shared.open(url)
                agentStates[id]?.accountLabel = L10n.text("Заверши вход в браузере", "Finish signing in in your browser")
            case .openLocalSignIn(let url):
                guard NSWorkspace.shared.open(url) else { throw ConversationIdentity.unavailable }
            case .complete:
                await refreshAccount(id)
            case .externalCLIRequired:
                throw ConversationIdentity.unavailable
            }
        } catch { self.error = error.localizedDescription }
    }
    func logout(_ id: AgentConnectionID) async {
        guard !anyBusy, let client = client(id) else { return }
        do { try await client.signOut(); agentStates[id]?.authenticated = false; clearLimits(id); await refreshAccount(id) }
        catch { self.error = error.localizedDescription }
    }
    /// The connection whose new chats use `SavedState.model`: the first registered one without a model catalog. Another
    /// agent with listed models needs a default setting of its own before it shares this one.
    func ownsDefaultModelSetting(_ id: AgentConnectionID) -> Bool { agentIDs.first { !traits($0).contains(.catalogModels) } == id }
    /// Lists the engine's models; the default model setting follows the engine's default when it is no longer listed.
    func refreshModels(_ id: AgentConnectionID) async {
        guard let client = client(id) else { return }
        do {
            let models = try await client.models()
            if agentState(id).models != models { agentStates[id]?.models = models }
            if ownsDefaultModelSetting(id), !models.contains(where: { $0.id == state.model }) {
                state.model = (models.first { $0.isDefault } ?? models.first)?.id ?? ""
            }
            // A session-models agent's default that its sessions no longer offer falls back to the agent's own default.
            let configured = defaultModelSetting(id)
            if traits(id).contains(.sessionModels), !models.isEmpty, !configured.isEmpty, !models.contains(where: { $0.id == configured }) {
                setDefaultModelSetting("", agent: id)
            }
            persist()
        } catch let failure as AgentOperationFailure where failure.rejection == .staleContext {
            return
        } catch let failure as AgentOperationFailure where failure.rejection == .unsupported(.modelDiscovery) && traits(id).contains(.sessionModels) {
            // No session has reported models yet; the first one does (`.configOptions`).
            agentStates[id]?.models = []
        } catch { self.error = error.localizedDescription }
    }
    func selectModel(_ model: String) {
        guard !isChangingChat(currentRunKey) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
            state.chats[index].model = model
            state.chats[index].effort = "medium"
            persist()
        } else {
            // A new chat's pick holds for the project's next chat only; its effort follows the defaults again.
            pickNewChatModel { $0.model = model; $0.effort = nil }
        }
    }
    /// `quiet`: the engine reported new limits (Codex does after each model response, mid-turn). It shows no "Checking limits"
    /// state and writes the result in one change, so each report publishes the model once instead of three or four times;
    /// it waits for any refresh in flight. A user refresh supersedes a quiet one.
    func refreshLimits(_ id: AgentConnectionID, quiet: Bool = false) async {
        guard let slot = slots[id], agentState(id).connected, agentState(id).authenticated, !agentState(id).refreshingLimits,
              !quiet || slot.limitsRequestID == nil else { return }
        let requestID = UUID()
        slot.limitsRequestID = requestID
        if !quiet {
            agentStates[id]?.refreshingLimits = true
            agentStates[id]?.limitsError = nil
        }
        defer {
            if slot.limitsRequestID == requestID {
                slot.limitsRequestID = nil
                if !quiet { agentStates[id]?.refreshingLimits = false }
            }
        }
        /// One publication for the whole result.
        func apply(limits: AccountLimits?, error: String?) {
            guard var next = agentStates[id] else { return }
            next.limits = limits; next.limitsError = error
            agentStates[id] = next
        }
        do {
            let result = try await slot.client.limits()
            guard slot.limitsRequestID == requestID, agentState(id).authenticated, agentState(id).connected else { return }
            apply(limits: result, error: nil)
        } catch let failure as AgentOperationFailure where failure.rejection == .staleContext {
            return
        } catch let failure as AgentOperationFailure where failure.rejection == .unsupported(.accountLimits) && slot.profile.noLimitsNotice != nil {
            guard slot.limitsRequestID == requestID else { return }
            apply(limits: nil, error: slot.profile.noLimitsNotice?())
        } catch {
            guard slot.limitsRequestID == requestID else { return }
            let message = agentState(id).limits == nil
                ? L10n.text("Не удалось получить лимиты. Попробуй обновить ещё раз.", "Could not fetch limits. Try refreshing again.")
                : L10n.text("Не удалось обновить лимиты. Показаны последние полученные данные.", "Could not refresh limits. Showing the last available data.")
            if agentState(id).limitsError != message { agentStates[id]?.limitsError = message }
        }
    }
    private func clearLimits(_ id: AgentConnectionID) {
        slots[id]?.limitsRequestID = nil
        agentStates[id]?.refreshingLimits = false
        agentStates[id]?.limits = nil
        agentStates[id]?.limitsError = nil
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
        // A new project starts with the presets its files suggest; project settings change them.
        _ = state.migrateAccessPresets()
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
    func showProject(_ id: UUID) {
        guard state.showProject(id) else { return }
        persist()
        selectProject(id)
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
        composer.text = projectID.flatMap { newChatDrafts[$0] } ?? ""
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
        let updated = DroppedFiles.appending(DroppedFiles.preserving(urls, in: DroppedFiles.directory), to: composer.text)
        guard updated != composer.text else { return }
        composer.text = updated
        composerFocusRequest = UUID()
    }
    /// Replaces a chat's draft through `change`, whether or not the chat is open; nothing is sent.
    func updateDraft(chatID id: String?, _ change: (String) -> String) {
        guard let id, id != chatID else {
            composer.text = change(composer.text); return
        }
        let updated = change(chatDrafts[id] ?? "")
        chatDrafts[id] = updated.isEmpty ? nil : updated
    }
    func draft(chatID id: String?) -> String {
        guard let id, id != chatID else { return composer.text }
        return chatDrafts[id] ?? ""
    }
    func openChat(_ chat: Chat) async {
        guard !isChangingChat(chat.id), state.chats.contains(where: { $0.id == chat.id }) else { return }
        Perf.begin("chat.open", id: chat.id); let perfLoad = Perf.span("chat.load", id: chat.id); defer { perfLoad.end() }
        transcript.cancelPending()
        showingArchive = isArchived(chat.id)
        archiveViewingChat = showingArchive
        showingJobs = false; showingAttention = false; projectID = chat.projectID; chatID = chat.id; composerFocusRequest = nil
        composer.text = chatDrafts[chat.id] ?? ""
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
            // Engine histories have no plans; the stored transcript shown so far keeps each turn's latest one.
            let turns = AgentPlan.carry(from: items, into: try await clientForChat(chat.id).history(sessionForChat(chat.id)))
            guard selectionGeneration == generation else { return }
            let timings = try await store.loadTimings(threadID: chat.id)
            guard selectionGeneration == generation else { return }
            guard historyEventRevisions[chat.id, default: 0] == eventRevision else { return }
            var loaded = turns.flatMap { turn in
                var entries = turn.items
                for index in entries.indices { entries[index].turnID = turn.id }
                ResponseTiming.apply(turn.timing(fallback: timings[turn.id ?? ""]), to: &entries)
                return entries
            }
            // Codex history has no compaction sizes; the stored transcript shown so far has them.
            ContextCompaction.carry(from: items, into: &loaded)
            items = loaded
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
    /// Archived chats are skipped: reading every one at connect loaded hundreds of megabytes of agent history
    /// into memory and rewrote every stored transcript (performance audit 2026-10-31, item 3). An archived chat
    /// is refreshed when it is opened; archive summaries read the stored transcript.
    func backfillHistory(_ chats: [Chat]) async {
        for chat in chats {
            guard !Task.isCancelled else { return }
            guard !chat.isScheduledRecord, !chat.isArchived, chatConnected(chat.id) else { continue }
            guard chatIsAvailable(chat.id), !isBusy(threadID: chat.id),
                  state.chats.contains(where: { $0.id == chat.id }), !isChangingChat(chat.id) else { continue }
            do {
                let capturedAt = Date()
                let session = try sessionForChat(chat.id)
                let history = try await clientForChat(chat.id).history(session)
                guard !Task.isCancelled else { return }
                // Plans live only in the stored transcript; keep them when it is rewritten from the engine's history.
                let stored = (try? await store.loadTranscript(conversationID: chat.id)).flatMap { $0 }.map(LocalHistory.items) ?? []
                let turns = AgentPlan.carry(from: stored, into: history)
                let timings = try await store.loadTimings(threadID: chat.id)
                // Encoding a long transcript takes tens of milliseconds; on the main actor it made scrolling stutter.
                let conversation = ConversationID(chat.id)
                let snapshot = try await Task.detached(priority: .utility) {
                    try LocalHistory.snapshot(conversation: conversation, source: session, turns: turns, timings: timings, capturedAt: capturedAt)
                }.value
                try await store.saveTranscript(snapshot)
            } catch {
                // Keep the last readable revision; opening the chat exposes any read error.
            }
        }
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
    func createHandoffChat(_ handoff: ContextHandoff, project: Project, route: RequestRoute, agent: AgentConnectionID,
                           model: String? = nil, effort: String? = nil, role: String? = nil, title: String? = nil) async -> Bool {
        guard !creatingHandoff else { return false }
        creatingHandoff = true; defer { creatingHandoff = false }
        do {
            guard let client = self.client(agent), agentState(agent).connected && agentState(agent).authenticated,
                  state.projects.contains(where: { $0 == project }), routeIsAvailable(route) else {
                throw ConversationIdentity.unavailable
            }
            let descriptor = try await client.descriptor()
            guard descriptor.context.connection == agent, descriptor.capabilities.contains(.interactiveSessions),
                  descriptor.routes.contains(route.agentRoute) else { throw ConversationIdentity.unavailable }
            let prompt = try handoff.prompt()
            let selectedModel = model ?? defaultModelSetting(agent)
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
        guard let chat = selectedChat, let origin = chat.handoffOrigin, !composer.hasText else { return }
        do {
            guard let saved = try await store.loadHandoff(origin.id), saved.origin == origin else { throw ConversationIdentity.invalidStorage }
            let prompt = try saved.prompt()
            guard chatID == chat.id, !composer.hasText else { return }
            composer.text = prompt
        } catch { self.error = error.localizedDescription }
    }
    func saveRoutine(_ routine: PortableRoutine) async -> Bool {
        do { routines = try await store.saveRoutine(routine); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func removeRoutine(_ id: UUID) async {
        do { routines = try await store.removeRoutine(id) } catch { self.error = error.localizedDescription }
    }
    /// The refresh replaces the recorded transcript with the engine's history; when it is skipped (busy, scheduled record,
    /// disconnected) or fails, the turn's pending recorded items are written now instead of at the store's next interval.
    /// A refresh that saved leaves nothing pending, so a finished turn costs one blob write either way.
    private func refreshHistoryAfterTurn(_ id: String) {
        let store = store
        guard let chat = state.chats.first(where: { $0.id == id }) else {
            Task { await store.flushTranscript(conversationID: id) }
            return
        }
        historyRefreshTasks[id]?.cancel()
        historyRefreshTasks[id] = Task { [weak self] in
            await self?.backfillHistory([chat])
            await store.flushTranscript(conversationID: id)
        }
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
            // A name given before the generated title arrived (which it cancels) names the worktree branch instead.
            settleWorktreeBranch(id)
        } catch { self.error = error.localizedDescription }
    }
    func canDeleteChat(_ id: String) -> Bool {
        (chatConnected(id) || isScheduledRecord(id)) && hasChat(id) &&
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
            if archived { state.chats[index].limitResume = nil }
            // Further turns add bodies to the history file; the next archive pass reads it again.
            if !archived { state.chats[index].historyReduced = nil }
            if chatID == id {
                if !archived { archiveViewingChat = false }
                else if revealArchive { openArchive() }
            }
            state.chats[index].sidebarOrder = nil
            loadedThreads.remove(id)
            if archived { offerWorktreeRemoval(state.chats[index]) }
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
        // Tool bodies of the newly archived chats go after the archive flag is durable; restoring a chat keeps them reduced.
        Task { [weak self] in for id in ids { await self?.reduceArchivedActivity(id) } }
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
        forgetTurnCheckpoints(chatID: id)
        let removed = state.chats.first { $0.id == id }
        // The process sweeper labels events with the agent session ID.
        ChatReferences.remove(chat: id); ChatEventLog.remove(chat: id)
        if let native = removed?.nativeSession?.nativeID { ChatEventLog.remove(chat: native) }
        state.chats.removeAll { $0.id == id }
        if let removed { offerWorktreeRemoval(removed) }
        state.queuedMessages = queuedMessages.filter { $0.threadID != id }
        usage.removeValue(forKey: id)
        archiveSummaries.removeValue(forKey: id)
        chatDrafts.removeValue(forKey: id)
        loadedThreads.remove(id)
        runs.removeValue(forKey: id)
        activity.setStatus(nil, for: id)
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
    /// The role the selected chat runs with; for a new chat, the role picked for it or the project's chat default.
    var currentRole: AgentRole {
        guard let project = state.projects.first(where: { $0.id == projectID }) else { return AgentRoleCatalog.preset(AgentRoleID.editor) }
        if let chat = selectedChat { return chat.resolvedRole(in: project, catalog: roleCatalog) }
        return newChatRole(for: project) ?? project.chatRole(roleCatalog)
    }
    /// The explicit role picked for the project's next new chat, if it still exists in the catalog.
    func newChatRole(for project: Project) -> AgentRole? { roleCatalog.role(newChatRoles[project.id]) }
    var accessMode: AccessMode { currentRole.legacyAccessMode }
    /// nil while the selected chat (or the new chat) follows the project default.
    var roleSelection: String? {
        guard let chat = selectedChat else { return selectedProject.flatMap { newChatRole(for: $0)?.id } }
        return chat.inheritsProjectRole ? nil : currentRole.id
    }
    var accessSelection: AccessMode? { roleSelection.map { _ in accessMode } }
    var projectRoleTitle: String {
        let role = state.projects.first { $0.id == projectID }?.chatRole(roleCatalog) ?? AgentRoleCatalog.preset(AgentRoleID.editor)
        return L10n.text("По умолчанию проекта", "Project default") + ": " + role.title
    }
    var projectAccessTitle: String { projectRoleTitle }
    /// Dimensions the current agent can only approximate for the current role; shown, never silently downgraded.
    var roleApproximations: [AgentPermissionDimension] {
        guard let project = state.projects.first(where: { $0.id == projectID }) else { return [] }
        return agentState(currentAgent).descriptor?.permissions.approximations(currentRole.profile(for: project, addOns: currentAddOns)) ?? []
    }
    /// Add-ons of the selected chat, or the ones picked for the new chat; both fall back to the project's.
    var currentAddOns: Set<RoleAddOn> {
        guard let project = state.projects.first(where: { $0.id == projectID }) else { return [] }
        if let chat = selectedChat { return chat.resolvedAddOns(in: project) }
        return newChatAddOns[project.id] ?? Set((project.chatRoleAddOns ?? []).compactMap(RoleAddOn.init(rawValue:)))
    }
    /// Turns one add-on on or off for the selected chat (from the next message) or for the new chat.
    func toggleAddOn(_ addOn: RoleAddOn) {
        guard !busy, !sending, !isChangingChat(currentRunKey) else { return }
        var addOns = currentAddOns
        if addOns.contains(addOn) { addOns.remove(addOn) } else { addOns.insert(addOn) }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
            state.chats[index].roleAddOns = RoleAddOn.allCases.filter(addOns.contains).map(\.rawValue)
            persist()
        } else if chatID == nil, let projectID, state.projects.contains(where: { $0.id == projectID }) {
            newChatAddOns[projectID] = addOns
        }
    }
    var roleApproximationNotice: String {
        let names = roleApproximations.map(Self.dimensionTitle).joined(separator: ", ")
        let agent = currentAgentName
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
    /// A chat's role (nil follows the project). For a new chat it is the role of the chat being created only;
    /// the project default changes in the project settings (`updateProjectRoles`). The legacy mode stays in step for the phone.
    func selectRole(_ id: String?) {
        guard !busy, !sending, !isChangingChat(currentRunKey) else { return }
        guard id == nil || roleCatalog.role(id) != nil else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) {
            state.chats[index].roleID = id
            state.chats[index].inheritsProjectAccess = id == nil
            state.chats[index].accessMode = roleCatalog.role(id)?.legacyAccessMode
            persist()
        } else if chatID == nil, let projectID, state.projects.contains(where: { $0.id == projectID }) {
            newChatRoles[projectID] = id
        }
    }
    func selectAccessMode(_ mode: AccessMode?) { selectRole(mode?.legacyRoleID) }
    /// Polls the proposal folder; a listing every two seconds costs next to nothing.
    private func watchSettingsProposals() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshSettingsProposals()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func refreshSettingsProposals() {
        let current = SettingsProposalInbox.load(state: state)
        if current != settingsProposals { settingsProposals = current }
    }
    /// Applies a proposal as it reads against the current settings, then removes its file.
    func applySettingsProposal(_ id: String) {
        refreshSettingsProposals()
        if let review = settingsProposals.first(where: { $0.id == id }), state.apply(review) {
            persist()
            AppLog.lifecycle.notice("Applied settings proposal \(id, privacy: .public) for \(review.projects.count, privacy: .public) projects")
        }
        SettingsProposalInbox.remove(id)
        refreshSettingsProposals()
    }
    func rejectSettingsProposal(_ id: String) {
        SettingsProposalInbox.remove(id)
        refreshSettingsProposals()
    }
    /// The chat a proposal names, when it is one of this app's chats.
    func proposalChatTitle(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return state.chats.first { $0.nativeSession?.nativeID == label || $0.id == label }?.title
    }
    /// Project defaults for chats and jobs plus the declared extra roots; the agent never changes these.
    func updateProjectRoles(_ id: UUID, chatRole: String?, jobRole: String?, extraRoots: [AgentPermissionProfile.Root]?, cookieSites: [String]?,
                            mcpServers: [String: String]? = nil, chatAddOns: Set<RoleAddOn>? = nil,
                            sandbox: (enabled: Bool, presets: [String], commands: [String])? = nil) {
        guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
        if let sandbox {
            state.projects[index].commandSandbox = sandbox.enabled ? nil : false
            state.projects[index].accessPresets = AccessPresetCatalog.all.map(\.id).filter(sandbox.presets.contains)
            let commands = sandbox.commands.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            state.projects[index].sandboxCommands = commands.isEmpty ? nil : commands
        }
        if let chatAddOns { state.projects[index].chatRoleAddOns = chatAddOns.isEmpty ? nil : RoleAddOn.allCases.filter(chatAddOns.contains).map(\.rawValue) }
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
    /// The project's own model and effort for new chats, by agent ID; empty choices follow the app default.
    func updateProjectChatModels(_ id: UUID, _ choices: [String: ModelChoice]) {
        guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return }
        let kept = choices.filter { !$0.value.isEmpty }
        guard state.projects[index].chatModels ?? [:] != kept else { return }
        state.projects[index].chatModels = kept.isEmpty ? nil : kept
        persist()
    }
    var queuedMessages: [QueuedMessage] { state.queuedMessages ?? [] }
    var visibleQueue: [QueuedMessage] { queuedMessages.filter { $0.threadID == chatID } }
    func removeQueuedMessage(_ id: String) {
        guard !runs.values.contains(where: { $0.priorityMessageID == id }) else { return }
        state.queuedMessages = queuedMessages.filter { $0.id != id }
        persist()
    }
    /// Messages the drain has claimed: "Interrupt and send" chose them, or their interruption finished and they go out next.
    private var claimedQueueIDs: Set<String> {
        Set(runs.values.flatMap { [$0.priorityMessageID, $0.interruptedFor].compactMap { $0 } })
    }
    /// A claimed message can be neither edited nor moved, and nothing moves past it.
    func queuedMessageIsClaimed(_ id: String) -> Bool { claimedQueueIDs.contains(id) }
    /// The chat's queue can be edited and reordered: not archived and not being archived or deleted.
    func canChangeQueue(_ threadID: String) -> Bool {
        chatIsAvailable(threadID) && !isChangingChat(threadID) && !isArchived(threadID)
    }
    /// Replaces a queued message's text; its ID, place, model and effort stay. Everything here runs on the main actor, and
    /// the drain takes a message out of the queue before its first suspension, so an edit either lands before the dequeue
    /// and goes out, or finds the message gone and is refused with a notice. Nothing is sent from here.
    @discardableResult
    func editQueuedMessage(_ id: String, text: String, threadID: String) -> QueueChange {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unchanged }
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else {
            refuseQueueEdit(text, threadID: threadID, notice: L10n.text("Сообщение уже вышло из очереди, правка не применена.",
                                                                        "The message already left the queue; the edit was not applied."))
            return .gone
        }
        guard !queuedMessageIsClaimed(id), canChangeQueue(threadID) else {
            refuseQueueEdit(text, threadID: threadID, notice: L10n.text("Сообщение уже отправляется, правка не применена.",
                                                                        "The message is already being sent; the edit was not applied."))
            return .claimed
        }
        guard queuedMessages[index].text != text else { return .unchanged }
        state.queuedMessages?[index].text = text
        persist()
        AppLog.delivery.notice("Queued message edited in chat \(threadID, privacy: .public)")
        return .applied
    }
    /// Opens the in-place editor on a queued message that is still waiting.
    @discardableResult
    func beginQueueEdit(_ id: String) -> Bool {
        guard let message = queuedMessages.first(where: { $0.id == id }), !queuedMessageIsClaimed(id), canChangeQueue(message.threadID) else { return false }
        queueEdit = QueueEditSession(message)
        return true
    }
    func cancelQueueEdit() { queueEdit = nil }
    /// Saves the open edit; a blank text keeps the editor open (removing the message is a separate action).
    @discardableResult
    func saveQueueEdit() -> QueueChange {
        guard let edit = queueEdit, edit.draft.hasMessage else { return .unchanged }
        queueEdit = nil
        return editQueuedMessage(edit.id, text: edit.draft.text, threadID: edit.threadID)
    }
    /// The drain took the message under edit: the edit closes, and a changed text is refused with a notice instead of being lost.
    private func closeQueueEdit(dequeued id: String) {
        guard let edit = queueEdit, edit.id == id else { return }
        queueEdit = nil
        guard edit.draft.text != edit.original, edit.draft.hasMessage else { return }
        refuseQueueEdit(edit.draft.text, threadID: edit.threadID, notice: L10n.text("Сообщение ушло агенту до сохранения правки, отправлен прежний текст.",
                                                                                     "The message went to the agent before the edit was saved; the earlier text was sent."))
    }
    /// A refused edit keeps the user's text: it goes into the open chat's empty composer and the notice says so.
    private func refuseQueueEdit(_ text: String, threadID: String, notice: String) {
        guard state.chats.contains(where: { $0.id == threadID }) else { return } // The chat itself was deleted.
        AppLog.delivery.notice("Queued message edit refused in chat \(threadID, privacy: .public): it is no longer waiting")
        if threadID == chatID, !isArchived(threadID), !composer.hasText {
            composer.text = text
            error = notice + L10n.text(" Исправленный текст в поле ввода.", " The edited text is in the composer.")
        } else {
            error = notice
        }
    }
    func canMoveQueuedMessage(_ id: String, by offset: Int) -> Bool { movedQueue(id, by: offset) != nil }
    /// Moves a message up (negative) or down among its chat's queued messages; delivery follows the new order.
    @discardableResult
    func moveQueuedMessage(_ id: String, by offset: Int) -> QueueChange {
        applyQueueMove(id, movedQueue(id, by: offset))
    }
    /// Drag and drop: moves a message onto another one's place, before it when moving up and after it when moving down.
    @discardableResult
    func moveQueuedMessage(_ id: String, onto targetID: String) -> QueueChange {
        guard let message = queuedMessages.first(where: { $0.id == id }) else { return .gone }
        let chat = queuedMessages.filter { $0.threadID == message.threadID }
        guard let target = chat.firstIndex(where: { $0.id == targetID }) else { return .unchanged }
        return applyQueueMove(id, canChangeQueue(message.threadID) ? queuedMessages.movingQueued(id, toChatPosition: target, pinned: claimedQueueIDs) : nil)
    }
    private func movedQueue(_ id: String, by offset: Int) -> [QueuedMessage]? {
        guard let message = queuedMessages.first(where: { $0.id == id }), canChangeQueue(message.threadID),
              let position = queuedMessages.filter({ $0.threadID == message.threadID }).firstIndex(where: { $0.id == id }) else { return nil }
        let target = position + offset
        guard target >= 0, target < queuedMessages.filter({ $0.threadID == message.threadID }).count else { return nil }
        return queuedMessages.movingQueued(id, toChatPosition: target, pinned: claimedQueueIDs)
    }
    private func applyQueueMove(_ id: String, _ moved: [QueuedMessage]?) -> QueueChange {
        guard let message = queuedMessages.first(where: { $0.id == id }) else { return .gone }
        guard let moved else {
            let claimed = claimedQueueIDs
            let blocked = !canChangeQueue(message.threadID) || queuedMessages.contains { $0.threadID == message.threadID && claimed.contains($0.id) }
            return blocked ? .claimed : .unchanged
        }
        state.queuedMessages = moved
        persist()
        return .applied
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
    /// Keeps a message that arrived while the app was quitting. Nothing was delivered; the entry is marked so the next
    /// launch sends it (`releaseQueueHeldForRestart`). The queue stays paused: the quit was judged idle already.
    private func holdForRestart(_ message: QueuedMessage, first: Bool) {
        var held = message; held.heldForRestart = true
        items.removeAll { $0.id == message.id }
        let others = queuedMessages.filter { $0.id != message.id }
        state.queuedMessages = first ? [held] + others : others + [held]
        runs[message.threadID, default: ChatRunState()].queuePaused = true
        AppLog.delivery.notice("Message for chat \(message.threadID, privacy: .public) held for the next launch: the app is quitting; nothing was delivered")
        persist()
    }
    /// Sends the messages held at the last quit in every chat whose agent is connected; the others stay in the
    /// paused queue, visible in the chat, until the user resumes it.
    func releaseQueueHeldForRestart() {
        var released: Set<String> = [], cleared = false
        for (index, message) in queuedMessages.enumerated() where message.heldForRestart == true {
            state.queuedMessages?[index].heldForRestart = nil
            cleared = true
            let id = message.threadID
            guard chatIsAvailable(id), chatConnected(id), chatAuthenticated(id), !isArchived(id), !isChangingChat(id) else { continue }
            runs[id, default: ChatRunState()].queuePaused = false
            released.insert(id)
        }
        guard cleared else { return }
        AppLog.delivery.notice("Messages held at the last quit: queue released in \(released.count, privacy: .public) chat(s)")
        persist()
        for id in released { scheduleQueue(threadID: id) }
    }
    func continueAfterRestart(_ chatIDs: [String]) {
        let queued = chatIDs.filter { queueContinuation($0, text: RestartContinuation.message) }
        guard !queued.isEmpty else { return }
        AppLog.lifecycle.notice("Restart continuation queued for \(queued.count, privacy: .public) chat(s)")
    }
    /// Queues an app-written continuation; with `removingLimitResume` the chat's limit-resume record goes in the same
    /// state change, so the continuation is queued at most once. It is delivered like any queued message.
    @discardableResult
    func queueContinuation(_ id: String, text: String, localID: String = "local-user:" + UUID().uuidString, removingLimitResume: Bool = false) -> Bool {
        guard let index = state.chats.firstIndex(where: { $0.id == id }), !state.chats[index].isArchived, chatIsAvailable(id) else { return false }
        let chat = state.chats[index]
        if removingLimitResume { state.chats[index].limitResume = nil }
        state.queuedMessages = queuedMessages + [QueuedMessage(id: localID, threadID: id,
            projectID: chat.projectID, text: text, model: dispatchModel(chat), effort: dispatchEffort(chat))]
        runs[id, default: ChatRunState()].queuePaused = false
        persist()
        scheduleQueue(threadID: id)
        return true
    }
    /// The chat directory server's command line (Claude chats only, plan Phase 5): all tools for a chat the user opted
    /// in; only `inspect_chat` over the chats the user named in this chat's messages otherwise; nothing without either.
    func chatDirectoryArguments(for id: String, script: URL? = Bundle.main.resourceURL?.appendingPathComponent("ChatDirectoryRuntime/server.py")) -> [String]? {
        guard let chat = state.chats.first(where: { $0.id == id }), traits(chat.nativeSession?.connection).contains(.chatDirectory),
              let script, FileManager.default.fileExists(atPath: script.path) else { return nil }
        let root = Locations.root.path
        guard chat.chatDirectoryAccess == true else {
            guard !ChatReferences.load(chat: id).isEmpty, let references = ChatReferences.file(chat: id) else { return nil }
            return ChatDirectory.serverArguments(script: script.path, snapshot: nil, chat: id, root: root, references: references.path)
        }
        // Every chat with access can search the index; only a chat-search chat gets the search recipe as instructions.
        return ChatDirectory.serverArguments(script: script.path, snapshot: chatDirectoryFile.path, chat: id, index: chatSearchIndexFile.path,
                                             recipe: chat.chatSearch == true ? chatSearchRecipe.path : nil, root: root)
    }
    /// Remembers the chats the user names in a message to this chat (`switchboard-chat:<ID>`, a chat ID or its agent
    /// session ID), so this chat may inspect them. IDs of unknown chats are ignored.
    func noteChatReferences(chatID: String, text: String) {
        let found = ChatReferences.identifiers(in: text)
        var named = found.compactMap { id in
            state.chats.first { $0.id.lowercased() == id || $0.nativeSession?.nativeID.lowercased() == id }?.id
        }.filter { $0 != chatID }
        // The first reference adds the server to the launch, which restarts a live CLI and would end its background
        // tasks and sub-agents; it waits for a message sent while none run.
        let backgroundWork = backgroundWaits[chatID] != nil || subagents[chatID]?.contains { $0.status == .running } == true
        if backgroundWork, ChatReferences.load(chat: chatID).isEmpty {
            if !named.isEmpty { deferredChatReferences[chatID, default: []] += named }
            return
        }
        named += deferredChatReferences.removeValue(forKey: chatID) ?? []
        guard !named.isEmpty else { return }
        do { try ChatReferences.record(named, chat: chatID) }
        catch { AppLog.delivery.error("Chat references not saved: \(error.localizedDescription, privacy: .public)") }
    }
    var chatDirectoryFile: URL { Locations.root.appendingPathComponent(ChatDirectory.fileName) }
    /// Chats named while the chat's CLI ran background work; recorded with its next message.
    private var deferredChatReferences: [String: [String]] = [:]
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
                                 agent: agentName(chat.nativeSession?.connection),
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
        for chat in state.chats where chat.lastTurnFailed == true && chat.hasUnreadResponse && !chat.isArchived && chat.limitResume?.isArmed != true {
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
        let message = QueuedMessage(id: "local-user:telegram:" + String(reply.id), threadID: chat.id, projectID: chat.projectID,
            text: L10n.text("Ответ пользователя из Telegram:", "The user's reply from Telegram:") + "\n\n" + text,
            model: dispatchModel(chat), effort: dispatchEffort(chat))
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
        if isBootstrapping || anyAgentConnecting { reasons.insert(L10n.text("Подключение к агентам", "Connecting to agents")) }
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
        closeQueueEdit(dequeued: next.id)
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
        if let thread = chatID { dropLimitResume(thread) } // The user's own message replaces a planned continuation.
        if let record = selectedChat, record.isScheduledRecord {
            await followUpScheduledRecord(record, text: composer.text, project: project); return
        }
        // A quit is in progress: a new chat cannot be created any more, so its text stays in the composer.
        if shuttingDown && chatID == nil { return }
        // A new chat's own worktree exists before anything is sent; after a git failure the text stays in the composer.
        var worktree: ChatWorktree?
        if chatID == nil {
            let selection = selectionGeneration
            let prepared = await worktreeForNewChat(project)
            guard !prepared.failed, selectionGeneration == selection, chatID == nil, !shuttingDown else { return }
            worktree = prepared.worktree
        }
        let text = composer.text; composer.text = ""
        let localID = "local-user:" + UUID().uuidString
        if shuttingDown, let thread = chatID {
            holdForRestart(QueuedMessage(id: localID, threadID: thread, projectID: project.id, text: text,
                                         model: currentModel, effort: currentEffort), first: false)
            return
        }
        if let thread = chatID, busy || !visibleQueue.isEmpty {
            if visibleQueue.isEmpty { runs[thread, default: ChatRunState()].queuePaused = false }
            state.queuedMessages = queuedMessages + [QueuedMessage(id: localID, threadID: thread,
                projectID: project.id, text: text, model: currentModel, effort: currentEffort)]
            persist()
            scheduleQueue(threadID: thread)
            return
        }
        await deliver(text: text, project: project, threadID: chatID, localID: localID,
                      selectedModel: currentModel, selectedEffort: currentEffort, worktree: worktree)
    }
    /// `worktree` is the new chat's own worktree (only with `threadID == nil`); an existing chat keeps its own folder.
    func deliver(text: String, project: Project, threadID: String?, localID: String,
                         selectedModel: String, selectedEffort: String, scheduledRun: UUID? = nil, scheduledRoute: RequestRoute? = nil, scheduledBrowserImport: ChromeSessionImportPolicy? = nil,
                         scheduledAgent: AgentConnectionID? = nil, scheduledRole: AgentRole? = nil, afterInterrupt: Bool = false,
                         worktree: ChatWorktree? = nil) async {
        let selection = selectionGeneration
        let visible = scheduledRun == nil && threadID == chatID && project.id == projectID
        if scheduledRun == nil, let threadID, !localID.hasPrefix(LimitResume.messageIDPrefix) { dropLimitResume(threadID) }
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
        else { role = newChatRole(for: project) ?? project.chatRole(roleCatalog) }
        // A role picked for this new chat belongs to it; nil keeps the chat following the project default.
        let explicitNewChatRole = scheduledRun == nil && threadID == nil ? newChatRole(for: project) : nil
        // Add-ons belong to interactive chats; a scheduled run keeps exactly its job role.
        let addOns: Set<RoleAddOn> = scheduledRun != nil ? [] : threadID.flatMap { id in state.chats.first { $0.id == id }?.resolvedAddOns(in: project) }
            ?? newChatAddOns[project.id] ?? Set((project.chatRoleAddOns ?? []).compactMap(RoleAddOn.init(rawValue:)))
        let explicitNewChatAddOns = scheduledRun == nil && threadID == nil ? newChatAddOns[project.id] : nil
        let access = role.profile(for: project, addOns: addOns)
        let newWorktree = threadID == nil && scheduledRun == nil ? worktree : nil
        // The chat's own folder (`Chat.workingDirectory(in:)`): engine cwd, permission root and checkpoints.
        let workingDirectory = newWorktree?.workingDirectory ?? threadID.flatMap { workingDirectory(forChat: $0) } ?? project.path
        let newConnection = scheduledRun == nil ? currentAgent : scheduledAgent ?? currentAgent
        let route = scheduledRoute ?? (threadID == nil ? newChatRoute(newConnection) : (state.chats.first { $0.id == threadID }?.route ?? .direct))
        do {
            if let threadID {
                guard !isScheduledRecord(threadID) else { throw ClientFailure(Self.scheduledRecordReadOnly) }
                _ = try nativeThread(threadID)
            } else if !isRegistered(newConnection) { throw ConversationIdentity.unavailable }
            if workingDirectory != project.path, !FileManager.default.fileExists(atPath: workingDirectory) {
                throw ClientFailure(L10n.text("Папка worktree этого чата не найдена: \(workingDirectory)", "This chat's worktree folder was not found: \(workingDirectory)"))
            }
            guard let client = try threadID.map({ try clientForChat($0) }) ?? self.client(newConnection) else { throw ConversationIdentity.unavailable }
            if route != .direct {
                guard let runtime = pluginRuntimes[route.rawValue], routeIsAvailable(route) else { throw ClientFailure(routeMessage(route)) }
                applyPluginStatus(try await runtime.status(), for: route.rawValue)
            }
            var id = threadID
            if id == nil {
                // Browser profiles belong to the folder they were made in, so a worktree chat starts with its own.
                let browserProfile = scheduledRun == nil && state.browserEnabled == true && newWorktree == nil
                    ? newChatBrowserProfiles[project.id].map { AgentBrowserProfile(id: $0) } : nil
                let session = try await client.createSession(projectPath: workingDirectory, permissions: access,
                                                                 model: selectedModel, route: route, browserProfile: browserProfile,
                                                                 kind: scheduledRun == nil ? .interactive : .scheduled)
                if let browserProfile, newChatBrowserProfiles[project.id] == browserProfile.id {
                    newChatBrowserProfiles.removeValue(forKey: project.id)
                }
                let nativeCreated = session.nativeID
                guard ConversationIdentity.appID(for: nativeCreated, in: state, connection: session.connection) == nil else { throw ConversationIdentity.invalidStorage }
                var chat = Chat(session: session, projectID: project.id, title: ChatTitle.placeholder(), model: selectedModel)
                chat.effort = selectedEffort
                chat.worktree = newWorktree
                if let newWorktree { consumeNewChatWorktree(newWorktree, project: project.id) }
                let explicitRole = scheduledRun == nil ? explicitNewChatRole : role
                chat.accessMode = explicitRole?.legacyAccessMode
                chat.roleID = explicitRole?.id
                chat.inheritsProjectAccess = explicitRole == nil
                if let explicitNewChatRole, newChatRoles[project.id] == explicitNewChatRole.id {
                    newChatRoles.removeValue(forKey: project.id)
                }
                if scheduledRun == nil { newChatModelChoices.removeValue(forKey: project.id) }
                if let explicitNewChatAddOns {
                    chat.roleAddOns = RoleAddOn.allCases.filter(explicitNewChatAddOns.contains).map(\.rawValue)
                    if newChatAddOns[project.id] == explicitNewChatAddOns { newChatAddOns.removeValue(forKey: project.id) }
                }
                let created = chat.id
                id = created
                tokenTotals[created] = .zero
                runs[created] = runs[runKey]
                runs.removeValue(forKey: runKey)
                activity.moveStatus(from: runKey, to: created)
                runKey = created
                if visible && selectionGeneration == selection {
                    chatID = created
                    chatDrafts[created] = composer.hasText ? composer.text : nil
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
                try await client.resume(sessionForChat(id), projectPath: workingDirectory, permissions: access, route: route,
                                        kind: scheduledRun == nil ? .interactive : .scheduled)
                loadedThreads.insert(id)
            }
            if let scheduledRun {
                jobLedger = try await jobStore.attach(scheduledRun, thread: id)
                try Task.checkCancellation()
                guard !schedulerStopping else { throw CancellationError() }
            }
            var outgoing = afterInterrupt ? InterruptedTurnNote.applying(L10n.text(InterruptedTurnNote.russian, InterruptedTurnNote.english), to: text) : text
            // Before the launch arguments are built: a newly named chat attaches `inspect_chat` to this turn.
            if scheduledRun == nil { noteChatReferences(chatID: id, text: text) }
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
                    let tool = profile(newConnection)?.browserImportTool ?? "browser_import_session"
                    outgoing = ScheduledBrowserImport.applying(preflight, policy: scheduledBrowserImport, to: text, tool: tool)
                }
            }
            let jobNote = scheduledRun == nil ? state.chats.first(where: { $0.id == id })?.job?.pendingNote : nil
            if let jobNote { outgoing = ChatJobNote.applying(ChatJob.noteText(jobNote), to: outgoing) }
            await prepareTurnCheckpoint(chatID: id, projectPath: workingDirectory)
            let submittedTurn = try await client.send(outgoing, to: sessionForChat(id), projectPath: workingDirectory,
                                                          permissions: access, model: selectedModel, effort: selectedEffort,
                                                          advisor: modelCatalog(threadID.flatMap { connectionOfChat($0) } ?? newConnection)?.advisor(state.claudeAdvisor, selectedModel),
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
            if let i = state.chats.firstIndex(where: { $0.id == id }) {
                state.chats[i].updated = Date()
                if let jobNote { state.chats[i].job?.markAnnounced(jobNote) }
                persist()
            }
        } catch {
            turnCheckpoints.discardPending(chatID: runKey)
            let engineTurn = runs[runKey]?.turnID.flatMap { $0 == priorTurn ? nil : $0 }
            // The app is quitting and closed its connections under this send: the message waits in the persisted
            // queue and goes out on the next launch (the quit itself was judged idle before the send arrived).
            if shuttingDown, let threadID, scheduledRun == nil, !localID.hasPrefix("local-user:remote:") {
                holdForRestart(QueuedMessage(id: localID, threadID: threadID, projectID: project.id, text: text,
                                             model: selectedModel, effort: selectedEffort), first: true)
                if engineTurn == nil {
                    runs[runKey, default: ChatRunState()].running = false
                    runs[runKey, default: ChatRunState()].turnID = nil
                }
                return
            }
            // The engine started a turn of its own while this send was in flight (Claude resuming after its background
            // tasks): that turn keeps the chat running. A definite rejection delivered nothing, so the message waits
            // in the queue for that turn to finish, exactly as if it had been sent while the chat was busy.
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
            if visible && selectionGeneration == selection && !composer.hasText { composer.text = text }
        }
    }
    func scheduledAgentReady(_ agent: AgentConnectionID) -> Bool {
        agentState(agent).connected && agentState(agent).authenticated
    }
    func deliverScheduled(_ job: ManagedJob, run: JobRun, project: Project, agent: AgentConnectionID) async {
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
        refreshGitStatus(afterTurnIn: threadID)
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
    /// Starts a job with this "done when" criterion, or changes the criterion of the open one. The agent receives it
    /// with the next message (`ChatJobNote`). Returns false for an empty criterion or an unknown chat.
    @discardableResult
    func setChatJob(_ chatID: String, doneWhen: String) -> Bool {
        guard let criterion = ChatJob.criterion(doneWhen),
              let i = state.chats.firstIndex(where: { $0.id == chatID }), !state.chats[i].isScheduledRecord else { return false }
        if state.chats[i].job?.isActive == true { state.chats[i].job?.doneWhen = criterion }
        else { state.chats[i].job = ChatJob(doneWhen: criterion, announced: state.chats[i].job?.announced) }
        persist()
        return true
    }
    /// Closes the open job as done or cancelled. Cancelling also stops the chat's running turn.
    func closeChatJob(_ chatID: String, done: Bool) async {
        guard let i = state.chats.firstIndex(where: { $0.id == chatID }), state.chats[i].job?.isActive == true else { return }
        state.chats[i].job?.close(done: done)
        persist()
        if !done, isBusy(threadID: chatID) { await interruptThread(chatID) }
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
            notificationsAllowed = allowed
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
                                                   unread: chat.hasUnreadResponse && chat.limitResume?.isArmed != true,
                                                   failed: chat.lastTurnFailed == true) else { return nil }
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
                self.settleWorktreeBranch(id)
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

    /// Shared by every `remoteSnapshot` call: the publication runs on every model change, once per running chat.
    static let remoteTimestampFormatter = ISO8601DateFormatter()
    func remoteSnapshot(projects: Set<String>) async -> RemoteSnapshot {
        let selected = state.projects.filter { projects.contains($0.id.uuidString) }
        var chats: [RemoteChat] = []
        let awaitingApproval = Set(pending.map(\.threadID))
        let enabled = state.chats.filter { projects.contains($0.projectID.uuidString) && !$0.isArchived }
        let phoneChats = enabled.sorted(by: {
            if awaitingApproval.contains($0.id) != awaitingApproval.contains($1.id) { return awaitingApproval.contains($0.id) }
            return $0.updated > $1.updated
        }).prefix(20)
        // Web chats are always listed for the web client; beyond the phone's 20 they carry only their latest messages.
        let phoneIDs = Set(phoneChats.map(\.id))
        let webChats = enabled.filter { $0.isWebVisible && !phoneIDs.contains($0.id) }.sorted { $0.updated > $1.updated }.prefix(WebChats.snapshotLimit)
        for chat in Array(phoneChats) + webChats {
            let messages: [TranscriptItem]
            if chat.id == chatID { messages = items }
            else {
                // Publication runs on every model change; decode stored transcripts only when they changed.
                let revision = await store.transcriptRevision(conversationID: chat.id)
                if let cached = remoteHistoryCache[chat.id], cached.revision == revision, cached.session == chat.nativeSession {
                    messages = cached.messages
                } else {
                    messages = (try? await store.recentMessages(conversationID: chat.id, limit: 20)) ?? []
                    remoteHistoryCache[chat.id] = (revision, chat.nativeSession, messages)
                }
            }
            let approvals = pending.filter { $0.threadID == chat.id }.compactMap { action -> RemoteApproval? in
                guard case .approval(let canAllow) = action.interaction.kind else { return nil }
                return RemoteApproval(id: action.id, details: String(action.interaction.details.prefix(8000)), canAllow: canAllow && action.interaction.details.count <= 8000)
            }
            let shown = phoneIDs.contains(chat.id) ? 20 : WebChats.snapshotMessages
            var remote = RemoteChat(id: chat.id, project: chat.projectID.uuidString, title: chat.title,
                running: isBusy(threadID: chat.id), messages: messages.filter { ["user", "assistant"].contains($0.kind) }.suffix(shown).map {
                    RemoteMessage(id: $0.id, role: $0.kind, fullText: $0.text)
                }, approvals: approvals, turn: runs[chat.id]?.turnID)
            if chat.isWebVisible { remote.web = true }
            if chat.chatSearch == true { remote.chatSearch = true }
            if remote.running, let run = runs[chat.id] {
                // The host replaces this with the current tool call when it saw one.
                remote.activity = activity.statuses[chat.id].map { String($0.prefix(RemoteChat.activityLimit)) }
                remote.runningSince = run.turnID.flatMap { turnStarts[chat.id + ":" + $0] }.map { Self.remoteTimestampFormatter.string(from: $0) }
            }
            if chat.isScheduledRecord { remote.readOnly = true; remote.supportsPhotos = false }
            if let project = selected.first(where: { $0.id == chat.projectID }), traits(chat.nativeSession?.connection).contains(.remoteChatSettings) {
                remote.settings = remoteSettings(chat, project: project)
            }
            publishRemoteWork(chat, into: &remote)
            chats.append(remote)
        }
        // Existing chats' settings list the models of the agent whose chats the phone may configure.
        let settingsOptions = remoteSettingsAgent.map { agentState($0).models.map { RemoteModelOption(id: $0.id, name: $0.displayName) } } ?? []
        // New-chat models of every ready agent: the default agent's first, then the others in registration order.
        let lists = agentIDs.map { id in (id, remoteReady(id) ? remoteNewChatModels(id) : []) }.filter { !$0.1.isEmpty }
        let ordered = lists.filter { $0.0 == state.defaultConnection } + lists.filter { $0.0 != state.defaultConnection }
        let newChatModels = ordered.flatMap(\.1)
        // The phone's preselected model for a project's new chat: the project default, else the app's.
        func defaultModel(_ project: UUID) -> String {
            guard let (lead, options) = ordered.first, traits(lead).contains(.catalogModels) else {
                return ordered.first.flatMap { projectModelChoice($0.0, project: project).model } ?? state.model
            }
            let configured = resolvedDefaultModel(lead, project: project)
            return options.contains(where: { $0.id == configured }) ? configured : options.first?.id ?? state.model
        }
        return RemoteSnapshot(projects: selected.map {
            let defaultModel = defaultModel($0.id)
            var project = RemoteProject(id: $0.id.uuidString, name: $0.name, canCreateChat: canCreateRemoteChat)
            project.canSearchChats = canStartChatSearch ? true : nil
            project.models = settingsOptions
            project.newChatModels = newChatModels
            let projectRole = $0.chatRole(roleCatalog)
            project.settings = RemoteChatSettings(options: RemoteChatOptions(model: defaultModel),
                projectAccess: RemoteAccessMode(rawValue: projectRole.legacyAccessMode.rawValue)!, canEdit: !newChatModels.isEmpty,
                projectRole: projectRole.id, roles: remoteRoles(project: $0),
                addOns: Self.remoteAddOnOptions(remoteAllowedAddOns(project: $0)), projectAddOns: Self.remoteAddOnIDs(Self.projectAddOns($0)))
            return project
        }, chats: chats)
    }
    /// Full user and assistant messages of a web chat, the latest `WebChats.messageLimit`: the open chat from memory,
    /// others from the store, decoded again only when the stored transcript changed. Nil for an unknown chat.
    func webMessages(_ id: String) async -> [TranscriptItem]? {
        guard let chat = state.chats.first(where: { $0.id == id }) else { return nil }
        webHistoryCache = webHistoryCache.filter { key, _ in state.chats.contains { $0.id == key && $0.isWebVisible } }
        if id == chatID { return Array(items.filter { ["user", "assistant"].contains($0.kind) }.suffix(WebChats.messageLimit)) }
        let revision = await store.transcriptRevision(conversationID: id)
        if let cached = webHistoryCache[id], cached.revision == revision, cached.session == chat.nativeSession { return cached.messages }
        // A failed read publishes nothing rather than an empty chat.
        guard let messages = try? await store.recentMessages(conversationID: id, limit: WebChats.messageLimit) else { return nil }
        webHistoryCache[id] = (revision, chat.nativeSession, messages)
        return messages
    }
    /// Desktop queue identity of a message a phone queued; the suffix is its command ID.
    static let phoneQueuePrefix = "local-user:phone:"
    /// Pending questions and forms, the desktop queue and whether the phone may queue or interrupt-and-send now.
    /// The host withdraws the phone actions while the cloud schema cannot carry them.
    private func publishRemoteWork(_ chat: Chat, into remote: inout RemoteChat) {
        let interactions = pending.filter { $0.threadID == chat.id }.compactMap { RemoteInteraction($0.interaction) }
        remote.interactions = interactions.isEmpty ? nil : Array(interactions.prefix(RemoteInteraction.chatLimit))
        let queued = queuedMessages.filter { $0.threadID == chat.id }
        let run = runs[chat.id] ?? ChatRunState()
        if !queued.isEmpty {
            let claimed = claimedQueueIDs
            remote.queue = queued.prefix(RemoteQueuedMessage.chatLimit).map { message in
                RemoteQueuedMessage(id: message.id, text: message.text,
                                    command: message.id.hasPrefix(Self.phoneQueuePrefix) ? String(message.id.dropFirst(Self.phoneQueuePrefix.count)) : nil,
                                    claimed: claimed.contains(message.id) ? true : nil)
            }
            if queued.count > RemoteQueuedMessage.chatLimit { remote.queueCount = queued.count }
            // A priority message pauses the queue only until its interruption completes.
            if run.queuePaused && run.priorityMessageID == nil && !run.sending { remote.queuePaused = true }
        }
        let open = !chat.isScheduledRecord && !chat.isArchived && chatIsAvailable(chat.id) && !isChangingChat(chat.id)
            && chatConnected(chat.id) && chatAuthenticated(chat.id)
        remote.canQueue = open
        remote.canInterrupt = open && run.running && run.turnID != nil && !run.sending && run.priorityMessageID == nil
    }
    static func projectAddOns(_ project: Project) -> Set<RoleAddOn> { Set((project.chatRoleAddOns ?? []).compactMap(RoleAddOn.init(rawValue:))) }
    static func remoteAddOnIDs(_ addOns: Set<RoleAddOn>) -> [String] { RoleAddOn.allCases.filter(addOns.contains).map(\.rawValue) }
    static func remoteAddOnOptions(_ addOns: Set<RoleAddOn>) -> [RemoteAddOnOption] {
        RoleAddOn.allCases.filter(addOns.contains).map { RemoteAddOnOption(id: $0.rawValue, name: $0.title, summary: $0.summary, symbol: $0.symbol) }
    }
    /// Add-ons the phone may turn on: only those the project's chat default (role and project add-ons) already grants,
    /// so a phone never widens a chat beyond the project default, as with roles (audit M3).
    private func remoteAllowedAddOns(project: Project) -> Set<RoleAddOn> {
        let base = project.chatRole(roleCatalog).profile(for: project, addOns: Self.projectAddOns(project))
        return Set(RoleAddOn.allCases.filter { addOn in
            var widened = base
            addOn.apply(to: &widened)
            return widened == base
        })
    }
    /// The add-ons a phone command asks for, or nil when it names none. Unknown ids and add-ons outside `allowed` fail closed.
    private func remoteAddOns(_ options: RemoteChatOptions?, allowed: Set<RoleAddOn>) throws -> Set<RoleAddOn>? {
        guard let ids = options?.addOns else { return nil }
        var result: Set<RoleAddOn> = []
        for id in ids {
            guard let addOn = RoleAddOn(rawValue: id), allowed.contains(addOn) else { throw RemoteFailure.invalidCommand }
            result.insert(addOn)
        }
        return result
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
        let addOns = chat.resolvedAddOns(in: project)
        return RemoteChatSettings(options: RemoteChatOptions(model: chat.model,
            access: chat.inheritsProjectRole ? nil : RemoteAccessMode(rawValue: role.legacyAccessMode.rawValue), role: chat.inheritsProjectRole ? nil : role.id,
            addOns: Self.remoteAddOnIDs(addOns)),
            projectAccess: RemoteAccessMode(rawValue: projectRole.legacyAccessMode.rawValue)!,
            canEdit: agentState(chat.nativeSession?.connection).connected && agentState(chat.nativeSession?.connection).authenticated
                && !agentState(chat.nativeSession?.connection).models.isEmpty && !isChangingChat(chat.id) && !isBusy(threadID: chat.id)
                && !pending.contains(where: { $0.threadID == chat.id }) && !queuedMessages.contains(where: { $0.threadID == chat.id })
                && role.rank <= projectRole.rank,
            projectRole: projectRole.id, roles: remoteRoles(project: project),
            // Turning off is always allowed; turning on only within the project default.
            addOns: Self.remoteAddOnOptions(remoteAllowedAddOns(project: project).union(addOns)), projectAddOns: Self.remoteAddOnIDs(Self.projectAddOns(project)))
    }
    private func remoteModel(_ options: RemoteChatOptions, agent: AgentConnectionID?) throws -> AgentModelInfo {
        guard let model = agentState(agent).models.first(where: { $0.id == options.model }) else { throw RemoteFailure.invalidCommand }
        return model
    }
    /// The agent whose chats the phone may configure (model and role).
    private var remoteSettingsAgent: AgentConnectionID? { firstAgent(with: .remoteChatSettings) }
    /// A phone may start a chat on any ready agent, independent of the desktop's default agent.
    private func remoteReady(_ id: AgentConnectionID) -> Bool {
        agentState(id).connected && agentState(id).authenticated && routeIsAvailable(newChatRoute(id))
    }
    /// Models the phone may start a chat with on this agent: the listed ones, or the catalog models the pinned build runs.
    private func remoteNewChatModels(_ id: AgentConnectionID) -> [RemoteModelOption] {
        guard let tag = profile(id)?.remoteAgent else { return [] }
        if traits(id).contains(.catalogModels) {
            return (modelCatalog(id)?.runnable ?? []).map { RemoteModelOption(id: $0.id, name: $0.name, agent: tag) }
        }
        return agentState(id).models.map { RemoteModelOption(id: $0.id, name: $0.displayName, agent: tag) }
    }
    private var canCreateRemoteChat: Bool { agentIDs.contains(where: remoteReady) }
    private func createRemoteChat(_ command: RemoteCommand) async throws -> String {
        guard !state.chats.contains(where: { $0.id == command.chat }),
              let project = state.projects.first(where: { $0.id.uuidString == command.project }) else { throw RemoteFailure.invalidCommand }
        let options = command.settings?.options
        // The command carries only a model ID; the Mac resolves its agent (the first registered one that offers the model).
        // Older phones without options mean the agent whose chats the phone configures.
        let agent = options.map { option in agentIDs.first { remoteNewChatModels($0).contains { $0.id == option.model } } } ?? remoteSettingsAgent
        guard let agent, remoteReady(agent), let client = client(agent) else { throw RemoteFailure.invalidCommand }
        let model: String, effort: String, route = newChatRoute(agent)
        if traits(agent).contains(.catalogModels), let options {
            model = options.model; effort = resolvedDefaultEffort(agent, project: project.id)
        } else {
            let chosen = try options.map { try remoteModel($0, agent: agent) }
            model = chosen?.id ?? resolvedDefaultModel(agent, project: project.id)
            effort = chosen?.defaultEffort ?? resolvedDefaultEffort(agent, project: project.id)
        }
        let explicitRole = try remoteRole(options, project: project)
        let role = explicitRole ?? project.chatRole(roleCatalog)
        let explicitAddOns = try remoteAddOns(options, allowed: remoteAllowedAddOns(project: project))
        // Persist the stable app ID before sending. Native identity never comes from the phone.
        let session = try await client.createSession(projectPath: project.path, permissions: role.profile(for: project, addOns: explicitAddOns ?? Self.projectAddOns(project)),
                                                     model: model, route: route)
        guard !state.chats.contains(where: { $0.id == command.chat }),
              ConversationIdentity.appID(for: session.nativeID, in: state, connection: session.connection) == nil else { throw RemoteFailure.invalidCommand }
        var chat = Chat(session: session, projectID: project.id, title: ChatTitle.placeholder(), model: model)
        chat.id = command.chat; chat.effort = effort; chat.route = route
        chat.roleID = explicitRole?.id; chat.accessMode = explicitRole?.legacyAccessMode; chat.inheritsProjectAccess = explicitRole == nil
        chat.roleAddOns = explicitAddOns.map(Self.remoteAddOnIDs)
        if command.createsWebChat { chat.webSince = Date() }
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
        if command.kind == "search" { return try await startRemoteChatSearch(command) }
        if command.kind == "restore" { return try await restoreWebChat(command) }
        if command.createsChat { return try await createRemoteChat(command) }
        guard let chat = state.chats.first(where: { $0.id == command.chat && $0.projectID.uuidString == command.project && !$0.isArchived }),
              let project = state.projects.first(where: { $0.id == chat.projectID }),
              !isChangingChat(chat.id), chatIsAvailable(chat.id), chatConnected(chat.id), chatAuthenticated(chat.id) else { throw RemoteFailure.invalidCommand }
        switch command.kind {
        case "configure":
            guard traits(chat.nativeSession?.connection).contains(.remoteChatSettings), let change = command.settings else { throw RemoteFailure.invalidCommand }
            let current = remoteSettings(chat, project: project)
            guard current.canEdit, let expected = change.expected, expected.matches(current: current.options),
                  change.expectedProjectAccess == current.projectAccess else { throw RemoteFailure.invalidCommand }
            let selectedModel = try remoteModel(change.options, agent: chat.nativeSession?.connection)
            let role = try remoteRole(change.options, project: project)
            let currentAddOns = chat.resolvedAddOns(in: project)
            let addOns = try remoteAddOns(change.options, allowed: remoteAllowedAddOns(project: project).union(currentAddOns))
            configuringRemoteChats.insert(chat.id)
            defer { configuringRemoteChats.remove(chat.id); objectWillChange.send() }
            guard let index = state.chats.firstIndex(where: { $0.id == chat.id }) else { throw RemoteFailure.invalidCommand }
            state.chats[index].model = selectedModel.id
            if chat.model != selectedModel.id { state.chats[index].effort = selectedModel.defaultEffort }
            state.chats[index].roleID = role?.id
            state.chats[index].accessMode = role?.legacyAccessMode
            state.chats[index].inheritsProjectAccess = role == nil
            // Unchanged add-ons keep following the project; a change stores them for this chat, as the desktop chip does.
            if let addOns, addOns != currentAddOns { state.chats[index].roleAddOns = Self.remoteAddOnIDs(addOns) }
            do { try await store.save(state) }
            catch {
                if let index = state.chats.firstIndex(where: { $0.id == chat.id }) {
                    state.chats[index].model = chat.model; state.chats[index].effort = chat.effort
                    state.chats[index].accessMode = chat.accessMode; state.chats[index].inheritsProjectAccess = chat.inheritsProjectAccess
                    state.chats[index].roleID = chat.roleID; state.chats[index].roleAddOns = chat.roleAddOns
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
        case "queue":
            // The desktop queue: like a message typed while the chat works, it runs after the current turn, in queue order.
            guard !chat.isScheduledRecord else { throw RemoteFailure.invalidCommand }
            let id = Self.phoneQueuePrefix + command.id.lowercased()
            guard !queuedMessages.contains(where: { $0.id == id }) else { throw RemoteFailure.invalidCommand }
            let prompt = try command.photoPrompt(directory: Locations.root.appendingPathComponent("mobile-photos", isDirectory: true))
            // As on the desktop: a message joining a waiting (paused) queue waits too; an empty queue starts moving.
            if !queuedMessages.contains(where: { $0.threadID == chat.id }) { runs[chat.id, default: ChatRunState()].queuePaused = false }
            state.queuedMessages = queuedMessages + [QueuedMessage(id: id, threadID: chat.id, projectID: chat.projectID, text: prompt,
                                                                   model: dispatchModel(chat), effort: dispatchEffort(chat))]
            // Saved before the phone is told "submitted": an acknowledged message survives a quit or crash.
            try await saveRemoteQueued(id)
            AppLog.delivery.notice("Phone message queued in chat \(chat.id, privacy: .public)")
            scheduleQueue(threadID: chat.id)
            return "submitted"
        case "interrupt":
            // The desktop's "Interrupt and send": only for the turn the phone saw running. Nothing is sent here; the
            // message goes first in the queue and the drain sends it, with the interruption note, once that turn ends.
            let run = runs[chat.id] ?? ChatRunState()
            guard !chat.isScheduledRecord, run.running, let turn = run.turnID, command.turn == turn,
                  !run.sending, run.priorityMessageID == nil else { throw RemoteFailure.invalidCommand }
            let id = Self.phoneQueuePrefix + command.id.lowercased()
            guard !queuedMessages.contains(where: { $0.id == id }) else { throw RemoteFailure.invalidCommand }
            let prompt = try command.photoPrompt(directory: Locations.root.appendingPathComponent("mobile-photos", isDirectory: true))
            let wasPaused = run.queuePaused
            state.queuedMessages = [QueuedMessage(id: id, threadID: chat.id, projectID: chat.projectID, text: prompt,
                                                  model: dispatchModel(chat), effort: dispatchEffort(chat))] + queuedMessages
            // Claimed before the save suspends, so a turn that ends meanwhile releases the message as "Interrupt and send" would.
            runs[chat.id, default: ChatRunState()].priorityMessageID = id
            runs[chat.id, default: ChatRunState()].queuePaused = true
            do { try await saveRemoteQueued(id) } catch {
                if runs[chat.id]?.priorityMessageID == id {
                    runs[chat.id, default: ChatRunState()].priorityMessageID = nil
                    runs[chat.id, default: ChatRunState()].queuePaused = wasPaused
                }
                if runs[chat.id]?.interruptedFor == id { runs[chat.id, default: ChatRunState()].interruptedFor = nil }
                throw error
            }
            // The turn ended during the save: the message is already released to go next; there is nothing to stop.
            guard runs[chat.id]?.priorityMessageID == id, runs[chat.id]?.turnID == turn else {
                AppLog.delivery.notice("Phone interrupt-and-send in chat \(chat.id, privacy: .public): turn \(turn, privacy: .public) ended before the stop; the message stays first in the queue")
                return "submitted"
            }
            do {
                try await clientForChat(chat.id).interrupt(sessionForChat(chat.id), turn: turn)
            } catch {
                // The message stays in the paused queue for the user on the Mac; it is never sent on its own.
                if runs[chat.id]?.priorityMessageID == id {
                    runs[chat.id, default: ChatRunState()].priorityMessageID = nil
                    runs[chat.id, default: ChatRunState()].queuePaused = true
                }
                throw error
            }
            AppLog.delivery.notice("Phone interrupt-and-send in chat \(chat.id, privacy: .public) for turn \(turn, privacy: .public)")
            return "submitted"
        case "answer":
            // Only the exact pending request, as the phone saw it: still answerable in full, with answers the desktop accepts.
            guard let handle = command.approval.flatMap(UUID.init(uuidString:)), let answers = command.answers,
                  let action = pending.first(where: { $0.threadID == chat.id && $0.interaction.id == handle }),
                  let published = RemoteInteraction(action.interaction), published.canAnswer,
                  (try? published.validate(answers: answers)) != nil else { throw RemoteFailure.invalidCommand }
            try await answerRemote(action, response: .answers(answers))
            return "submitted"
        case "stop":
            guard let turn = runs[chat.id]?.turnID, command.turn == turn else { throw RemoteFailure.invalidCommand }
            runs[chat.id, default: ChatRunState()].queuePaused = true
            runs[chat.id, default: ChatRunState()].stopRequested = true
            try await clientForChat(chat.id).interrupt(sessionForChat(chat.id), turn: turn)
            return "stop_requested"
        case "deny" where remoteRequest(command, chat: chat.id).map({ if case .approval = $0.interaction.kind { false } else { true } }) == true:
            // The desktop's Decline of a form, link or unsupported request. Questions have no Decline there, so none here.
            guard let action = remoteRequest(command, chat: chat.id), RemoteInteraction(action.interaction)?.canDecline == true else { throw RemoteFailure.invalidCommand }
            try await answerRemote(action, response: .deny)
            return "submitted"
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
    /// Writes the state with a phone message just put in the desktop queue, before the command is acknowledged. When the
    /// write fails and the message still waits, it is taken out again and the command is rejected: nothing was queued or
    /// sent. A message the drain already took has gone out, so its command stands.
    private func saveRemoteQueued(_ id: String) async throws {
        do { try await store.save(state) } catch {
            guard queuedMessages.contains(where: { $0.id == id }) else { return }
            state.queuedMessages = queuedMessages.filter { $0.id != id }
            persist()
            AppLog.delivery.error("Phone message not queued, the app state could not be saved: \(error.localizedDescription, privacy: .public)")
            throw RemoteFailure.invalidCommand
        }
    }
    /// The pending request a phone command names by its handle, in that chat only.
    private func remoteRequest(_ command: RemoteCommand, chat: String) -> PendingAction? {
        guard let id = command.approval.flatMap(UUID.init(uuidString:)) else { return nil }
        return pending.first { $0.threadID == chat && $0.interaction.id == id }
    }
    /// Answers a pending request for the phone. A definite rejection sent nothing; any other failure stays uncertain.
    private func answerRemote(_ action: PendingAction, response: AgentInteractionResponse) async throws {
        do {
            try await clientForChat(action.threadID).answer(action.interaction.id, session: action.interaction.session, response: response)
        } catch let failure as AgentOperationFailure where failure.rejection != nil && !failure.uncertain {
            throw RemoteFailure.invalidCommand
        }
        pending.removeAll { $0.id == action.id }; removeActionNotices([action])
        refreshDockBadge()
    }
    func shutdown() async {
        // Each awaited step is logged so a stalled quit names the step that never returned.
        let log = AppLog.lifecycle
        func step(_ name: String) { log.notice("Shutdown step: \(name, privacy: .public)") }
        flushDeltas()
        photoCleanupTask?.cancel(); photoCleanupTask = nil
        step("mobile remote"); await mobileRemote.disable()
        for slot in slots.values { slot.historyBackfillTask?.cancel() }
        activityCleanupTask?.cancel()
        for task in historyRefreshTasks.values { task.cancel() }
        step("chat titles (\(titleTasks.count))")
        for id in Array(titleTasks.keys) { await cancelChatTitle(id) }
        step("scheduler"); await stopScheduler()
        summaryTask?.cancel()
        step("handoff"); await cancelHandoffPreparation()
        step("summary runners")
        for id in agentIDs { await slots[id]?.generationRunner.stop() }
        step("summary queue"); await summaryTask?.value
        for id in agentIDs {
            guard let slot = slots[id] else { continue }
            step("\(slot.profile.name) connection"); await slot.client.stop()
            slot.eventTask?.cancel()
        }
        step("plugins"); await stopPlugins()
        step("capability ledger"); await capabilityLedger.flush()
        step("orphan processes"); await orphanProcesses.shutdown()
        step("done")
    }
    func saveAgentChoice() { persist() }
    /// The agent of new chats. One that does not connect at launch connects when it is chosen.
    func selectAgent(_ agent: AgentConnectionID) {
        guard chatID == nil, !sending, isRegistered(agent), agentState(agent).installed else { return }
        // Browser profiles belong to one agent; a picked profile does not carry over.
        if state.defaultConnection != agent { newChatBrowserProfiles.removeAll() }
        state.defaultConnection = agent; persist()
        if !traits(agent).contains(.connectsAtLaunch) && !agentState(agent).connected { Task { await connect(agent) } }
    }
    /// The composer's sign-in button. A shared engine that is not connected connects first; its account may already be
    /// signed in. Others sign in at once (connecting on the way).
    func loginCurrentAgent() async {
        let id = currentAgent
        if agentState(id).connected || !traits(id).contains(.sharedEngine) { await login(id) } else { await connect(id) }
    }
    private func resetAgentState(_ agent: AgentConnectionID) {
        let ids = Set(state.chats.filter { $0.nativeSession?.connection == agent }.map(\.id))
        clearAgentInteractions(agent)
        for id in ids { runs[id] = nil; loadedThreads.remove(id) }
        activity.clearRuns(ids)
    }
    private func clearAgentInteractions(_ agent: AgentConnectionID) {
        let actions = pending.filter { $0.interaction.session.connection == agent }
        removeActionNotices(actions); pending.removeAll { $0.interaction.session.connection == agent }
        refreshDockBadge()
    }
    // MARK: State persistence
    /// `persist()` calls within this delay share one write (a turn makes 2-3 of them).
    static let persistDelay: Duration = .milliseconds(200)
    private var persistTask: Task<Void, Never>?
    private var persistWriting = false
    private var persistDirty = false
    /// Writes the coalesced persistence issued; tests count them.
    private(set) var persistWrites = 0
    /// Replaces `store.save` for coalesced writes; tests slow it down or record the written snapshots.
    var persistWriter: (@MainActor (SavedState) async throws -> Void)?

    /// Schedules a save of the latest state. One pending task per model: calls within `persistDelay` share one
    /// write, and a call during a running write queues exactly one follow-up. Every write takes `state` as it is
    /// at write time, so an older snapshot never overwrites a newer one. `flushPersist()` writes now (quit path).
    func persist() {
        persistDirty = true
        guard persistTask == nil else { return }
        persistTask = Task {
            // flushPersist cancels only this delay; the write itself never checks for cancellation.
            try? await Task.sleep(for: Self.persistDelay)
            await writePendingState()
        }
    }
    private func writePendingState() async {
        persistWriting = true
        defer { persistWriting = false; persistTask = nil }
        while persistDirty {
            persistDirty = false
            let snapshot = state
            persistWrites += 1
            do {
                if let persistWriter { try await persistWriter(snapshot) } else { try await store.save(snapshot) }
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Writes the pending state now and returns after the write (and its follow-up, if one was requested meanwhile).
    func flushPersist() async {
        guard let task = persistTask else { return }
        if !persistWriting { task.cancel() }
        await task.value
    }

    /// Every event of every registered connection, tagged with the connection it came from.
    func receive(_ event: AgentEvent, from id: AgentConnectionID) async {
        let thread = event.session.flatMap { appID(for: $0) }
        if event.session != nil && thread == nil {
            if case .interaction(let request) = event.payload { await client(id)?.rejectInteraction(request.id) }
            return
        }
        // A plan update is the turn's plan item: recorded, shown and carried over history reloads like any other item.
        if case .plan(let turn, let plan) = event.payload {
            guard let thread, let turn = turn ?? runs[thread]?.turnID else { return }
            let item = plan.transcriptItem(turn: turn, agentName: agentName(id))
            await receive(AgentEvent(session: event.session, payload: .item(item)), from: id)
            return
        }
        defer { mobileRemote.observe(event, thread: thread) }
        let traits = traits(id), name = agentName(id)
        switch event.payload {
        case .descriptor(let descriptor):
            if agentState(id).descriptor?.context != descriptor.context { agentStates[id]?.models = []; clearLimits(id) }
            agentStates[id]?.descriptor = descriptor
        case .interaction(let request):
            guard let thread else { await client(id)?.rejectInteraction(request.id); return }
            let action = PendingAction(interaction: request, threadID: thread)
            if !pending.contains(where: { $0.id == action.id }) { pending.append(action); notify(action) }
        case .interactionsReset:
            clearAgentInteractions(id)
        case .capability(let record):
            guard let thread, let chat = state.chats.first(where: { $0.id == thread }),
                  let project = state.projects.first(where: { $0.id == chat.projectID }) else { return }
            let role = chat.resolvedRole(in: project, catalog: roleCatalog)
            let run = jobLedger.runs.first { $0.threadID == thread && $0.status.active }?.id
            // The ledger names the agent by its job engine value ("codex", "claude").
            let agent = profile(event.session?.connection ?? id)?.engine.rawValue ?? id.agent.rawValue
            let decision = CapabilityDecision(chatID: thread, runID: run, projectID: project.id, roleID: role.id,
                                              agent: agent, record: record, audit: role.profile.audit)
            Task { [capabilityLedger] in await capabilityLedger.record(decision) }
        case .accountChanged(let issue):
            if traits.contains(.sharedEngine) {
                // Titles of this connection's chats (and of chats no registered connection owns) ran on the old account.
                for (chatID, task) in titleTasks {
                    let owner = state.chats.first(where: { $0.id == chatID })?.nativeSession?.connection
                    if owner == id || !isRegistered(owner) { task.cancel() }
                }
            }
            agentStates[id]?.models = []; clearLimits(id); resetAgentState(id)
            await interruptSummaries(id, issue: L10n.text("Аккаунт изменился. Проверь итог перед новым запуском.", "The account changed. Review the summary before starting again."))
            if traits.contains(.sharedEngine), let engine = profile(id)?.engine {
                for run in jobLedger.runs where run.engine == engine && run.status.active {
                    await finishJob(run.id, status: .uncertain, output: L10n.text("Аккаунт изменился; запуск не повторён.", "The account changed; the run was not retried."))
                }
            }
            if let issue { error = issue }
            await refreshAccount(id)
        case .limitsChanged: await refreshLimits(id, quiet: true)
        case .disconnected:
            flushDeltas()
            slots[id]?.historyBackfillTask?.cancel()
            if traits.contains(.sharedEngine) {
                // Every chat of the engine lost its turn: running scheduled runs end as uncertain and nothing is resent.
                for task in historyRefreshTasks.values { task.cancel() }
                agentStates[id]?.descriptor = nil; agentStates[id]?.models = []
                agentStates[id]?.connected = false
                if let engine = profile(id)?.engine {
                    for run in jobLedger.runs where run.engine == engine && run.status.active {
                        await finishJob(run.id, status: .uncertain, output: L10n.text("Соединение потеряно; повторной отправки не было.", "Connection lost; the task was not sent again."))
                    }
                }
                resetAgentState(id)
                agentStates[id]?.connected = false
                error = Self.disconnectedNotice(name)
            } else {
                resetAgentState(id)
                agentStates[id]?.connected = false; agentStates[id]?.authenticated = false; clearLimits(id)
                await interruptSummaries(id, issue: L10n.text("\(name) отключился. Итог не повторён автоматически.", "\(name) disconnected. The summary was not retried automatically."))
            }
        case .diagnostic(let message):
            error = message
            if let thread { ChatEventLog.append(chat: thread, kind: "diagnostic", text: message) }
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
                // Message deltas often repeat the previous values; an identical snapshot must not redraw the window.
                if usage[id] != snapshot { usage[id] = snapshot }
                try? await store.saveUsage(threadID: id, snapshot: snapshot)
            }
        case .started(let turn):
            if let thread,
               completedTurns[thread + ":" + turn] == nil {
                if turnStarts[thread + ":" + turn] == nil {
                    recordTurnBranch(threadID: thread)
                    ChatEventLog.append(chat: thread, kind: "turn", text: "Turn \(turn) started")
                }
                turnStarts[thread + ":" + turn] = turnStarts[thread + ":" + turn] ?? Date()
                if turnTokens[thread + ":" + turn] == nil {
                    turnTokens[thread + ":" + turn] = ResponseTokenTracker(baseline: tokenTotals[thread])
                }
                // One publication for the whole change, and none when nothing changed.
                var run = runs[thread] ?? ChatRunState()
                run.running = true; run.turnID = turn
                if runs[thread] != run { runs[thread] = run }
                activity.setStatus(nil, for: thread)
                if backgroundWaits[thread] != nil { backgroundWaits[thread] = nil }
                noteTurnStarted(chatID: thread, turnID: turn)
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
                recordTurnChanges(chatID: threadID, turnID: turnID)
                let status = completion.status
                ChatEventLog.append(chat: threadID, kind: "turn", text: "Turn \(turnID) finished: \(status.rawValue)"
                                    + (completion.hasError ? ", error: " + (completion.error ?? "-") : ""))
                let title = completion.hasError || (status != .completed && status != .cancelled) ? L10n.text("Ошибка в разговоре", "Conversation error") : status == .cancelled ? L10n.text("Ответ остановлен", "Response stopped") : L10n.text("Ответ готов", "Response ready")
                let completionID = "turn:" + threadID + ":" + turnID
                recordRecap(threadID: threadID, failed: completion.hasError || (status != .completed && status != .cancelled), error: completion.error)
                noteLimitStop(threadID: threadID, completion: completion)
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
            transcript.enqueue(id: id, text: text, turn: turn) { $0.agentName = name }
        case .status(let turn, let text):
            guard let thread, let run = runs[thread], run.running, turn == nil || run.turnID == turn else { return }
            // Claude repeats the status on every content block; identical text must not publish.
            activity.setStatus(text, for: thread)
        case .background(let tasks):
            guard let thread else { return }
            let count = tasks > 0 ? tasks : nil
            if backgroundWaits[thread] != count {
                backgroundWaits[thread] = count
                ChatEventLog.append(chat: thread, kind: "background", text: count.map { "Waiting for \($0) background task(s) after the turn" } ?? "Background wait ended")
            }
        case .subagents(let list):
            guard let thread else { return }
            let agents = list.isEmpty ? nil : list
            if subagents[thread] != agents { subagents[thread] = agents }
            // A marked sub-agent that reported again loses its mark at once; the loop runs while any sub-agent does.
            if stalledSubagents[thread] != nil { markStalledSubagents(thread) }
            if list.contains(where: { $0.status == .running }) { startSubagentWatch() }
        case .backgroundTasks(let list):
            guard let thread else { return }
            let tasks = list.isEmpty ? nil : list
            if backgroundTasks[thread] != tasks { backgroundTasks[thread] = tasks }
        case .commands(let list):
            guard let thread else { return }
            sessionCommands[thread] = list
        case .configOptions(let options):
            // A session-models agent lists the models its sessions report.
            if traits.contains(.sessionModels), options.contains(where: { $0.category == .model }) { await refreshModels(id) }
            guard let thread else { return }
            sessionConfigOptions[thread] = options
        case .plan: break // Converted to an item above.
        }
    }
    private func flushDeltas() { transcript.flush() }

    /// Calls `handler` with the property name on every `@Published` write (each one is an `objectWillChange`), for the
    /// `model.publish` signpost (`PerfSignposts`) and the publication probes. Lives here because `runs` is private.
    func observePublications(_ handler: @escaping @MainActor (String) -> Void) -> [AnyCancellable] {
        func watch<P: Publisher>(_ publisher: P, _ name: String) -> AnyCancellable where P.Failure == Never {
            publisher.dropFirst().sink { _ in MainActor.assumeIsolated { handler(name) } }
        }
        return [
            watch($configuringBrowserChats, "configuringBrowserChats"), watch($newChatBrowserProfiles, "newChatBrowserProfiles"),
            watch($newChatRoles, "newChatRoles"), watch($newChatAddOns, "newChatAddOns"), watch($newChatWorkspaces, "newChatWorkspaces"), watch($creatingWorktree, "creatingWorktree"),
            watch($worktreeRemovalOffers, "worktreeRemovalOffers"), watch($runningBrowserChats, "runningBrowserChats"),
            watch($composerFocusRequest, "composerFocusRequest"), watch($plugins, "plugins"), watch($pluginIssues, "pluginIssues"),
            watch($pluginStatuses, "pluginStatuses"), watch($pluginMessages, "pluginMessages"), watch($notices, "notices"),
            watch($unreadResponseItems, "unreadResponseItems"), watch($state, "state"), watch($projectID, "projectID"),
            watch($chatID, "chatID"), watch($showingArchive, "showingArchive"), watch($archiveViewingChat, "archiveViewingChat"),
            watch($showingJobs, "showingJobs"), watch($jobs, "jobs"), watch($jobLedger, "jobLedger"), watch($schedulerReady, "schedulerReady"),
            watch($attention, "attention"), watch($showingAttention, "showingAttention"), watch($archiveSummaries, "archiveSummaries"),
            watch($summaryActiveThread, "summaryActiveThread"), watch($localHistoryNotice, "localHistoryNotice"), watch($routines, "routines"),
            watch($creatingHandoff, "creatingHandoff"), watch($preparingHandoff, "preparingHandoff"), watch($handoffProgress, "handoffProgress"),
            watch($pending, "pending"), watch($restartWaitingChatIDs, "restartWaitingChatIDs"),
            watch($draftEffort, "draftEffort"), watch($newChatModelChoices, "newChatModelChoices"), watch($agentStates, "agentStates"), watch($isBootstrapping, "isBootstrapping"),
            watch($runs, "runs"), watch($stoppingTasks, "stoppingTasks"), watch($deletingChatIDs, "deletingChatIDs"),
            watch($archivingChatIDs, "archivingChatIDs"), watch($loadingChat, "loadingChat"), watch($error, "error"),
            watch($queueEdit, "queueEdit"), watch($notificationStatus, "notificationStatus"),
            watch($notificationsAllowed, "notificationsAllowed"), watch($documentExpanded, "documentExpanded"),
        ]
    }
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
    func isScheduledRecord(_ id: String) -> Bool { chat(id)?.isScheduledRecord == true }

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
                                          model: model, effort: traits(agent).contains(.catalogModels) ? effort : nil, role: role, title: title) else { return }
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
        // The record belongs to the job's agent; print runs exist only for Claude jobs.
        guard let connection = connection(for: job.engine) else { throw ConversationIdentity.unavailable }
        let session = AgentSessionReference(connection: connection, nativeID: "scheduled-" + run.id.uuidString.lowercased())
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
                answer.turnID = turn; answer.agentName = agentName(session.connection)
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
