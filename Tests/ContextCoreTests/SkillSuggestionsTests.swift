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
