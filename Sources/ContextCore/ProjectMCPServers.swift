import Foundation
import CryptoKit

/// MCP servers from the project's `.mcp.json`. Claude chats run with `--strict-mcp-config`, so the CLI never reads
/// this file; the app passes a server only after the user approved it in the project's permissions. An approval is
/// bound to a fingerprint of the server's definition, so any later edit of the entry turns the server off until the
/// user approves it again. The project folder cannot approve its own servers.
public enum ProjectMCPServers {
    static let file = ".mcp.json"
    static let limit = 64 * 1024
    /// Names the app itself uses for MCP tool prefixes.
    static let reservedNames = ["switchboard_browser", "switchboard_chats", "claude-in-chrome"]
    static let reservedPrefix = "claude_ai"

    public struct Server: Hashable, Sendable {
        public var name: String
        public var definition: JSONValue
        public var fingerprint: String
        /// The command line or URL, for the approval list.
        public var summary: String
    }

    /// Usable servers of the project, sorted by name; empty when the file is missing or invalid.
    public static func servers(projectPath: String) -> [Server] {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard let text = ProjectInstructions.read(root.appendingPathComponent(file), root: root), text.utf8.count <= limit,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return [] }
        return value["mcpServers"].object.compactMap { name, definition in
            guard isValidName(name), case .object = definition, let summary = summary(definition) else { return nil }
            return Server(name: name, definition: definition, fingerprint: fingerprint(definition), summary: summary)
        }.sorted { $0.name < $1.name }
    }

    /// The approved servers whose definition still matches its approval (name -> definition for `--mcp-config`).
    public static func approved(projectPath: String, approvals: [String: String]?) -> [String: JSONValue] {
        guard let approvals, !approvals.isEmpty else { return [:] }
        var result: [String: JSONValue] = [:]
        for server in servers(projectPath: projectPath) where approvals[server.name] == server.fingerprint {
            result[server.name] = server.definition
        }
        return result
    }

    public static func fingerprint(_ definition: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = (try? encoder.encode(definition)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func summary(_ definition: JSONValue) -> String? {
        if let command = definition["command"].string, !command.isEmpty {
            return ([command] + definition["args"].array.compactMap(\.string)).joined(separator: " ")
        }
        return definition["url"].string.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !reservedNames.contains(name) && !name.hasPrefix(reservedPrefix)
            && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }
}
