import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ClaudeAdapter

private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func skill(_ name: String, in root: URL, header: String) throws {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try header.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

@Test func skillCatalogReadsFrontMatterAndPrefersTheEarlierRoot() throws {
    let first = try folder(), second = try folder()
    try skill("hours-tracking", in: first, header: "---\nname: hours-tracking\ndescription: Reconcile and log work hours.\n---\n# Hours\n")
    try skill("folded", in: first, header: "---\nname: \"folded\"\ndescription: >\n  Two lines\n  joined.\n---\n")
    try skill("no-header", in: first, header: "# Just text\n")
    try skill("hours-tracking", in: second, header: "---\nname: hours-tracking\ndescription: Shadowed copy\n---\n")
    try skill("grill-me", in: second, header: "---\r\nname: grill-me\r\ndescription: 'Ask hard questions'\r\n---\r\n")
    try FileManager.default.createDirectory(at: second.appendingPathComponent("empty"), withIntermediateDirectories: true)

    let skills = SkillCatalog.scan([first, second, first.appendingPathComponent("missing")])
    #expect(skills.map(\.name) == ["folded", "grill-me", "hours-tracking"])
    #expect(skills.first { $0.name == "hours-tracking" }?.description == "Reconcile and log work hours.")
    #expect(skills.first { $0.name == "hours-tracking" }?.path == first.appendingPathComponent("hours-tracking").path)
    #expect(skills.first { $0.name == "folded" }?.description == "Two lines joined.")
    #expect(skills.first { $0.name == "grill-me" }?.description == "Ask hard questions")
}

@Test func claudeSkillPluginsLinkTheSourceFoldersAndDropMissingOnes() throws {
    let home = try folder(), user = try folder()
    #expect(try ClaudeSkills.pluginRoot(home: home, user: nil) == nil)
    try skill("hours-tracking", in: user, header: "---\nname: hours-tracking\ndescription: x\n---\n")

    let root = try #require(try ClaudeSkills.pluginRoot(home: home, user: user))
    let manager = FileManager.default
    #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("user/skills").path) == user.path)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("user/.claude-plugin/plugin.json"))) as? [String: Any]
    #expect(manifest?["name"] as? String == "user")
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("app").path))

    // The profile's own folder joins as `app`; a removed source drops its plugin without touching the source.
    try manager.createDirectory(at: home.appendingPathComponent("skills"), withIntermediateDirectories: true)
    _ = try ClaudeSkills.pluginRoot(home: home, user: user)
    #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("app/skills").path) == home.appendingPathComponent("skills").path)
    _ = try ClaudeSkills.pluginRoot(home: home, user: home.appendingPathComponent("gone"))
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("user").path))
    #expect(manager.fileExists(atPath: user.appendingPathComponent("hours-tracking/SKILL.md").path))
    #expect(ClaudeSkills.displayName("user:hours-tracking") == "hours-tracking" && ClaudeSkills.displayName("plain") == "plain")
}

@Test func claudeChatsWithSkillsLoadThePluginsInsteadOfSafeMode() throws {
    let profile = AgentRoleCatalog.preset(AgentRoleID.editor).profile
    let plain = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: profile, model: "", effort: nil)
    #expect(plain.contains("--safe-mode") && !plain.contains { $0.hasPrefix("--plugin-dir") })

    let skilled = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: profile, model: "", effort: nil, skills: "/tmp/plugins")
    #expect(skilled.contains("--plugin-dir=/tmp/plugins") && !skilled.contains("--safe-mode") && !skilled.contains("--disable-slash-commands"))
    #expect(skilled.contains("--strict-mcp-config") && skilled.contains("--setting-sources"))
    let settings = try #require(skilled.firstIndex(of: "--settings").map { skilled[$0 + 1] })
    let object = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
    #expect(object?["disableBundledSkills"] as? Bool == true)
    #expect(skilled.contains { $0.contains("Skill,AskUserQuestion") })

    let full = AgentRoleCatalog.preset(AgentRoleID.routineOperator).profile
    let connectors = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: full, model: "", effort: nil, skills: "/tmp/plugins")
    #expect(connectors.contains("--plugin-dir=/tmp/plugins") && !connectors.contains("--disable-slash-commands"))
}

@Test func skillLoadsShowAsSkillRows() throws {
    #expect(ToolCallText.skillName(reading: "/Users/me/.codex/skills/hours-tracking/SKILL.md") == "hours-tracking")
    #expect(ToolCallText.skillName(reading: "/Users/me/notes/README.md") == nil)
    #expect(ToolCallText.read("/a/skills/grill-me/SKILL.md") == L10n.text("Скилл: grill-me", "Skill: grill-me"))

    let call = ClaudeToolCalls.toolCall(id: "t", name: "Skill", input: .object(["skill": .string("user:hours-tracking"), "args": .string("what is unlogged")]))
    #expect(call.title == L10n.text("Скилл: hours-tracking", "Skill: hours-tracking") && call.inputSummary == "what is unlogged")
}
