import Foundation
import ContextCore
import Testing
@testable import ClaudeAdapter

@Test func claudeChatsReceiveProjectInstructionsDespiteIsolatedSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    #expect(ProjectInstructions.prompt(projectPath: root.path) == nil)

    // CLAUDE.md imports are expanded; files outside the project are not read.
    try "secret".write(to: outside, atomically: true, encoding: .utf8)
    try "Commit after build.".write(to: root.appendingPathComponent("rules.md"), atomically: true, encoding: .utf8)
    try "@rules.md\n@\(outside.path)\n@../\(outside.lastPathComponent)".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    let fallback = try #require(ProjectInstructions.prompt(projectPath: root.path, language: .english))
    #expect(fallback.hasPrefix("Project instructions from CLAUDE.md"))
    #expect(fallback.contains("Commit after build.") && !fallback.contains("secret"))

    try "Push after verification.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    let rules = try #require(ProjectInstructions.prompt(projectPath: root.path, language: .russian))
    #expect(rules.hasPrefix("Инструкции проекта из AGENTS.md") && rules.contains("Push after verification."))

    let args = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .standard, model: "", effort: nil, projectInstructions: rules)
    #expect(args[args.firstIndex(of: "--setting-sources")! + 1] == "")
    #expect(args.filter { $0 == "--append-system-prompt" }.count == 1)
    let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
    #expect(prompt.hasPrefix(AgentAutonomy.instructions()) && prompt.hasSuffix(rules))
}

@Test func claudeChatsReceiveUserInstructionsAndAttributionFromTheProfile() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let global = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: global) }
    let bare = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .standard, model: "", effort: nil, profile: home)
    // Only the inbound-message policy: messages from other Claude sessions are refused.
    let bareSettings = try JSONDecoder().decode(JSONValue.self, from: Data(bare[try #require(bare.firstIndex(of: "--settings")) + 1].utf8))
    #expect(bareSettings == .object(["crossSessionInbound": .string("refuse")]))

    // The profile's CLAUDE.md is usually a symlink to ~/.claude/CLAUDE.md; only commit/PR attribution is taken from settings.json.
    try "No Co-Authored-By in commit messages.".write(to: global, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("CLAUDE.md"), withDestinationURL: global)
    try #"{"attribution":{"commit":"","pr":"","extra":"x"},"hooks":{"Stop":[]}}"#.write(to: home.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let args = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .fullAccess, model: "", effort: nil,
                                               projectInstructions: "Project rules.", profile: home)
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(args[try #require(args.firstIndex(of: "--settings")) + 1].utf8))
    #expect(settings["attribution"] == .object(["commit": .string(""), "pr": .string("")]))
    #expect(settings["hooks"] == .null && settings["permissions"]["ask"].array.isEmpty == false)
    let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
    let user = try #require(prompt.range(of: "No Co-Authored-By in commit messages."))
    #expect(prompt.hasSuffix("Project rules.") && user.upperBound < prompt.range(of: "Project rules.")!.lowerBound)
    #expect(ClaudeProfile.instructions(home: home, language: .russian)?.hasPrefix("Глобальные инструкции пользователя") == true)
    #expect(ClaudeProfile.instructions(home: home, language: .english)?.hasPrefix("User's global instructions") == true)
}
