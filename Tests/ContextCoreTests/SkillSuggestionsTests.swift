import Foundation
import Testing
import AgentContract
@testable import ContextCore

private func token(_ location: Int, _ length: Int, _ query: String) -> SkillSuggestions.Token {
    SkillSuggestions.Token(range: NSRange(location: location, length: length), query: query)
}
private func skill(_ name: String) -> SkillInfo { SkillInfo(name: name, description: "", path: "/skills/" + name) }

@Test func skillTokenStartsAtTheTextOrAfterWhitespaceAndEndsAtTheCaret() {
    #expect(SkillSuggestions.token(in: "/", caret: 1) == token(0, 1, ""))
    #expect(SkillSuggestions.token(in: "/rev", caret: 4) == token(0, 4, "rev"))
    #expect(SkillSuggestions.token(in: "please /pd", caret: 10) == token(7, 3, "pd"))
    #expect(SkillSuggestions.token(in: "line\n/x more", caret: 7) == token(5, 2, "x"))
    // Inside a word, a path, a word ending in `/` or with the caret before the end of the word: no list.
    #expect(SkillSuggestions.token(in: "a/b", caret: 3) == nil)
    #expect(SkillSuggestions.token(in: "/usr/bin", caret: 8) == nil)
    #expect(SkillSuggestions.token(in: "/review", caret: 3) == nil)
    #expect(SkillSuggestions.token(in: "/review ", caret: 8) == nil)
    #expect(SkillSuggestions.token(in: "text", caret: 4) == nil)
    #expect(SkillSuggestions.token(in: "", caret: 0) == nil)
    #expect(SkillSuggestions.token(in: "/x", caret: 5) == nil)
}

@Test func skillTokenCountsUTF16LikeTheTextView() {
    // The emoji takes two UTF-16 units, so the `/` sits at offset 3.
    #expect(SkillSuggestions.token(in: "😀 /ab", caret: 6) == token(3, 3, "ab"))
}

@Test func skillMatchesListPrefixesBeforeSubstringsIgnoringCase() {
    let skills = ["code-review", "pdf", "Review", "write-docs"].map(skill)
    #expect(SkillSuggestions.matches(skills, query: "").map(\.name) == ["code-review", "pdf", "Review", "write-docs"])
    #expect(SkillSuggestions.matches(skills, query: "rev").map(\.name) == ["Review", "code-review"])
    #expect(SkillSuggestions.matches(skills, query: "PDF").map(\.name) == ["pdf"])
    #expect(SkillSuggestions.matches(skills, query: "zzz").isEmpty)
}

@Test func skillInvocationFollowsTheEngine() {
    #expect(SkillSuggestions.syntax(for: .claudeCode) == .slash)
    #expect(SkillSuggestions.syntax(for: .codex) == .dollar)
    #expect(SkillSuggestions.syntax(for: AgentID(rawValue: "gemini")) == nil)
    #expect(SkillMentionSyntax.slash.invocation("pdf") == "/pdf ")
    #expect(SkillMentionSyntax.dollar.invocation("pdf") == "$pdf ")
}

// Project skills (2026-11-27): plain `SKILL.md` files in a temporary project and a temporary user root.
private func temporaryFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeSkill(_ folder: URL, name: String, description: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\n"
        .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

@Test func skillListPutsTheProjectsVettedSkillsFirstWithDescriptions() throws {
    let project = try temporaryFolder(), user = try temporaryFolder()
    try writeSkill(project.appendingPathComponent(".agents/skills/clear-answers"), name: "clear-answers", description: "Answer plainly.")
    try writeSkill(project.appendingPathComponent(".claude/skills/review"), name: "review", description: "Project review.")
    // Front matter the CLI acts on keeps a skill out of the project set, as for the agents.
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude/skills/tools"), withIntermediateDirectories: true)
    try "---\nname: tools\ndescription: x\nallowed-tools: Bash\n---\n"
        .write(to: project.appendingPathComponent(".claude/skills/tools/SKILL.md"), atomically: true, encoding: .utf8)
    try writeSkill(user.appendingPathComponent("review"), name: "review", description: "User review.")
    try writeSkill(user.appendingPathComponent("pdf"), name: "pdf", description: "Read PDFs.")

    let projectOnly = SkillSuggestions.projectSkills(projectPath: project.path)
    #expect(projectOnly.map(\.name) == ["clear-answers", "review"])
    #expect(projectOnly.allSatisfy { $0.origin == .project })
    #expect(projectOnly.first?.description == "Answer plainly.")

    let skills = SkillSuggestions.skills(.slash, projectPath: project.path, userRoots: [user])
    #expect(skills.map(\.name) == ["clear-answers", "review", "pdf", "review"])
    #expect(skills.map(\.origin) == [.project, .project, .user, .user])
    // A user skill and a project skill with one name are both listed with distinct ids.
    #expect(Set(skills.map(\.id)).count == skills.count)
    #expect(skills.filter { $0.name == "review" }.map(\.description) == ["Project review.", "User review."])
    // Without a project only the user's skills.
    #expect(SkillSuggestions.skills(.dollar, projectPath: nil, userRoots: [user]).map(\.origin) == [.user, .user])
}

@Test func projectSkillInvocationFollowsTheEngine() {
    let project = SkillInfo(name: "clear-answers", description: "", path: "/p/clear-answers", origin: .project)
    let user = skill("clear-answers")
    #expect(project.id != user.id)
    #expect(SkillMentionSyntax.slash.invocation(project) == "/project:clear-answers ")
    #expect(SkillMentionSyntax.dollar.invocation(project) == "$clear-answers ")
    #expect(SkillMentionSyntax.slash.invocation(user) == "/clear-answers ")
    #expect(SkillMentionSyntax.dollar.invocation(user) == "$clear-answers ")
    #expect(SkillMentionSyntax.slash.invokedName(project) == "project:clear-answers")
    #expect(SkillMentionSyntax.dollar.invokedName(project) == "clear-answers")
}

@Test func projectSkillMatchesItsPlainNameAndTheProjectPrefix() {
    let project = SkillInfo(name: "clear-answers", description: "", path: "/p/clear-answers", origin: .project)
    let unclear = SkillInfo(name: "unclear", description: "", path: "/p/unclear", origin: .project)
    let skills = [project, unclear, skill("clean"), skill("pdf")]
    // Project skills come first in each group; prefixes still come before substrings.
    #expect(SkillSuggestions.matches(skills, query: "cl").map(\.id) == ["project:clear-answers", "user:clean", "project:unclear"])
    #expect(SkillSuggestions.matches(skills, query: "project:cl").map(\.id) == ["project:clear-answers"])
    #expect(SkillSuggestions.matches(skills, query: "Project:").map(\.id) == ["project:clear-answers", "project:unclear"])
    #expect(SkillSuggestions.matches(skills, query: "project:pdf").isEmpty)
    // The typed `/project:cl` is one token: `:` is allowed, only a second `/` ends it.
    #expect(SkillSuggestions.token(in: "/project:cl", caret: 11) == token(0, 11, "project:cl"))
}
