import Foundation
import CryptoKit
import ContextCore
import AgentContract

// Claude Code under the external boundary (PERMISSIONS.md, channel 1; plan phase B2). The nono helper holds the CLI's
// whole process tree. The Keychain is closed inside, so the app reads its own profile's sign-in outside and hands only
// the bare access token to the CLI (credential option d, B1 probe): the token is the first line on the CLI's stdin, a
// zsh launcher inside the boundary moves it to fd 3 through a process-substitution pipe, and the CLI reads it from
// `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`. It is never in arguments, the environment, files, logs or the ledger.

/// The app profile's access token with its expiry. `value` is a secret: never log, store or print it.
struct ClaudeAccessToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date
}

enum ClaudeTokenFailure: Error, Equatable, Sendable {
    /// No sign-in item for this profile, or it is not a Claude OAuth document.
    case missing
    /// The token expires within `ClaudeBoundaryToken.minimumLifetime`; the CLI cannot refresh it under the boundary.
    case expiring
}

/// Where the app reads the profile's token. Tests inject a fake; the app reads its Keychain item outside the boundary.
protocol ClaudeTokenSource: Sendable {
    func token(home: URL) -> Result<ClaudeAccessToken, ClaudeTokenFailure>
}

enum ClaudeBoundaryToken {
    /// A launch needs this much token lifetime left, and a live worker is relaunched at a turn boundary once less is left.
    /// The CLI cannot refresh a token handed over on fd 3 (B1: no `oauth_token_refresh` after a 401).
    static let minimumLifetime: TimeInterval = 30 * 60
    /// The OAuth document's `claudeAiOauth.accessToken` and `expiresAt` (milliseconds since 1970).
    static func parse(_ data: Data, now: Date = Date()) -> Result<ClaudeAccessToken, ClaudeTokenFailure> {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data),
              let value = document["claudeAiOauth"]["accessToken"].string, !value.isEmpty, !value.contains(where: \.isNewline),
              case .number(let milliseconds) = document["claudeAiOauth"]["expiresAt"] else { return .failure(.missing) }
        let expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        guard expiresAt.timeIntervalSince(now) > minimumLifetime else { return .failure(.expiring) }
        return .success(.init(value: value, expiresAt: expiresAt))
    }
}

/// Claude Code keeps the profile's sign-in in the login Keychain item `Claude Code-credentials-<sha256(config dir)[:8]>`.
/// The item is read through `/usr/bin/security` (the tool the CLI writes it with, so the read does not prompt; B1 probe),
/// outside the boundary; the output stays in memory.
struct ClaudeKeychainTokenSource: ClaudeTokenSource {
    static func item(home: URL) -> String {
        "Claude Code-credentials-" + SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
    }
    func token(home: URL) -> Result<ClaudeAccessToken, ClaudeTokenFailure> {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", Self.item(home: home)]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failure(.missing) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .failure(.missing) }
        return ClaudeBoundaryToken.parse(data)
    }
}

/// What a chat launch needs to run under the boundary; nil in `ClaudeIntegration` keeps every chat on the CLI sandbox.
public struct ClaudeBoundaryRuntime: Sendable {
    let helper: @Sendable () -> Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>
    let tokens: any ClaudeTokenSource
    let home: URL
    /// The binary nono runs: the real CLI in the granted versions folder, not the `~/.local/bin` link to it.
    let binary: @Sendable (URL) -> URL
    init(helper: @escaping @Sendable () -> Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>, tokens: any ClaudeTokenSource,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, binary: @escaping @Sendable (URL) -> URL = { $0.resolvingSymlinksInPath() }) {
        self.helper = helper; self.tokens = tokens; self.home = home; self.binary = binary
    }
    /// The bundled, verified nono helper and the profile's Keychain item.
    public static var live: Self { .init(helper: { ExternalSandboxHelper.bundled() }, tokens: ClaudeKeychainTokenSource()) }
}

/// Why a chat that could run under the boundary runs on the CLI sandbox with prompts instead.
enum ClaudeBoundaryFallback: Error, Equatable, Sendable {
    case planner(ExternalSandboxPlanner.Ineligible)
    case token(ClaudeTokenFailure)
    /// The CLI's own Claude in Chrome bridge is not verified under nono.
    case userChrome
    /// Role-defined native paths are expected and logged, not shown: an unrestricted role, a role without network.
    var isExpected: Bool {
        if case .planner(let reason) = self { return reason == .unrestricted || reason == .networkOff }
        return false
    }
    func description(language: AppLanguage = L10n.language) -> String {
        switch self {
        case .planner(let reason): reason.description(language: language)
        case .token(.missing): L10n.text("вход в Claude в профиле приложения не найден", "the app profile's Claude sign-in was not found", language: language)
        case .token(.expiring): L10n.text("срок входа в Claude скоро истекает; CLI обновит его в этом запуске",
                                          "the Claude sign-in expires soon; the CLI renews it in this launch", language: language)
        case .userChrome: L10n.text("Chrome пользователя пока не проверен внутри границы", "the user's Chrome is not yet verified inside the boundary", language: language)
        }
    }
    /// The chat notice: once per change of reason, RU/EN.
    func notice(language: AppLanguage = L10n.language) -> String {
        L10n.text("Внешняя граница недоступна: \(description(language: language)). Чат работает с песочницей CLI и запросами подтверждения.",
                  "External boundary unavailable: \(description(language: language)). This chat runs with the CLI sandbox and approval prompts.",
                  language: language)
    }
}

/// One CLI launch under the boundary: the plan, the verified helper and the token launcher.
struct ClaudeBoundaryLaunch: Sendable {
    let launch: ExternalSandboxLaunch
    var plan: ExternalSandboxPlan { launch.plan }
    /// Inside the boundary: read the token line from stdin, open it as fd 3 through a pipe, drop the variable, exec the CLI.
    /// nono closes every inherited descriptor above 2, so the descriptor has to be made inside (B1 probe, option d).
    static let tokenLauncher = ["-f", "-c", "IFS= read -r t; exec 3< <(print -r -- \"$t\"); unset t; exec \"$@\"", "zsh"]
    static let tokenEnvironment = ["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR": "3", "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH": "1"]
    /// Credentials the CLI must not see from the app's own environment under the boundary.
    static let strippedEnvironment = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    /// launcher (setsid) -> nono run ... -- /bin/zsh <token launcher> <claude> <arguments>
    func command(claude: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        launch.command(provider: URL(fileURLWithPath: "/bin/zsh"), arguments: Self.tokenLauncher + [claude.path] + arguments)
    }
    func environment(base: [String: String]) -> [String: String] {
        var result = base
        for key in Self.strippedEnvironment { result.removeValue(forKey: key) }
        result.merge(plan.environment) { _, new in new }
        result.merge(Self.tokenEnvironment) { _, new in new }
        return result
    }
    /// The launch arguments under the boundary: `--settings` moves into the worker's `settings.json` (read-only grant), and
    /// app-owned MCP servers (`switchboard_*`, the chat directory) run outside behind the relay; project servers stay inside.
    /// Writes `settings.json` and `servers.json`; call after `plan.materialize()`.
    func rewrite(_ arguments: [String], appServers: Set<String>) throws -> [String] {
        var result = arguments
        if let index = result.firstIndex(of: "--settings"), index + 1 < result.count {
            try Data(result[index + 1].utf8).write(to: plan.settingsFile, options: .atomic)
            result[index + 1] = plan.settingsFile.path
        }
        var servers: [String: ExternalSandboxServer] = [:]
        if let index = result.firstIndex(of: "--mcp-config"), index + 1 < result.count,
           let config = try? JSONDecoder().decode(JSONValue.self, from: Data(result[index + 1].utf8)) {
            var entries = config["mcpServers"].object
            for (name, entry) in entries where appServers.contains(name) {
                guard let command = entry["command"].string, command.hasPrefix("/") else { continue }
                var environment: [String: String] = [:]
                for (key, value) in entry["env"].object { if let text = value.string { environment[key] = text } }
                servers[name] = ExternalSandboxServer(command: command, arguments: entry["args"].array.compactMap(\.string), environment: environment)
                let relay = plan.relayCommand(for: name)
                entries[name] = .object(["type": .string("stdio"), "command": .string(relay.command), "args": .array(relay.arguments.map(JSONValue.string))])
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            result[index + 1] = String(decoding: try encoder.encode(JSONValue.object(["mcpServers": .object(entries)])), as: UTF8.self)
        }
        try plan.writeServers(servers)
        return result
    }
}

extension ClaudeIntegration {
    /// The instructions for a chat under the boundary: no flag, no workaround, the standard route after a refusal.
    static func boundaryCommandInstructions(language: AppLanguage = L10n.language) -> String {
        L10n.text(
            """
            Внешняя граница в этом чате:
            - Bash, файлы и подагенты работают внутри границы проекта (папки проекта и его настроек). Внутри ничего не подтверждается; флаг `dangerouslyDisableSandbox` ничего не меняет.
            - Путь или действие вне границы завершаются ошибкой (часто `Operation not permitted`). Не ищи обход: используй инструмент приложения, если он есть (например `project_diagnostics` для нагрузки и процессов), иначе запиши одно предложение настроек с точной папкой, набором или командой и причиной, продолжи независимую часть задачи и сообщи о запросе.
            - В проекте работающего приложения Switchboard журнал приложения читай инструментом `app_log` (не `log show`), а перезапуск после успешной сборки и тестов запрашивай один раз инструментом `request_app_restart` (не `scripts/request-app-restart.sh`); после него заверши ход и жди.
            """,
            """
            External boundary in this chat:
            - Bash, files and sub-agents run inside the project's boundary (the project's folders and settings). Nothing inside is asked; the `dangerouslyDisableSandbox` flag changes nothing.
            - A path or action outside the boundary fails (often `Operation not permitted`). Do not look for a workaround: use the app's tool when one exists (for example `project_diagnostics` for load and processes), otherwise write one settings proposal with the exact folder, access set or command and the reason, continue the independent part of the task and report the request.
            - In the project of the running Switchboard app, read the app's log with the `app_log` tool (not `log show`) and request a restart after a successful build and tests once with the `request_app_restart` tool (not `scripts/request-app-restart.sh`); then end the turn and wait.
            """, language: language)
    }
    /// The refusal of a file tool outside the boundary, naming the standard route.
    static func outsideBoundaryRefusal(_ path: String, language: AppLanguage = L10n.language) -> String {
        L10n.text("Путь вне границы проекта: \(path). Не ищи обход: если он нужен задаче, запиши одно предложение настроек (addFolders) с точной папкой и причиной.",
                  "Outside the project's boundary: \(path). Do not look for a workaround: if the task needs it, write one settings proposal (addFolders) with the exact folder and the reason.",
                  language: language)
    }
    /// The refusal of a role deny-list command (`denyList`). It stays denied; the text names the app's tool where one
    /// covers the usual purpose, and rules out a workaround.
    static func roleDenyRefusal(_ command: String, language: AppLanguage = L10n.language) -> String {
        let hint: (ru: String, en: String)
        switch command {
        case "osascript": hint = (" Для браузера используй инструменты браузера Switchboard.", " For a browser, use Switchboard's browser tools.")
        case "launchctl": hint = (" Перезапуск Switchboard запрашивай инструментом `request_app_restart`, если он подключён.",
                                  " To restart Switchboard, use the `request_app_restart` tool when it is attached.")
        default: hint = ("", "")
        }
        return L10n.text("Команда запрещена ролью: \(command). Обход не допускается: не ищи другую команду, интерпретатор, путь или флаг с тем же действием.\(hint.ru) Если без неё задача не решается, сообщи об этом пользователю.",
                         "The role forbids this command: \(command). No workaround is allowed: do not look for another command, interpreter, path or flag with the same effect.\(hint.en) If the task cannot be done without it, report this to the user.",
                         language: language)
    }
    /// The refusal in a run that cannot ask (`unattended`, and an unattended ask-list hit): no wait, the standard route.
    static func unattendedRefusal(outsideSandbox: Bool = false, language: AppLanguage = L10n.language) -> String {
        let inbox = "`$" + SettingsProposalInbox.environmentKey + "`"
        return L10n.text((outsideSandbox ? "Команда вне песочницы; запуск без присмотра её не выполняет." : "Действие вне роли; запуск без присмотра не ждёт подтверждения.")
                         + " Не ищи обход. Если доступ нужен задаче, запиши одно предложение настроек с точным доступом и причиной (если задан \(inbox)) и назови блокер в итоговом сообщении.",
                         (outsideSandbox ? "A command outside the sandbox; an unattended run does not run it." : "Outside the role; an unattended run does not wait for approval.")
                         + " Do not look for a workaround. If the task needs this access, write one settings proposal with the exact access and the reason (when \(inbox) is set) and name the blocker in the final message.",
                         language: language)
    }
    /// The refusal of a shell command in a role without one (`shellOff`). Only the user changes a chat's role.
    static func shellOffRefusal(language: AppLanguage = L10n.language) -> String {
        L10n.text("Роль этого чата не разрешает команды. Не выполняй команду другим способом; работай файловыми инструментами. Если задаче нужна командная строка, сообщи об этом пользователю: роль чата меняет только он.",
                  "This chat's role does not allow shell commands. Do not run the command another way; use the file tools. If the task needs a shell, report it to the user: only the user changes the chat's role.",
                  language: language)
    }
}
