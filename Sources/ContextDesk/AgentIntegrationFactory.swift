import Foundation
import AgentContract
import ContextCore
import CodexAdapter
import ClaudeAdapter

/// Composition root only; orchestration and UI depend on the common contract.
/// A new agent is one more `AgentProfile` in `profiles` and a case in `registrations`; the app iterates them.
enum AgentIntegrationFactory {
    static let claudeVersion = ClaudeJobRunner.version
    static func codex() -> any AgentIntegration { CodexIntegration() }
    static func claude() -> any AgentIntegration { ClaudeIntegration() }

    /// The presentation table: every agent this build supports, in the order the app lists them.
    static let profiles: [AgentProfile] = [codexProfile, claudeProfile]

    static let codexProfile = AgentProfile(
        connection: .originalCodex, engine: .codex, name: "Codex", productName: "Codex",
        traits: [.connectsAtLaunch, .sharedEngine, .optimizerPlugins, .remoteChatSettings],
        accountLine: { $0.connecting ? L10n.text("Подключение…", "Connecting…") : $0.accountLabel },
        accountLabel: { account in
            account.authenticated ? L10n.text("ChatGPT · \(account.plan ?? "подключён")", "ChatGPT · \(account.plan ?? "connected")")
                : L10n.text("Вход не выполнен", "Not signed in")
        },
        signInPrompt: { L10n.text("Войди через ChatGPT, чтобы начать чат.", "Sign in with ChatGPT to start a chat.") },
        noLimitsNotice: nil, browserImportTool: "browser_import_session", remoteAgent: RemoteModelOption.codexAgent,
        restartRequester: (key: RestartContinuation.codexThreadKey, environment: "CODEX_THREAD_ID"), routineCapabilities: nil,
        accountCopy: AgentAccountCopy(section: { L10n.text("Аккаунт Codex", "Codex account") },
                                      signIn: { L10n.text("Войти через ChatGPT", "Sign in with ChatGPT") },
                                      signOut: { L10n.text("Выйти из аккаунта этого приложения", "Sign out of this app") }, note: nil,
                                      limitsScope: {
            L10n.text("Лимиты Codex общие для аккаунта во всех приложениях. Контекст отдельного чата показан рядом с полем сообщения.",
                      "Codex limits are shared across all apps on your account. Each chat’s context usage is shown next to the message field.")
        }, limitsSignIn: {
            L10n.text("Войди в ChatGPT в настройках приложения, чтобы увидеть лимиты.", "Sign in with ChatGPT in the app’s settings to see your limits.")
        }, handoffSignIn: nil), modelCatalog: nil)

    static let claudeProfile = AgentProfile(
        connection: .appClaude, engine: .claude, name: "Claude", productName: "Claude Code",
        traits: [.catalogModels, .chatDirectory, .adapterHistory],
        accountLine: { $0.authenticated ? L10n.text("Claude · подключён", "Claude · connected") : L10n.text("Claude · вход не выполнен", "Claude · not signed in") },
        accountLabel: { $0.authenticated ? L10n.text("Вход выполнен", "Signed in") : L10n.text("Вход не выполнен", "Not signed in") },
        signInPrompt: { L10n.text("Войди по подписке Claude в отдельный профиль приложения.", "Sign in with your Claude subscription in the app’s separate profile.") },
        noLimitsNotice: {
            L10n.text("Claude Code не сообщает лимиты для этого аккаунта. Они доступны только для подписки Claude.",
                      "Claude Code reports no limits for this account. They are available only with a Claude subscription.")
        },
        browserImportTool: ScheduledBrowserImport.claudeImportTool, remoteAgent: RemoteModelOption.claudeAgent,
        restartRequester: (key: RestartContinuation.claudeSessionKey, environment: "CLAUDE_CODE_SESSION_ID"),
        // Routines of Claude jobs are checked against the print runner's capabilities.
        routineCapabilities: [.scheduledExecution, .interruption],
        accountCopy: AgentAccountCopy(section: { L10n.text("Подписка Claude", "Claude subscription") },
                                      signIn: { L10n.text("Войти по подписке Claude", "Sign in with Claude subscription") },
                                      signOut: { L10n.text("Выйти из Claude в этом приложении", "Sign out of Claude in this app") },
                                      note: {
            L10n.text("Официальный Claude Code \(ClaudeRuntime.pinnedVersion). Вход открывается в Terminal в отдельном профиле Switchboard, затем нажми «Проверить вход»; твой профиль Claude Code не меняется.",
                      "Official Claude Code \(ClaudeRuntime.pinnedVersion). Sign-in opens in Terminal in a separate Switchboard profile, then click Check sign-in; your own Claude Code profile is unchanged.")
        }, limitsScope: {
            L10n.text("Лимиты подписки Claude общие для аккаунта: Claude Code, claude.ai и другие приложения. Контекст отдельного чата показан рядом с полем сообщения.",
                      "Claude subscription limits are shared across your account: Claude Code, claude.ai and other apps. Each chat’s context usage is shown next to the message field.")
        }, limitsSignIn: {
            L10n.text("Войди в Claude в настройках приложения, чтобы увидеть лимиты.", "Sign in to Claude in the app’s settings to see your limits.")
        }, handoffSignIn: {
            L10n.text("Сначала войди по подписке Claude в настройках.", "First sign in with your Claude subscription in settings.")
        }), modelCatalog: { claudeCatalog })

    /// The Claude adapter's model, effort and advisor catalog in the app's neutral form.
    static var claudeCatalog: AgentModelCatalog {
        AgentModelCatalog(
            entries: ClaudeModel.catalog.map { .init(id: $0.id, name: $0.name, menuTitle: $0.menuTitle, isCurrent: $0.isCurrent, requirementNote: $0.requirementNote()) },
            defaultModel: ClaudeModel.defaultID,
            efforts: ClaudeEffort.allCases.map { .init(id: $0.rawValue, title: $0.title) },
            defaultEffort: .init(id: ClaudeEffort.defaultLevel.rawValue, title: ClaudeEffort.defaultLevel.title),
            advisors: ClaudeAdvisor.options.map { .init(id: $0.id, title: $0.name) },
            resolveModel: { ClaudeModel.resolved($0) }, resolveEffort: { ClaudeEffort.resolved($0) },
            isDispatchableEffort: { ClaudeEffort.isDispatchable($0) },
            title: { ClaudeModel.title(for: $0) }, reasoningTitle: { ClaudeModel.reasoningTitle(for: $0) },
            requirementNote: { ClaudeModel.requirementNote(for: $0) },
            advisor: { ClaudeAdvisor.attached($0, mainModel: $1) })
    }
    /// The verified Claude Code build and the branch other builds connect on as unverified, for job copy.
    static let claudeBranch = ClaudeRuntime.branch

    /// The registered connections with their integrations and homes. Tests replace integrations and homes here.
    static func registrations(codex: any AgentIntegration = codex(), claude: any AgentIntegration = claude(),
                              summaryExecutable: URL? = nil, summaryHome: URL = Locations.codexHome,
                              claudeHome: URL = Locations.claudeHome) -> [AgentRegistration] {
        [AgentRegistration(profile: codexProfile, integration: codex, home: Locations.codexHome,
                           generationHome: summaryHome, generationExecutable: summaryExecutable),
         AgentRegistration(profile: claudeProfile, integration: claude, home: claudeHome,
                           generationHome: claudeHome, generationExecutable: nil)]
    }

    @MainActor static let scheduledReadiness: [JobEngine: @MainActor (DeskModel) -> Bool] = {
        var map: [JobEngine: @MainActor (DeskModel) -> Bool] = [:]
        for profile in profiles {
            let connection = profile.connection
            map[profile.engine] = { $0.scheduledAgentReady(connection) }
        }
        return map
    }()
    /// Every agent runs a scheduled task as a resumable chat of its own connection (Claude in the app's own Claude profile).
    @MainActor static let scheduled: [JobEngine: @MainActor (DeskModel, ManagedJob, JobRun, Project) -> any AgentScheduledExecutor] = {
        var map: [JobEngine: @MainActor (DeskModel, ManagedJob, JobRun, Project) -> any AgentScheduledExecutor] = [:]
        for profile in profiles {
            let connection = profile.connection
            map[profile.engine] = { ChatScheduledExecutor(model: $0, agent: connection, job: $1, run: $2, project: $3) }
        }
        return map
    }()
    /// Legacy print runner (the installed CLI's `~/.claude` profile); not used for new runs. Claude print runs get the same per-run Switchboard browser as Codex chats when it is enabled and installed.
    static func claudeRunner(browserEnabled: Bool, job: ManagedJob, resources: URL? = Bundle.main.resourceURL,
                             root: URL = BrowserEnvironmentStore.directory, executable: URL? = nil) -> ClaudeJobRunner {
        guard browserEnabled, let resources, FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.json").path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("BrowserRuntime/server.py").path) else {
            return ClaudeJobRunner(executable: executable,
                                   browserBlocker: job.browserSessionImport == nil ? nil : ScheduledBrowserImport.unavailable.message)
        }
        return ClaudeJobRunner(executable: executable, browser: .init(resources: resources, root: root, policy: job.browserSessionImport))
    }
}

extension DeskModel {
    /// The app's model with the registered agents; tests replace the Codex and Claude integrations and homes.
    convenience init(connection: any AgentIntegration = AgentIntegrationFactory.codex(),
                     claudeIntegration: any AgentIntegration = AgentIntegrationFactory.claude(),
                     store: AppStore = AppStore(file: Locations.root.appendingPathComponent("metadata.sqlite")),
                     capabilityLedger: CapabilityLedger = CapabilityLedger(file: Locations.root.appendingPathComponent("capability-ledger.sqlite")),
                     pluginDirectory: URL = PluginCatalog.defaultDirectory,
                     summaryResources: URL? = Bundle.main.resourceURL?.appendingPathComponent("Skills"),
                     summaryExecutable: URL? = nil, summaryHome: URL = Locations.codexHome, claudeHome: URL = Locations.claudeHome,
                     jobStore: JobStore = JobStore(file: Locations.root.appendingPathComponent("scheduled-jobs.json"))) {
        self.init(agents: AgentIntegrationFactory.registrations(codex: connection, claude: claudeIntegration, summaryExecutable: summaryExecutable,
                                                                summaryHome: summaryHome, claudeHome: claudeHome),
                  store: store, capabilityLedger: capabilityLedger, pluginDirectory: pluginDirectory,
                  summaryResources: summaryResources, summaryHome: summaryHome, jobStore: jobStore)
    }
}
