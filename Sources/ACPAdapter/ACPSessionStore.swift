import Foundation
import AgentContract
import ContextCore

/// The app's own record of one ACP session, like the Claude adapter's `contextdesk-sessions` files. ACP v1 agents are not
/// required to list or replay sessions (Gemini CLI 0.66.0 has no `session/list` and replays only through `session/load`),
/// so the chat's history comes from here; the agent's own session state stays in its isolated home.
struct ACPSessionRecord: Codable {
    var version = 1
    let id: String
    let cwd: String
    var turns: [AgentHistoryTurn] = []
    /// The turn sent but not finished when last saved; still set after a crash, then closed as uncertain.
    var active: String?
    var current: [TranscriptItem] = []
    /// Agent-reported title (`session_info_update`), kept for the app once the contract carries it.
    var title: String?
    var configOptions: [ACPConfigOption]?
}

/// `<home>/switchboard-sessions/<sha256 of the session ID>.json`, one file per session, owner-only.
struct ACPSessionStore {
    let directory: URL

    init(home: URL) { directory = home.appendingPathComponent("switchboard-sessions", isDirectory: true) }

    func file(_ id: String) throws -> URL {
        // Session IDs are agent data; the file name never contains them.
        guard !id.isEmpty, id.utf8.count <= 1024 else { throw ConversationIdentity.unavailable }
        return directory.appendingPathComponent(SummarySource.hash(Data(id.utf8)) + ".json")
    }

    func load(_ id: String) throws -> ACPSessionRecord {
        let record = try JSONDecoder().decode(ACPSessionRecord.self, from: Data(contentsOf: file(id)))
        guard record.version == 1, record.id == id else { throw ConversationIdentity.invalidStorage }
        return record
    }

    func save(_ record: ACPSessionRecord) throws {
        let path = try file(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

/// App-side state kept across launches in the agent home: whether the last sign-in check succeeded. ACP v1 has no stable
/// account query, so this is the adapter's own memory of the last `authenticate`, `session/new` or `auth_required` outcome.
struct ACPAccountState: Codable, Equatable {
    var authenticated: Bool

    static func file(home: URL) -> URL { home.appendingPathComponent("switchboard-acp-account.json") }
    static func load(home: URL) -> Self? { (try? Data(contentsOf: file(home: home))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
    func save(home: URL) throws {
        let path = Self.file(home: home)
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
