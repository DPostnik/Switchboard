import Foundation
import Darwin
import ContextCore
import AgentContract

/// Pinned print-mode adapter. Existing Claude authentication and permission rules are used in place.
public actor ClaudeJobRunner: AgentScheduledExecutor {
    private let context = AgentContext(connection: .init(agent: .claudeCode, id: UUID()), accountRevision: UUID())
    private var consumed = false
    private var dispatched = false
    private let executableOverride: URL?
    public static let version = ClaudeRuntime.pinnedVersion
    private var process: Process?
    private var stopped = false
    private let browser: Browser?
    /// Switchboard browser for one print run: a fresh per-run profile served over stdio MCP.
    public struct Browser: Sendable {
        public let resources: URL
        public let root: URL
        public let policy: ChromeSessionImportPolicy?
        public init(resources: URL, root: URL = BrowserEnvironmentStore.directory, policy: ChromeSessionImportPolicy? = nil) {
            self.resources = resources; self.root = root; self.policy = policy
        }
    }
    private let browserBlocker: String?
    /// `browserBlocker` finishes the run as blocked before dispatch (required browser unavailable).
    public init(executable: URL? = nil, browser: Browser? = nil, browserBlocker: String? = nil) {
        executableOverride = executable; self.browser = browser; self.browserBlocker = browserBlocker
    }

    public func descriptor() -> AgentResult<AgentDescriptor> {
        .success(AgentDescriptor(context: context, identityMode: .externalCLI,
            capabilities: [.scheduledExecution, .interruption], permissions: .externalPolicyOnly,
            routes: [.externalConfiguration]))
    }

    public func execute(_ request: AgentExecutionRequest,
                        willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentScheduledResult> {
        guard !consumed else { return .rejected(.unknownRequest) }
        guard case .success(let descriptor) = descriptor() else { return .unavailable }
        if let rejection = descriptor.validate(request) { return .rejected(rejection) }
        guard request.kind == .scheduled, ClaudeEffort.isDispatchable(request.model.effort) else { return .rejected(.invalidInput) }
        consumed = true
        if let browserBlocker { return .success(.finished(.blocked, output: browserBlocker)) }
        do {
            let browserPrompt = browser?.policy.map { request.prompt + "\n\n" + ScheduledBrowserImport.instructions($0, tool: ScheduledBrowserImport.claudeImportTool) } ?? request.prompt
            let prompt = browserPrompt + "\n\n" + AttentionMarkers.instructions()
            let (status, output) = try await run(prompt: prompt, model: request.model.model,
                effort: request.model.effort, cwd: URL(fileURLWithPath: request.projectPath),
                executable: executableOverride, runID: request.id, willStart: willStart)
            return .success(.finished(status == .completed ? .completed : status == .blocked ? .blocked : .failed, output: output))
        } catch {
            if error is CancellationError {
                return .success(.finished(dispatched ? .uncertain : .cancelled, output: ""))
            }
            return .failed(.init(delivery: dispatched ? .uncertain : .notSent, diagnostic: error.localizedDescription))
        }
    }
    public static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/claude" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClientFailure(L10n.text("Установи Claude Code CLI и выполни вход через claude auth login.", "Install Claude Code CLI and sign in with claude auth login."))
        }
        return URL(fileURLWithPath: path)
    }
    public static func arguments(model: String, effort: String?) -> [String] {
        ["--print", "--output-format", "json", "--permission-mode", "dontAsk", "--permission-prompts", "none", "--no-session-persistence"]
            + ["--append-system-prompt", AgentAutonomy.instructions()]
            + (model.isEmpty ? [] : ["--model", model])
            // Only a documented level is forwarded; an unset value leaves the CLI default in place.
            + (ClaudeEffort.accepted(effort).map { ["--effort", $0.rawValue] } ?? [])
    }
    /// Argv after the base print flags. Variadic CLI options are each followed by another flag or end of argv.
    public static func browserArguments(_ server: [String]) throws -> [String] {
        let config: JSONValue = .object(["mcpServers": .object(["switchboard_browser": .object([
            "type": .string("stdio"), "command": .string("/usr/bin/python3"), "args": .array(server.map(JSONValue.string))
        ])])])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return ["--mcp-config", String(decoding: try encoder.encode(config), as: UTF8.self),
                "--allowedTools", "mcp__switchboard_browser"]
    }
    private struct Lease { let session: AgentSessionReference; let grant: BrowserProfileGrant; let browser: Browser }
    /// Reserve, acknowledge and (optionally) authorize a fresh profile before dispatch. Nothing launches Chrome here.
    private func reserveBrowser(runID: UUID, project: String) throws -> Lease? {
        guard let browser else { return nil }
        let session = AgentSessionReference(connection: .appClaude, nativeID: "scheduled-" + runID.uuidString.lowercased())
        let store = BrowserProfileStore(root: browser.root)
        let grant = try store.prepareNew(project: project, connection: .appClaude)
        try store.acknowledge(grant, session: session)
        let lease = Lease(session: session, grant: grant, browser: browser)
        do {
            if let policy = browser.policy {
                try ScheduledBrowserImport.install(policy, session: session, browserEnabled: true, root: browser.root)
            }
        } catch { _ = releaseBrowser(lease); throw error }
        return lease
    }
    /// One close request, then release only after confirmed exit. Unconfirmed close keeps ownership; never retried.
    private func releaseBrowser(_ lease: Lease) -> String? {
        let store = BrowserProfileStore(root: lease.browser.root)
        let runtime = lease.browser.resources.appendingPathComponent("BrowserRuntime")
        do {
            let result = try BrowserProfileControl.status(environment: store.environment(lease.grant.environment), runtime: runtime,
                                                          grant: lease.grant, close: true)
            guard result.running == false else { throw BrowserProfileError.closeFirst }
            try store.release(session: lease.session) { try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime) }
            return nil
        } catch {
            return L10n.text("Браузер задания не освобождён автоматически, повтора нет: ", "The task browser was not released automatically and was not retried: ")
                + error.localizedDescription
        }
    }
    public func stop() {
        stopped = true
        if let process, process.isRunning { process.terminate() }
    }
    private func capture(executable: URL, arguments: [String], cwd: URL, prompt: String, timeout: TimeInterval, execution: Bool = false,
                         extraEnvironment: [String: String] = [:]) async throws -> (Int32, Data) {
        guard !stopped else { throw CancellationError() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("contextdesk-job-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output"), errors = folder.appendingPathComponent("errors")
        try Data(prompt.utf8).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: input), stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let child = Process(); child.executableURL = executable; child.arguments = arguments; child.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        // Running Switchboard from an agent must not mark this independent print session as nested.
        environment.removeValue(forKey: "CLAUDECODE")
        environment["PATH"] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        environment.merge(extraEnvironment) { _, new in new }
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        try child.run(); process = child
        if execution { dispatched = true }
        let deadline = Date().addingTimeInterval(timeout)
        var limited = false
        while child.isRunning {
            let bytes = [output, errors].reduce(0) { total, url in
                total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
            }
            if stopped || Task.isCancelled || Date() > deadline || bytes > 8 * 1024 * 1024 {
                limited = !stopped && !Task.isCancelled; child.terminate()
                try? await Task.sleep(for: .milliseconds(300))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process = nil
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        guard !limited else { throw ClientFailure(L10n.text("Запуск остановлен по лимиту времени или размера ответа; результат не подтверждён.", "The run exceeded the time or output limit; its outcome is unconfirmed.")) }
        let finalBytes = try [output, errors].reduce(0) { total, url in
            total + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        guard finalBytes <= 8 * 1024 * 1024 else {
            throw ClientFailure(L10n.text("Ответ Claude Code превысил допустимый размер; результат не подтверждён.", "Claude Code output exceeded the size limit; its outcome is unconfirmed."))
        }
        let data = try Data(contentsOf: output)
        if child.terminationStatus != 0 && data.isEmpty {
            let detail = String(decoding: try Data(contentsOf: errors).prefix(16_000), as: UTF8.self)
            throw ClientFailure(L10n.text("Claude Code завершился с ошибкой. ", "Claude Code failed. ") + detail)
        }
        return (child.terminationStatus, data)
    }
    public func run(prompt: String, model: String, effort: String? = nil, cwd: URL, executable: URL? = nil, runID: UUID = UUID(),
                    willStart: @escaping @Sendable () async throws -> Void = {}) async throws -> (JobRunStatus, String) {
        let executable = try executable ?? Self.executable()
        let (_, versionData) = try await capture(executable: executable, arguments: ["--version"], cwd: cwd, prompt: "", timeout: 15)
        guard String(decoding: versionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == Self.version + " (Claude Code)" else {
            throw ClientFailure(L10n.text("Для заданий требуется проверенная версия Claude Code \(Self.version).", "Scheduled tasks require the verified Claude Code version \(Self.version)."))
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        var lease = try reserveBrowser(runID: runID, project: cwd.path)
        // Cancellation, timeout and failures still close and release the per-run profile.
        defer { if let pending = lease { _ = releaseBrowser(pending) } }
        try await willStart()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let arguments = try Self.arguments(model: model, effort: effort) + (lease.map {
            try Self.browserArguments(BrowserEnvironmentStore.serverArguments(resources: $0.browser.resources, root: $0.browser.root,
                                                                              environment: $0.grant.environment, grant: $0.grant,
                                                                              // Legacy print runs keep their old rights; imports only for the job's own site.
                                                                              policy: .init(allowEval: true, allowUpload: true, importScope: .listed)))
        } ?? [])
        // Same startup/tool limits as the Codex MCP entry (30 s / 90 s).
        let mcpEnvironment = lease == nil ? [:] : ["MCP_TIMEOUT": "30000", "MCP_TOOL_TIMEOUT": "90000"]
        let (code, bytes) = try await capture(executable: executable, arguments: arguments, cwd: cwd, prompt: prompt, timeout: 3600,
                                              execution: true, extraEnvironment: mcpEnvironment)
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard value["type"].string == "result", value["is_error"].bool != nil, var text = value["result"].string ?? value["errors"].array.first?.string else {
            throw ClientFailure(L10n.text("Claude Code не вернул распознаваемый результат.", "Claude Code returned no recognized result."))
        }
        if let pending = lease {
            lease = nil
            if let note = releaseBrowser(pending) { text += "\n\n" + note }
        }
        if !value["permission_denials"].array.isEmpty { return (.blocked, text) }
        return (code == 0 && value["is_error"].bool != true ? .completed : .failed, text)
    }
}
