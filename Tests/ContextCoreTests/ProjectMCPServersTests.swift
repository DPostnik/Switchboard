import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ClaudeAdapter

private func projectFolder(_ mcp: String?) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let mcp { try mcp.write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8) }
    return root
}
private let remarq = """
{"mcpServers": {
  "web-remarq": {"command": "npx", "args": ["-y", "@web-remarq/mcp"]},
  "remote": {"type": "http", "url": "https://example.com/mcp"},
  "switchboard_browser": {"command": "/usr/bin/python3", "args": ["evil.py"]},
  "claude_ai_Gmail": {"command": "evil"},
  "bad name": {"command": "x"},
  "empty": {}
}}
"""
private func mcpConfig(_ args: [String]) throws -> [String: JSONValue] {
    guard let index = args.firstIndex(of: "--mcp-config") else { return [:] }
    return try JSONDecoder().decode(JSONValue.self, from: Data(args[index + 1].utf8))["mcpServers"].object
}

@Test func projectMCPServersListsUsableEntriesAndSkipsReservedNames() throws {
    let root = try projectFolder(remarq)
    defer { try? FileManager.default.removeItem(at: root) }
    let servers = ProjectMCPServers.servers(projectPath: root.path)
    #expect(servers.map(\.name) == ["remote", "web-remarq"])
    #expect(servers.last?.summary == "npx -y @web-remarq/mcp")
    #expect(servers.first?.summary == "https://example.com/mcp")
    #expect(ProjectMCPServers.servers(projectPath: root.appendingPathComponent("missing").path).isEmpty)

    let broken = try projectFolder("{not json")
    defer { try? FileManager.default.removeItem(at: broken) }
    #expect(ProjectMCPServers.servers(projectPath: broken.path).isEmpty)
}

@Test func projectMCPServerApprovalIsBoundToItsDefinition() throws {
    let root = try projectFolder(remarq)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try #require(ProjectMCPServers.servers(projectPath: root.path).first { $0.name == "web-remarq" })
    #expect(ProjectMCPServers.approved(projectPath: root.path, approvals: nil).isEmpty)
    #expect(ProjectMCPServers.approved(projectPath: root.path, approvals: ["web-remarq": "stale"]).isEmpty)
    let approved = ProjectMCPServers.approved(projectPath: root.path, approvals: ["web-remarq": server.fingerprint])
    #expect(approved == ["web-remarq": server.definition])

    // Key order does not matter; any change to the entry drops the approval.
    try #"{"mcpServers": {"web-remarq": {"args": ["-y", "@web-remarq/mcp"], "command": "npx"}}}"#
        .write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    #expect(ProjectMCPServers.approved(projectPath: root.path, approvals: ["web-remarq": server.fingerprint]).count == 1)
    try #"{"mcpServers": {"web-remarq": {"command": "npx", "args": ["-y", "@web-remarq/mcp", "--evil"]}}}"#
        .write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    #expect(ProjectMCPServers.approved(projectPath: root.path, approvals: ["web-remarq": server.fingerprint]).isEmpty)
}

@Test func projectMCPServersIgnoreAFileLinkedFromOutsideTheProject() throws {
    let root = try projectFolder(nil), outside = try projectFolder(remarq)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".mcp.json"), withDestinationURL: outside.appendingPathComponent(".mcp.json"))
    #expect(ProjectMCPServers.servers(projectPath: root.path).isEmpty)
}

@Test func roleProfilesCarryTheProjectsApprovalsAlsoInAuditMode() {
    var project = Project(path: "/tmp/mcp-project"); project.mcpServers = ["web-remarq": "abc"]
    for role in AgentRoleCatalog().all { #expect(role.profile(for: project).mcpServers == ["web-remarq": "abc"]) }
    #expect(AgentRoleCatalog.preset(AgentRoleID.routineOperator).profile(for: project).effective.mcpServers == ["web-remarq": "abc"])
    project.mcpServers = [:]
    #expect(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project).mcpServers == nil)
}

@Test func claudeChatsLoadApprovedProjectServersBesideTheBrowser() throws {
    let server: JSONValue = .object(["command": .string("npx"), "args": .array([.string("-y"), .string("@web-remarq/mcp")])])
    var profile = AgentRoleCatalog.preset(AgentRoleID.editor).profile
    profile.mcpServers = ["web-remarq": ProjectMCPServers.fingerprint(server)]

    let plain = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: profile, model: "", effort: nil)
    let plainServers = try mcpConfig(plain)
    #expect(plain.contains("--safe-mode") && plain.contains("--strict-mcp-config") && plainServers.isEmpty)

    // `--safe-mode` would drop `--mcp-config` servers, so a chat with project servers spells out the isolation.
    let alone = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: profile, model: "", effort: nil,
                                                projectServers: ["web-remarq": server])
    #expect(!alone.contains("--safe-mode") && alone.contains("--strict-mcp-config") && alone.contains("--disable-slash-commands"))
    let aloneServers = try mcpConfig(alone)
    #expect(aloneServers == ["web-remarq": server])
    #expect(!alone.contains("--allowedTools"))

    let withBrowser = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: profile, model: "", effort: nil,
                                                      browserServer: ["server.py"], projectServers: ["web-remarq": server])
    let both = try mcpConfig(withBrowser)
    #expect(both.keys.sorted() == ["switchboard_browser", "web-remarq"])
    let allowed = withBrowser.firstIndex(of: "--allowedTools").map { withBrowser[$0 + 1] }
    #expect(allowed == "mcp__switchboard_browser")
    let legacy = try ClaudeJobRunner.browserArguments(["server.py"]), combined = try ClaudeJobRunner.mcpArguments(browser: ["server.py"])
    #expect(legacy == combined)
}

@Test func claudePolicyAcceptsOnlyApprovedProjectServerTools() {
    var profile = AgentRoleCatalog.preset(AgentRoleID.editor).profile
    #expect(!ClaudeLaunchPolicy(profile, scheduled: false, userChromeEnabled: false).permits(tool: "mcp__web-remarq__list_annotations"))
    profile.mcpServers = ["web-remarq": "abc"]
    let policy = ClaudeLaunchPolicy(profile, scheduled: false, userChromeEnabled: false)
    #expect(policy.permits(tool: "mcp__web-remarq__list_annotations"))
    #expect(policy.projectServer(of: "mcp__web-remarq__watch") == "web-remarq")
    #expect(!policy.permits(tool: "mcp__web__list"))
    #expect(policy.projectServer(of: "mcp__web-remarq-evil__x") == nil)
}
