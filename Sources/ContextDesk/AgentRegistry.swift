import Foundation
import ContextCore

/// How the app treats one agent where agents genuinely differ. The composition root (`AgentIntegrationFactory`)
/// declares them per agent; orchestration and UI test traits and descriptor capabilities, never concrete connection IDs.
struct AgentAppTraits: OptionSet, Sendable {
    let rawValue: Int
    /// Connects when the app launches. Other agents connect on first use: as the default agent of new chats, or when
    /// they own a chat or an enabled scheduled job.
    static let connectsAtLaunch = Self(rawValue: 1 << 0)
    /// One engine process serves every chat of the connection. Reconnecting stops it first and waits until the whole app
    /// is idle; losing it is reported and ends the connection's running scheduled runs, and an account change also cancels
    /// its chat-title generations. Without it each chat has its own engine process and a connection only checks the
    /// engine and the account, so losing it signs the connection out and stops its summaries instead.
    static let sharedEngine = Self(rawValue: 1 << 1)
    /// Requests can run through the app's optimizer plugins (process plugin v1); new chats take the default route.
    static let optimizerPlugins = Self(rawValue: 1 << 2)
    /// Models come from the app's catalog (`AgentProfile.modelCatalog`) with fixed effort levels and the advisor setting,
    /// instead of the engine's model discovery and the free-form efforts of the selected model.
    static let catalogModels = Self(rawValue: 1 << 3)
    /// Chats can get the app's chat-directory and chat-search tools; chat search runs on this agent.
    static let chatDirectory = Self(rawValue: 1 << 4)
    /// The phone may change a chat's model and role.
    static let remoteChatSettings = Self(rawValue: 1 << 5)
    /// The adapter keeps the session history files itself, so the tool bodies of archived chats can be reduced through it.
    static let adapterHistory = Self(rawValue: 1 << 6)
}

/// Copy and identifiers of one agent: the presentation table. Only the composition root fills it.
struct AgentProfile: Sendable {
    let connection: AgentConnectionID
    /// Value scheduled jobs and run records store for this agent.
    let engine: JobEngine
    /// Short name in chats, labels and the transcript ("Codex", "Claude").
    let name: String
    /// Product name of the engine in settings and version notices ("Codex", "Claude Code").
    let productName: String
    let traits: AgentAppTraits
    /// Account line in the sidebar for the connection's state.
    let accountLine: @MainActor @Sendable (AgentConnectionState) -> String
    /// Account label after a successful account read.
    let accountLabel: @Sendable (AgentAccountInfo) -> String
    /// Banner over the composer while the current agent is signed out.
    let signInPrompt: @Sendable () -> String
    /// Shown instead of the generic limits error when the account reports no limits; nil keeps the generic error.
    let noLimitsNotice: (@Sendable () -> String)?
    /// Name of the browser session-import tool as the agent sees it in a scheduled run.
    let browserImportTool: String
    /// Tag of the agent's new-chat models in the phone protocol (`RemoteModelOption.agent`).
    let remoteAgent: String
    /// Key and environment variable through which the agent's CLI names its session in a restart request.
    let restartRequester: (key: String, environment: String)
    /// Capabilities a routine is checked against for this agent's jobs; nil uses the connected descriptor's.
    let routineCapabilities: Set<AgentCapability>?
    /// Copy of the agent's section in Settings → Accounts.
    let accountCopy: AgentAccountCopy
    /// The app's model catalog for an agent with `catalogModels`, built on each call so its copy follows the language.
    let modelCatalog: (@Sendable () -> AgentModelCatalog)?
}

/// Selectable models, effort levels and advisors of an agent whose engine lists no models. The adapter owns the
/// catalog; the composition root hands it to the app in this neutral form.
struct AgentModelCatalog: Sendable {
    struct Entry: Identifiable, Sendable {
        let id: String
        let name: String
        /// Name and reasoning mode, as the menus show it.
        let menuTitle: String
        /// False for superseded generations the provider still serves.
        let isCurrent: Bool
        /// Why the verified engine cannot run the model; nil when it can.
        let requirementNote: String?
    }
    struct Level: Sendable {
        let id: String
        let title: String
    }
    let entries: [Entry]
    /// The model of a message when none is chosen.
    let defaultModel: String
    let efforts: [Level]
    let defaultEffort: Level
    /// Advisor choices; an empty ID means none.
    let advisors: [Level]
    /// An unset or blank model means the default; any other identifier is kept verbatim.
    let resolveModel: @Sendable (String?) -> String
    /// An unset, blank or unknown effort means the default level.
    let resolveEffort: @Sendable (String?) -> String
    /// True for an effort the adapter may forward: empty (engine default) or a known level.
    let isDispatchableEffort: @Sendable (String?) -> Bool
    /// Label of a configured model; an unknown identifier is shown verbatim.
    let title: @Sendable (String) -> String
    let reasoningTitle: @Sendable (String) -> String?
    let requirementNote: @Sendable (String) -> String?
    /// The advisor attached to a message on `mainModel` for the advisor setting, or nil.
    let advisor: @Sendable (_ setting: String?, _ mainModel: String) -> String?
    var current: [Entry] { entries.filter(\.isCurrent) }
    var previous: [Entry] { entries.filter { !$0.isCurrent } }
    /// Catalog models the verified engine can run.
    var runnable: [Entry] { entries.filter { $0.requirementNote == nil } }
    func effortTitle(_ id: String) -> String? { efforts.first { $0.id == id }?.title }
}

/// Settings → Accounts copy of one agent; the layout follows `AgentAppTraits.sharedEngine`.
struct AgentAccountCopy: Sendable {
    let section: @Sendable () -> String
    let signIn: @Sendable () -> String
    let signOut: @Sendable () -> String
    /// Explanation under the sign-in state, if any.
    let note: (@Sendable () -> String)?
    /// The usage-limits popover: whose limits these are, and where to sign in to see them.
    let limitsScope: @Sendable () -> String
    let limitsSignIn: @Sendable () -> String
    /// Hint in the handoff editor while the agent is signed out; nil shows none.
    let handoffSignIn: (@Sendable () -> String)?
}

/// One registered connection as the app builds it: its profile, integration and homes.
struct AgentRegistration {
    let profile: AgentProfile
    let integration: any AgentIntegration
    /// The app-owned home the connection starts in.
    let home: URL
    /// Home and executable for isolated generation (titles, summaries, handoffs) on this connection.
    let generationHome: URL
    let generationExecutable: URL?
    var connection: AgentConnectionID { profile.connection }
}

extension AgentConnectionID {
    /// No registered connection: nothing routes to it and every lookup fails closed.
    static let unregistered = Self(agent: AgentID(rawValue: ""), id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
}

/// Published state of one registered connection.
struct AgentConnectionState {
    var connected = false
    var authenticated = false
    var connecting = false
    var descriptor: AgentDescriptor?
    /// Models the engine listed (`models()`); empty for catalog agents and until signed in.
    var models: [AgentModelInfo] = []
    var accountLabel = L10n.text("Вход не выполнен", "Not signed in")
    var limits: AccountLimits?
    var limitsError: String?
    var refreshingLimits = false
}

/// The parts of a connection that are not published: its client, generation runner and tasks.
@MainActor final class AgentConnectionSlot {
    let registration: AgentRegistration
    let client: AgentClient
    let generationRunner: AgentGenerationRunner
    var eventTask: Task<Void, Never>?
    var historyBackfillTask: Task<Void, Never>?
    var limitsRequestID: UUID?
    var profile: AgentProfile { registration.profile }
    init(_ registration: AgentRegistration) {
        self.registration = registration
        client = AgentClient(integration: registration.integration)
        generationRunner = AgentGenerationRunner(integration: registration.integration)
    }
}
