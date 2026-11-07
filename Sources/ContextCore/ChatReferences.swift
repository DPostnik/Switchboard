import Foundation

/// Chats the user named in another chat's messages (`switchboard-chat:<ID>` or a bare chat or session ID).
/// The chat directory server lets a chat inspect only these chats unless the user gave it access to all chats.
/// One owner-only JSON file per chat under `chat-references/`; it only grows while the chat exists.
public enum ChatReferences {
    public static let directoryName = "chat-references"
    private static let pattern = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    /// Every UUID in the text, lowercased, in order and without repeats; the caller maps them to known chats.
    public static func identifiers(in text: String) -> [String] {
        var seen = Set<String>()
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { text[$0].lowercased() }
        }.filter { seen.insert($0).inserted }
    }
    public static func file(chat: String, root: URL = Locations.root) -> URL? {
        guard ChatEventLog.isSafeName(chat) else { return nil }
        return root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(chat + ".json")
    }
    public static func load(chat: String, root: URL = Locations.root) -> [String] {
        guard let url = file(chat: chat, root: root), let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.chats
    }
    /// Adds chat IDs to the chat's list; returns the full list.
    @discardableResult public static func record(_ chats: [String], chat: String, root: URL = Locations.root) throws -> [String] {
        let known = load(chat: chat, root: root)
        let merged = known + chats.filter { !known.contains($0) && $0 != chat }
        guard merged != known, let url = file(chat: chat, root: root) else { return known }
        try ChatEventLog.makeDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(Stored(chats: merged)).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return merged
    }
    public static func remove(chat: String, root: URL = Locations.root) {
        if let url = file(chat: chat, root: root) { try? FileManager.default.removeItem(at: url) }
    }
    private struct Stored: Codable { var chats: [String] }
}

/// What the app saw in a chat that its transcript does not show: turn starts and ends, diagnostics, background waits,
/// processes stopped for it. One owner-only JSON Lines file per chat under `chat-events/`, cut to the latest entries;
/// the chat directory server's `inspect_chat` reads it, because agents cannot read the system log from their sandbox.
public enum ChatEventLog {
    public static let directoryName = "chat-events"
    static let keep = 200, trimBytes = 96 * 1024
    private static let lock = NSLock()

    public struct Event: Codable, Equatable, Sendable {
        public var date: Date
        public var kind: String
        public var text: String
    }
    public static func file(chat: String, root: URL = Locations.root) -> URL? {
        guard isSafeName(chat) else { return nil }
        return root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(chat + ".jsonl")
    }
    public static func append(chat: String, kind: String, text: String, date: Date = Date(), root: URL = Locations.root) {
        guard let url = file(chat: chat, root: root) else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(Event(date: date, kind: kind, text: String(text.prefix(2000)))) else { return }
        line.append(0x0A)
        lock.withLock {
            do {
                try makeDirectory(url.deletingLastPathComponent())
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                try handle.write(contentsOf: line)
                if size + UInt64(line.count) > UInt64(trimBytes) { try trim(url) }
            } catch {}
        }
    }
    public static func events(chat: String, root: URL = Locations.root) -> [Event] {
        guard let url = file(chat: chat, root: root), let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Event.self, from: Data($0)) }
    }
    public static func remove(chat: String, root: URL = Locations.root) {
        if let url = file(chat: chat, root: root) { lock.withLock { try? FileManager.default.removeItem(at: url) } }
    }
    private static func trim(_ url: URL) throws {
        let lines = try Data(contentsOf: url).split(separator: 0x0A).suffix(keep)
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Chat and session IDs only: letters, digits and hyphens, so an ID never leaves its folder.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }
    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
