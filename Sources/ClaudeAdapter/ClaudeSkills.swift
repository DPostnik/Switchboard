import Foundation

/// The user's skills in Claude chats (2026-11-04). `--setting-sources ""` skips `~/.claude/skills` and the profile's
/// `skills/`, and `--disable-slash-commands` turns off every skill. Instead each skill folder becomes the `skills/` link
/// of a generated plugin under the profile, loaded with one `--plugin-dir` (a folder of plugins loads each child;
/// verified on Claude Code 2.1.292, also with `--setting-sources ""`). The links are read at every launch, so a skill
/// added later is there in the next CLI process. Skills are named `<plugin>:<skill>`, e.g. `user:hours-tracking`;
/// `/hours-tracking` in a message still finds it. Nothing is copied and the sources are never written.
enum ClaudeSkills {
    static let directory = "skill-plugins"
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
        let manager = FileManager.default
        let root = home.appendingPathComponent(directory, isDirectory: true)
        let current = sources(home: home, user: user)
        // A plugin whose source is gone is removed: its link first (never followed), then its own manifest folder.
        for entry in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] where !current.contains(where: { $0.name == entry }) {
            let plugin = root.appendingPathComponent(entry, isDirectory: true)
            unlink(plugin.appendingPathComponent("skills").path)
            try? manager.removeItem(at: plugin)
        }
        guard !current.isEmpty else { return nil }
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
        return root
    }

    /// "user:hours-tracking" → "hours-tracking".
    static func displayName(_ skill: String) -> String {
        guard let colon = skill.lastIndex(of: ":") else { return skill }
        let name = skill[skill.index(after: colon)...]
        return name.isEmpty ? skill : String(name)
    }
}
