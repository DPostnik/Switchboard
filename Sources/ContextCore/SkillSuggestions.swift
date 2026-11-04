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
    /// case- and diacritic-insensitive. An empty query lists every skill.
    public static func matches(_ skills: [SkillInfo], query: String) -> [SkillInfo] {
        guard !query.isEmpty else { return skills }
        var prefixed: [SkillInfo] = [], contained: [SkillInfo] = []
        for skill in skills {
            guard let found = skill.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            if found.lowerBound == skill.name.startIndex { prefixed.append(skill) } else { contained.append(skill) }
        }
        return prefixed + contained
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}
