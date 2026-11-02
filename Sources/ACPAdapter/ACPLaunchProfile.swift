import Foundation
import AgentContract
import ContextCore

/// How to start one ACP agent and which of its builds this adapter was verified on. The integration is generic; everything
/// agent-specific lives here (the executable, its arguments, the isolated home, the environment and the verified versions).
public struct ACPLaunchProfile: Sendable {
    /// Agent identity for drift records and the connection ID.
    public let agent: AgentID
    public let connection: AgentConnectionID
    /// Product name in diagnostics ("Gemini CLI").
    public let productName: String
    public let arguments: [String]
    /// Executable candidates for an app-owned home, in order; the first existing executable file wins.
    public let candidates: @Sendable (_ home: URL, _ environment: [String: String]) -> [String]
    /// The agent's environment: the inherited one with credentials and redirections removed, plus the isolated home.
    public let environment: @Sendable (_ home: URL, _ executable: URL, _ inherited: [String: String]) -> [String: String]
    /// Creates the isolated home and any app-owned defaults inside it. Never touches the user's own agent state.
    public let prepareHome: @Sendable (_ home: URL) throws -> Void
    /// `agentInfo.version` values from `initialize` the adapter was verified on (`AgentVersionPolicy`).
    public let verifiedVersions: [String]
    /// The agent-type auth method used for sign-in when the agent advertises several.
    public let signInMethod: String?
    /// After `session/load`, updates for the session are dropped until it stays quiet this long (history replay).
    public let replaySettle: Duration
    /// How long a cancelled turn may take to answer before the process is stopped and the turn reported as uncertain.
    public let cancelGrace: Duration
    public let startupTimeout: Duration
    public let sessionTimeout: Duration
    public let signInTimeout: Duration

    public init(agent: AgentID, connection: AgentConnectionID, productName: String, arguments: [String],
                candidates: @escaping @Sendable (URL, [String: String]) -> [String],
                environment: @escaping @Sendable (URL, URL, [String: String]) -> [String: String],
                prepareHome: @escaping @Sendable (URL) throws -> Void = ACPLaunchProfile.createHome,
                verifiedVersions: [String], signInMethod: String? = nil,
                replaySettle: Duration = .milliseconds(300), cancelGrace: Duration = .seconds(30),
                startupTimeout: Duration = .seconds(60), sessionTimeout: Duration = .seconds(120), signInTimeout: Duration = .seconds(600)) {
        self.agent = agent; self.connection = connection; self.productName = productName; self.arguments = arguments
        self.candidates = candidates; self.environment = environment; self.prepareHome = prepareHome
        self.verifiedVersions = verifiedVersions; self.signInMethod = signInMethod
        self.replaySettle = replaySettle; self.cancelGrace = cancelGrace
        self.startupTimeout = startupTimeout; self.sessionTimeout = sessionTimeout; self.signInTimeout = signInTimeout
    }

    public static let createHome: @Sendable (URL) throws -> Void = { home in
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The first candidate that is an executable regular file (or a link to one). Relative PATH entries are never used.
    public func executable(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let found = candidates(home, environment).first { path in
            var directory: ObjCBool = false
            return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }
        guard let found else {
            throw ClientFailure(L10n.text("\(productName) не найден. Установи его, затем подключись снова.",
                                          "\(productName) was not found. Install it, then connect again."))
        }
        return URL(fileURLWithPath: found)
    }

    /// PATH entries of an environment that are absolute, as executable candidates named `name`.
    public static func pathCandidates(_ name: String, environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/\(name)" }
    }
}
