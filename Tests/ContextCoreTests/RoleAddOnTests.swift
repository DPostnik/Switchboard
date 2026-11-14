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

@Test func claudeChromeAddOnUnderTheBoundaryUsesTheAppsOwnChromeServer() throws {
    let project = Project(path: "/tmp/addons")
    let profile = preset(AgentRoleID.developer).profile(for: project, addOns: [.userChrome])
    let server = ["-I", "/app/UserChromeRuntime/server.py", "mcp", "--chat-id", "c"]
    func arguments(boundary: Bool, server: [String]?, scheduled: Bool = false, enabled: Bool = true) throws -> [String] {
        try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: profile, model: "", effort: nil, scheduled: scheduled,
                                        userChrome: enabled, userChromeServer: server, boundary: boundary)
    }
    func servers(_ arguments: [String]) throws -> JSONValue {
        let config = try #require(arguments.firstIndex(of: "--mcp-config").map { arguments[$0 + 1] })
        return try JSONDecoder().decode(JSONValue.self, from: Data(config.utf8))["mcpServers"]
    }
    func prompt(_ arguments: [String]) -> String { arguments.firstIndex(of: "--append-system-prompt").map { arguments[$0 + 1] } ?? "" }
    // Under the boundary: the app's server, no `--chrome`, guidance for its tools; the server is not pre-allowed.
    let inside = try arguments(boundary: true, server: server)
    #expect(!inside.contains("--chrome") && !inside.contains("--safe-mode") && inside.contains("--strict-mcp-config"))
    #expect(try servers(inside)[ClaudeIntegration.userChromeServerName]["args"].array.compactMap(\.string) == server)
    #expect(try servers(inside)[ClaudeIntegration.userChromeServerName]["command"].string == "/usr/bin/python3")
    #expect(!inside.contains("--allowedTools"))
    #expect(prompt(inside).contains("mcp__switchboard_user_chrome__") && !prompt(inside).contains("mcp__claude-in-chrome__"))
    // Outside the boundary (the CLI sandbox, also a token fallback) the CLI's own bridge stays, whatever the grant.
    let outside = try arguments(boundary: false, server: server)
    #expect(outside.contains("--chrome"))
    #expect(try servers(outside).object.isEmpty)
    #expect(prompt(outside).contains("mcp__claude-in-chrome__") && !prompt(outside).contains("mcp__switchboard_user_chrome__"))
    // Negative: off in Settings or in a scheduled run the add-on attaches neither.
    for quiet in [try arguments(boundary: true, server: server, enabled: false), try arguments(boundary: true, server: server, scheduled: true)] {
        #expect(!quiet.contains("--chrome"))
        #expect(try servers(quiet)[ClaudeIntegration.userChromeServerName] == .null)
        #expect(!prompt(quiet).contains("switchboard_user_chrome"))
    }
    // The role answers both tool families only with the add-on.
    let policy = ClaudeLaunchPolicy(profile, scheduled: false, userChromeEnabled: true, boundary: true)
    #expect(policy.permits(tool: "mcp__switchboard_user_chrome__switchboard_user_chrome_open") && policy.permits(tool: "mcp__claude-in-chrome__navigate"))
    let plain = ClaudeLaunchPolicy(preset(AgentRoleID.developer).profile(for: project), scheduled: false, userChromeEnabled: true, boundary: true)
    #expect(!plain.permits(tool: "mcp__switchboard_user_chrome__switchboard_user_chrome_open"))
    #expect(ClaudeIntegration.capability(tool: "mcp__switchboard_user_chrome__switchboard_user_chrome_read", input: .null, cwd: nil) == .browser)
    for language in [AppLanguage.russian, .english] {
        let text = ClaudeIntegration.appChromeInstructions(language: language)
        #expect(text.contains("switchboard_user_chrome_list") && text.contains("leaseId") && text.contains("switchboard_browser"))
        // The extension's newer tools: coordinate clicks, zoom, focused typing, form values, frames.
        #expect(["triple_click", "`x`,`y`", "clip", "set_value", "waitSeconds", "frameId", "cmd+a"].allSatisfy { text.contains($0) })
    }
    // The candidate rule shared with the settings proposal review.
    #expect(!ClaudeIntegration.boundaryCandidate(profile, userChromeEnabled: true))
    #expect(ClaudeIntegration.boundaryCandidate(profile, userChromeEnabled: true, userChromeReady: true))
    #expect(ClaudeIntegration.boundaryCandidate(profile, userChromeEnabled: false))
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
