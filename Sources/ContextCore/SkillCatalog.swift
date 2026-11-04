import Foundation

/// One skill the user installed: a folder with a `SKILL.md` whose front matter gives its name and description.
public struct SkillInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    /// The skill's folder.
    public var path: String
    public var id: String { name }
    public init(name: String, description: String, path: String) {
        self.name = name; self.description = description; self.path = path
    }
}

/// The user's skills per engine (2026-11-04), read-only. Claude chats load `~/.claude/skills` and the app profile's
/// `skills/` as plugins (`ClaudeSkills`); Codex chats get `~/.codex/skills` as an extra skill root next to its own
/// home. The composer lists the same folders, so the `/` list shows what the agent can load.
public enum SkillCatalog {
    public static var claudeRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true),
         Locations.claudeHome.appendingPathComponent("skills", isDirectory: true)]
    }
    public static var codexRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills", isDirectory: true),
         Locations.codexHome.appendingPathComponent("skills", isDirectory: true)]
    }

    /// Skills under the roots, sorted by name; a name in an earlier root hides the same name in a later one.
    /// A folder without `SKILL.md` or without a name is skipped; symbolic links to skill folders are followed.
    public static func scan(_ roots: [URL]) -> [SkillInfo] {
        let manager = FileManager.default
        var seen = Set<String>(), result: [SkillInfo] = []
        for root in roots {
            guard let entries = try? manager.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let folder = root.appendingPathComponent(entry, isDirectory: true)
                guard let data = manager.contents(atPath: folder.appendingPathComponent("SKILL.md").path) else { continue }
                let header = frontMatter(String(decoding: data.prefix(64 * 1024), as: UTF8.self))
                let name = header.name ?? ""
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                result.append(SkillInfo(name: name, description: header.description ?? "", path: folder.path))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `name` and `description` of a `---` front matter block; folded (`>`, `|`) and indented continuation lines
    /// join into one line.
    static func frontMatter(_ text: String) -> (name: String?, description: String?) {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        lines.removeFirst()
        var values: [String: String] = [:], key: String?
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let first = line.first, first == " " || first == "\t" {
                guard let key else { continue }
                let part = line.trimmingCharacters(in: .whitespaces)
                values[key] = values[key].map { $0.isEmpty ? part : $0 + " " + part } ?? part
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) { value = "" }
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            key = name; values[name] = value
        }
        return (values["name"], values["description"])
    }
}
