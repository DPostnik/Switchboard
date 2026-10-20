import Foundation
import ContextCore
import AgentContract

/// Role encoding for the Claude CLI. Claude has no OS sandbox here, so a role is layered: the tool set,
/// settings rules, the app's `can_use_tool` answers and a `PreToolUse` hook for command text (plan 4.5).
struct ClaudeLaunchPolicy: Equatable {
    static let readTools = ["Read", "Glob", "Grep"]
    static let editTools = ["Write", "Edit"]
    static let fetchTools = ["WebFetch", "WebSearch"]
    static let hookCallback = "switchboard-bash"
    /// Secrets no restricted role may read even inside its roots.
    static let secretDenyRules = ["Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.gnupg/**)", "Read(~/.config/gh/**)",
                                  "Read(**/.env)", "Read(**/.env.*)", "Read(~/.codex/auth.json)", "Read(~/.claude/.credentials.json)"]
    /// Commands that reach the network; denied by the hook when the role has shell but no network.
    static let networkCommands = ["curl ", "wget ", "ssh ", "scp ", "sftp ", "nc ", "git push", "git fetch", "git pull", "git clone",
                                  "npm install", "npm i ", "npx ", "pip install", "pip3 install", "brew install", "brew upgrade"]

    let profile: AgentPermissionProfile
    let scheduled: Bool
    /// nil keeps every built-in tool (unrestricted roles).
    let tools: [String]?
    let permissionMode: String
    let restricted: Bool
    /// Whether the account's claude.ai connectors are loaded.
    let connectors: Bool
    let userChrome: Bool
    let allowRules: [String]
    let denyRules: [String]
    let askRules: [String]
    let additionalDirectories: [String]
    /// Tool names a subagent may keep (`--agents` definitions are capped to them); nil passes them unchanged, empty drops them.
    let subagentTools: [String]?
    let delegation: Bool
    let inspectsCommands: Bool
    /// Audit mode: the engine runs unrestricted and the hook only records what the role would have denied.
    let audit: Bool

    init(_ requested: AgentPermissionProfile, scheduled: Bool, userChromeEnabled: Bool) {
        let profile = requested.effective
        self.profile = profile; self.scheduled = scheduled; self.audit = requested.audit
        let unrestricted = profile.filesystem == .unrestricted
        self.tools = Self.toolList(profile)
        if unrestricted && profile.approvals == .never { permissionMode = "bypassPermissions" }
        else if profile.projectWrites == .silent, profile.filesystem != .readOnly { permissionMode = "acceptEdits" }
        else { permissionMode = "default" }
        // `--restricted` confines files to the project and drops code-running tools unless named; roots or a shell need the open form.
        restricted = !unrestricted && profile.extraRoots.isEmpty && profile.shell != .on
        connectors = profile.connectors != .off
        userChrome = userChromeEnabled && profile.browser == .appAndUserChrome && !scheduled && connectors
        var allow: [String] = [], deny: [String] = [], ask: [String] = []
        if let scratch = profile.scratch, profile.filesystem == .readOnly {
            allow += Self.editTools.map { "\($0)(\(scratch)/**)" }
        }
        if profile.shell == .on, !unrestricted { allow.append("Bash") }
        if profile.network, !unrestricted { allow += Self.fetchTools }
        if !unrestricted, profile.network || profile.shell == .on { deny += Self.secretDenyRules }
        switch profile.connectors {
        case .off, .all where scheduled: break
        // Attended operator chats still hold connector writes for approval, as full access always did.
        case .all, .askWrites where !scheduled: ask += ClaudeIntegration.connectorApprovalRules
        case .askWrites, .read: deny += ClaudeIntegration.connectorApprovalRules
        }
        if profile.connectors == .read || profile.connectors == .askWrites, !unrestricted { allow.append("mcp__claude_ai_*") }
        allowRules = allow; denyRules = deny; askRules = ask
        additionalDirectories = profile.extraRoots.map(\.path)
        if let cap = profile.subagentRole {
            // A capped worker gets no scratch writes: the parent's edit mode would widen them beyond the scratch folder.
            var capped = AgentRoleCatalog.preset(cap).profile.effective; capped.scratch = nil
            subagentTools = Self.toolList(capped).map { $0.filter { $0 != "AskUserQuestion" } }
        } else { subagentTools = [] }
        delegation = profile.subagentRole != nil
        inspectsCommands = profile.shell == .on && !unrestricted && (!profile.commandInspection.isEmpty || !profile.network)
    }

    /// Built-in tools for a profile; nil keeps every tool (unrestricted roles).
    static func toolList(_ profile: AgentPermissionProfile) -> [String]? {
        guard profile.filesystem != .unrestricted else { return nil }
        var list = readTools
        switch profile.filesystem {
        case .readOnly: if profile.scratch != nil { list += editTools }
        default: list += editTools
        }
        if profile.shell == .on { list.append("Bash") }
        if profile.network { list += fetchTools } else if profile.webSearch { list.append("WebSearch") }
        if profile.subagentRole != nil { list.append("Agent") }
        list.append("AskUserQuestion")
        return list
    }
    /// `permissions` for `--settings`; nil when the launch carries none.
    var settings: JSONValue? {
        var permissions: [String: JSONValue] = [:]
        if !allowRules.isEmpty { permissions["allow"] = .array(allowRules.map(JSONValue.string)) }
        if !denyRules.isEmpty { permissions["deny"] = .array(denyRules.map(JSONValue.string)) }
        if !askRules.isEmpty { permissions["ask"] = .array(askRules.map(JSONValue.string)) }
        if !additionalDirectories.isEmpty { permissions["additionalDirectories"] = .array(additionalDirectories.map(JSONValue.string)) }
        return permissions.isEmpty ? nil : .object(["permissions": .object(permissions)])
    }
    /// `hooks` for the control-protocol `initialize`; the app answers each callback with the role's decision.
    var hooks: JSONValue {
        guard inspectsCommands || audit else { return .null }
        return .object(["PreToolUse": .array([.object(["matcher": .string("Bash"), "hookCallbackIds": .array([.string(Self.hookCallback)]), "timeout": .number(600)])])])
    }

    enum CommandDecision: Equatable { case allow, ask, deny(String) }
    /// Inspection of one shell command against the role: deny-list first, then the network list, then the ask-list.
    /// A recursive delete whose every target stays inside the project, a writable root or a temporary folder is not asked.
    func inspect(command: String, cwd: String? = nil) -> CommandDecision {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        if let hit = profile.commandInspection.deny.first(where: { Self.matches(text, $0) }) {
            return .deny(L10n.text("Команда запрещена ролью: \(hit.trimmingCharacters(in: .whitespaces))", "The role forbids this command: \(hit.trimmingCharacters(in: .whitespaces))"))
        }
        if !profile.network, let hit = Self.networkCommands.first(where: { Self.matches(text, $0) }) {
            return .deny(L10n.text("Роль без сети: \(hit.trimmingCharacters(in: .whitespaces))", "The role has no network: \(hit.trimmingCharacters(in: .whitespaces))"))
        }
        for head in Self.heads(text) {
            guard let pattern = profile.commandInspection.ask.first(where: { (head + " ").hasPrefix($0) }) else { continue }
            if pattern.hasPrefix("rm "), let cwd, safeRemoval(head, cwd: cwd) { continue }
            return profile.approvals == .ask && !scheduled ? .ask : .deny(L10n.text("Действие вне роли; запуск без присмотра не ждёт.", "Outside the role; an unattended run does not wait."))
        }
        return .allow
    }
    /// `rm` targets that are plain paths inside the project, a writable extra root or a temporary folder.
    /// Variables, `~`, globs at the root and `..` are never considered safe.
    func safeRemoval(_ head: String, cwd: String) -> Bool {
        let targets = head.split(separator: " ").dropFirst().map(String.init).filter { !$0.hasPrefix("-") }
        guard !targets.isEmpty else { return false }
        let temporary = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"] + [ProcessInfo.processInfo.environment["TMPDIR"]].compactMap { $0 }
        let roots = [cwd] + writableRoots + temporary
        return targets.allSatisfy { raw in
            let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !path.isEmpty, !path.contains("$"), !path.hasPrefix("~"), !path.split(separator: "/").contains(".."),
                  path != "/", path != ".", path != "*", !path.hasPrefix("/*") else { return false }
            let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
            return roots.contains { root in
                let base = root.hasSuffix("/") ? String(root.dropLast()) : root
                return absolute.hasPrefix(base + "/") && absolute.count > base.count + 1
            }
        }
    }
    /// The commands a shell line runs (see `ShellSegments`), with leading environment assignments and
    /// command wrappers (`nohup`, `env`, `exec`…) removed so the real command is what gets matched.
    static func heads(_ text: String) -> [String] {
        ShellSegments.commands(text).map { segment in
            var head = segment.trimmingCharacters(in: .whitespaces)
            var changed = true
            while changed {
                changed = false
                if let space = head.firstIndex(of: " "), head[..<space].contains("="), !head[..<space].contains("/") {
                    head = String(head[head.index(after: space)...]).trimmingCharacters(in: .whitespaces); changed = true
                }
                for wrapper in ShellSegments.wrappers where head.hasPrefix(wrapper + " ") {
                    head = String(head.dropFirst(wrapper.count + 1)).trimmingCharacters(in: .whitespaces); changed = true
                }
            }
            return head
        }
    }
    /// A pattern matches the head of a command segment (after `|`, `;`, `&&`, `(`, backticks, `$(` or a newline),
    /// so `sudo ` is found in `cd x && sudo rm` but not inside `pseudo ` or as an argument such as `echo curl`.
    static func matches(_ text: String, _ pattern: String) -> Bool {
        heads(text).contains { ($0 + " ").hasPrefix(pattern) }
    }

    /// Tools the app answers `can_use_tool` for; anything else is unsupported and denied.
    func permits(tool name: String) -> Bool {
        if name.hasPrefix(ClaudeIntegration.connectorToolPrefix) { return connectors }
        if name.hasPrefix("mcp__switchboard_browser__") { return profile.browser != .off }
        if name.hasPrefix("mcp__claude-in-chrome__") { return userChrome }
        if projectServer(of: name) != nil { return true }
        guard let tools else { return true }
        return tools.contains(name)
    }
    /// The approved project server a tool belongs to (`mcp__<server>__<tool>`), or nil.
    func projectServer(of tool: String) -> String? {
        (profile.mcpServers ?? [:]).keys.first { tool.hasPrefix("mcp__" + $0 + "__") }
    }
    /// Roots the role may read (all) and write (writable ones); the project itself is implied.
    var readableRoots: [String] { profile.extraRoots.map(\.path) }
    var writableRoots: [String] { profile.extraRoots.filter(\.writable).map(\.path) }
}

extension ProjectAgents {
    /// `--agents` definitions capped to `tools`: a subagent never exceeds the role's cap, whatever its file says.
    public static func capped(_ definitions: JSONValue, to tools: [String]) -> JSONValue {
        var capped: [String: JSONValue] = [:]
        for (name, value) in definitions.object {
            var definition = value.object
            let own = definition["tools"]?.array.compactMap(\.string)
            let kept = (own ?? tools).filter { tools.contains($0) }
            definition["tools"] = .array(kept.map(JSONValue.string))
            let blocked = ["Bash", "Write", "Edit", "Agent", "WebFetch", "WebSearch"].filter { !tools.contains($0) }
            let disallowed = Set(definition["disallowedTools"]?.array.compactMap(\.string) ?? []).union(blocked)
            definition["disallowedTools"] = .array(disallowed.sorted().map(JSONValue.string))
            capped[name] = .object(definition)
        }
        return .object(capped)
    }
}

/// Claude permission-rule globs for tool names (`mcp__claude_ai_*__*send*`): `*` matches any run of characters.
enum ClaudeToolRule {
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return name == pattern }
        var position = name.startIndex
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 { guard name.hasPrefix(part) else { return false }; position = name.index(position, offsetBy: part.count); continue }
            if index == parts.count - 1 { return name[position...].hasSuffix(part) }
            guard let range = name.range(of: part, range: position..<name.endIndex) else { return false }
            position = range.upperBound
        }
        return true
    }
}
