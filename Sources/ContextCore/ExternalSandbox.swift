import Foundation
import CryptoKit
import Security
import os
import AgentContract

// External execution boundary for agent processes: the pinned nono helper (`NonoRuntime/runtime.lock.json`)
// wraps a provider process so the OS, not the provider's prompts, enforces the project's roots. The policy
// is compiled from the role profile and the project settings only; the agent's cwd adds nothing, and the
// policy file lives outside every granted root. App-owned MCP servers stay outside the boundary behind
// `SandboxRuntime/mcp_host.py`; the sandboxed process reaches them through `mcp_relay.py` over one socket.

/// The helper shipped in `Contents/Helpers/Nono`, verified against the lock before every use.
public struct ExternalSandboxHelper: Hashable, Sendable {
    public let executable: URL
    public let version: String

    public struct Lock: Decodable, Sendable {
        public let version: String
        public let platform: String
        public let binary_sha256: String
        public let identifier: String
        public let team_identifier: String
    }
    public enum Failure: LocalizedError, Equatable, Sendable {
        case missing(String)
        case lock(String)
        case checksum
        case architecture
        case signature(String)
        public var errorDescription: String? {
            switch self {
            case .missing(let path): L10n.text("Helper nono отсутствует: \(path)", "The nono helper is missing: \(path)")
            case .lock(let detail): L10n.text("Файл закрепления nono не читается: \(detail)", "The nono lock file is unreadable: \(detail)")
            case .checksum: L10n.text("Контрольная сумма helper nono не совпадает с закреплённой", "The nono helper checksum does not match the pinned value")
            case .architecture: L10n.text("Helper nono собран не для arm64", "The nono helper is not an arm64 binary")
            case .signature(let detail): L10n.text("Подпись helper nono не прошла проверку: \(detail)", "The nono helper signature failed verification: \(detail)")
            }
        }
    }

    /// `Contents/Helpers/nono` with its lock in `Contents/Resources/NonoRuntime` (non-code files cannot sit in Helpers).
    /// Results are cached per executable for the process lifetime.
    public static func bundled(_ bundle: Bundle = .main) -> Result<Self, Failure> {
        verifiedCached(executable: bundle.bundleURL.appendingPathComponent("Contents/Helpers/nono"),
                       lock: bundle.bundleURL.appendingPathComponent("Contents/Resources/NonoRuntime/runtime.lock.json"))
    }
    private static let cache = OSAllocatedUnfairLock<[String: Result<Self, Failure>]>(initialState: [:])
    public static func verifiedCached(executable: URL, lock: URL) -> Result<Self, Failure> {
        let key = executable.standardizedFileURL.path
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let result: Result<Self, Failure>
        do { result = .success(try verified(executable: executable, lock: lock)) } catch let failure as Failure { result = .failure(failure) } catch { result = .failure(.lock(error.localizedDescription)) }
        cache.withLock { $0[key] = result }
        return result
    }

    /// Checksum, Mach-O architecture and (unless disabled for fixtures) the vendor's code signature.
    public static func verified(executable: URL, lock lockURL: URL, checkSignature: Bool = true) throws -> Self {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.missing(executable.path) }
        let lock: Lock
        do { lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: lockURL)) } catch { throw Failure.lock(error.localizedDescription) }
        let data = try Data(contentsOf: executable)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == lock.binary_sha256.lowercased() else { throw Failure.checksum }
        guard isARM64(data) else { throw Failure.architecture }
        if checkSignature { try verifySignature(executable, lock: lock) }
        return Self(executable: executable, version: lock.version)
    }

    private static func isARM64(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        func word(_ offset: Int, bigEndian: Bool) -> UInt32 {
            let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return bigEndian ? value : value.byteSwapped
        }
        let arm64: UInt32 = 0x0100_000C
        switch word(0, bigEndian: true) {
        case 0xCFFA_EDFE: return word(4, bigEndian: false) == arm64          // MH_MAGIC_64, little endian
        case 0xCAFE_BABE:                                                      // fat: any arm64 slice
            let count = Int(word(4, bigEndian: true))
            guard count > 0, count < 16, data.count >= 8 + count * 20 else { return false }
            return (0..<count).contains { word(8 + $0 * 20, bigEndian: true) == arm64 }
        default: return false
        }
    }

    private static func verifySignature(_ executable: URL, lock: Lock) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.signature("static code") }
        let text = "anchor apple generic and identifier \"\(lock.identifier)\" and certificate leaf[subject.OU] = \"\(lock.team_identifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw Failure.signature("requirement") }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "status \(status)"
            throw Failure.signature(detail)
        }
    }
}

/// Where the app keeps boundary state: nono's own config/state, and one folder per sandboxed worker holding its
/// policy, MCP spec and socket. It is a sibling of the data root (`Switchboard-sandbox`), because projects may grant
/// the data root itself to agents and nono refuses a grant that contains its state. Only a worker's `tmp` and socket
/// are granted.
public enum ExternalSandboxLocations {
    public static var root: URL { Locations.root.deletingLastPathComponent().appendingPathComponent("Switchboard-sandbox", isDirectory: true) }
    public static var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    public static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    public static var workers: URL { root.appendingPathComponent("workers", isDirectory: true) }
    /// AF_UNIX paths are limited to 104 bytes; a long data root falls back to a private folder under /tmp.
    public static func socket(worker: URL, id: String) -> URL {
        let preferred = worker.appendingPathComponent("mcp.sock")
        if preferred.path.utf8.count <= 100 { return preferred }
        return URL(fileURLWithPath: "/tmp/switchboard-\(getuid())", isDirectory: true).appendingPathComponent("\(id).sock")
    }
}

/// One mediated command: runs through nono's broker shim with its own grants (the session union plus the Keychain
/// or network it needs). Commands the role does not list run inside the session sandbox like everything else.
public struct ExternalSandboxCommand: Hashable, Sendable, Encodable {
    public let name: String
    public let executable: String
    public let keychain: Bool
    public let network: Bool
    /// Directories whose executables the command may run by absolute path (git's own helpers).
    public let executableTrees: [String]
    public init(name: String, executable: String, keychain: Bool, network: Bool, executableTrees: [String] = []) {
        self.name = name; self.executable = executable; self.keychain = keychain; self.network = network; self.executableTrees = executableTrees
    }
}

/// The compiled boundary for one worker process. Equal plans mean the same authority: a changed plan replaces the process.
public struct ExternalSandboxPlan: Hashable, Sendable {
    public enum Mode: String, Sendable {
        case allow = "--allow", read = "--read", allowFile = "--allow-file", readFile = "--read-file", unixSocket = "--allow-unix-socket"
    }
    public struct Grant: Hashable, Sendable {
        public let mode: Mode
        public let path: String
        public init(_ mode: Mode, _ path: String) { self.mode = mode; self.path = path }
    }
    public let workerID: String
    public let project: String
    public let grants: [Grant]
    public let commands: [ExternalSandboxCommand]
    public let executableDirectories: [String]
    public let worker: URL
    public let socket: URL
    public let relay: URL
    public let temporary: URL
    public var policyFile: URL { worker.appendingPathComponent("policy.json") }
    /// Provider settings the app writes before launch (Claude `--settings`); granted read-only when the plan asks for it.
    public var settingsFile: URL { worker.appendingPathComponent("settings.json") }
    public var serversFile: URL { worker.appendingPathComponent("servers.json") }
    public var hostLog: URL { worker.appendingPathComponent("mcp-host.log") }
    public var readOnlyProject: Bool { !grants.contains { $0.mode == .allow && $0.path == project } }
    /// What the plan grants, without the per-worker paths (folder, tmp, socket, settings): two plans with equal authority
    /// give a process the same rights, so a live process is kept; a different authority replaces it.
    public var authority: [String] {
        let own = worker.path
        let paths = grants.filter { !$0.path.hasPrefix(own + "/") && $0.path != socket.path }.map { $0.mode.rawValue + " " + $0.path }
        let mediated = commands.map { "command \($0.name) \($0.executable) keychain=\($0.keychain) network=\($0.network) trees=\($0.executableTrees.joined(separator: ","))" }
        return ["project " + project] + paths + mediated + executableDirectories.map { "exec " + $0 }
    }

    /// Environment the wrapped process receives on top of the provider's: a private temp folder inside the grants and
    /// nono's own state away from the user's `~/.config`.
    public var environment: [String: String] {
        // The boundary keeps the Keychain (and so the system trust store) closed to the session; a provider that
        // validates TLS through it gets macOS's own CA bundle file instead of a Keychain grant.
        ["TMPDIR": temporary.path, "XDG_STATE_HOME": ExternalSandboxLocations.state.path, "XDG_CONFIG_HOME": ExternalSandboxLocations.config.path,
         "SWITCHBOARD_EXTERNAL_SANDBOX": "1", "SSL_CERT_FILE": "/etc/ssl/cert.pem"]
    }

    /// `nono run` arguments; the caller appends `--` and the provider command.
    public func arguments(helper: ExternalSandboxHelper) -> [String] {
        var result = [helper.executable.path, "run", "--silent", "--no-audit", "--no-diagnostics", "--no-rollback", "--profile", policyFile.path]
        for grant in grants { result += [grant.mode.rawValue, grant.path] }
        return result
    }

    /// The nono profile document (command policies only; filesystem grants travel as arguments).
    public func policyDocument() -> [String: Any] {
        let reads = grants.filter { $0.mode == .read || $0.mode == .allow }.map(\.path)
        let readFiles = grants.filter { $0.mode == .readFile || $0.mode == .allowFile }.map(\.path)
        let writes = grants.filter { $0.mode == .allow }.map(\.path)
        let writeFiles = grants.filter { $0.mode == .allowFile }.map(\.path)
        var commands: [String: Any] = [:]
        for command in self.commands {
            var sandbox: [String: Any] = ["fs_read": reads, "fs_read_file": readFiles, "fs_write": writes, "fs_write_file": writeFiles,
                                          "network": ["allow_all": command.network],
                                          "environment": ["allow_vars": ["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_*", "TERM", "TMPDIR", "GIT_*", "SSL_CERT_FILE"]]]
            if command.keychain { sandbox["keychain_access"] = "read" }
            if !command.executableTrees.isEmpty {
                // macOS has no exec_paths: helpers a tool runs by absolute path need explicit Seatbelt rules.
                sandbox["unsafe_macos_seatbelt_rules"] = command.executableTrees.flatMap { tree in
                    ["(allow process-exec* (subpath \"\(tree)\"))", "(allow file-read* (subpath \"\(tree)\"))", "(allow file-map-executable (subpath \"\(tree)\"))"]
                }
            }
            var policy: [String: Any] = ["executable": command.executable, "sandbox": sandbox]
            // Swift Build invokes codesign by absolute path for ad-hoc signatures.
            // Direct execution retains the session sandbox (no Keychain); named execution uses the broker.
            if command.name == "codesign" && command.executable == "/usr/bin/codesign" {
                policy["allow_direct_exec_bypass"] = [command.executable]
            }
            commands[command.name] = policy
        }
        var document: [String: Any] = ["meta": ["name": "switchboard-\(workerID)", "version": "1"], "workdir": ["access": "none"]]
        // nono 0.81.0 refuses `command_policies` fields when no command is mediated (`inactive_non_empty`, B1 probe).
        if !commands.isEmpty { document["command_policies"] = ["executable_dirs": executableDirectories, "commands": commands] }
        return document
    }

    /// Writes the worker folder, policy and an empty server spec. The folder is private to the app (0700).
    public func materialize() throws {
        let manager = FileManager.default
        for directory in [ExternalSandboxLocations.state, ExternalSandboxLocations.config, worker, temporary, socket.deletingLastPathComponent()] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let data = try JSONSerialization.data(withJSONObject: policyDocument(), options: [.sortedKeys, .prettyPrinted])
        try data.write(to: policyFile, options: .atomic)
        if !manager.fileExists(atPath: serversFile.path) { try writeServers([:]) }
    }
    /// Replaces the MCP spec the host reads on every connection: `name -> command, args, env`.
    public func writeServers(_ servers: [String: ExternalSandboxServer]) throws {
        var document: [String: Any] = [:]
        // Each server starts in the project folder, as it does when the provider launches it itself: the browser server
        // takes its workspace from its working directory, and the host's own is the app's.
        for (name, server) in servers {
            document[name] = ["command": server.command, "args": server.arguments, "env": server.environment, "cwd": project]
        }
        let data = try JSONSerialization.data(withJSONObject: ["servers": document], options: [.sortedKeys])
        try data.write(to: serversFile, options: .atomic)
    }
    public func removeWorkerFolder() {
        try? FileManager.default.removeItem(at: worker)
        if socket.deletingLastPathComponent() != worker { try? FileManager.default.removeItem(at: socket) }
    }
    /// The MCP server entry the sandboxed provider launches instead of `server`: the relay that reaches the host.
    public func relayCommand(for name: String) -> ExternalSandboxServer {
        ExternalSandboxServer(command: "/usr/bin/python3", arguments: ["-I", relay.path, socket.path, name], environment: [:])
    }
}

/// An app-owned stdio MCP server launched outside the boundary by the host.
public struct ExternalSandboxServer: Hashable, Sendable {
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public init(command: String, arguments: [String], environment: [String: String] = [:]) {
        self.command = command; self.arguments = arguments; self.environment = environment
    }
}

public enum ExternalSandboxPlanner {
    public struct Input: Sendable {
        public var project: String
        public var profile: AgentPermissionProfile
        public var providerHome: URL
        public var providerExecutable: URL
        public var resources: URL?
        public var workflowDirectories: [URL]
        public var workerID: String
        public var home: URL
        /// Provider-specific app folders the session reads (attachments) or writes (the settings proposal inbox).
        public var extraReads: [String] = []
        public var extraWrites: [String] = []
        /// Grant the worker's own `settings.json` read-only (Claude reads its launch settings from that file).
        public var settingsFile = false
        /// Mediate `pgrep`: inside the session it sees only sandboxed processes (B1 probe, check 4).
        public var mediateProcessList = false
        /// Refuse the boundary when a trusted project command cannot run inside it (`trustedCommandOutside`).
        public var commandInventory = false
        public init(project: String, profile: AgentPermissionProfile, providerHome: URL, providerExecutable: URL, resources: URL?,
                    workflowDirectories: [URL] = [], workerID: String = String(UUID().uuidString.lowercased().prefix(8)),
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            self.project = project; self.profile = profile; self.providerHome = providerHome; self.providerExecutable = providerExecutable
            self.resources = resources; self.workflowDirectories = workflowDirectories; self.workerID = workerID; self.home = home
        }
    }
    /// Why a worker runs under the provider's native sandbox instead. Every case keeps the native prompts; none runs unrestricted.
    public enum Ineligible: Error, Equatable, Sendable {
        case helper(ExternalSandboxHelper.Failure)
        case unrestricted
        case networkOff
        case commandSandboxOff
        case resourcesMissing
        /// A trusted project command that is neither mediated nor able to run inside the boundary.
        case trustedCommandOutside(String)
        public func description(language: AppLanguage = L10n.language) -> String {
            switch self {
            case .helper(let failure): failure.errorDescription ?? ""
            case .unrestricted: L10n.text("роль без ограничений", "unrestricted role", language: language)
            case .networkOff: L10n.text("роль без сети пока не поддерживается внешней границей", "a role without network is not yet supported by the external boundary", language: language)
            case .commandSandboxOff: L10n.text("песочница команд выключена в настройках проекта", "the command sandbox is off in the project settings", language: language)
            case .resourcesMissing: L10n.text("компонент SandboxRuntime отсутствует в сборке", "the SandboxRuntime component is missing from this build", language: language)
            case .trustedCommandOutside(let command): L10n.text(
                "доверенная команда проекта `\(command)` не может работать внутри границы; убери её из настроек проекта или замени инструментом приложения",
                "the project's trusted command `\(command)` cannot run inside the boundary; remove it from the project settings or replace it with an app tool",
                language: language)
            }
        }
    }

    /// Fixed read-only trees every sandboxed worker needs for its toolchain: Xcode, Command Line Tools, Homebrew.
    static let toolchainTrees = ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools", "/opt/homebrew"]
    static let executableSubdirectories = ["Toolchains/XcodeDefault.xctoolchain/usr/bin", "usr/bin"]

    public static func eligibility(_ profile: AgentPermissionProfile) -> Ineligible? {
        let effective = profile.effective
        if effective.filesystem == .unrestricted { return .unrestricted }
        if !effective.network { return .networkOff }
        if effective.shell == .on && effective.commandSandbox == nil { return .commandSandboxOff }
        return nil
    }

    public static func plan(_ input: Input, helper: Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>,
                            manager: FileManager = .default) -> Result<ExternalSandboxPlan, Ineligible> {
        if case .failure(let failure) = helper { return .failure(.helper(failure)) }
        if let reason = eligibility(input.profile) { return .failure(reason) }
        guard let resources = input.resources, manager.fileExists(atPath: resources.appendingPathComponent("SandboxRuntime/mcp_relay.py").path) else {
            return .failure(.resourcesMissing)
        }
        let effective = input.profile.effective
        let project = canonical(input.project)
        let worker = ExternalSandboxLocations.workers.appendingPathComponent(input.workerID, isDirectory: true)
        let socket = ExternalSandboxLocations.socket(worker: worker, id: input.workerID)
        var grants: [ExternalSandboxPlan.Grant] = []
        let protected = canonical(ExternalSandboxLocations.root.path)
        func add(_ requested: ExternalSandboxPlan.Mode, _ path: String, mustExist: Bool = true) {
            let resolved = canonical(expand(path, home: input.home))
            guard !resolved.isEmpty, resolved.hasPrefix("/") else { return }
            // nono refuses any grant that contains its own state root (the app's nono folder); such a grant is dropped,
            // never widened. The data root is not an agent root in any role.
            if protected == resolved || protected.hasPrefix(resolved + "/") {
                ExternalSandboxLog.logger.notice("Grant dropped: \(resolved, privacy: .public) contains the boundary state")
                return
            }
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: resolved, isDirectory: &isDirectory)
            if mustExist && !exists { return }
            // Presets may list single files (`~/.gitconfig`, `~/.npmrc`); nono grants files and folders with different flags.
            var mode = requested
            if exists && !isDirectory.boolValue {
                if mode == .read { mode = .readFile } else if mode == .allow { mode = .allowFile }
            }
            if let index = grants.firstIndex(where: { $0.path == resolved }) {
                let widened = (grants[index].mode == .read && mode == .allow) || (grants[index].mode == .readFile && mode == .allowFile)
                if widened { grants[index] = .init(mode, resolved) }
                return
            }
            grants.append(.init(mode, resolved))
        }
        let readOnly = effective.filesystem == .readOnly
        add(readOnly ? .read : .allow, project)
        if readOnly, let scratch = effective.scratch, !scratch.isEmpty, !scratch.hasPrefix("/"), !scratch.split(separator: "/").contains("..") {
            let folder = project + "/" + scratch
            try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            add(.allow, folder)
        }
        for root in effective.extraRoots { add(root.writable && !readOnly ? .allow : .read, root.path) }
        if let sandbox = effective.commandSandbox, effective.shell == .on {
            for path in sandbox.write { add(.allow, path) }
            for path in sandbox.read { add(.read, path) }
            // The app's own cache folder holds the shared build lock every project script takes.
            let caches = input.home.appendingPathComponent("Library/Caches/Switchboard").path
            try? manager.createDirectory(atPath: caches, withIntermediateDirectories: true)
            add(.allow, caches)
        }
        add(.allow, input.providerHome.path, mustExist: false)
        add(.read, input.providerExecutable.resolvingSymlinksInPath().deletingLastPathComponent().path)
        for tree in toolchainTrees { add(.read, tree) }
        add(.read, resources.path)
        for directory in input.workflowDirectories { add(.read, directory.path) }
        for path in input.extraReads { add(.read, path) }
        for path in input.extraWrites { add(.allow, path) }
        add(.readFile, input.home.appendingPathComponent(".gitconfig").path)
        add(.read, input.home.appendingPathComponent(".config/git").path)
        let temporary = worker.appendingPathComponent("tmp", isDirectory: true)
        grants.append(.init(.allow, temporary.path))
        grants.append(.init(.readFile, resources.appendingPathComponent("SandboxRuntime/mcp_relay.py").path))
        grants.append(.init(.unixSocket, socket.path))
        if input.settingsFile { grants.append(.init(.readFile, worker.appendingPathComponent("settings.json").path)) }
        var executableDirectories: [String] = []
        for tree in toolchainTrees.prefix(2) {
            // nono refuses a policy executable directory that its group or everyone may write (Command Line Tools' usr/bin is).
            for sub in executableSubdirectories where manager.fileExists(atPath: tree + "/" + sub) && !isGroupOrWorldWritable(tree + "/" + sub, manager: manager) {
                executableDirectories.append(tree + "/" + sub)
            }
        }
        var commands: [ExternalSandboxCommand] = []
        if effective.shell == .on, let sandbox = effective.commandSandbox {
            let trusted = sandbox.unsandboxed
            if trusted.contains("codesign") {
                commands.append(.init(name: "codesign", executable: "/usr/bin/codesign", keychain: true, network: false))
                commands.append(.init(name: "security", executable: "/usr/bin/security", keychain: true, network: false))
            }
            if trusted.contains("gh"), let gh = resolveExecutable("gh") {
                commands.append(.init(name: "gh", executable: gh, keychain: true, network: true))
            }
            if trusted.contains(where: { $0.hasPrefix("git ") }), let git = resolveGit() {
                // git's own helpers (remote-https, credential-osxkeychain) by absolute path, and /bin/sh for hooks and helpers.
                var trees = ["/bin"]
                if let execPath = gitExecPath(git) { trees += [execPath, canonical(execPath)] }
                commands.append(.init(name: "git", executable: git, keychain: true, network: true, executableTrees: Array(Set(trees)).sorted()))
            }
            if input.mediateProcessList { commands.append(.init(name: "pgrep", executable: "/usr/bin/pgrep", keychain: false, network: false)) }
            if input.commandInventory,
               let command = unrunnableTrustedCommand(trusted, mediated: Set(commands.map(\.name)), grants: grants, home: input.home) {
                return .failure(.trustedCommandOutside(command))
            }
        }
        return .success(.init(workerID: input.workerID, project: project, grants: grants, commands: commands,
                              executableDirectories: executableDirectories, worker: worker, socket: socket,
                              relay: resources.appendingPathComponent("SandboxRuntime/mcp_relay.py"), temporary: temporary))
    }

    /// Heads nono can neither run in the session nor mediates here: setuid tools, the unified log, launchd, Apple Events,
    /// process killers, screen capture, Launch Services, system settings (B1 probe, check 4).
    static let unrunnableHeads: Set<String> = ["log", "ps", "launchctl", "sudo", "su", "osascript", "pkill", "killall", "screencapture",
                                               "open", "defaults", "diskutil", "security", "shutdown", "reboot"]
    /// System trees a command may name as an argument without a grant (executables, devices, configuration).
    static let systemPrefixes = ["/usr/", "/bin/", "/sbin/", "/System/", "/Library/Developer/", "/Applications/", "/opt/homebrew/",
                                 "/dev/", "/etc/", "/private/etc/"]
    /// The project command inventory: the first trusted command that can neither be mediated nor run inside the plan's
    /// grants, or nil. The app's base entries (`AccessPresetCatalog.baseUnsandboxed`) are exempt. Pure, so both providers
    /// can call it; only Claude does today (Codex: PERMISSIONS.md section 5).
    public static func unrunnableTrustedCommand(_ trusted: [String], mediated: Set<String>, grants: [ExternalSandboxPlan.Grant], home: URL) -> String? {
        let base = Set(AccessPresetCatalog.baseUnsandboxed)
        func inside(_ raw: String) -> Bool {
            let path = canonical(expand(raw, home: home))
            if systemPrefixes.contains(where: { (path + "/").hasPrefix($0) }) { return true }
            return grants.contains { $0.mode != .unixSocket && (path == $0.path || path.hasPrefix($0.path + "/")) }
        }
        for command in trusted where !base.contains(command) {
            let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
            guard let first = tokens.first else { continue }
            let head = (first as NSString).lastPathComponent
            if mediated.contains(head) { continue }
            if unrunnableHeads.contains(head) { return command }
            for token in tokens where token.hasPrefix("/") || token.hasPrefix("~/") || token == "~" {
                if !inside(token) { return command }
            }
        }
        return nil
    }

    static func isGroupOrWorldWritable(_ path: String, manager: FileManager) -> Bool {
        guard let permissions = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? Int else { return true }
        return permissions & 0o022 != 0
    }
    static func expand(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public static func resolveExecutable(_ name: String) -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    static func gitExecPath(_ git: String) -> String? { absolutePathOutput(git, ["--exec-path"]) }
    /// The git binary a mediated command runs. `/usr/bin/git` is Apple's `xcrun` shim: inside the mediated sandbox it cannot
    /// read Xcode's `Info.plist` or write its cache, so git never starts (seen live 2026-11-12). The app resolves the real
    /// binary once, outside the boundary; it lies in a toolchain tree the worker already reads.
    public static func resolveGit(found: String? = resolveExecutable("git"), homebrew: String? = "/opt/homebrew/bin/git", locate: (String) -> String? = { absolutePathOutput("/usr/bin/xcrun", ["--find", $0]) }) -> String? {
        guard found == "/usr/bin/git" else { return found }
        // Homebrew's git first: that shape is the one `scripts/probe-nono-runtime.py` verifies under the real helper.
        for real in [homebrew, locate("git")].compactMap({ $0 }) where real != found && FileManager.default.isExecutableFile(atPath: real) { return real }
        return found
    }
    /// stdout of a fixed argv when it exits 0 and prints one absolute path.
    public static func absolutePathOutput(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && path.hasPrefix("/") && !path.contains("\n") ? path : nil
    }
}

/// Launch recipe for a provider process under the boundary: a `setsid` launcher so the whole tree forms one process
/// group that revocation can signal, then `nono run …`, then the provider command.
public struct ExternalSandboxLaunch: Hashable, Sendable {
    public let plan: ExternalSandboxPlan
    public let helper: ExternalSandboxHelper
    public init(plan: ExternalSandboxPlan, helper: ExternalSandboxHelper) { self.plan = plan; self.helper = helper }
    public static let launcher = "/usr/bin/python3"
    // Foundation's Process already makes the child a process-group leader; setsid then fails with EPERM and is not needed.
    public static let launcherArguments = ["-I", "-c", "import os,sys\ntry:\n    os.setsid()\nexcept PermissionError:\n    pass\nos.execv(sys.argv[1], sys.argv[1:])"]
    public func command(provider executable: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: Self.launcher), Self.launcherArguments + plan.arguments(helper: helper) + ["--", executable.path] + arguments)
    }
}

public enum ExternalSandboxLog {
    public static let logger = Logger(subsystem: "local.daniil.switchboard", category: "externalSandbox")
}

/// Signals a whole process group: SIGTERM, then SIGKILL after a grace period for anything still alive.
public enum ProcessGroupTerminator {
    public static func terminate(group pid: Int32, grace: Duration = .seconds(3)) {
        guard pid > 1 else { return }
        if killpg(pid, SIGTERM) != 0 { return }
        Task.detached {
            try? await Task.sleep(for: grace)
            killpg(pid, SIGKILL)
        }
    }
}

/// The MCP host process that serves app-owned servers outside the boundary for one worker.
public actor ExternalSandboxHost {
    private var process: Process?
    private let plan: ExternalSandboxPlan
    private let script: URL
    public init(plan: ExternalSandboxPlan, resources: URL) {
        self.plan = plan
        self.script = resources.appendingPathComponent("SandboxRuntime/mcp_host.py")
    }
    public var isRunning: Bool { process?.isRunning == true }
    public func start() throws {
        guard process == nil else { return }
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-I", script.path, "--socket", plan.socket.path, "--spec", plan.serversFile.path,
                           "--owner-pid", String(ProcessInfo.processInfo.processIdentifier), "--log", plan.hostLog.path]
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.merge(ProcessLabels.environment()) { _, new in new }
        child.environment = environment
        try child.run()
        process = child
        // The host prints `ready` once it listens; a provider started before that would fail its MCP startup.
        let line = output.fileHandleForReading.readLine(timeout: 10)
        guard line == "ready" else {
            child.terminate()
            throw ClientFailure(L10n.text("Хост MCP-серверов не запустился", "The MCP server host did not start"))
        }
    }
    public func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}

private extension FileHandle {
    /// Reads one line with a deadline; nil on timeout or EOF.
    func readLine(timeout seconds: Int) -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var buffer = Data()
        let descriptor = fileDescriptor
        while Date() < deadline {
            var set = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard poll(&set, 1, remaining) > 0 else { return nil }
            var byte: UInt8 = 0
            let read = Darwin.read(descriptor, &byte, 1)
            if read <= 0 { return nil }
            if byte == 10 { return String(decoding: buffer, as: UTF8.self) }
            buffer.append(byte)
        }
        return nil
    }
}
