import Foundation

/// What a "master" chat may read about the other chats (plan Phase 5): a snapshot file the app rewrites every
/// scheduler tick and a small stdio MCP server (`ChatDirectoryRuntime/server.py`) that answers `list_chats` and
/// `read_chat` from it. Read-only. The server is attached only to chats the user opted in, and the file exists
/// only while at least one chat has that access.
public enum ChatDirectory {
    public static let serverName = "switchboard_chats"
    public static let fileName = "chat-directory.json"
    /// Messages kept per chat, each cut to `messageLimit` characters.
    public static let messageCount = 8, messageLimit = 1500

    public struct Snapshot: Codable, Equatable, Sendable {
        public var generatedAt: Date
        public var chats: [Entry]
        public init(generatedAt: Date, chats: [Entry]) { self.generatedAt = generatedAt; self.chats = chats }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var project: String
        public var agent: String
        /// `needs-approval`, `needs-answer`, `failed`, `unread`, `working` or `idle`.
        public var state: String
        public var detail: String?
        public var activity: String?
        public var updated: Date
        public var messages: [Message]
        public init(id: String, title: String, project: String, agent: String, state: String, detail: String?, activity: String?,
                    updated: Date, messages: [Message]) {
            self.id = id; self.title = title; self.project = project; self.agent = agent; self.state = state
            self.detail = detail; self.activity = activity; self.updated = updated; self.messages = messages
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var text: String
        public init(role: String, text: String) {
            self.role = role
            self.text = text.count > ChatDirectory.messageLimit ? String(text.prefix(ChatDirectory.messageLimit)) + "…" : text
        }
    }

    public static func state(_ attention: ChatAttention?, running: Bool) -> String {
        switch attention {
        case .needsApproval: "needs-approval"
        case .needsAnswer: "needs-answer"
        case .failed: "failed"
        case .finishedUnread: "unread"
        case nil: running ? "working" : "idle"
        }
    }

    /// Writes the snapshot owner-only and atomically; never leaves a world-readable copy behind.
    public static func write(_ snapshot: Snapshot, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The MCP server's command line for one chat. `index` adds the full-text search tools;
    /// `recipe` makes the server hand its search instructions to a chat-search chat.
    public static func serverArguments(script: String, snapshot: String, chat: String, index: String? = nil, recipe: String? = nil) -> [String] {
        [script, "--snapshot", snapshot, "--chat", chat] + (index.map { ["--index", $0] } ?? []) + (recipe.map { ["--recipe", $0] } ?? [])
    }
}
