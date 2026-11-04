import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ClaudeAdapter

private func preset(_ id: String) -> AgentRole { AgentRoleCatalog.preset(id) }

@Test func roleAddOnsWidenOnlyWhatTheyName() {
    let project = Project(path: "/tmp/addons")
    let developer = preset(AgentRoleID.developer).profile(for: project)
    let mail = preset(AgentRoleID.developer).profile(for: project, addOns: [.mail])
    #expect(developer.connectors == .off && mail.connectors == .askWrites)
    var rest = mail; rest.connectors = developer.connectors
    #expect(rest == developer)
    let chrome = preset(AgentRoleID.developer).profile(for: project, addOns: [.userChrome])
    #expect(chrome.browser == .appAndUserChrome && chrome.connectors == .off)
    // A role that already allows more keeps it; audit mode runs as recorded.
    #expect(preset(AgentRoleID.fullOperator).profile(for: project, addOns: [.mail]).connectors == .all)
    #expect(preset(AgentRoleID.routineOperator).profile(for: project, addOns: [.mail, .userChrome])
            == preset(AgentRoleID.routineOperator).profile(for: project))
}

@Test func chatAddOnsFollowTheProjectUntilTheChatPicksItsOwn() {
    var project = Project(path: "/tmp/addons")
    project.chatRoleAddOns = ["mail", "future-add-on"]
    var chat = Chat(id: "c", projectID: project.id, title: "t", model: "m")
    #expect(chat.resolvedAddOns(in: project) == [.mail])
    chat.roleAddOns = []
    #expect(chat.resolvedAddOns(in: project).isEmpty)
    chat.roleAddOns = ["userChrome"]
    #expect(chat.resolvedAddOns(in: project) == [.userChrome])
}

@Test func claudeChromeAddOnLaunchesTheUsersChromeWithoutConnectors() throws {
    let project = Project(path: "/tmp/addons")
    let profile = preset(AgentRoleID.developer).profile(for: project, addOns: [.userChrome])
    let arguments = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: profile, model: "", effort: nil, userChrome: true)
    #expect(arguments.contains("--chrome") && arguments.contains("--strict-mcp-config"))
    // `--safe-mode` would drop the Chrome server.
    #expect(!arguments.contains("--safe-mode"))
    // Off in Settings, or in a scheduled run, the add-on adds nothing.
    let off = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: profile, model: "", effort: nil, userChrome: false)
    #expect(!off.contains("--chrome"))
    let scheduled = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: profile, model: "", effort: nil, scheduled: true, userChrome: true)
    #expect(!scheduled.contains("--chrome"))
}

@Test func claudeMailAddOnLoadsConnectorsWithWritesAsked() throws {
    let project = Project(path: "/tmp/addons")
    let profile = preset(AgentRoleID.developer).profile(for: project, addOns: [.mail])
    let arguments = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: profile, model: "", effort: nil)
    #expect(!arguments.contains("--strict-mcp-config"))
    let policy = ClaudeLaunchPolicy(profile, scheduled: false, userChromeEnabled: false)
    #expect(policy.permits(tool: "mcp__claude_ai_Gmail__search_threads"))
    #expect(policy.allowRules.contains("mcp__claude_ai_*"))
    #expect(policy.askRules.contains { ClaudeToolRule.matches("mcp__claude_ai_Gmail__send_message", $0) })
}
