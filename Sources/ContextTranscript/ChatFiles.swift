import Foundation
import ContextCore

/// One file a chat touched or cited, for the chat's file panel: what the agent edited or read through its tool calls,
/// and the files either side named in messages. Every mention keeps the transcript item it came from, so the panel
/// can jump back to it.
public struct ChatFile: Identifiable, Equatable, Sendable {
    /// Ordered weakest to strongest; a file shows its strongest use.
    public enum Use: Int, Comparable, Sendable {
        case mentioned, read, edited
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public struct Mention: Equatable, Sendable {
        public var itemID: String
        public var use: Use
        public var line: Int?
        public init(itemID: String, use: Use, line: Int? = nil) { self.itemID = itemID; self.use = use; self.line = line }
    }
    /// Absolute, standardized path.
    public var path: String
    public var mentions: [Mention]
    /// The last edit that reached it removed the file.
    public var deleted = false
    public var id: String { path }
    public var use: Use { mentions.map(\.use).max() ?? .mentioned }
    /// The line of the most recent mention that names one.
    public var line: Int? { mentions.last { $0.line != nil }?.line }
    public init(path: String, mentions: [Mention], deleted: Bool = false) {
        self.path = path; self.mentions = mentions; self.deleted = deleted
    }
}

/// A turn whose checkpoints recorded changes, and the transcript item that carries them.
public struct ChatTurnChanges: Identifiable, Equatable, Sendable {
    public var itemID: String
    /// 1-based position among the chat's turns with recorded changes.
    public var number: Int
    public var completedAt: Date?
    public var changes: TurnChanges
    public var id: String { itemID }
    public init(itemID: String, number: Int, completedAt: Date?, changes: TurnChanges) {
        self.itemID = itemID; self.number = number; self.completedAt = completedAt; self.changes = changes
    }
}

/// A changed file summed over the turns that changed it.
public struct ChatChangedFile: Identifiable, Equatable, Sendable {
    /// Repository-relative path after the last change.
    public var path: String
    public var repository: String
    /// Net status across the turns: a file added and later edited stays added; one deleted at the end shows deleted.
    public var status: GitCheckpoints.FileChange.Status
    /// Nil once a turn changed it as a binary file.
    public var added: Int?
    public var removed: Int?
    /// Each turn's own entry for the file, oldest first.
    public var turns: [Step]
    public var id: String { repository + "/" + path }
    public var absolutePath: String { URL(fileURLWithPath: repository).appendingPathComponent(path).path }
    public var isBinary: Bool { added == nil && removed == nil }

    public struct Step: Identifiable, Equatable, Sendable {
        public var turn: ChatTurnChanges
        public var change: GitCheckpoints.FileChange
        public var id: String { turn.itemID }
    }
}

/// Pure and thread-safe: the app collects off the main thread (a 3,000-item chat took about 250 ms on first open).
public enum ChatFiles {
    public typealias FileCheck = @Sendable (String) -> Bool
    /// Collects the files of a transcript, most recently mentioned first. `isFile` decides whether a path cited in text
    /// names an existing regular file; tool-call paths are kept without it (an edited file may since have been deleted).
    public static func collect(_ items: [TranscriptItem], baseDirectory: URL?,
                               isFile: @escaping FileCheck = { ChatFiles.cachedIsFile($0) }) -> [ChatFile] {
        ChatFilesIndex(isFile: isFile).collect(items, baseDirectory: baseDirectory)
    }

    static func collect(_ items: [TranscriptItem], mentions: (TranscriptItem) -> [(String, ChatFile.Mention, Bool)]) -> [ChatFile] {
        var files: [String: ChatFile] = [:]
        var order: [String: Int] = [:]
        var position = 0
        for item in items {
            for (path, mention, deleted) in mentions(item) {
                position += 1
                order[path] = position
                var file = files[path] ?? ChatFile(path: path, mentions: [])
                file.mentions.append(mention)
                if mention.use == .edited { file.deleted = deleted }
                files[path] = file
            }
        }
        return files.values.sorted { order[$0.path, default: 0] > order[$1.path, default: 0] }
    }

    /// Turns that recorded checkpoint changes, in transcript order.
    public static func turnChanges(_ items: [TranscriptItem]) -> [ChatTurnChanges] {
        var result: [ChatTurnChanges] = []
        for item in items {
            guard let changes = item.timing?.changes, changes.start != changes.end else { continue }
            result.append(ChatTurnChanges(itemID: item.id, number: result.count + 1, completedAt: item.timing?.completedAt, changes: changes))
        }
        return result
    }

    /// A turn's changed files from its stored list; nil when it was recorded without one or the list was cut short.
    public static func storedFiles(_ changes: TurnChanges) -> [GitCheckpoints.FileChange]? {
        guard let list = changes.list, list.count == changes.files else { return nil }
        return list.map { GitCheckpoints.FileChange(path: $0.path, oldPath: $0.oldPath,
                                                    status: GitCheckpoints.FileChange.Status(rawValue: $0.status) ?? .modified,
                                                    added: $0.added, removed: $0.removed) }
    }

    /// Sums each turn's changed files per file, most recently changed first. A rename carries the file's earlier
    /// turns over to its new path.
    public static func mergeChanges(_ turns: [(turn: ChatTurnChanges, files: [GitCheckpoints.FileChange])]) -> [ChatChangedFile] {
        var merged: [String: ChatChangedFile] = [:]
        var order: [String: Int] = [:]
        var position = 0
        for (turn, files) in turns.sorted(by: { $0.turn.number < $1.turn.number }) {
            let repository = turn.changes.repository
            for change in files {
                position += 1
                let key = repository + "/" + change.path
                var file: ChatChangedFile
                if let old = change.oldPath, change.status == .renamed, let earlier = merged.removeValue(forKey: repository + "/" + old) {
                    file = earlier
                    file.path = change.path
                } else if let existing = merged[key] {
                    file = existing
                } else {
                    file = ChatChangedFile(path: change.path, repository: repository, status: change.status, added: 0, removed: 0, turns: [])
                }
                if file.turns.isEmpty || change.status == .deleted || file.status == .deleted {
                    // A file deleted and then created again reads as added; the first turn sets the starting status.
                    file.status = file.turns.isEmpty ? change.status : change.status == .deleted ? .deleted : .added
                } else if file.status == .modified, change.status != .modified {
                    file.status = change.status
                }
                if change.isBinary { file.added = nil; file.removed = nil }
                else if let added = file.added, let removed = file.removed {
                    file.added = added + (change.added ?? 0); file.removed = removed + (change.removed ?? 0)
                }
                file.turns.append(ChatChangedFile.Step(turn: turn, change: change))
                merged[key] = file
                order[key] = position
            }
        }
        return merged.values.sorted { order[$0.id, default: 0] > order[$1.id, default: 0] }
    }

    // MARK: Mentions

    static func mentions(in item: TranscriptItem, baseDirectory: URL?, isFile: FileCheck) -> [(String, ChatFile.Mention, Bool)] {
        if let call = item.toolCall { return callMentions(call, itemID: item.id, baseDirectory: baseDirectory, isFile: isFile) }
        guard item.kind == "user" || item.kind == "assistant" else { return [] }
        return textReferences(item.text, baseDirectory: baseDirectory, isFile: isFile)
            .map { ($0.path, ChatFile.Mention(itemID: item.id, use: .mentioned, line: $0.line), false) }
    }

    private static func callMentions(_ call: AgentToolCall, itemID: String, baseDirectory: URL?,
                                     isFile: FileCheck) -> [(String, ChatFile.Mention, Bool)] {
        // A refused or failed edit did not change the file; it still names it.
        let landed = ![.failed, .rejected, .cancelled].contains(call.status)
        let use: ChatFile.Use = switch call.kind {
        case .edit, .delete, .move: landed ? .edited : .mentioned
        case .read: .read
        default: .mentioned
        }
        var result: [(String, ChatFile.Mention, Bool)] = []
        var seen: Set<String> = []
        func add(_ raw: String, line: Int?) {
            guard let path = resolve(raw, baseDirectory: baseDirectory), seen.insert(path).inserted else { return }
            // Searches and other calls may name folders; only files belong in the list.
            if use == .mentioned || call.kind == .read, !isFile(path) { return }
            result.append((path, ChatFile.Mention(itemID: itemID, use: use, line: line), call.kind == .delete && landed))
        }
        for diff in call.diffs { add(diff.path, line: diff.line) }
        for location in call.locations { add(location.path, line: location.line) }
        return result
    }

    private static func resolve(_ raw: String, baseDirectory: URL?) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("://") else { return nil }
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(1) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        guard let baseDirectory else { return nil }
        return URL(fileURLWithPath: path, relativeTo: baseDirectory).standardizedFileURL.path
    }

    private static let fence = try? NSRegularExpression(pattern: #"(?ms)^[ \t]*(`{3,}|~{3,}).*?^[ \t]*\1[ \t]*$"#)
    private static let markdownLink = try? NSRegularExpression(pattern: #"\[[^\]\n]*\]\(([^)\s]+)(?:\s+"[^"\n]*")?\)"#)
    private static let codeSpan = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let plainPath = try? NSRegularExpression(
        pattern: #"(?<![\w/.@:-])(?:~?/)?(?:[\w.@-]+/)+[\w@-][\w.@-]*\.[A-Za-z0-9]{1,10}(?::\d+(?::\d+)?)?"#)

    /// Files cited in message text the way the transcript links them: Markdown links, paths in inline code and bare
    /// paths. Fenced code blocks are skipped; the transcript does not link paths inside them either.
    static func textReferences(_ text: String, baseDirectory: URL?, isFile: FileCheck) -> [(path: String, line: Int?)] {
        guard text.contains("/") || text.contains("`") || text.contains("](") else { return [] }
        var remaining = text as NSString
        if text.contains("```") || text.contains("~~~"), let fence {
            remaining = fence.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: remaining.length), withTemplate: " ") as NSString
        }
        var found: [(range: NSRange, path: String, line: Int?)] = []
        func take(_ expression: NSRegularExpression?, group: Int, explicit: Bool) {
            guard let expression else { return }
            for match in expression.matches(in: remaining as String, range: NSRange(location: 0, length: remaining.length)) {
                guard !found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                var raw = remaining.substring(with: match.range(at: group))
                if explicit {
                    if raw.hasPrefix("file://"), let url = URL(string: raw) { raw = url.path }
                    else if raw.contains(":"), !raw.hasPrefix("/"), lineSuffix(raw) == nil { continue }
                    raw = raw.removingPercentEncoding ?? raw
                }
                guard let reference = fileReference(raw, baseDirectory: baseDirectory, explicit: explicit, isFile: isFile) else { continue }
                found.append((match.range, reference.path, reference.line))
            }
        }
        take(markdownLink, group: 1, explicit: true)
        take(codeSpan, group: 1, explicit: false)
        take(plainPath, group: 0, explicit: false)
        var seen: Set<String> = []
        return found.sorted { $0.range.location < $1.range.location }
            .filter { seen.insert($0.path).inserted }
            .map { ($0.path, $0.line) }
    }

    /// The same resolution as `TranscriptLinks.fileReference` (absolute, `~/` or project-relative; a bare name only in
    /// a Markdown link or with a line), without its main-actor options.
    static func fileReference(_ text: String, baseDirectory: URL?, explicit: Bool, isFile: FileCheck) -> (path: String, line: Int?)? {
        var path = text.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains(" ") || path.hasPrefix("/"), !path.contains("://") else { return nil }
        if let hash = path.firstIndex(of: "#"), hash != path.startIndex { path = String(path[..<hash]) }
        let suffix = lineSuffix(path)
        if let suffix { path.removeLast(suffix.count) }
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(1) }
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if let baseDirectory, path.contains("/") || suffix != nil || explicit {
            url = URL(fileURLWithPath: path, relativeTo: baseDirectory)
        } else { return nil }
        let resolved = url.standardizedFileURL.path
        guard resolved.count > 1, isFile(resolved) else { return nil }
        return (resolved, suffix.flatMap { Int($0.dropFirst().split(separator: ":").first ?? "") })
    }

    private static func lineSuffix(_ value: String) -> String? {
        value.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression).map { String(value[$0]) }
    }

    /// Regular-file checks are cached for a few seconds; a long chat cites the same files many times.
    private static let fileChecks = FileCheckCache()
    public static func cachedIsFile(_ path: String) -> Bool { fileChecks.isFile(path) }
}

private final class FileCheckCache: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: [String: (Bool, Date)] = [:]

    func isFile(_ path: String) -> Bool {
        let now = Date()
        if let (isFile, checked) = lock.withLock({ checks[path] }), now.timeIntervalSince(checked) < 5 { return isFile }
        var directory: ObjCBool = false
        let isFile = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
        lock.withLock {
            if checks.count > 4096 { checks.removeAll() }
            checks[path] = (isFile, now)
        }
        return isFile
    }
}

/// `ChatFiles.collect` with per-item results kept between calls: a streaming update changes only the last message, so
/// the rest is not parsed again (3,000 items: about 250 ms first, about 12 ms after). Results stay until the item
/// changes; a file cited before it existed shows once that message changes or the chat is opened again.
/// Calls must not overlap; the app runs one at a time off the main thread.
public final class ChatFilesIndex: @unchecked Sendable {
    private struct Memo { var item: TranscriptItem; var base: URL?; var found: [(String, ChatFile.Mention, Bool)] }
    private var memo: [String: Memo] = [:]
    private let isFile: ChatFiles.FileCheck
    private let lock = NSLock()

    public init(isFile: @escaping ChatFiles.FileCheck = { ChatFiles.cachedIsFile($0) }) { self.isFile = isFile }

    public func collect(_ items: [TranscriptItem], baseDirectory: URL?) -> [ChatFile] {
        lock.lock(); defer { lock.unlock() }
        var kept: [String: Memo] = [:]
        kept.reserveCapacity(items.count)
        let files = ChatFiles.collect(items) { item in
            if let cached = memo[item.id], cached.base == baseDirectory, cached.item == item {
                kept[item.id] = cached
                return cached.found
            }
            let found = ChatFiles.mentions(in: item, baseDirectory: baseDirectory, isFile: isFile)
            kept[item.id] = Memo(item: item, base: baseDirectory, found: found)
            return found
        }
        // Only the current transcript's items stay; another chat's are dropped with it.
        memo = kept
        return files
    }
}
