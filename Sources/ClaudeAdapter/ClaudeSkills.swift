import Foundation
import ContextCore

/// The user's skills in Claude chats (2026-11-04). `--setting-sources ""` skips `~/.claude/skills` and the profile's
/// `skills/`, and `--disable-slash-commands` turns off every skill. Instead each skill folder becomes the `skills/` link
/// of a generated plugin under the profile, loaded with one `--plugin-dir` (a folder of plugins loads each child;
/// verified on Claude Code 2.1.292, also with `--setting-sources ""`). The links are read at every launch, so a skill
/// added later is there in the next CLI process. Skills are named `<plugin>:<skill>`, e.g. `user:hours-tracking`;
/// `/hours-tracking` in a message still finds it. Nothing is copied and the sources are never written.
///
/// Project skills (2026-11-12): a project with skills (`ProjectSkills`) gets its own folder of plugins under
/// `project-skill-plugins/<key>` with the same `user` and `app` plugins plus `project`, whose `skills/` links to the
/// app's vetted link folder of that project. They are named `project:<skill>`. Only the plugin manifest and the
/// `skills/` link exist in a plugin folder, so no hooks, agents, commands or MCP servers come with it.
enum ClaudeSkills {
    static let directory = "skill-plugins"
    static let projectDirectory = "project-skill-plugins"
    static let projectPlugin = "project"

    /// The `--plugin-dir` folder of a launch and the project skills it carries (part of the launch identity).
    struct Plugins: Equatable {
        var root: String
        var projectSkills: [String]
    }

    /// Plugin name → source folder: `user` is `~/.claude/skills`, `app` the profile's own `skills/`.
    static func sources(home: URL, user: URL?) -> [(name: String, folder: URL)] {
        [("user", user), ("app", home.appendingPathComponent("skills", isDirectory: true))].compactMap { name, folder in
            guard let folder else { return nil }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? (name, folder) : nil
        }
    }

    /// The folder of plugins for `--plugin-dir`, updated to the sources that exist; nil when there is none.
    static func pluginRoot(home: URL, user: URL?) throws -> URL? {
        let root = home.appendingPathComponent(directory, isDirectory: true)
        let current = sources(home: home, user: user)
        try link(current, into: root)
        return current.isEmpty ? nil : root
    }

    /// The plugins of a launch in `project`: the shared folder when the project has no skill, else the project's own
    /// folder with `user`, `app` and `project`. Read at every turn, so a skill added or removed shows in the result.
    static func plugins(home: URL, user: URL?, project: String?, links: URL = ProjectSkills.directory) throws -> Plugins? {
        guard let project, let vetted = try ProjectSkills.linkFolder(projectPath: project, root: links) else {
            return try pluginRoot(home: home, user: user).map { Plugins(root: $0.path, projectSkills: []) }
        }
        let root = home.appendingPathComponent(projectDirectory, isDirectory: true)
            .appendingPathComponent(ProjectSkills.key(project), isDirectory: true)
        try link(sources(home: home, user: user) + [(name: projectPlugin, folder: vetted.folder)], into: root)
        return Plugins(root: root.path, projectSkills: vetted.skills.map { $0.name + "=" + $0.folder })
    }

    /// Makes `root` hold exactly one plugin per source: a manifest and a `skills` link to the source folder.
    static func link(_ current: [(name: String, folder: URL)], into root: URL) throws {
        let manager = FileManager.default
        // A plugin whose source is gone is removed: its link first (never followed), then its own manifest folder.
        for entry in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] where !current.contains(where: { $0.name == entry }) {
            let plugin = root.appendingPathComponent(entry, isDirectory: true)
            unlink(plugin.appendingPathComponent("skills").path)
            try? manager.removeItem(at: plugin)
        }
        for (name, folder) in current {
            let plugin = root.appendingPathComponent(name, isDirectory: true)
            let manifestFolder = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
            try manager.createDirectory(at: manifestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let manifest = manifestFolder.appendingPathComponent("plugin.json")
            let body = Data("{\"name\":\"\(name)\",\"version\":\"1.0.0\",\"description\":\"Switchboard: skills from \(folder.path)\"}\n".utf8)
            if manager.contents(atPath: manifest.path) != body { try body.write(to: manifest, options: .atomic) }
            let link = plugin.appendingPathComponent("skills")
            if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != folder.path {
                unlink(link.path)
                try manager.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
            }
        }
    }

    /// "user:hours-tracking" → "hours-tracking".
    static func displayName(_ skill: String) -> String {
        guard let colon = skill.lastIndex(of: ":") else { return skill }
        let name = skill[skill.index(after: colon)...]
        return name.isEmpty ? skill : String(name)
    }

    /// One line for the system prompt when the project has skills: the names its files mention are listed with the prefix.
    static func projectInstructions(language: AppLanguage = L10n.language) -> String {
        L10n.text(
            "Навыки этого проекта (`.agents/skills`, `.claude/skills`) подключены как `project:<имя>`. Если файлы проекта называют навык просто `<имя>`, вызывай инструмент Skill с `project:<имя>`.",
            "This project's skills (`.agents/skills`, `.claude/skills`) are loaded as `project:<name>`. When the project's files name a skill just `<name>`, call the Skill tool with `project:<name>`.",
            language: language)
    }
}
