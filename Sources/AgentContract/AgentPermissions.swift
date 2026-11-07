import Foundation

/// Capability dimensions of a role. These are restrictions, not provider-specific sandbox names:
/// each adapter encodes what it supports and reports the dimensions it can only approximate.
public struct AgentPermissionProfile: Codable, Hashable, Sendable {
    /// A folder outside the project the role may read, and optionally write.
    public struct Root: Codable, Hashable, Sendable {
        public var path: String
        public var writable: Bool
        public init(path: String, writable: Bool) { self.path = path; self.writable = writable }
    }
    public enum Filesystem: Codable, Hashable, Sendable {
        case readOnly
        /// The project folder plus declared extra roots.
        case project(extraRoots: [Root])
        case unrestricted
    }
    public enum Shell: String, Codable, Sendable {
        case off
        /// Commands run inside the engine's sandbox (Codex). Claude has no sandbox and encodes this as `off`.
        case sandboxed
        case on
    }
    /// Whether writes inside the role's roots run silently or are asked (Claude `acceptEdits` versus `default`).
    public enum ProjectWrites: String, Codable, Sendable { case ask, silent }
    public enum Browser: String, Codable, Sendable { case off, app, appAndUserChrome }
    /// claude.ai connectors (Gmail, Calendar…); Codex has no equivalent and ignores this dimension.
    public enum Connectors: String, Codable, Sendable { case off, read, askWrites, all }
    public enum CookieImport: Codable, Hashable, Sendable { case none, sites([String]), any }
    /// What happens to an action outside the role: an unattended run never waits, an attended chat asks, `never` means no prompts at all.
    public enum Approvals: String, Codable, Sendable { case blocked, ask, never }
    /// Command text inspection before a shell command runs (Claude `PreToolUse` hook). Patterns are matched against the command.
    public struct CommandInspection: Codable, Hashable, Sendable {
        public var deny: [String]
        public var ask: [String]
        public init(deny: [String] = [], ask: [String] = []) { self.deny = deny; self.ask = ask }
        public var isEmpty: Bool { deny.isEmpty && ask.isEmpty }
    }

    /// What shell commands may touch when the engine confines them in an OS sandbox (Claude `sandbox` settings).
    /// Paths are absolute or start with `~/`; everything else in the home folder stays closed to commands.
    public struct CommandSandbox: Codable, Hashable, Sendable {
        public var read: [String]
        public var write: [String]
        /// Declared read-only folders the engine would otherwise make writable for commands.
        public var readOnly: [String]
        /// Trusted command prefixes that run outside the sandbox without a prompt.
        public var unsandboxed: [String]
        public init(read: [String], write: [String], readOnly: [String] = [], unsandboxed: [String] = []) {
            self.read = read; self.write = write; self.readOnly = readOnly; self.unsandboxed = unsandboxed
        }
    }

    public var filesystem: Filesystem
    /// Network for shell commands and fetch tools (sandbox network on Codex; WebFetch/WebSearch tools and the hook deny-list on Claude).
    public var network: Bool
    /// The engine's own web search tool (Codex `web_search`, Claude `WebSearch`).
    public var webSearch: Bool
    public var shell: Shell
    public var projectWrites: ProjectWrites
    public var browser: Browser
    public var connectors: Connectors
    public var cookieImport: CookieImport
    public var approvals: Approvals
    public var commandInspection: CommandInspection
    /// Role id that caps subagents, or nil when the role allows no subagents.
    public var subagentRole: String?
    /// A folder inside the project (relative path) that a read-only role may write.
    public var scratch: String?
    /// Audit mode: the engine runs with unrestricted permissions while every action outside the role is recorded as "would deny".
    public var audit: Bool
    /// Project MCP servers the user approved for this project: server name -> fingerprint of its approved `.mcp.json` entry.
    public var mcpServers: [String: String]?
    /// The project's command sandbox; nil runs commands unconfined (and engines without one ignore it).
    public var commandSandbox: CommandSandbox?

    public init(filesystem: Filesystem, network: Bool, webSearch: Bool, shell: Shell, projectWrites: ProjectWrites = .ask,
                browser: Browser, connectors: Connectors, cookieImport: CookieImport = .none, approvals: Approvals,
                commandInspection: CommandInspection = .init(), subagentRole: String? = nil, scratch: String? = nil, audit: Bool = false) {
        self.filesystem = filesystem; self.network = network; self.webSearch = webSearch; self.shell = shell; self.projectWrites = projectWrites
        self.browser = browser; self.connectors = connectors; self.cookieImport = cookieImport; self.approvals = approvals
        self.commandInspection = commandInspection; self.subagentRole = subagentRole; self.scratch = scratch; self.audit = audit
    }

    /// Codex `workspace-write` with no network and on-request approvals; Claude project-file tools only.
    /// The app browser stays attached as it was for the old standard mode.
    /// Writes inside the project run without a prompt (plan 4.2: the editor asks only for outside writes).
    public static func workspace(extraRoots: [Root] = []) -> Self {
        .init(filesystem: .project(extraRoots: extraRoots), network: false, webSearch: false, shell: .sandboxed, projectWrites: .silent,
              browser: .app, connectors: .off, cookieImport: .any, approvals: .ask)
    }
    /// No restrictions and no prompts (Codex `danger-full-access`, Claude `bypassPermissions`).
    public static let unrestricted = Self(filesystem: .unrestricted, network: true, webSearch: true, shell: .on, projectWrites: .silent,
                                          browser: .appAndUserChrome, connectors: .all, cookieImport: .any, approvals: .never, subagentRole: "operator")

    public var isUnrestricted: Bool { filesystem == .unrestricted && approvals == .never }
    /// The profile the engine actually runs with: audit mode runs unrestricted while the role is only recorded.
    public var effective: Self {
        guard audit else { return self }
        var result = Self.unrestricted; result.mcpServers = mcpServers
        return result
    }
    public var extraRoots: [Root] { if case .project(let roots) = filesystem { return roots }; return [] }
}

public enum AgentPermissionDimension: String, Codable, CaseIterable, Sendable {
    case filesystem, network, webSearch, shell, projectWrites, browser, connectors, cookieImport, approvals, commandInspection, subagents, scratch
}

public enum AgentPermissionIntent: Codable, Hashable, Sendable {
    /// A role profile for the project at `root` (must equal the request's project path).
    case profile(AgentPermissionProfile, root: String)
    /// Explicitly accepts the external CLI's policy, with new prompts denied.
    /// Never derive this case from a project's standard/full-access setting.
    case externalPolicyDenyPrompts

    public enum ApprovalPolicy: String, Codable, Sendable { case ask, never }
    /// Legacy shape: Codex `workspace-write`, Claude project files only.
    public static func workspaceWrite(root: String, network: Bool, approval: ApprovalPolicy) -> Self {
        var profile = AgentPermissionProfile.workspace()
        profile.network = network
        profile.approvals = approval == .ask ? .ask : .never
        return .profile(profile, root: root)
    }
    /// Legacy shape: no restrictions.
    public static func unrestricted(approval: ApprovalPolicy) -> Self {
        var profile = AgentPermissionProfile.unrestricted
        profile.approvals = approval == .ask ? .ask : .never
        return .profile(profile, root: "")
    }
    public var profile: AgentPermissionProfile? { if case .profile(let value, _) = self { return value }; return nil }
}

/// A role requirement that not every engine can enforce exactly. An adapter declares the ones it enforces; the app shows
/// the rest as approximations of the role (`AgentPermissionSupport.approximations`) instead of downgrading silently.
public enum AgentPermissionRule: String, Codable, CaseIterable, Sendable {
    /// No shell at all (`shell == .off`).
    case shellOff
    /// Shell commands inside an engine sandbox (`shell == .sandboxed`).
    case sandboxedShell
    /// Shell on with the network off.
    case networkOffWithShell
    /// Command text inspection before a command runs.
    case commandInspection
    /// Some connectors only, or connectors with write prompts (neither `off` nor `all`).
    case selectedConnectors
    /// A writable research folder inside an otherwise read-only role.
    case scratchInReadOnly
    /// Driving the user's own Chrome (`browser == .appAndUserChrome`).
    case userChrome
    /// Approval prompts while the filesystem is unrestricted.
    case promptsWithoutSandbox

    /// The role dimension an unenforced rule approximates.
    public var dimension: AgentPermissionDimension {
        switch self {
        case .shellOff, .sandboxedShell: .shell
        case .networkOffWithShell: .network
        case .commandInspection: .commandInspection
        case .selectedConnectors: .connectors
        case .scratchInReadOnly: .scratch
        case .userChrome: .browser
        case .promptsWithoutSandbox: .approvals
        }
    }

    /// True when the profile asks for this requirement.
    public func applies(to profile: AgentPermissionProfile) -> Bool {
        switch self {
        case .shellOff: profile.shell == .off
        case .sandboxedShell: profile.shell == .sandboxed
        case .networkOffWithShell: profile.shell == .on && !profile.network
        case .commandInspection: !profile.commandInspection.isEmpty
        case .selectedConnectors: profile.connectors != .off && profile.connectors != .all
        case .scratchInReadOnly: profile.scratch != nil && profile.filesystem == .readOnly
        case .userChrome: profile.browser == .appAndUserChrome
        case .promptsWithoutSandbox: profile.filesystem == .unrestricted && profile.approvals != .never
        }
    }
}

/// Which permission requests an engine takes and which role requirements it enforces. Described by capabilities, not by
/// engine name: each adapter declares its own value (the Codex and Claude presets live in their adapters).
public struct AgentPermissionSupport: Codable, Hashable, Sendable {
    /// Takes app role profiles (`AgentPermissionIntent.profile`).
    public let roleProfiles: Bool
    /// Takes the external CLI's own policy with new prompts denied (`.externalPolicyDenyPrompts`).
    public let externalPolicy: Bool
    /// Rules enforced exactly; every other rule a profile asks for is reported as an approximation.
    public let enforced: Set<AgentPermissionRule>

    public init(roleProfiles: Bool, externalPolicy: Bool = false, enforced: Set<AgentPermissionRule> = []) {
        self.roleProfiles = roleProfiles; self.externalPolicy = externalPolicy; self.enforced = enforced
    }

    /// Runs only under the external CLI's policy; the app enforces no role dimension.
    public static let externalPolicyOnly = Self(roleProfiles: false, externalPolicy: true)

    public func accepts(_ intent: AgentPermissionIntent) -> Bool {
        switch intent {
        case .externalPolicyDenyPrompts: return externalPolicy
        case .profile(let profile, _):
            // Unrestricted execution with prompts is not a role any engine runs; it would silently become "never".
            return roleProfiles && !(profile.filesystem == .unrestricted && profile.approvals != .never)
        }
    }

    /// Dimensions this engine cannot enforce as requested; the app shows them instead of downgrading silently.
    public func approximations(_ profile: AgentPermissionProfile) -> [AgentPermissionDimension] {
        guard roleProfiles else { return AgentPermissionDimension.allCases }
        let effective = profile.effective
        var result: [AgentPermissionDimension] = []
        for rule in AgentPermissionRule.allCases where !enforced.contains(rule) && rule.applies(to: effective) {
            if !result.contains(rule.dimension) { result.append(rule.dimension) }
        }
        return result
    }
}
