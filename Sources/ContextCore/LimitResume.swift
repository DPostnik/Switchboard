import Foundation

/// A chat's turn stopped on an exhausted usage limit, and the user's one-click request to continue after the reset.
///
/// Stored with the chat, so an armed continuation survives a restart. The record is removed in the same state change
/// that queues the continuation, so the message is queued at most once; the queue itself never retries an uncertain send.
public struct LimitResume: Codable, Hashable, Sendable {
    /// The engine's own reset time for this stop; nil falls back to the account limits.
    public var resetsAt: Date?
    /// When the continuation goes out. Only the user's click sets it; Cancel clears it.
    public var continueAt: Date?
    public var isArmed: Bool { continueAt != nil }

    public init(resetsAt: Date?, continueAt: Date? = nil) {
        self.resetsAt = resetsAt; self.continueAt = continueAt
    }

    /// The continuation waits this long after the reset, so the limiter has certainly let go.
    public static let margin: TimeInterval = 60
    /// Longest wait between wall-clock checks; covers sleep and clock changes without a monotonic timer.
    public static let recheck: TimeInterval = 30
    /// Queued continuation IDs start with this; such a send does not count as the user's own message.
    public static let messageIDPrefix = "local-user:limit-resume:"

    public static func message(language: AppLanguage = L10n.language) -> String {
        L10n.text("Продолжай с того места, где остановился.", "Continue where you left off.", language: language)
    }

    /// The reset to wait for: the engine's own, else the latest reset among exhausted account windows still ahead.
    public func reset(limits: AccountLimits?, now: Date) -> Date? {
        resetsAt ?? Self.exhaustedReset(limits, now: now)
    }

    /// Every exhausted window must reset before work can go on, so the latest of them counts.
    /// No exhausted window with a future reset means no automatic time.
    public static func exhaustedReset(_ limits: AccountLimits?, now: Date) -> Date? {
        limits?.buckets.flatMap(\.windows).filter { $0.remainingPercent == 0 }.compactMap(\.resetsAt).filter { $0 > now }.max()
    }

    /// The record after the user's click: the reset plus the margin, never earlier than now.
    public func armed(reset: Date, now: Date) -> LimitResume {
        var copy = self
        copy.continueAt = max(reset.addingTimeInterval(Self.margin), now)
        return copy
    }

    /// What the chat looks like at a check.
    public struct Situation: Equatable, Sendable {
        public var exists: Bool
        public var archived: Bool
        /// The chat's agent is connected and signed in, and the app is not quitting.
        public var ready: Bool
        /// A turn, send, request, background wait or queued message is in progress.
        public var busy: Bool
        public init(exists: Bool, archived: Bool, ready: Bool, busy: Bool) {
            self.exists = exists; self.archived = archived; self.ready = ready; self.busy = busy
        }
    }

    public enum Step: Equatable, Sendable {
        /// Nothing armed.
        case none
        /// Check again at this time (wall clock).
        case wait(until: Date)
        /// Remove the record and queue the continuation once.
        case send
        /// The chat is busy at the time: drop the plan and show the offer again instead of queuing blindly.
        case disarm
        /// The chat is gone or archived: forget the record.
        case drop
    }

    public static func step(_ resume: LimitResume?, situation: Situation, now: Date) -> Step {
        guard let resume, let due = resume.continueAt else { return .none }
        if !situation.exists || situation.archived { return .drop }
        if now < due { return .wait(until: min(due, now.addingTimeInterval(recheck))) }
        // The time has passed (also while the app was closed): wait for the agent, then send only to an idle chat.
        if !situation.ready { return .wait(until: now.addingTimeInterval(recheck)) }
        return situation.busy ? .disarm : .send
    }

    /// "14:30" today, otherwise with the date.
    public static func timeText(_ date: Date, now: Date, language: AppLanguage = L10n.language, calendar: Calendar = .current) -> String {
        let style: Date.FormatStyle = calendar.isDate(date, inSameDayAs: now)
            ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle(date: .abbreviated, time: .shortened)
        var formatted = style.locale(language.locale)
        formatted.calendar = calendar; formatted.timeZone = calendar.timeZone
        return date.formatted(formatted)
    }

    public static func offerText(reset: Date?, now: Date, language: AppLanguage = L10n.language, calendar: Calendar = .current) -> String {
        guard let reset else {
            return L10n.text("Лимит исчерпан. Время сброса неизвестно.", "Usage limit reached. Reset time unknown.", language: language)
        }
        let time = timeText(reset, now: now, language: language, calendar: calendar)
        return L10n.text("Лимит исчерпан. Сброс в \(time).", "Usage limit reached. Resets at \(time).", language: language)
    }

    public static func armedText(_ due: Date, now: Date, language: AppLanguage = L10n.language, calendar: Calendar = .current) -> String {
        let time = timeText(due, now: now, language: language, calendar: calendar)
        return L10n.text("Продолжу в \(time)", "Will continue at \(time)", language: language)
    }
}
