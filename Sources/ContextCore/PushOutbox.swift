import Foundation

/// Held, released and sent push events of one Mac (plan 4.2-4.5). A pure value: time and the "away" state are inputs,
/// there are no timers or I/O. The owner calls `due(now:away:)` when something is held (every 20 seconds) or a retry
/// is scheduled (`nextRetry`), sends what it returns, and reports each result with `delivered` / `failed` / `drop`.
public struct PushOutbox: Sendable, Equatable {
    /// Turn and attention events are dropped if the user does not become away within this time (the Mac showed them).
    public static let presentWindow: TimeInterval = 10 * 60
    /// Delays after the first and second transport failure.
    public static let transportDelays: [TimeInterval] = [30, 120]
    public static let maximumAttempts = 3
    /// Remembered sent events (for withdrawal and de-duplication).
    public static let sentLimit = 200

    public struct Entry: Sendable, Equatable {
        public let event: PushEvent
        public let posted: Date
        /// Attempts handed out by `due`.
        public internal(set) var attempts = 0
        /// Earliest time of the next attempt after a failure.
        public internal(set) var notBefore: Date?
        /// True while an attempt is out (between `due` and its result).
        public internal(set) var sending = false
    }
    /// Sent events that a withdrawal must reach on the phone.
    public struct Withdrawal: Sendable, Equatable {
        public init() {}
        public var events: [String] = []
        public var chats: [String] = []
        public var isEmpty: Bool { events.isEmpty && chats.isEmpty }
    }
    struct Sent: Sendable, Equatable { let id: String; let kind: PushMarker.Kind; let chat: String? }

    /// "Only while I am away from the Mac". Off: every event is due at once.
    public var onlyWhileAway: Bool
    public private(set) var held: [Entry] = []
    private(set) var sent: [Sent] = []

    public init(onlyWhileAway: Bool = true) { self.onlyWhileAway = onlyWhileAway }

    /// True while an event waits; the owner keeps its 20-second re-check timer only then.
    public var isHolding: Bool { !held.isEmpty }
    /// The earliest scheduled retry, if any.
    public var nextRetry: Date? { held.compactMap(\.notBefore).min() }

    /// Adds an event. False for a duplicate ID (held or already sent) and for a withdrawal kind. A turn event replaces
    /// a held, not yet sending turn event of the same chat.
    @discardableResult
    public mutating func post(_ event: PushEvent, now: Date) -> Bool {
        guard event.kind != .withdraw, !held.contains(where: { $0.event.id == event.id }),
              !sent.contains(where: { $0.id == event.id }) else { return false }
        if event.kind == .turn {
            held.removeAll { $0.event.kind == .turn && $0.event.chat == event.chat && !$0.sending }
        }
        held.append(Entry(event: event, posted: now))
        return true
    }

    /// Resolved or read events: held ones are removed (nothing reaches the phone). Returns the part that already went
    /// out or is being sent, which needs a withdrawal push; it is forgotten so it is withdrawn once. `chats` withdraws
    /// turn notifications of those chats.
    public mutating func withdraw(events: Set<String>, chats: Set<String>) -> Withdrawal {
        func matches(_ id: String, _ kind: PushMarker.Kind, _ chat: String?) -> Bool {
            events.contains(id) || (kind == .turn && chat.map(chats.contains) == true)
        }
        var result = Withdrawal()
        for entry in held where entry.sending && matches(entry.event.id, entry.event.kind, entry.event.chat) {
            result.events.append(entry.event.id)
        }
        held.removeAll { matches($0.event.id, $0.event.kind, $0.event.chat) }
        for item in sent where matches(item.id, item.kind, item.chat) {
            if item.kind == .turn, let chat = item.chat, chats.contains(chat) {
                if !result.chats.contains(chat) { result.chats.append(chat) }
            } else { result.events.append(item.id) }
        }
        sent.removeAll { matches($0.id, $0.kind, $0.chat) }
        return result
    }

    /// Events to send now; each is marked as sending and counts one attempt. Expired events are dropped first:
    /// past their APNs lifetime, or (while the user is at the Mac) turn and attention events older than 10 minutes.
    /// `test` ignores the away rule; so does a retry of an event that was already released once.
    public mutating func due(now: Date, away: Bool) -> [PushEvent] {
        held.removeAll { entry in
            guard !entry.sending else { return false }
            let age = now.timeIntervalSince(entry.posted)
            if entry.event.lifetime > 0 && age >= entry.event.lifetime { return true }
            if entry.event.kind == .test && age >= 60 { return true }
            let present = onlyWhileAway && !away && entry.attempts == 0
            return present && [.turn, .attention].contains(entry.event.kind) && age >= Self.presentWindow
        }
        var result: [PushEvent] = []
        for index in held.indices where !held[index].sending {
            let entry = held[index]
            if let notBefore = entry.notBefore, notBefore > now { continue }
            let released = !onlyWhileAway || away || entry.event.kind == .test || entry.attempts > 0
            guard released else { continue }
            held[index].attempts += 1; held[index].sending = true; held[index].notBefore = nil
            result.append(entry.event)
        }
        return result
    }

    /// At least one device answered 200: the event is remembered as sent (bounded) for withdrawal.
    public mutating func delivered(_ id: String) {
        guard let index = held.firstIndex(where: { $0.event.id == id }) else { return }
        let event = held.remove(at: index).event
        sent.append(Sent(id: event.id, kind: event.kind, chat: event.chat))
        if sent.count > Self.sentLimit { sent.removeFirst(sent.count - Self.sentLimit) }
    }

    /// No device accepted the event. `retryAfter` nil = transport failure (30 seconds, then 2 minutes); otherwise
    /// APNs' delay (429: 60 seconds, 5xx: 15 minutes). After `maximumAttempts` attempts the event is dropped.
    public mutating func failed(_ id: String, retryAfter: TimeInterval?, now: Date) {
        guard let index = held.firstIndex(where: { $0.event.id == id }) else { return }
        let attempts = held[index].attempts
        guard attempts < Self.maximumAttempts else { held.remove(at: index); return }
        let delay = retryAfter ?? Self.transportDelays[min(max(attempts - 1, 0), Self.transportDelays.count - 1)]
        held[index].sending = false
        held[index].notBefore = now.addingTimeInterval(delay)
    }

    /// Removes an event without retry (no devices, rejected request, credential failure).
    public mutating func drop(_ id: String) { held.removeAll { $0.event.id == id } }

    /// Forgets everything (remote access or notifications turned off, key changed, credential failure).
    public mutating func reset() { held = []; sent = [] }
}
