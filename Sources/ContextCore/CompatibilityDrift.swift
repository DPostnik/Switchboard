import Foundation
import os
import AgentContract

/// Protocol drift seen in this app process: engine messages, item types or fields an adapter does not
/// recognize. Decoding is unchanged; this only makes silent drops visible.
///
/// A record is (agent, engine version, category, name) and never carries payload content. The first
/// occurrence of each record is written to the unified log (category `compatibility`); later ones are only
/// counted in memory. Distinct records are capped, so a misbehaving engine cannot grow memory or the log.
public final class CompatibilityDrift: Sendable {
    public enum Category: String, CaseIterable, Codable, Sendable {
        case notification, serverRequest, itemType, frameType, systemSubtype, streamEvent, controlRequest, missingField

        public var title: String {
            switch self {
            case .notification: L10n.text("уведомление", "notification")
            case .serverRequest: L10n.text("запрос движка", "engine request")
            case .itemType: L10n.text("тип элемента", "item type")
            case .frameType: L10n.text("тип сообщения", "message type")
            case .systemSubtype: L10n.text("системное событие", "system event")
            case .streamEvent: L10n.text("событие потока", "stream event")
            case .controlRequest: L10n.text("управляющий запрос", "control request")
            case .missingField: L10n.text("нет поля", "missing field")
            }
        }
    }

    public struct Key: Hashable, Sendable {
        public let agent: AgentID
        public let version: String
        public let category: Category
        public let name: String
    }

    public struct Entry: Hashable, Sendable {
        public let key: Key
        public var count: Int
        public let firstSeen: Date
    }

    public static let shared = CompatibilityDrift()
    /// Posted (on the recording thread) when a record is seen for the first time.
    public static let changed = Notification.Name("local.daniil.switchboard.compatibility-drift")
    static let keyLimit = 200
    static let nameLimit = 120
    /// Records past `keyLimit` are counted under this name.
    static let overflowName = "(more)"

    private let entries = OSAllocatedUnfairLock(initialState: [Key: Entry]())
    private let unverified = OSAllocatedUnfairLock(initialState: Set<String>())
    private let logger: Logger?

    public init(logging: Bool = true) {
        logger = logging ? Logger(subsystem: "local.daniil.switchboard", category: "compatibility") : nil
    }

    /// Counts one occurrence. Returns true when this record is new in this process (and was logged).
    @discardableResult
    public func record(_ agent: AgentID, version: String?, _ category: Category, _ name: String, at date: Date = Date()) -> Bool {
        let requested = Key(agent: agent, version: Self.clean(version ?? "", limit: 40, empty: "unknown"),
                            category: category, name: Self.clean(name, limit: Self.nameLimit, empty: "(none)"))
        let (first, key) = entries.withLock { entries -> (Bool, Key) in
            var key = requested
            if entries[key] == nil, entries.count >= Self.keyLimit {
                key = Key(agent: key.agent, version: key.version, category: key.category, name: Self.overflowName)
            }
            if entries[key] != nil { entries[key]!.count += 1; return (false, key) }
            entries[key] = Entry(key: key, count: 1, firstSeen: date)
            return (true, key)
        }
        guard first else { return false }
        logger?.notice("Protocol drift: agent=\(key.agent.rawValue, privacy: .public) version=\(key.version, privacy: .public) category=\(key.category.rawValue, privacy: .public) name=\(key.name, privacy: .public)")
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }

    /// Logs once per process that an unverified (same-branch) engine version was accepted.
    public func noteUnverified(_ agent: AgentID, version: String) {
        let key = "\(agent.rawValue) \(Self.clean(version, limit: 40, empty: "unknown"))"
        guard unverified.withLock({ $0.insert(key).inserted }) else { return }
        logger?.notice("Unverified engine version connected: agent=\(agent.rawValue, privacy: .public) version=\(Self.clean(version, limit: 40, empty: "unknown"), privacy: .public)")
    }

    /// Records of one agent (or all), most frequent first.
    public func snapshot(agent: AgentID? = nil) -> [Entry] {
        entries.withLock { Array($0.values) }
            .filter { agent == nil || $0.key.agent == agent }
            .sorted { ($0.count, $1.key.name) > ($1.count, $0.key.name) }
    }

    /// Identifiers are engine data, not content; still keep them short and printable.
    static func clean(_ text: String, limit: Int, empty: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./:#"))
        let scalars = text.unicodeScalars.prefix(limit).map { allowed.contains($0) && $0.isASCII ? Character($0) : "?" }
        let value = String(scalars)
        return value.isEmpty ? empty : value
    }

    /// One line for the UI, or nil when nothing was seen: "3 kinds, 12 times: notification foo ×5, …".
    public static func summary(_ entries: [Entry], limit: Int = 4) -> String? {
        guard !entries.isEmpty else { return nil }
        let total = entries.reduce(0) { $0 + $1.count }
        let shown = entries.prefix(limit).map { "\($0.key.category.title) \($0.key.name) ×\($0.count)" }.joined(separator: ", ")
        let more = entries.count > limit ? L10n.text(", и ещё \(entries.count - limit)", ", and \(entries.count - limit) more") : ""
        return L10n.text("Незнакомые данные протокола с запуска: видов \(entries.count), раз \(total). ",
                         "Unrecognized protocol data since launch: \(entries.count) kinds, \(total) times. ") + shown + more
    }
}
