import Foundation

/// An important message that stays highlighted until the user resolves it, unlike transient notices.
public struct AttentionItem: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Reported by the agent with a `BLOCKER:` line in a scheduled run's final answer.
        case blocker
        /// A scheduled run that failed, was blocked or has an unconfirmed outcome.
        case runProblem
    }
    public var id = UUID()
    public var kind: Kind
    public var text: String
    public var detail: String?
    public var jobID: UUID?
    public var jobName: String
    public var runID: UUID?
    public var threadID: String?
    public var created: Date
    public var lastSeen: Date
    public var occurrences = 1
    public var resolved: Date?
    /// Set when a later successful run cleared a run problem; blockers are only resolved by the user.
    public var resolvedAutomatically = false
    public var isOpen: Bool { resolved == nil }
    public init(kind: Kind, text: String, detail: String? = nil, jobID: UUID?, jobName: String,
                runID: UUID?, threadID: String?, now: Date) {
        self.kind = kind; self.text = text; self.detail = detail; self.jobID = jobID; self.jobName = jobName
        self.runID = runID; self.threadID = threadID; self.created = now; self.lastSeen = now
    }
}

/// The scheduled run whose result is being recorded.
public struct AttentionSource: Sendable {
    public var jobID: UUID
    public var jobName: String
    public var runID: UUID
    public var threadID: String?
    public init(jobID: UUID, jobName: String, runID: UUID, threadID: String?) {
        self.jobID = jobID; self.jobName = jobName; self.runID = runID; self.threadID = threadID
    }
}

public struct AttentionLedger: Codable, Equatable, Sendable {
    public var version = 1
    public var items: [AttentionItem] = []
    public init() {}
    public static let resolvedLimit = 100

    public var open: [AttentionItem] { items.filter(\.isOpen).sorted { $0.lastSeen > $1.lastSeen } }
    public var resolved: [AttentionItem] {
        items.filter { !$0.isOpen }.sorted { ($0.resolved ?? $0.lastSeen) > ($1.resolved ?? $1.lastSeen) }
    }

    /// Records one finished run. Repeated reports of an open item update it instead of adding a duplicate.
    /// Returns the newly created items, which are the only ones worth a system notification.
    @discardableResult
    public mutating func record(_ source: AttentionSource, status: JobRunStatus, output: String, now: Date = Date()) -> [AttentionItem] {
        var created: [AttentionItem] = []
        func upsert(_ kind: AttentionItem.Kind, _ text: String, detail: String?) {
            let key = Self.key(text)
            if let index = items.firstIndex(where: { $0.isOpen && $0.kind == kind && $0.jobID == source.jobID && Self.key($0.text) == key }) {
                items[index].lastSeen = now; items[index].occurrences += 1
                items[index].runID = source.runID; items[index].threadID = source.threadID ?? items[index].threadID
                items[index].jobName = source.jobName
                if let detail { items[index].detail = detail }
            } else {
                let item = AttentionItem(kind: kind, text: text, detail: detail, jobID: source.jobID, jobName: source.jobName,
                                         runID: source.runID, threadID: source.threadID, now: now)
                items.append(item); created.append(item)
            }
        }
        for blocker in AttentionMarkers.blockers(in: output) { upsert(.blocker, blocker, detail: nil) }
        switch status {
        case .failed, .blocked, .uncertain:
            let excerpt = Self.excerpt(output)
            upsert(.runProblem, status.title, detail: excerpt.isEmpty ? nil : excerpt)
        case .completed:
            // A successful run supersedes earlier failures of the same task; reported blockers stay open.
            for index in items.indices where items[index].isOpen && items[index].kind == .runProblem && items[index].jobID == source.jobID {
                items[index].resolved = now; items[index].resolvedAutomatically = true
            }
        // A skipped run found nothing to do; it neither raises nor clears problems.
        case .starting, .running, .interrupted, .skipped: break
        }
        prune()
        return created
    }

    @discardableResult public mutating func resolve(_ id: UUID, now: Date = Date()) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && $0.isOpen }) else { return false }
        items[index].resolved = now; items[index].resolvedAutomatically = false
        return true
    }
    @discardableResult public mutating func reopen(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && !$0.isOpen }) else { return false }
        let key = Self.key(items[index].text)
        // Reopening never creates a duplicate of an item that was reported again meanwhile.
        guard !items.contains(where: { $0.isOpen && $0.kind == items[index].kind && $0.jobID == items[index].jobID && Self.key($0.text) == key }) else { return false }
        items[index].resolved = nil; items[index].resolvedAutomatically = false
        return true
    }
    public mutating func clearResolved() { items.removeAll { !$0.isOpen } }

    private mutating func prune() {
        let keep = Set(resolved.prefix(Self.resolvedLimit).map(\.id))
        items.removeAll { !$0.isOpen && !keep.contains($0.id) }
    }
    static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func excerpt(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }
}

/// Explicit, line-based markers in an agent's final answer. Free-form mentions of "blocker" are ignored.
public enum AttentionMarkers {
    public static let prefix = "BLOCKER:"
    public static let maxPerRun = 20
    public static let maxLength = 500

    public static func blockers(in text: String) -> [String] {
        var result: [String] = []
        var fenced = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced else { continue }
            // Tolerate list, quote and emphasis wrappers an agent may add around the marker.
            while let first = line.first, ["-", "*", "+", ">", "•"].contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            var body = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            body = String(body.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            guard !body.isEmpty else { continue }
            if body.count > maxLength { body = String(body.prefix(maxLength)) + "…" }
            guard !result.contains(where: { AttentionLedger.key($0) == AttentionLedger.key(body) }) else { continue }
            result.append(body)
            if result.count == maxPerRun { break }
        }
        return result
    }

    /// Appended to every scheduled run so blockers reach the app's important messages.
    public static func instructions(language: AppLanguage = L10n.language) -> String {
        L10n.text(
            "Если в этом запуске что-то блокирует задачу и требует действия или решения пользователя, в конце итогового ответа добавь по отдельной строке на каждый блокер в формате `BLOCKER: что мешает и что нужно сделать пользователю` (одно короткое предложение). Switchboard покажет эти строки в разделе «Важное», пока пользователь не отметит их решёнными. Не используй префикс BLOCKER: для частичных результатов, которые не требуют участия пользователя, и не пиши его, если блокеров нет.",
            "If something in this run blocks the task and needs the user's action or decision, end your final answer with one line per blocker in the form `BLOCKER: what is blocked and what the user needs to do` (one short sentence). Switchboard shows these lines under Important until the user marks them resolved. Do not use the BLOCKER: prefix for partial results that need no user involvement, and omit it when there are no blockers.",
            language: language)
    }
}

/// Persists important messages. A corrupt or unknown file is never overwritten.
public actor AttentionStore {
    private let file: URL
    private var ledger: AttentionLedger?
    public init(file: URL = Locations.root.appendingPathComponent("attention.json")) { self.file = file }
    public func load() throws -> AttentionLedger {
        if let ledger { return ledger }
        let value = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(AttentionLedger.self, from: Data(contentsOf: file)) : AttentionLedger()
        guard value.version == 1 else {
            throw ClientFailure(L10n.text("Неизвестный формат файла важных сообщений.", "Unknown format of the important messages file."))
        }
        ledger = value
        return value
    }
    @discardableResult
    public func update<T: Sendable>(_ change: @Sendable (inout AttentionLedger) -> T) throws -> (AttentionLedger, T) {
        var value = try load()
        let result = change(&value)
        guard value != ledger else { return (value, result) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // No data-protection class: agents and jobs update this file while the Mac is locked; 0600 keeps it private.
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        ledger = value
        return (value, result)
    }
}
