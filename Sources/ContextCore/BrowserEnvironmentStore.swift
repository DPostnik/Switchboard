import Foundation
import CryptoKit
import AgentContract

/// Persistent browser ownership; stores no authentication material.
public enum BrowserEnvironmentStore {
    public static var directory: URL { Locations.root.appendingPathComponent("browser", isDirectory: true) }
    public static let parallelLimitKey = "parallelBrowserLimit"

    /// Shared stdio MCP argv (after `/usr/bin/python3`) so every engine launches the browser identically.
    /// The role's browser rights travel only as launch arguments; the runtime fails closed without them.
    public static func serverArguments(resources: URL, root: URL, environment: UUID, grant: BrowserProfileGrant?,
                                       policy: BrowserLaunchPolicy, language: AppLanguage = L10n.language) -> [String] {
        let limit = UserDefaults.standard.integer(forKey: parallelLimitKey)
        return [resources.appendingPathComponent("BrowserRuntime/server.py").path,
                "--root", root.path, "--environment", environment.uuidString.lowercased(),
                "--max-browsers", String((1...8).contains(limit) ? limit : 2),
                "--language", language.rawValue]
            + (grant.map { ["--profile-lease", $0.generation.uuidString.lowercased()] } ?? [])
            + policy.arguments
    }
    /// Host-owned identity, independent of MCP process IDs and model arguments.
    public static func bindingPath(session: String, root: URL) -> URL {
        let key = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("bindings").appendingPathComponent(key + ".json")
    }

    public static func existingEnvironment(session: String, root: URL = directory) throws -> URL? {
        try existingEnvironment(session: .init(connection: .originalCodex, nativeID: session), root: root)
    }
    public static func existingEnvironment(session: AgentSessionReference, root: URL = directory) throws -> URL? {
        if let profile = try BrowserProfileStore(root: root).current(session: session) {
            return root.appendingPathComponent("environments").appendingPathComponent(profile.id.uuidString.lowercased())
        }
        // Only the original Codex connection has pre-profile bindings keyed by native ID.
        guard session.connection == .originalCodex, let id = try legacyEnvironment(session: session.nativeID, root: root) else { return nil }
        return root.appendingPathComponent("environments").appendingPathComponent(id.uuidString.lowercased())
    }

    static func legacyEnvironment(session: String, root: URL) throws -> UUID? {
        let path = bindingPath(session: session, root: root)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: path))
    }

    public static func environment(session: String, root: URL) throws -> UUID {
        if let profile = try BrowserProfileStore(root: root).current(session: .init(connection: .originalCodex, nativeID: session)) {
            return profile.id
        }
        let path = bindingPath(session: session, root: root)
        if FileManager.default.fileExists(atPath: path.path) {
            return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: path))
        }
        let id = UUID()
        try bind(id, session: session, root: root)
        return id
    }

    public static func bind(_ id: UUID, session: String, root: URL) throws {
        let path = bindingPath(session: session, root: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(id).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

}

/// Browser rights of one chat's role (roles plan, Phase 4; audit H3, M8).
public struct BrowserLaunchPolicy: Equatable, Sendable {
    public enum ImportScope: String, Sendable { case none, listed, any }
    public var allowEval: Bool
    public var allowUpload: Bool
    public var importScope: ImportScope
    public init(allowEval: Bool, allowUpload: Bool, importScope: ImportScope) {
        self.allowEval = allowEval; self.allowUpload = allowUpload; self.importScope = importScope
    }
    /// Script evaluation and uploads need a role that may run commands; reader and editor do not get them.
    /// An unattended run imports cookies only for sites listed for it: the app-wide "any site" never applies.
    public init(_ requested: AgentPermissionProfile, scheduled: Bool) {
        let profile = requested.effective
        let operating = profile.shell == .on || profile.filesystem == .unrestricted
        allowEval = operating; allowUpload = operating
        switch profile.cookieImport {
        case .none: importScope = .none
        case .sites: importScope = .listed
        case .any: importScope = scheduled ? .listed : .any
        }
    }
    var arguments: [String] {
        (allowEval ? ["--allow-eval"] : []) + (allowUpload ? ["--allow-upload"] : []) + ["--import-scope", importScope.rawValue]
    }
}
