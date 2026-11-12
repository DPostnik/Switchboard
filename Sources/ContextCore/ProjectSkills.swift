import CryptoKit
import Foundation

/// A project's own skills for both providers (2026-11-12): `<project>/.agents/skills/*/SKILL.md` and
/// `<project>/.claude/skills/*/SKILL.md`; a folder name in `.agents/skills` hides the same name in `.claude/skills`.
/// Only skill folders are exposed: nothing else of the project's `.claude/` (settings, hooks, commands, agents,
/// `.mcp.json`) is read. The app keeps one folder of links per project in its data directory, outside every
/// provider home and project (`directory`): Claude loads it as the `skills/` of the plugin `project`
/// (`ClaudeSkills`), Codex as an extra skill root of the chat's own worker. Each link points at the resolved skill
/// folder; a skill whose folder, `SKILL.md` or any link inside resolves outside the project is skipped, so a skill
/// never reaches files the chat could not read in its project. Nothing is copied and the project is never written.
public enum ProjectSkills {
    /// Where the skills are looked up, first wins.
    public static let sources = [".agents/skills", ".claude/skills"]
    /// The app-owned folders of links, one per project.
    public static var directory: URL { Locations.root.appendingPathComponent("project-skills", isDirectory: true) }
    /// More entries than this inside one skill folder are not inspected: such a skill is skipped.
    static let entryLimit = 5_000

    public struct Skill: Sendable, Equatable {
        /// The folder name, also the name the provider shows.
        public var name: String
        /// The resolved skill folder inside the project.
        public var folder: String
    }

    /// The project's skills that pass the checks, sorted by name.
    public static func scan(projectPath: String) -> [Skill] {
        guard let project = realPath(projectPath) else { return [] }
        let manager = FileManager.default
        var seen = Set<String>(), result: [Skill] = []
        for source in sources {
            let root = URL(fileURLWithPath: projectPath).appendingPathComponent(source, isDirectory: true).path
            guard let entries = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where !entry.hasPrefix(".") && !seen.contains(entry) {
                guard let folder = realPath(root + "/" + entry), within(folder, project) else { continue }
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
                      let file = realPath(folder + "/SKILL.md"), within(file, project),
                      manager.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue,
                      let data = manager.contents(atPath: file), descriptiveOnly(String(decoding: data.prefix(64 * 1024), as: UTF8.self)),
                      linksStayInside(folder, project: project) else { continue }
                seen.insert(entry)
                result.append(Skill(name: entry, folder: folder))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// The project's folder of links, updated to `scan`; nil (and the folder removed) when the project has no skill.
    /// Links are replaced atomically, so two chats of one project updating at once leave a whole set.
    @discardableResult
    public static func linkFolder(projectPath: String, root: URL = directory) throws -> (folder: URL, skills: [Skill])? {
        let manager = FileManager.default
        let folder = root.appendingPathComponent(key(projectPath), isDirectory: true)
        let skills = scan(projectPath: projectPath)
        let wanted = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0.folder) })
        for entry in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where wanted[entry] == nil {
            // Never followed: a link is unlinked, anything else the app did not make is removed as itself.
            let path = folder.appendingPathComponent(entry).path
            if unlink(path) != 0 { try? manager.removeItem(atPath: path) }
        }
        guard !skills.isEmpty else {
            try? manager.removeItem(at: folder)
            return nil
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for skill in skills {
            let link = folder.appendingPathComponent(skill.name).path
            if (try? manager.destinationOfSymbolicLink(atPath: link)) == skill.folder { continue }
            let temporary = folder.appendingPathComponent(".\(skill.name).\(UUID().uuidString)").path
            try manager.createSymbolicLink(atPath: temporary, withDestinationPath: skill.folder)
            guard rename(temporary, link) == 0 else {
                unlink(temporary)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: link])
            }
        }
        return (folder, skills)
    }

    /// A stable folder name per project: its last component (readable) and a hash of the resolved path.
    public static func key(_ projectPath: String) -> String {
        let path = realPath(projectPath) ?? projectPath
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = URL(fileURLWithPath: path).lastPathComponent.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
        return String(name.prefix(40)) + "-" + hash
    }

    /// Front matter keys that only describe a skill. Project files are agent-writable, and Claude Code acts on other keys
    /// (`allowed-tools` approves tools while the skill runs, `hooks` runs commands, `model`, `context`, `agent` change the
    /// run), so a skill with any other key is not exposed: its text never widens what the chat may do.
    public static let descriptiveKeys: Set<String> = ["name", "description", "license", "metadata", "version", "compatibility",
                                                      "when_to_use", "argument-hint", "user-invocable", "disable-model-invocation",
                                                      "tags", "author"]

    /// The `SKILL.md` has a front matter block with a name and only `descriptiveKeys` at its top level.
    static func descriptiveOnly(_ text: String) -> Bool {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        lines.removeFirst()
        var named = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return named }
            guard let first = line.first, first != " ", first != "\t", first != "#", first != "-" else { continue }
            guard let colon = line.firstIndex(of: ":") else { return false }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard descriptiveKeys.contains(key) else { return false }
            if key == "name" { named = true }
        }
        return false
    }

    /// Every link inside the skill folder (any depth) resolves inside the project; links to folders are not entered.
    static func linksStayInside(_ folder: String, project: String) -> Bool {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
        var count = 0
        for case let url as URL in walker {
            count += 1
            if count > entryLimit { return false }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            guard let target = realPath(url.path), within(target, project) else { return false }
        }
        return true
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
}
