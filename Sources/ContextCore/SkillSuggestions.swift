import AgentContract
import Foundation

/// How an engine's prompt invokes a skill (2026-11-04): Claude Code runs `/<name>`, Codex mentions `$<name>`.
public enum SkillMentionSyntax: Sendable, Hashable {
    case slash, dollar

    /// What the composer inserts for the skill, with a trailing space so the user types the request after it.
    public func invocation(_ name: String) -> String {
        switch self {
        case .slash: "/" + name + " "
        case .dollar: "$" + name + " "
        }
    }

    /// What the composer inserts for this skill: a project skill is `/project:<name>` in Claude Code (the plugin
    /// `project`, `ClaudeSkills`) and plain `$<name>` in Codex (an extra skill root).
    public func invocation(_ skill: SkillInfo) -> String { invocation(invokedName(skill)) }

    /// The skill's name as this engine knows it, shown as the list row's title.
    public func invokedName(_ skill: SkillInfo) -> String {
        skill.origin == .project && self == .slash ? SkillSuggestions.projectPrefix + skill.name : skill.name
    }
}

/// The composer's `/` skill list: which typed token it completes, which skills match it and where they come from.
public enum SkillSuggestions {
    /// A `/token` being typed: its UTF-16 range in the text, `/` included, and the characters after the `/`.
    public struct Token: Sendable, Equatable {
        public var range: NSRange
        public var query: String
        public init(range: NSRange, query: String) { self.range = range; self.query = query }
    }

    /// The syntax of an engine with skills; nil for the others (Gemini and other ACP agents), which get no list.
    public static func syntax(for agent: AgentID) -> SkillMentionSyntax? {
        if agent == .claudeCode { return .slash }
        if agent == .codex { return .dollar }
        return nil
    }

    /// The folders the engine loads skills from.
    public static func roots(_ syntax: SkillMentionSyntax) -> [URL] {
        switch syntax {
        case .slash: SkillCatalog.claudeRoots
        case .dollar: SkillCatalog.codexRoots
        }
    }

    /// The namespace of project skills in Claude Code; a query may start with it in either engine.
    public static let projectPrefix = "project:"

    /// The project's skills for the list (2026-11-27): exactly the vetted set the agents load (`ProjectSkills.scan`),
    /// named by folder, with the description from the skill's `SKILL.md` front matter.
    public static func projectSkills(projectPath: String) -> [SkillInfo] {
        ProjectSkills.scan(projectPath: projectPath).map { skill in
            let data = FileManager.default.contents(atPath: skill.folder + "/SKILL.md") ?? Data()
            let header = SkillCatalog.frontMatter(String(decoding: data.prefix(64 * 1024), as: UTF8.self))
            return SkillInfo(name: skill.name, description: header.description ?? "", path: skill.folder, origin: .project)
        }
    }

    /// Everything the `/` list offers in a chat: the project's skills first (the chat's own context), then the user's.
    public static func skills(_ syntax: SkillMentionSyntax, projectPath: String?, userRoots: [URL]? = nil) -> [SkillInfo] {
        let project = projectPath.map { projectSkills(projectPath: $0) } ?? []
        return project + SkillCatalog.scan(userRoots ?? roots(syntax))
    }

    /// The token that ends at the caret (a UTF-16 offset, as `NSTextView` reports it): a `/` at the start of the text
    /// or after whitespace, followed by characters without whitespace or another `/` (a path is not a skill). The caret
    /// must be at the token's end, so text right after it (the middle of a word) opens nothing.
    public static func token(in text: String, caret: Int) -> Token? {
        let string = text as NSString
        guard caret >= 0, caret <= string.length else { return nil }
        if caret < string.length, !isSpace(string.character(at: caret)) { return nil }
        var start = caret
        while start > 0, !isSpace(string.character(at: start - 1)) { start -= 1 }
        guard start < caret, string.character(at: start) == 0x2F else { return nil }
        let query = string.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        guard !query.contains("/") else { return nil }
        return Token(range: NSRange(location: start, length: caret - start), query: query)
    }

    /// Skills whose name starts with the query, then those that contain it elsewhere, each group in catalog order;
    /// case- and diacritic-insensitive. A project skill also matches as `project:<name>`, so `/project:cl` finds it in
    /// both engines. An empty query lists every skill.
    public static func matches(_ skills: [SkillInfo], query: String) -> [SkillInfo] {
        guard !query.isEmpty else { return skills }
        var prefixed: [SkillInfo] = [], contained: [SkillInfo] = []
        for skill in skills {
            let names = skill.origin == .project ? [skill.name, projectPrefix + skill.name] : [skill.name]
            let found = names.compactMap { name in
                name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]).map { $0.lowerBound == name.startIndex }
            }
            if found.contains(true) { prefixed.append(skill) } else if !found.isEmpty { contained.append(skill) }
        }
        return prefixed + contained
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}
