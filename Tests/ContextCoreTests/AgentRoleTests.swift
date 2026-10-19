import Foundation
import Testing
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
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(.unrestricted) == [.browser])
    // Audit mode is judged by what actually runs.
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(preset(AgentRoleID.routineOperator).profile) == [.browser])
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
    #expect(value(after: "--tools", in: editor) == "Read,Glob,Grep,Write,Edit,AskUserQuestion")
    #expect(value(after: "--permission-mode", in: editor) == "default")
    #expect(!editor.contains("--settings") && !editor.contains("--agents") && !editor.contains("--chrome") && !editor.contains("--add-dir"))
    #expect(editor == (try ClaudeIntegration.arguments(id: value(after: "--session-id", in: editor)!, resumed: false, access: .standard, model: "", effort: nil, projectAgents: #"{"w":{"description":"d","prompt":"p"}}"#, userChrome: true)))
    let operatorArgs = try claudeArguments(preset(AgentRoleID.fullOperator), agents: #"{"w":{"description":"d","prompt":"p"}}"#)
    #expect(!operatorArgs.contains("--strict-mcp-config") && !operatorArgs.contains("--safe-mode") && !operatorArgs.contains("--restricted") && !operatorArgs.contains("--tools"))
    #expect(value(after: "--permission-mode", in: operatorArgs) == "bypassPermissions" && operatorArgs.contains("--chrome"))
    #expect(try settings(operatorArgs)["permissions"]["ask"].array.count == ClaudeIntegration.connectorApprovalRules.count)
    #expect(value(after: "--agents", in: operatorArgs) == #"{"w":{"description":"d","prompt":"p"}}"#)
    let scheduled = try claudeArguments(preset(AgentRoleID.fullOperator), scheduled: true)
    #expect(!scheduled.contains("--settings") && !scheduled.contains("--chrome"))
    // Audit mode runs exactly like the operator; only the hook is registered to record.
    let audit = try claudeArguments(preset(AgentRoleID.routineOperator), scheduled: true)
    #expect(audit == (try ClaudeIntegration.arguments(id: value(after: "--session-id", in: audit)!, resumed: false, access: .fullAccess, model: "", effort: nil, scheduled: true, userChrome: true)))
}

@Test func claudeEncodesReaderDeveloperAndRoutineRoles() throws {
    let project = project(extraRoots: [.init(path: "/Users/me/fringe", writable: true)])
    let reader = try claudeArguments(preset(AgentRoleID.reader), browser: true)
    #expect(value(after: "--tools", in: reader) == "Read,Glob,Grep,Write,Edit,WebFetch,WebSearch,Agent,AskUserQuestion")
    #expect(value(after: "--permission-mode", in: reader) == "default" && reader.contains("--restricted") && !reader.contains("--strict-mcp-config"))
    let readerSettings = try settings(reader)["permissions"]
    #expect(readerSettings["allow"].array == [.string("Write(research/**)"), .string("Edit(research/**)"), .string("WebFetch"), .string("WebSearch"), .string("mcp__claude_ai_*")])
    #expect(readerSettings["deny"].array.contains(.string("Read(~/.ssh/**)")))
    #expect(readerSettings["deny"].array.contains { ($0.string ?? "").hasPrefix("mcp__claude_ai_*__*send") })
    #expect(reader.contains("--mcp-config") && reader.contains("mcp__switchboard_browser"))
    let developer = try claudeArguments(preset(AgentRoleID.developer), agents: #"{"w":{"description":"d","prompt":"p","tools":["Read","Bash","Write"]}}"#, project: project)
    #expect(value(after: "--tools", in: developer) == "Read,Glob,Grep,Write,Edit,Bash,WebFetch,WebSearch,Agent,AskUserQuestion")
    #expect(value(after: "--permission-mode", in: developer) == "acceptEdits" && !developer.contains("--restricted"))
    #expect(value(after: "--add-dir", in: developer) == "/Users/me/fringe" && developer.contains("--strict-mcp-config"))
    let developerSettings = try settings(developer)["permissions"]
    #expect(developerSettings["additionalDirectories"].array == [.string("/Users/me/fringe")] && developerSettings["allow"].array.contains(.string("Bash")))
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
    #expect(developer.inspect(command: "swift build") == .allow)
    #expect(developer.inspect(command: "rm -rf .build") == .ask)
    #expect(developer.inspect(command: "cd /tmp && sudo rm -rf /") == .deny(L10n.text("Команда запрещена ролью: sudo", "The role forbids this command: sudo")))
    #expect(developer.inspect(command: "pseudo tool") == .allow && developer.inspect(command: "FOO=1 sudo ls") != .allow && developer.inspect(command: "echo hi; sudo ls") != .allow)
    #expect(developer.inspect(command: "git push --force origin main") != .allow)
    let unattended = ClaudeLaunchPolicy(preset(AgentRoleID.developer).profile, scheduled: true, userChromeEnabled: false)
    if case .deny = unattended.inspect(command: "rm -rf build") {} else { Issue.record("An unattended run must not wait") }
    var offline = preset(AgentRoleID.developer).profile; offline.network = false
    let noNetwork = ClaudeLaunchPolicy(offline, scheduled: false, userChromeEnabled: false)
    if case .deny = noNetwork.inspect(command: "curl https://example.com") {} else { Issue.record("Network command must be denied") }
    #expect(noNetwork.inspect(command: "echo curl") == .allow)
    let editor = ClaudeLaunchPolicy(preset(AgentRoleID.editor).profile, scheduled: false, userChromeEnabled: false)
    #expect(!editor.inspectsCommands && editor.hooks == .null && !editor.permits(tool: "Bash") && editor.permits(tool: "Write"))
    let operatorPolicy = ClaudeLaunchPolicy(.unrestricted, scheduled: false, userChromeEnabled: true)
    #expect(operatorPolicy.permits(tool: "Bash") && operatorPolicy.permits(tool: "mcp__claude_ai_Gmail__send_message") && operatorPolicy.hooks == .null)
    let audit = ClaudeLaunchPolicy(preset(AgentRoleID.routineOperator).profile, scheduled: true, userChromeEnabled: false)
    #expect(audit.hooks != .null && audit.permissionMode == "bypassPermissions")
    #expect(ClaudeToolRule.matches("mcp__claude_ai_Gmail__send_message", "mcp__claude_ai_*__*send*"))
    #expect(!ClaudeToolRule.matches("mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_*__*send*"))
    #expect(ClaudeToolRule.matches("mcp__claude_ai_Gmail__label_message", "mcp__claude_ai_*__label*"))
}

// MARK: - Ledger

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
