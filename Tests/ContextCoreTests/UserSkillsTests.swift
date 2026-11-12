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
    #expect(ClaudeSkills.displayName("project:client-transcript") == "client-transcript")
}

// MARK: - Project skills (`.agents/skills`, `.claude/skills`)

func writeSkillFixture(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func skillHeader(_ name: String, _ description: String, extra: String = "") -> String {
    "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n# \(name)\n"
}

/// A project with skills in both folders, a shadowed name, links inside and outside, active front matter and the rest
/// of a `.claude/` folder that must never be exposed.
func projectSkillFixture() throws -> URL {
    let project = try folder(), outside = try folder(), manager = FileManager.default
    let agents = project.appendingPathComponent(".agents/skills"), claude = project.appendingPathComponent(".claude/skills")
    try writeSkillFixture(skillHeader("shared", "From .agents"), to: agents.appendingPathComponent("shared/SKILL.md"))
    try writeSkillFixture(skillHeader("only-agents", "Agents only", extra: "metadata:\n  description-en: x\n"), to: agents.appendingPathComponent("only-agents/SKILL.md"))
    try writeSkillFixture(skillHeader("shared", "From .claude"), to: claude.appendingPathComponent("shared/SKILL.md"))
    try writeSkillFixture(skillHeader("client-transcript", "Transcribe a client session"), to: claude.appendingPathComponent("client-transcript/SKILL.md"))
    try writeSkillFixture("print('ok')\n", to: claude.appendingPathComponent("client-transcript/scripts/run.py"))
    // A link to a skill folder elsewhere in the project is fine; links that leave the project are not.
    try writeSkillFixture(skillHeader("linked", "Kept elsewhere in the project"), to: project.appendingPathComponent("tools/linked/SKILL.md"))
    try manager.createSymbolicLink(at: claude.appendingPathComponent("linked"), withDestinationURL: project.appendingPathComponent("tools/linked"))
    try writeSkillFixture(skillHeader("escape", "Outside"), to: outside.appendingPathComponent("escape/SKILL.md"))
    try manager.createSymbolicLink(at: claude.appendingPathComponent("escape"), withDestinationURL: outside.appendingPathComponent("escape"))
    try writeSkillFixture(skillHeader("inner-escape", "Links out"), to: claude.appendingPathComponent("inner-escape/SKILL.md"))
    try writeSkillFixture("secret\n", to: outside.appendingPathComponent("secret.txt"))
    try manager.createSymbolicLink(at: claude.appendingPathComponent("inner-escape/data"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    try manager.createDirectory(at: claude.appendingPathComponent("file-escape"), withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: claude.appendingPathComponent("file-escape/SKILL.md"), withDestinationURL: outside.appendingPathComponent("escape/SKILL.md"))
    // Front matter the CLI acts on: never exposed.
    try writeSkillFixture(skillHeader("tools", "Wants Bash", extra: "allowed-tools: Bash\n"), to: claude.appendingPathComponent("tools/SKILL.md"))
    try writeSkillFixture(skillHeader("hooked", "Runs hooks", extra: "hooks:\n  PreToolUse: []\n"), to: claude.appendingPathComponent("hooked/SKILL.md"))
    try writeSkillFixture("# No front matter\n", to: claude.appendingPathComponent("plain/SKILL.md"))
    try manager.createDirectory(at: claude.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try writeSkillFixture("notes\n", to: claude.appendingPathComponent("README.md"))
    // The rest of `.claude/`: settings, hooks, commands, agents, MCP servers.
    try writeSkillFixture("{\"permissions\":{\"allow\":[\"Bash\"]}}", to: project.appendingPathComponent(".claude/settings.json"))
    try writeSkillFixture("#!/bin/sh\n", to: project.appendingPathComponent(".claude/hooks/pre.sh"))
    try writeSkillFixture("run me\n", to: project.appendingPathComponent(".claude/commands/deploy.md"))
    try writeSkillFixture("---\nname: a\n---\n", to: project.appendingPathComponent(".claude/agents/a.md"))
    try writeSkillFixture("{\"mcpServers\":{}}", to: project.appendingPathComponent(".mcp.json"))
    try writeSkillFixture("{\"mcpServers\":{}}", to: project.appendingPathComponent(".claude/.mcp.json"))
    return project
}

private func real(_ url: URL) -> String { ProjectSkills.realPath(url.path) ?? url.path }

@Test func projectSkillsComeFromBothFoldersAgentsFirstAndStayInsideTheProject() throws {
    let project = try projectSkillFixture()
    let skills = ProjectSkills.scan(projectPath: project.path)
    #expect(skills.map(\.name) == ["client-transcript", "linked", "only-agents", "shared"])
    #expect(skills.first { $0.name == "shared" }?.folder == real(project.appendingPathComponent(".agents/skills/shared")))
    #expect(skills.first { $0.name == "linked" }?.folder == real(project.appendingPathComponent("tools/linked")))
    // Missing folders are fine.
    #expect(ProjectSkills.scan(projectPath: try folder().path).isEmpty)
    #expect(ProjectSkills.scan(projectPath: "/nonexistent/project").isEmpty)
    #expect(ProjectSkills.descriptiveOnly(skillHeader("a", "b", extra: "license: MIT\nargument-hint: \"[file]\"\n")))
    #expect(!ProjectSkills.descriptiveOnly(skillHeader("a", "b", extra: "model: opus\n")))
    #expect(!ProjectSkills.descriptiveOnly("---\ndescription: no name\n---\n"))
}

@Test func projectSkillLinkFolderHoldsOnlySkillLinksAndFollowsChanges() throws {
    let project = try projectSkillFixture()
    let links = try folder(), manager = FileManager.default
    let first = try #require(try ProjectSkills.linkFolder(projectPath: project.path, root: links))
    #expect(first.folder.path.hasPrefix(links.path + "/") && first.folder.lastPathComponent == ProjectSkills.key(project.path))
    let entries = try manager.contentsOfDirectory(atPath: first.folder.path).sorted()
    #expect(entries == ["client-transcript", "linked", "only-agents", "shared"])
    for entry in entries {
        let target = try manager.destinationOfSymbolicLink(atPath: first.folder.appendingPathComponent(entry).path)
        #expect(target == first.skills.first { $0.name == entry }?.folder)
    }
    // Unchanged: same result. Removed skill: its link goes. No skill left: the folder goes, the project stays.
    #expect(try ProjectSkills.linkFolder(projectPath: project.path, root: links)?.skills == first.skills)
    try manager.removeItem(at: project.appendingPathComponent(".agents/skills/only-agents"))
    let second = try #require(try ProjectSkills.linkFolder(projectPath: project.path, root: links))
    #expect(second.skills.map(\.name) == ["client-transcript", "linked", "shared"])
    #expect(!manager.fileExists(atPath: first.folder.appendingPathComponent("only-agents").path))
    for source in ProjectSkills.sources { try manager.removeItem(at: project.appendingPathComponent(source)) }
    #expect(try ProjectSkills.linkFolder(projectPath: project.path, root: links) == nil)
    #expect(!manager.fileExists(atPath: first.folder.path))
    #expect(manager.fileExists(atPath: project.appendingPathComponent("tools/linked/SKILL.md").path))
}

@Test func claudeProjectSkillsArriveAsTheProjectPluginWithNothingElseFromTheClaudeFolder() throws {
    let project = try projectSkillFixture()
    let home = try folder(), user = try folder(), links = try folder(), manager = FileManager.default
    try skill("hours-tracking", in: user, header: "---\nname: hours-tracking\ndescription: x\n---\n")

    let plugins = try #require(try ClaudeSkills.plugins(home: home, user: user, project: project.path, links: links))
    let root = URL(fileURLWithPath: plugins.root)
    #expect(root.path == home.appendingPathComponent("project-skill-plugins/" + ProjectSkills.key(project.path)).path)
    #expect(try manager.contentsOfDirectory(atPath: root.path).sorted() == ["project", "user"])
    #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("user/skills").path) == user.path)
    let vetted = links.appendingPathComponent(ProjectSkills.key(project.path))
    #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("project/skills").path) == vetted.path)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("project/.claude-plugin/plugin.json"))) as? [String: Any]
    #expect(manifest?["name"] as? String == "project")
    // The project plugin is a manifest and a link to the vetted folder; that folder holds only skill links.
    #expect(try manager.contentsOfDirectory(atPath: root.appendingPathComponent("project").path).sorted() == [".claude-plugin", "skills"])
    let exposed = try manager.contentsOfDirectory(atPath: vetted.path).sorted()
    #expect(exposed == ["client-transcript", "linked", "only-agents", "shared"])
    for leaked in ["settings.json", "hooks", "commands", "agents", ".mcp.json", "tools", "hooked", "escape", "inner-escape", "file-escape"] {
        #expect(!exposed.contains(leaked))
    }
    #expect(plugins.projectSkills.contains("shared=" + real(project.appendingPathComponent(".agents/skills/shared"))))

    // The same folders give the same plugins: no relaunch while nothing changed; a changed set changes the identity.
    #expect(try ClaudeSkills.plugins(home: home, user: user, project: project.path, links: links) == plugins)
    try writeSkillFixture(skillHeader("new-skill", "Added later"), to: project.appendingPathComponent(".claude/skills/new-skill/SKILL.md"))
    let changed = try #require(try ClaudeSkills.plugins(home: home, user: user, project: project.path, links: links))
    #expect(changed.root == plugins.root && changed.projectSkills != plugins.projectSkills)

    // A project without skills and a launch without a project keep the shared folder.
    let plain = try ClaudeSkills.plugins(home: home, user: user, project: try folder().path, links: links)
    #expect(plain == ClaudeSkills.Plugins(root: home.appendingPathComponent("skill-plugins").path, projectSkills: []))
    #expect(try ClaudeSkills.plugins(home: home, user: user, project: nil, links: links)?.root == plain?.root)
    #expect(try ClaudeSkills.plugins(home: try folder(), user: nil, project: try folder().path, links: links) == nil)

    // Sandboxed commands read the vetted folder (skill scripts); its links resolve inside the project.
    #expect(ClaudeIntegration.sandboxReads(home: nil, skills: plugins.root).contains { $0.hasSuffix("/" + ProjectSkills.key(project.path)) })
}

@Test func claudeLaunchWithProjectSkillsNamesThePrefix() throws {
    let profile = AgentRoleCatalog.preset(AgentRoleID.editor).profile
    func prompt(_ projectSkills: Bool) throws -> String {
        let arguments = try ClaudeIntegration.arguments(id: "s", resumed: false, permissions: profile, model: "", effort: nil,
                                                        skills: "/tmp/plugins", projectSkills: projectSkills)
        #expect(arguments.contains("--setting-sources") && arguments.contains("--plugin-dir=/tmp/plugins"))
        return try #require(arguments.firstIndex(of: "--append-system-prompt").map { arguments[$0 + 1] })
    }
    #expect(try prompt(true).contains("project:<"))
    #expect(try !prompt(false).contains("project:<"))
}
