import Foundation
import Testing
import SQLite3
import AgentContract
@testable import ContextCore
@testable import CodexAdapter
@testable import ClaudeAdapter

private let catalog = AgentRoleCatalog()
private func preset(_ id: String) -> AgentRole { AgentRoleCatalog.preset(id) }
private func project(_ path: String = "/tmp/roles-project", extraRoots: [AgentPermissionProfile.Root] = [], cookieSites: [String] = []) -> Project {
    var project = Project(path: path); project.extraRoots = extraRoots; project.cookieSites = cookieSites; return project
}
private func claudeArguments(_ role: AgentRole, scheduled: Bool = false, agents: String? = nil, browser: Bool = false, userChrome: Bool = true, project: Project = project()) throws -> [String] {
    try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: role.profile(for: project), model: "", effort: nil,
                                    scheduled: scheduled, projectAgents: agents, browserServer: browser ? ["server.py"] : nil, userChrome: userChrome)
}
private func value(after flag: String, in args: [String]) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
private func settings(_ args: [String]) throws -> JSONValue {
    guard let raw = value(after: "--settings", in: args) else { return .null }
    return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
}

// MARK: - Catalog and migration

@Test func rolePresetsCoverThePlanAndRankByReach() {
    #expect(catalog.all.map(\.id) == [AgentRoleID.reader, AgentRoleID.editor, AgentRoleID.developer, AgentRoleID.routineOperator, AgentRoleID.fullOperator])
    #expect(preset(AgentRoleID.editor).profile == .workspace())
    #expect(preset(AgentRoleID.fullOperator).profile == .unrestricted)
    #expect(preset(AgentRoleID.routineOperator).profile.audit && preset(AgentRoleID.routineOperator).profile.effective == .unrestricted)
    #expect(preset(AgentRoleID.reader).rank < preset(AgentRoleID.editor).rank && preset(AgentRoleID.developer).rank < preset(AgentRoleID.fullOperator).rank)
    #expect(catalog.scheduled.map(\.id).contains(AgentRoleID.fullOperator) == false)
    #expect(preset(AgentRoleID.editor).legacyAccessMode == .standard && preset(AgentRoleID.fullOperator).legacyAccessMode == .fullAccess)
    #expect(preset(AgentRoleID.routineOperator).legacyAccessMode == .fullAccess) // audit mode runs unrestricted today
    for role in catalog.all { #expect(!role.title(language: .russian).isEmpty && !role.title(language: .english).isEmpty && role.summary(language: .russian) != role.summary(language: .english)) }
}

@Test func roleResolutionFillsProjectRootsAndCookieSitesNeverFromTheAgent() {
    let project = project(extraRoots: [.init(path: "/Users/me/data", writable: true), .init(path: "relative/path", writable: true)], cookieSites: ["LinkedIn.com"])
    let developer = preset(AgentRoleID.developer).profile(for: project)
    #expect(developer.extraRoots == [.init(path: "/Users/me/data", writable: true)])
    let routine = preset(AgentRoleID.routineOperator).profile(for: project)
    #expect(routine.cookieImport == .sites(["linkedin.com"]))
    #expect(preset(AgentRoleID.reader).profile(for: project).extraRoots.isEmpty && preset(AgentRoleID.editor).profile(for: project).extraRoots.isEmpty)
    #expect(preset(AgentRoleID.fullOperator).profile(for: project) == .unrestricted)
}

@Test func legacyStateMigratesToRolesOnceWithoutChangingBehaviour() throws {
    var state = SavedState()
    var full = Project(path: "/tmp/full"); full.accessMode = .fullAccess; full.defaultChatAccessMode = .fullAccess
    var standard = Project(path: "/tmp/standard"); standard.accessMode = .standard
    let bare = Project(path: "/tmp/bare")
    state.projects = [full, standard, bare]
    var inherited = Chat(id: "a", projectID: full.id, title: "", model: ""); inherited.inheritsProjectAccess = true
    var explicitFull = Chat(id: "b", projectID: full.id, title: "", model: ""); explicitFull.accessMode = .fullAccess
    var explicitStandard = Chat(id: "c", projectID: full.id, title: "", model: ""); explicitStandard.accessMode = .standard
    let legacy = Chat(id: "d", projectID: full.id, title: "", model: "")
    state.chats = [inherited, explicitFull, explicitStandard, legacy]
    let before = state.chats.map { $0.resolvedAccessMode(in: full) }
    let migrated = state.migrateRoles(now: Date(timeIntervalSince1970: 1)), again = state.migrateRoles()
    #expect(migrated && !again)
    #expect(state.chats.map(\.roleID) == [nil, AgentRoleID.fullOperator, AgentRoleID.editor, AgentRoleID.editor])
    #expect(state.chats.map { $0.resolvedAccessMode(in: state.projects[0]) } == before)
    #expect(state.projects[0].chatRoleID == AgentRoleID.fullOperator && state.projects[0].jobRoleID == AgentRoleID.routineOperator)
    #expect(state.projects[1].chatRoleID == nil && state.projects[1].jobRoleID == AgentRoleID.editor)
    #expect(state.projects[2].chatRoleID == nil && state.projects[2].jobRoleID == nil)
    #expect(state.roleMigration?.chats["inherited"] == 1 && state.roleMigration?.chats["fullAccess->operator"] == 1 && state.roleMigration?.chats["none->editor"] == 1)
    #expect(state.roleMigration?.jobs["fullAccess->routine-operator"] == 1)
    // Still decodable by a build without roles: the access fields are untouched.
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    #expect(restored.projects[0].accessMode == .fullAccess && restored.chats[1].accessMode == .fullAccess && restored.roleMigration != nil)
    #expect(state.chats[0].resolvedRole(in: state.projects[0], catalog: catalog).id == AgentRoleID.fullOperator)
    #expect(state.chats[0].inheritsProjectRole && !state.chats[1].inheritsProjectRole)
}

@Test func scheduledJobsNeverRunAboveTheProjectJobRole() {
    var project = project(); project.jobRoleID = AgentRoleID.editor
    var job = ManagedJob(); job.roleID = AgentRoleID.fullOperator
    #expect(job.role(project: project, catalog: catalog).id == AgentRoleID.editor)
    job.roleID = AgentRoleID.reader
    #expect(job.role(project: project, catalog: catalog).id == AgentRoleID.reader)
    job.roleID = nil
    #expect(job.role(project: project, catalog: catalog).id == AgentRoleID.editor)
    let descriptor = AgentDescriptor(context: .init(connection: .originalCodex, accountRevision: UUID()), identityMode: .appOwnedHome,
                                     capabilities: [.scheduledExecution], permissions: .codexProjectPolicy, routes: [.direct])
    let request = job.executionRequest(runID: UUID(), project: project, descriptor: descriptor)
    #expect(request.permissions == .profile(preset(AgentRoleID.editor).profile(for: project), root: project.path))
    var legacy = Project(path: "/tmp/legacy-full"); legacy.accessMode = .fullAccess
    #expect(job.executionRequest(runID: UUID(), project: legacy, descriptor: descriptor).permissions == .profile(.unrestricted, root: legacy.path))
}

// MARK: - Contract

@Test func permissionSupportReportsApproximationsInsteadOfDowngrading() {
    let developer = preset(AgentRoleID.developer).profile
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(developer) == [.commandInspection])
    #expect(AgentPermissionSupport.claudeRestrictedFiles.approximations(developer).isEmpty)
    #expect(AgentPermissionSupport.claudeRestrictedFiles.approximations(preset(AgentRoleID.editor).profile) == [.shell])
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(preset(AgentRoleID.reader).profile) == [.shell, .connectors, .scratch])
    var offline = developer; offline.network = false
    #expect(AgentPermissionSupport.claudeRestrictedFiles.approximations(offline) == [.network])
    // Codex now enforces My Chrome with app-issued, revocable extension capabilities.
    #expect(AgentPermissionSupport.codexProjectPolicy.enforced.contains(.userChrome))
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(.unrestricted).isEmpty)
    // Audit mode is judged by what actually runs.
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(preset(AgentRoleID.routineOperator).profile).isEmpty)
    var prompting = AgentPermissionProfile.unrestricted; prompting.approvals = .ask
    #expect(!AgentPermissionSupport.codexProjectPolicy.accepts(.profile(prompting, root: "/x")))
    #expect(!AgentPermissionSupport.externalPolicyOnly.accepts(.profile(developer, root: "/x")))
    #expect(AgentPermissionSupport.externalPolicyOnly.accepts(.externalPolicyDenyPrompts))
    #expect(AgentPermissionIntent.workspaceWrite(root: "/x", network: false, approval: .ask) == .profile(.workspace(), root: "/x"))
}

// MARK: - Codex encoding

@Test func codexEncodesEveryRolePreset() {
    let path = "/tmp/roles-project"
    let project = project(path, extraRoots: [.init(path: "/Users/me/fringe", writable: true), .init(path: "/Users/me/.codex", writable: false)])
    let reader = preset(AgentRoleID.reader).profile(for: project)
    #expect(reader.codexThreadParameters == ["approvalPolicy": .string("never"), "sandbox": .string("read-only")])
    #expect(reader.codexTurnParameters(projectPath: path)["sandboxPolicy"] == .object(["type": .string("readOnly")]))
    #expect(reader.codexConfiguration.isEmpty)
    let editor = preset(AgentRoleID.editor).profile(for: project)
    #expect(editor.codexThreadParameters == ["approvalPolicy": .string("on-request"), "sandbox": .string("workspace-write")])
    #expect(editor.codexTurnParameters(projectPath: path)["sandboxPolicy"] == .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(path)]), "networkAccess": .bool(false)]))
    #expect(editor.codexConfiguration == ["web_search": .string("disabled")])
    let developer = preset(AgentRoleID.developer).profile(for: project)
    #expect(developer.codexThreadParameters["approvalPolicy"] == .string("on-request"))
    #expect(developer.codexTurnParameters(projectPath: path)["sandboxPolicy"] == .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(path), .string("/Users/me/fringe")]), "networkAccess": .bool(true)]))
    let routine = preset(AgentRoleID.routineOperator).profile(for: project)
    #expect(routine.codexThreadParameters == ["approvalPolicy": .string("never"), "sandbox": .string("danger-full-access")]) // audit mode
    var enforced = routine; enforced.audit = false
    #expect(enforced.codexThreadParameters == ["approvalPolicy": .string("never"), "sandbox": .string("workspace-write")]) // blocked never waits
    let full = AgentPermissionProfile.unrestricted
    #expect(full.codexTurnParameters(projectPath: path) == ["approvalPolicy": .string("never"), "sandboxPolicy": .object(["type": .string("dangerFullAccess")])])
    // The browser table is switched off for a role without a browser, and left alone otherwise.
    let table: JSONValue = .object(["mcp_servers.switchboard_browser": .object(["command": .string("/usr/bin/python3"), "enabled": .bool(true), "required": .bool(true)])])
    var headless = developer; headless.browser = .off
    #expect(headless.codexThreadConfiguration(browser: table)["mcp_servers.switchboard_browser"]["enabled"].bool == false)
    #expect(developer.codexThreadConfiguration(browser: table)["mcp_servers.switchboard_browser"]["enabled"].bool == true)
    #expect(editor.codexThreadConfiguration(browser: table)["web_search"].string == "disabled")
}

// MARK: - Claude encoding

@Test func claudeEncodesEditorAndOperatorExactlyAsTheOldModes() throws {
    let editor = try claudeArguments(preset(AgentRoleID.editor), agents: #"{"w":{"description":"d","prompt":"p"}}"#)
    #expect(editor.contains("--strict-mcp-config") && editor.contains("--safe-mode") && editor.contains("--restricted"))
    #expect(value(after: "--tools", in: editor) == "Read,Glob,Grep,Write,Edit,Skill,AskUserQuestion")
    #expect(value(after: "--permission-mode", in: editor) == "acceptEdits") // project writes no longer ask
    #expect(try settings(editor) == .object(["crossSessionInbound": .string("refuse")]))
    #expect(!editor.contains("--agents") && !editor.contains("--chrome") && !editor.contains("--add-dir"))
    #expect(editor == (try ClaudeIntegration.arguments(id: value(after: "--session-id", in: editor)!, resumed: false, access: .standard, model: "", effort: nil, projectAgents: #"{"w":{"description":"d","prompt":"p"}}"#, userChrome: true)))
    let operatorArgs = try claudeArguments(preset(AgentRoleID.fullOperator), agents: #"{"w":{"description":"d","prompt":"p"}}"#)
    #expect(!operatorArgs.contains("--strict-mcp-config") && !operatorArgs.contains("--safe-mode") && !operatorArgs.contains("--restricted") && !operatorArgs.contains("--tools"))
    #expect(value(after: "--permission-mode", in: operatorArgs) == "bypassPermissions" && operatorArgs.contains("--chrome"))
    #expect(try settings(operatorArgs)["permissions"]["ask"].array.count == ClaudeIntegration.connectorApprovalRules.count)
    #expect(value(after: "--agents", in: operatorArgs) == #"{"w":{"description":"d","prompt":"p"}}"#)
    let scheduled = try claudeArguments(preset(AgentRoleID.fullOperator), scheduled: true)
    #expect(try settings(scheduled)["permissions"] == .null && !scheduled.contains("--chrome"))
    #expect(try settings(scheduled)["crossSessionInbound"] == .string("refuse"))
    // Audit mode runs exactly like the operator; only the hook is registered to record.
    let audit = try claudeArguments(preset(AgentRoleID.routineOperator), scheduled: true)
    #expect(audit == (try ClaudeIntegration.arguments(id: value(after: "--session-id", in: audit)!, resumed: false, access: .fullAccess, model: "", effort: nil, scheduled: true, userChrome: true)))
}

@Test func claudeEncodesReaderDeveloperAndRoutineRoles() throws {
    let project = project(extraRoots: [.init(path: "/Users/me/fringe", writable: true)])
    let reader = try claudeArguments(preset(AgentRoleID.reader), browser: true)
    #expect(value(after: "--tools", in: reader) == "Read,Glob,Grep,Write,Edit,WebFetch,WebSearch,Agent,SendMessage,Skill,AskUserQuestion")
    #expect(value(after: "--permission-mode", in: reader) == "default" && reader.contains("--restricted") && !reader.contains("--strict-mcp-config"))
    let readerSettings = try settings(reader)["permissions"]
    #expect(readerSettings["allow"].array == [.string("Write(research/**)"), .string("Edit(research/**)"), .string("WebFetch"), .string("WebSearch"), .string("mcp__claude_ai_*")])
    #expect(readerSettings["deny"].array.contains(.string("Read(~/.ssh/**)")))
    #expect(readerSettings["deny"].array.contains { ($0.string ?? "").hasPrefix("mcp__claude_ai_*__*send") })
    #expect(reader.contains("--mcp-config") && reader.contains("mcp__switchboard_browser"))
    let developer = try claudeArguments(preset(AgentRoleID.developer), agents: #"{"w":{"description":"d","prompt":"p","tools":["Read","Bash","Write"]}}"#, project: project)
    #expect(value(after: "--tools", in: developer) == "Read,Glob,Grep,Write,Edit,Bash,WebFetch,WebSearch,Agent,SendMessage,Skill,AskUserQuestion")
    #expect(value(after: "--permission-mode", in: developer) == "acceptEdits" && !developer.contains("--restricted"))
    #expect(value(after: "--add-dir", in: developer) == "/Users/me/fringe" && developer.contains("--strict-mcp-config"))
    let developerSettings = try settings(developer)["permissions"]
    // Commands run in the project's sandbox, so no blanket Bash rule would auto-approve one that leaves it.
    #expect(developerSettings["additionalDirectories"].array == [.string("/Users/me/fringe")] && !developerSettings["allow"].array.contains(.string("Bash")))
    #expect(try settings(developer)["sandbox"]["enabled"] == .bool(true))
    #expect(developerSettings["ask"] == .null)
    #expect(value(after: "--agents", in: developer) == #"{"w":{"description":"d","disallowedTools":[],"prompt":"p","tools":["Read","Bash","Write"]}}"#)
    var routine = preset(AgentRoleID.routineOperator).profile; routine.audit = false
    let enforced = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: routine, model: "", effort: nil, scheduled: true,
                                                   projectAgents: #"{"w":{"description":"d","prompt":"p","tools":["Read","Bash","Write"]}}"#, userChrome: true)
    #expect(!enforced.contains("--chrome") && value(after: "--permission-mode", in: enforced) == "acceptEdits")
    let routineSettings = try settings(enforced)["permissions"]
    #expect(routineSettings["ask"] == .null && routineSettings["deny"].array.contains { ($0.string ?? "").hasPrefix("mcp__claude_ai_*__*send") })
    // The worker is capped to the reader role whatever its file says.
    #expect(value(after: "--agents", in: enforced) == #"{"w":{"description":"d","disallowedTools":["Bash","Edit","Write"],"prompt":"p","tools":["Read"]}}"#)
}

@Test func claudeHookInspectsCommandsByRole() {
    let developer = ClaudeLaunchPolicy(preset(AgentRoleID.developer).profile, scheduled: false, userChromeEnabled: false)
    #expect(developer.inspectsCommands && developer.hooks["PreToolUse"].array.first?["matcher"].string == "Bash")
    // Delegating roles may continue their sub-agents; the sub-agents themselves get no SendMessage.
    #expect(developer.permits(tool: "SendMessage") && developer.hooks["PreToolUse"].array.last?["matcher"].string == "SendMessage")
    #expect(developer.subagentTools?.contains("SendMessage") == false && developer.subagentTools?.contains("Agent") == true)
    #expect(developer.inspect(command: "swift build") == .allow)
    #expect(developer.inspect(command: "rm -rf .build") == .ask) // no cwd known: ask
    #expect(developer.inspect(command: "rm -rf .build Tests/tmp", cwd: "/p/proj") == .allow)
    #expect(developer.inspect(command: "rm -rf /tmp/roles-x /private/var/folders/ab/T/y", cwd: "/p/proj") == .allow)
    #expect(developer.inspect(command: "rm -rf /p/proj/build && swift build", cwd: "/p/proj") == .allow)
    for risky in ["rm -rf ../other", "rm -rf ~/Library", "rm -rf $HOME/x", "rm -rf /p/other", "rm -rf /", "rm -rf .", "rm -fr /p/projx", "rm -r /Users/x"] {
        #expect(developer.inspect(command: risky, cwd: "/p/proj") == .ask, "\(risky)")
    }
    #expect(developer.inspect(command: "git push origin main", cwd: "/p/proj") == .allow)
    #expect(developer.inspect(command: "cd /tmp && sudo rm -rf /") == .deny(ClaudeIntegration.roleDenyRefusal("sudo")))
    // The deny list stays a denial; its text rules out a workaround and names the app's tool where one exists.
    #expect(ClaudeIntegration.roleDenyRefusal("sudo", language: .russian).hasPrefix("Команда запрещена ролью: sudo. Обход не допускается")
            && ClaudeIntegration.roleDenyRefusal("sudo", language: .english).hasPrefix("The role forbids this command: sudo. No workaround is allowed"))
    #expect(developer.inspect(command: "osascript -e 'tell app \"Safari\" to quit'") == .deny(ClaudeIntegration.roleDenyRefusal("osascript")))
    #expect(ClaudeIntegration.roleDenyRefusal("osascript", language: .english).contains("browser tools")
            && ClaudeIntegration.roleDenyRefusal("osascript", language: .russian).contains("инструменты браузера"))
    #expect(ClaudeIntegration.roleDenyRefusal("launchctl", language: .english).contains("`request_app_restart`")
            && ClaudeIntegration.roleDenyRefusal("launchctl", language: .russian).contains("`request_app_restart`"))
    #expect(!ClaudeIntegration.roleDenyRefusal("diskutil", language: .english).contains("request_app_restart"))
    // A direct `security` stays denied; the text names the project's Keychain items and the one request for another item.
    #expect(developer.inspect(command: "security find-generic-password -s api -w") == .deny(ClaudeIntegration.roleDenyRefusal("security")))
    #expect(ClaudeIntegration.roleDenyRefusal("security", language: .english).contains("Keychain items listed in the project settings")
            && ClaudeIntegration.roleDenyRefusal("security", language: .english).contains("`addKeychainItems`")
            && ClaudeIntegration.roleDenyRefusal("security", language: .russian).contains("`addKeychainItems`"))
    #expect(!ClaudeIntegration.roleDenyRefusal("sudo", language: .english).contains("addKeychainItems"))
    #expect(developer.inspect(command: "pseudo tool") == .allow && developer.inspect(command: "FOO=1 sudo ls") != .allow && developer.inspect(command: "echo hi; sudo ls") != .allow)
    #expect(developer.inspect(command: "git push --force origin main") != .allow)
    let unattended = ClaudeLaunchPolicy(preset(AgentRoleID.developer).profile, scheduled: true, userChromeEnabled: false)
    #expect(unattended.inspect(command: "rm -rf build") == .deny(ClaudeIntegration.unattendedRefusal()), "An unattended run must not wait")
    // Refusals that cannot ask name the route: one settings proposal when the inbox exists, the blocker in the final message.
    for outsideSandbox in [false, true] {
        let ru = ClaudeIntegration.unattendedRefusal(outsideSandbox: outsideSandbox, language: .russian)
        let en = ClaudeIntegration.unattendedRefusal(outsideSandbox: outsideSandbox, language: .english)
        #expect(ru.contains("Не ищи обход") && ru.contains("одно предложение настроек") && ru.contains("$SWITCHBOARD_SETTINGS_PROPOSALS") && ru.contains("блокер"))
        #expect(en.contains("Do not look for a workaround") && en.contains("one settings proposal") && en.contains("$SWITCHBOARD_SETTINGS_PROPOSALS") && en.contains("blocker"))
    }
    #expect(ClaudeIntegration.unattendedRefusal(outsideSandbox: true, language: .english).hasPrefix("A command outside the sandbox"))
    #expect(ClaudeIntegration.shellOffRefusal(language: .english).contains("only the user changes the chat's role")
            && ClaudeIntegration.shellOffRefusal(language: .russian).contains("роль чата меняет только он"))
    var offline = preset(AgentRoleID.developer).profile; offline.network = false
    let noNetwork = ClaudeLaunchPolicy(offline, scheduled: false, userChromeEnabled: false)
    if case .deny = noNetwork.inspect(command: "curl https://example.com") {} else { Issue.record("Network command must be denied") }
    #expect(noNetwork.inspect(command: "echo curl") == .allow)
    let editor = ClaudeLaunchPolicy(preset(AgentRoleID.editor).profile, scheduled: false, userChromeEnabled: false)
    #expect(!editor.inspectsCommands && editor.hooks == .null && !editor.permits(tool: "Bash") && editor.permits(tool: "Write"))
    #expect(!editor.permits(tool: "SendMessage"))
    let operatorPolicy = ClaudeLaunchPolicy(.unrestricted, scheduled: false, userChromeEnabled: true)
    #expect(operatorPolicy.permits(tool: "Bash") && operatorPolicy.permits(tool: "mcp__claude_ai_Gmail__send_message") && operatorPolicy.hooks == .null)
    let audit = ClaudeLaunchPolicy(preset(AgentRoleID.routineOperator).profile, scheduled: true, userChromeEnabled: false)
    #expect(audit.hooks != .null && audit.permissionMode == "bypassPermissions")
    #expect(ClaudeToolRule.matches("mcp__claude_ai_Gmail__send_message", "mcp__claude_ai_*__*send*"))
    #expect(!ClaudeToolRule.matches("mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_*__*send*"))
    #expect(ClaudeToolRule.matches("mcp__claude_ai_Gmail__label_message", "mcp__claude_ai_*__label*"))
}

// MARK: - Ledger

@Test func commandHookReadsQuotesHeredocsAndSubstitutionsLikeTheShell() {
    let developer = ClaudeLaunchPolicy(preset(AgentRoleID.developer).profile, scheduled: false, userChromeEnabled: false)
    func allowed(_ command: String) -> Bool { developer.inspect(command: command, cwd: "/p/proj") == .allow }
    // Data, not commands: quoted heredocs, single quotes, plain words in double quotes, commit messages.
    #expect(allowed("python3 -I - <<'EOF'\nprint('the role forbids `security` and sudo here')\nEOF\necho done"))
    #expect(allowed("cat > notes.md <<\"END\"\nRun `sudo ls` later.\nEND"))
    #expect(allowed("echo 'sudo ls; $(sudo ls) `security x`'"))
    #expect(allowed("git commit -m \"Explain why sudo and osascript are denied\""))
    #expect(allowed("grep -n \"sudo \" Sources/x.swift | head"))
    #expect(allowed("cat <<-EOF\n\tplain text with sudo\n\tEOF"))
    // Commands, even when nested or wrapped.
    for risky in ["echo \"$(sudo ls)\"", "echo \"`security find-generic-password`\"", "x=$(sudo ls)", "echo `sudo ls`",
                  "bash -c \"sudo ls\"", "sh -c 'osascript -e beep'", "nohup sudo ls &", "env A=1 sudo ls", "time sudo ls",
                  "cat <<EOF\n$(sudo ls)\nEOF", "(cd /tmp && sudo ls)", "ls | xargs sudo rm", "echo ok\nsudo ls"] {
        #expect(!allowed(risky), "\(risky)")
    }
    // An unclosed quote never hides what came before it.
    #expect(!allowed("sudo ls; echo \"unterminated"))
    #expect(ShellSegments.commands("a | b && c; d\ne").count == 5)
}

@Test func capabilityLedgerStoresRowsAggregatesAndSweeps() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = CapabilityLedger(file: root.appendingPathComponent("ledger.sqlite"), flushDelay: .milliseconds(10))
    let project = UUID()
    let old = Date().addingTimeInterval(-40 * 86_400)
    for index in 0..<250 {
        await ledger.record(.init(date: index == 0 ? old : Date(), chatID: "chat", runID: nil, projectID: project, roleID: AgentRoleID.developer, agent: "claude",
                                  record: .init(tool: "Bash", capability: .shell, target: "swift build \(index)", decision: index % 2 == 0 ? .used : .hookDenied), audit: false))
    }
    await ledger.flush()
    #expect(try await ledger.count() == 250)
    let recent = try await ledger.recent(days: 7)
    #expect(recent.count == 249 && recent.first?.target == "swift build 249" && recent.allSatisfy { $0.projectID == project })
    let daily = try await ledger.daily(days: 7)
    #expect(daily.map(\.count).reduce(0, +) == 249 && Set(daily.map(\.decision)) == [.used, .hookDenied])
    try await ledger.sweep()
    #expect(try await ledger.count() == 249)
    #expect(await ledger.lastError == nil)
}

@Test func capabilityLedgerBatchesOnOneWALConnectionReadableByAnotherOne() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ledger.sqlite")
    let ledger = CapabilityLedger(file: file, flushDelay: .milliseconds(300))
    func decision(_ index: Int) -> CapabilityDecision {
        .init(chatID: "chat", runID: nil, projectID: nil, roleID: AgentRoleID.developer, agent: "claude",
              record: .init(tool: "Bash", capability: .shell, target: "step \(index)", decision: .used), audit: false)
    }
    // Rows recorded within the delay share one commit.
    for index in 0..<20 { await ledger.record(decision(index)) }
    #expect(await ledger.commitCount == 0)
    let deadline = Date().addingTimeInterval(15)
    while await ledger.commitCount < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await ledger.commitCount == 1)
    // Another connection (an older build opens the file per write) reads the rows while the ledger keeps its own open.
    func raw(_ sql: String) throws -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let db = handle else { throw ClientFailure("open") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
    #expect(try raw("PRAGMA journal_mode") == "wal")
    #expect(try raw("SELECT COUNT(*) FROM decisions") == "20")
    // Quit writes the buffer at once; a second ledger on the same file sees every row.
    await ledger.record(decision(20))
    await ledger.flush()
    #expect(await ledger.commitCount == 2)
    #expect(try await CapabilityLedger(file: file).count() == 21)
    #expect(await ledger.lastError == nil)
}

// MARK: - Browser rights

@Test func browserRightsFollowTheRoleAndUnattendedRunsNeverImportAnySite() {
    func policy(_ id: String, scheduled: Bool = false) -> BrowserLaunchPolicy { BrowserLaunchPolicy(preset(id).profile, scheduled: scheduled) }
    #expect(policy(AgentRoleID.reader) == .init(allowEval: false, allowUpload: false, importScope: .any))
    #expect(policy(AgentRoleID.editor) == .init(allowEval: false, allowUpload: false, importScope: .any))
    #expect(policy(AgentRoleID.developer) == .init(allowEval: true, allowUpload: true, importScope: .any))
    #expect(policy(AgentRoleID.fullOperator) == .init(allowEval: true, allowUpload: true, importScope: .any))
    // Routines keep eval (the ledger shows they rely on it) but import only their own sites.
    #expect(policy(AgentRoleID.routineOperator, scheduled: true) == .init(allowEval: true, allowUpload: true, importScope: .listed))
    #expect(policy(AgentRoleID.fullOperator, scheduled: true).importScope == .listed)
    var none = preset(AgentRoleID.developer).profile; none.cookieImport = .none
    #expect(BrowserLaunchPolicy(none, scheduled: false).importScope == .none)
    let args = BrowserEnvironmentStore.serverArguments(resources: URL(fileURLWithPath: "/r"), root: URL(fileURLWithPath: "/b"), environment: UUID(),
                                                       grant: nil, policy: policy(AgentRoleID.editor))
    #expect(!args.contains("--allow-eval") && !args.contains("--allow-upload") && Array(args.suffix(2)) == ["--import-scope", "any"])
    let developer = BrowserEnvironmentStore.serverArguments(resources: URL(fileURLWithPath: "/r"), root: URL(fileURLWithPath: "/b"), environment: UUID(),
                                                            grant: nil, policy: policy(AgentRoleID.developer))
    #expect(developer.contains("--allow-eval") && developer.contains("--allow-upload"))
}

// MARK: - Claude advisor

@Test func claudeAdvisorAttachesOnlyToAWeakerMainModel() throws {
    #expect(ClaudeAdvisor.attached("opus", mainModel: "claude-sonnet-5-5") == "opus")
    #expect(ClaudeAdvisor.attached("opus", mainModel: "claude-haiku-4-5-20251001") == "opus")
    #expect(ClaudeAdvisor.attached("opus", mainModel: "claude-opus-5-5") == nil)
    #expect(ClaudeAdvisor.attached("fable", mainModel: "claude-opus-5-5") == "fable")
    #expect(ClaudeAdvisor.attached("fable", mainModel: "claude-fable-5-1") == nil)
    // The CLI default and unknown models stay without an advisor; so does no setting.
    #expect(ClaudeAdvisor.attached("opus", mainModel: "") == nil)
    #expect(ClaudeAdvisor.attached("opus", mainModel: "gpt-5.5") == nil)
    #expect(ClaudeAdvisor.attached(nil, mainModel: "claude-sonnet-5-5") == nil && ClaudeAdvisor.attached("", mainModel: "sonnet") == nil)

    let advised = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: preset(AgentRoleID.editor).profile(for: project()),
                                                  model: "claude-sonnet-5-5", effort: nil, advisor: "opus")
    #expect(try settings(advised)["advisorModel"] == .string("opus") && !advised.contains("--advisor"))
    let plain = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: preset(AgentRoleID.editor).profile(for: project()),
                                                model: "claude-sonnet-5-5", effort: nil)
    #expect(try settings(plain)["advisorModel"] == .null)
    // Requests saved before the advisor existed still decode.
    let selection = AgentModelSelection(context: AgentContext(connection: .appClaude, accountRevision: UUID()), model: "m", effort: "high")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as! [String: Any]
    object.removeValue(forKey: "advisor")
    let decoded = try JSONDecoder().decode(AgentModelSelection.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.advisor == nil && decoded.model == "m")
}

// MARK: - Folders for every project

@Test func sharedRootsReachOnlyRolesThatAcceptExtraFolders() {
    let shared: [AgentPermissionProfile.Root] = [.init(path: "/Users/me/Public/self-projects/", writable: true)]
    let own = project(extraRoots: [.init(path: "/Users/me/wiki", writable: false)])
    let developer = preset(AgentRoleID.developer).profile(for: own, sharedRoots: shared)
    #expect(developer.extraRoots == [.init(path: "/Users/me/wiki", writable: false), .init(path: "/Users/me/Public/self-projects", writable: true)])
    #expect(developer.commandSandbox?.write.contains("/Users/me/Public/self-projects") == true)
    #expect(preset(AgentRoleID.routineOperator).profile(for: own, sharedRoots: shared).extraRoots.contains { $0.path == "/Users/me/Public/self-projects" })
    for id in [AgentRoleID.editor, AgentRoleID.reader] {
        let profile = preset(id).profile(for: own, sharedRoots: shared)
        #expect(profile.extraRoots.isEmpty && profile.commandSandbox == nil)
    }
    // A folder the project already has keeps write access if either side grants it; the project itself is never added.
    let both = preset(AgentRoleID.developer).profile(for: own, sharedRoots: [.init(path: "/Users/me/wiki", writable: true), .init(path: own.path, writable: true)])
    #expect(both.extraRoots == [.init(path: "/Users/me/wiki", writable: true)])
    // Nothing is granted until the user adds a folder.
    #expect(preset(AgentRoleID.developer).profile(for: project()).extraRoots.isEmpty)
}

@Test func sharedRootsRefuseTheHomeAndTheDataFolder() {
    let home = "/Users/me", data = ["/Users/me/Library/Application Support/Switchboard", "/Users/me/Library/Application Support/Context Desk"]
    func refusal(_ path: String) -> SharedRoots.Refusal? { SharedRoots.refusal(path, home: home, dataRoots: data) }
    #expect(refusal("~") == .home && refusal("/Users/me/") == .home)
    #expect(refusal("~/Library/Application Support/Switchboard") == .dataFolder)
    #expect(refusal("/Users/me/Library/Application Support/Context Desk/chats") == .dataFolder)
    #expect(refusal("/Users/me/Library") == .dataFolder && refusal("/") == .dataFolder)
    #expect(refusal("relative/folder") == .notAbsolute)
    #expect(refusal("~/Public/self-projects") == nil && SharedRoots.canonical("~/Public/self-projects/", home: home) == "/Users/me/Public/self-projects")
    let kept = SharedRoots.usable([.init(path: "~", writable: true), .init(path: data[0], writable: true), .init(path: "~/Public/x/../self-projects", writable: false),
                                   .init(path: "/Users/me/Public/self-projects", writable: true)], home: home, dataRoots: data)
    #expect(kept == [.init(path: "/Users/me/Public/self-projects", writable: true)])
    // The app's real data folder is refused without any arguments, so a stored entry can never reach a profile.
    #expect(SharedRoots.refusal(Locations.root.path) == .dataFolder && SharedRoots.refusal(NSHomeDirectory()) == .home)
    #expect(preset(AgentRoleID.developer).profile(for: project(), sharedRoots: [.init(path: NSHomeDirectory(), writable: true)]).extraRoots.isEmpty)
    #expect(SharedRoots.Refusal.home.message("~", language: .english).contains("home folder"))
}

@Test func sharedRootsRoundTripAndOldStatesDecodeWithoutThem() throws {
    var state = SavedState()
    state.sharedRoots = [.init(path: "/Users/me/Public/self-projects", writable: true)]
    let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    #expect(decoded.sharedRoots == state.sharedRoots)
    var old = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedState())) as? [String: Any])
    old.removeValue(forKey: "sharedRoots")
    let legacy = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.sharedRoots == nil)
}

@Test func scheduledJobsGetSharedRootsAsSet() throws {
    var job = ManagedJob(); job.roleID = AgentRoleID.routineOperator
    var own = project(); own.jobRoleID = AgentRoleID.routineOperator
    let descriptor = AgentDescriptor(context: .init(connection: .originalCodex, accountRevision: UUID()), identityMode: .appOwnedHome,
                                     capabilities: [.scheduledExecution], permissions: .codexProjectPolicy, routes: [.direct])
    let shared: [AgentPermissionProfile.Root] = [.init(path: "/Users/me/Public/self-projects", writable: true)]
    let request = job.executionRequest(runID: UUID(), project: own, descriptor: descriptor, sharedRoots: shared)
    #expect(request.permissions == .profile(preset(AgentRoleID.routineOperator).profile(for: own, sharedRoots: shared), root: own.path))
    guard case .profile(let profile, _) = request.permissions else { Issue.record("expected a role profile"); return }
    #expect(profile.extraRoots == shared)
}
