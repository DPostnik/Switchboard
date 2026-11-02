import Foundation
import AgentContract
import ContextCore

/// Gemini CLI (`@google/gemini-cli`) over ACP: `gemini --acp`.
///
/// Isolation, verified against the 0.66.0 bundle (`homedir()` in the core chunk) and docs/reference/configuration.md:
/// `GEMINI_CLI_HOME` replaces the home directory for all user-level state, so settings, OAuth credentials, sessions and
/// history live in `<home>/.gemini/` (home = `~/Library/Application Support/Switchboard/gemini/`), never in `~/.gemini`.
/// Checked live on 0.66.0 with `HOME` and `GEMINI_CLI_HOME` pointing at different folders: `initialize` and `session/new`
/// wrote `projects.json`, `history/` and `tmp/<project>/chats/` only under `GEMINI_CLI_HOME`, nothing under `HOME`.
/// `GEMINI_FORCE_FILE_STORAGE=true` keeps OAuth tokens in that folder instead of the shared login Keychain. Inherited API
/// keys, Google Cloud credentials, endpoint overrides, system settings paths and trust overrides are removed, as the
/// Codex adapter removes `OPENAI_API_KEY`. A project's own `.env` file can still set variables for that project
/// (Gemini CLI loads it from the session folder); that is project configuration, not inherited state.
public enum GeminiProfile {
    public static let agent = AgentID(rawValue: "gemini-cli")
    /// The app-owned Gemini connection; local to an app store like the Codex and Claude connections.
    public static let connection = AgentConnectionID(agent: agent, id: UUID(uuidString: "F0362513-6DDA-4E2A-9F74-807F29BCE003")!)
    /// `agentInfo.version` builds verified live (initialize without sign-in or inference, 2026-11-02).
    public static let verifiedVersions = ["0.66.0"]
    /// The ACP auth method that signs in with a Google account inside `authenticate` (Gemini's `oauth-personal`).
    public static let signInMethod = "oauth-personal"

    /// `~/Library/Application Support/Switchboard/gemini/`: `GEMINI_CLI_HOME`, the app's session records and the install folder.
    public static var home: URL { Locations.root.appendingPathComponent("gemini", isDirectory: true) }
    /// Where the app installs the CLI (`npm install --prefix <home>/cli`); searched first.
    public static func installedExecutable(home: URL) -> URL {
        home.appendingPathComponent("cli/node_modules/.bin/gemini")
    }

    /// Variables removed from the inherited environment: anything that selects another account, key, endpoint or state folder.
    static let removedPrefixes = ["GEMINI_", "GOOGLE_", "CODE_ASSIST_", "OTEL_", "OTLP_"]
    static let removedKeys: Set<String> = [
        "GCLOUD_PROJECT", "CLOUD_SHELL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "SANDBOX", "SEATBELT_PROFILE"
    ]

    static func environment(home: URL, executable: URL, inherited: [String: String]) -> [String: String] {
        var result = inherited.filter { key, _ in
            !removedKeys.contains(key) && !removedPrefixes.contains { key.hasPrefix($0) }
        }
        result["GEMINI_CLI_HOME"] = home.path
        result["GEMINI_FORCE_FILE_STORAGE"] = "true"
        // One process: the CLI otherwise relaunches itself as a child only to raise the heap limit.
        result["GEMINI_CLI_NO_RELAUNCH"] = "true"
        // `gemini` is a Node script (`#!/usr/bin/env node`); an app started from Finder has a minimal PATH.
        let paths = [executable.resolvingSymlinksInPath().deletingLastPathComponent().path, executable.deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin"] + (inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        result["PATH"] = paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        // One engine serves every Gemini chat, so only the instance label applies (swept at quit and next launch).
        result.merge(ProcessLabels.environment()) { _, new in new }
        return result
    }

    /// The isolated home and, once, app-owned defaults in its `.gemini/settings.json`: no usage statistics and no
    /// self-update (the adapter is verified on exact builds). An existing settings file is never rewritten.
    static func prepare(home: URL) throws {
        try ACPLaunchProfile.createHome(home)
        let folder = home.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let settings = folder.appendingPathComponent("settings.json")
        guard !FileManager.default.fileExists(atPath: settings.path) else { return }
        let defaults: JSONValue = .object([
            "privacy": .object(["usageStatisticsEnabled": .bool(false)]),
            "general": .object(["enableAutoUpdate": .bool(false), "enableAutoUpdateNotification": .bool(false)])
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(defaults).write(to: settings, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    }

    /// App-owned install first (stage E installs there), then Homebrew, then absolute PATH entries.
    static func candidates(home: URL, environment: [String: String]) -> [String] {
        [installedExecutable(home: home).path, "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]
            + ACPLaunchProfile.pathCandidates("gemini", environment: environment)
    }

    public static let profile = ACPLaunchProfile(
        agent: agent, connection: connection, productName: "Gemini CLI", arguments: ["--acp"],
        candidates: { candidates(home: $0, environment: $1) },
        environment: { environment(home: $0, executable: $1, inherited: $2) },
        prepareHome: { try prepare(home: $0) },
        verifiedVersions: verifiedVersions, signInMethod: signInMethod)
}
