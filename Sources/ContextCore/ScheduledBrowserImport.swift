import Foundation

extension ManagedJob {
    public func validateBrowserSessionImport() throws {
        guard let policy = browserSessionImport else { return }
        guard engine == .codex || engine == .claude,
              try ChromeSessionImportPolicy(profile: policy.profile, site: policy.site) == policy else {
            throw ClientFailure(L10n.text("Импорт сессии доступен только для заданий Codex или Claude Code с корректным доменом и профилем Chrome.",
                                          "Session import requires a Codex or Claude Code task with a valid site domain and Chrome profile."))
        }
    }

    /// Keep the saved user prompt/frozen routine intact; derive run instructions from explicit metadata.
    public func browserExecutionPrompt(language: AppLanguage = L10n.language) throws -> String {
        try validateBrowserSessionImport()
        guard let policy = browserSessionImport else { return prompt }
        let tool = engine == .claude ? ScheduledBrowserImport.claudeImportTool : "browser_import_session"
        return prompt + "\n\n" + ScheduledBrowserImport.instructions(policy, tool: tool, language: language)
    }
}

public enum ScheduledBrowserImport {
    /// Claude Code exposes MCP tools as `mcp__<server>__<tool>`; Codex uses the plain tool name.
    public static let claudeImportTool = "mcp__switchboard_browser__browser_import_session"

    public static func instructions(_ policy: ChromeSessionImportPolicy, tool: String = "browser_import_session",
                                    language: AppLanguage = L10n.language) -> String {
        let ru = policy.coversAnySite ? "любого нужного сайта" : "сайта \(policy.site)"
        let en = policy.coversAnySite ? "any site the task needs" : policy.site
        return L10n.text(
            "Во всех запусках разрешён импорт cookies \(ru) из выбранного профиля Chrome в браузер задания. Прочитай нужную страницу. Только если не выполнен вход, вызови \(tool) один раз с session своей вкладки и текущим expectedURL. При подтверждённом импорте отдельно обнови страницу один раз и проверь защищённое содержимое. Не импортируй из-за сетевой ошибки, CAPTCHA или блокировки сайта. Не повторяй действия с неизвестным исходом и не закрывай обычный Chrome. Если импорт недоступен или вход не восстановлен, укажи точную причину и продолжай независимую работу. Для внешних действий требуется отдельное разрешение.",
            "Every run may import cookies for \(en) from the selected Chrome profile into the task browser. Read the required page. Only if sign-in is missing, call \(tool) once with your tab's session and current expectedURL. After a confirmed import, reload once separately and check protected content. Skip import for network errors, CAPTCHA, or site blocks. Never repeat uncertain actions or close regular Chrome. If import or sign-in fails, report the exact reason and continue independent work. External actions require separate authorization.", language: language)
    }

    public static var unavailable: ClientFailure {
        ClientFailure(L10n.text("Для восстановления входа в задании включи браузер Switchboard и переподключи Codex или Claude Code.",
                                "Enable the Switchboard browser and reconnect Codex or Claude Code to restore sign-in for this task."))
    }

    /// Runs after the fresh chat is durably attached, before its first model turn.
    /// Does not access source cookies or Keychain and never changes another profile's permission.
    public static func install(_ policy: ChromeSessionImportPolicy, session: AgentSessionReference, browserEnabled: Bool,
                               root: URL = BrowserEnvironmentStore.directory) throws {
        guard browserEnabled, session.connection == .originalCodex || session.connection == .appClaude else { throw unavailable }
        let checked = try ChromeSessionImportPolicy(profile: policy.profile, site: policy.site)
        let store = BrowserProfileStore(root: root)
        guard let profile = try store.current(session: session) else { throw ChromeCookieError.missingEnvironment }
        let environment = store.environment(profile.id)
        let grant = try store.ownedGrant(session: session, allowHuman: false)
        try ChromeSessionImportPolicy.save(checked, environment: environment, grant: grant, browserRoot: root)
    }
}

/// Result of the app-side sign-in transfer that runs before the first model turn of a scheduled run.
public enum ScheduledBrowserPreflight: Equatable, Sendable {
    /// Site cookies were written to and read back from the run's fresh profile; website sign-in is not yet verified.
    case imported(verified: Int)
    /// Definite failure; nothing that could need a retry was left behind.
    case blocked(ChromeCookieError)
    /// The write may have happened. Never retried in this run.
    case uncertain
    /// The agent keeps the import step: a wildcard policy (the site is known only once the agent opens a page),
    /// or no browser slot freed up before dispatch (nothing was started or written).
    case skipped
}

extension ScheduledBrowserImport {
    /// Transfers only the policy site's cookies into the run's own fresh profile, once, before dispatch.
    /// A fresh per-run profile has no cookies, so missing sign-in is certain and no agent turn is spent observing it.
    public static func preflight(_ policy: ChromeSessionImportPolicy, session: AgentSessionReference, runtime: URL, maxBrowsers: Int,
                                 root: URL = BrowserEnvironmentStore.directory, sourceIsRunning: @escaping @Sendable () -> Bool,
                                 read: (@Sendable (String, String) throws -> ChromeCookieRead)? = nil,
                                 transfer: (@Sendable (ChromeCookieRead, URL, BrowserProfileGrant) async throws -> ChromeCookieImportResult)? = nil,
                                 slotWaits: Int = 18,
                                 wait: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(10)) }) async -> ScheduledBrowserPreflight {
        guard !policy.coversAnySite else { return .skipped }
        do {
            let store = BrowserProfileStore(root: root)
            guard let profile = try store.current(session: session) else { return .blocked(.missingEnvironment) }
            let environment = store.environment(profile.id)
            let grant = try store.ownedGrant(session: session, allowHuman: false)
            let cookies = try (read ?? { try ChromeCookieSource.read(profile: $0, site: $1, sourceIsRunning: sourceIsRunning) })(policy.profile, policy.site)
            guard !cookies.cookies.isEmpty else { return .blocked(.empty) }
            let send = transfer ?? { read, environment, grant in
                try await ChromeCookieImporter.transfer(read, environment: environment, runtime: runtime, maxBrowsers: maxBrowsers,
                                                        grant: grant, browserRoot: root)
            }
            // The browser limit refuses before launch, so waiting for a free slot never repeats a write.
            // If none frees up, the agent imports later through its own browser, which also needs that slot.
            var waits = 0
            while true {
                do {
                    let result = try await send(cookies, environment, grant)
                    return result.verified > 0 ? .imported(verified: result.verified) : .blocked(.empty)
                } catch ChromeCookieError.browserLimit {
                    guard waits < slotWaits else { return .skipped }
                    waits += 1
                    try await wait()
                }
            }
        } catch let error as ChromeCookieError {
            return error == .uncertain ? .uncertain : .blocked(error)
        } catch {
            return .blocked(.connection)
        }
    }

    /// Use the outcome when preflight ran, or keep the normal import instructions when it was skipped.
    public static func instructions(_ policy: ChromeSessionImportPolicy, preflight: ScheduledBrowserPreflight, tool: String = "browser_import_session",
                                    language: AppLanguage = L10n.language) -> String {
        let site = policy.site
        let tail = L10n.text(
            " Не вызывай \(tool) в этом запуске, не повторяй действия с неизвестным исходом и не закрывай обычный Chrome. Если нужный сайт недоступен, укажи точную причину и продолжай независимую работу. Для внешних действий требуется отдельное разрешение.",
            " Do not call \(tool) in this run, repeat uncertain actions, or close regular Chrome. If a required site is unavailable, report the exact reason and continue independent work. External actions require separate authorization.", language: language)
        switch preflight {
        case .skipped:
            return instructions(policy, tool: tool, language: language)
        case .imported:
            return L10n.text(
                "Switchboard перенёс cookies сайта \(site) в браузер задания. Только если задаче нужен этот сайт, открой его и проверь защищённое содержимое. Если сайт просит войти, попроси пользователя войти в \(site) в обычном Chrome.",
                "Switchboard imported \(site) cookies into the task browser. Only if the task needs this site, open it and check protected content. If prompted to sign in, ask the user to sign in to \(site) in regular Chrome.", language: language) + tail
        case .uncertain:
            return L10n.text(
                "Результат импорта cookies сайта \(site) не подтверждён. Только если задаче нужен этот сайт, проверь вход обычным чтением страницы.",
                "Cookie import for \(site) is unconfirmed. Only if the task needs this site, check sign-in by reading the page.", language: language) + tail
        case .blocked(let error):
            return L10n.text(
                "Импорт cookies сайта \(site) не выполнен: \(error.message(language: language)) Если нужен вход, этот сайт недоступен в текущем запуске.",
                "Cookie import for \(site) failed: \(error.message(language: language)) If sign-in is required, this site is unavailable for this run.", language: language) + tail
        }
    }

    /// Swaps the standard import paragraph that `browserExecutionPrompt` appended for the preflight outcome.
    public static func applying(_ preflight: ScheduledBrowserPreflight, policy: ChromeSessionImportPolicy, to prompt: String,
                                tool: String, language: AppLanguage = L10n.language) -> String {
        let standard = instructions(policy, tool: tool, language: language)
        let replacement = instructions(policy, preflight: preflight, tool: tool, language: language)
        guard standard != replacement else { return prompt }
        return prompt.contains(standard) ? prompt.replacingOccurrences(of: standard, with: replacement) : prompt + "\n\n" + replacement
    }
}
