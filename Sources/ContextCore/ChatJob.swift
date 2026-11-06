import Foundation
import AgentContract

/// The chat's current job: what "done" means for it, set by the user, and whether it is still open. The agent learns
/// the criterion, and later that the job was closed, through `ChatJobNote` on the next message it receives.
public struct ChatJob: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case active, done, cancelled }
    /// What the agent still has to be told with the next message.
    public enum Note: Hashable, Sendable {
        case criterion(String)
        case closed(done: Bool)
    }
    public static let criterionLimit = 2_000

    public var doneWhen: String
    public var started: Date
    public var status: Status
    public var finished: Date?
    /// The criterion the agent last received; nil while it knows of no open job.
    public var announced: String?

    public init(doneWhen: String, started: Date = Date(), announced: String? = nil) {
        self.doneWhen = doneWhen; self.started = started; status = .active; self.announced = announced
    }

    public var isActive: Bool { status == .active }

    /// Criterion text as stored: trimmed and capped; nil when nothing is left.
    public static func criterion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(criterionLimit))
    }

    /// Time since the job started, up to its close.
    public func elapsed(now: Date = Date()) -> TimeInterval {
        max(0, (finished ?? now).timeIntervalSince(started))
    }

    public var pendingNote: Note? {
        switch status {
        case .active: announced == doneWhen ? nil : .criterion(doneWhen)
        case .done, .cancelled: announced == nil ? nil : .closed(done: status == .done)
        }
    }

    /// The agent received `note`; a note for an older state changes nothing.
    public mutating func markAnnounced(_ note: Note) {
        guard note == pendingNote else { return }
        announced = isActive ? doneWhen : nil
    }

    public mutating func close(done: Bool, at date: Date = Date()) {
        guard isActive else { return }
        status = done ? .done : .cancelled
        finished = date
    }

    public static func noteText(_ note: Note, language: AppLanguage = L10n.language) -> String {
        switch note {
        case .criterion(let text):
            L10n.text(ChatJobNote.russianCriterion(text), ChatJobNote.englishCriterion(text), language: language)
        case .closed(let done):
            L10n.text(ChatJobNote.russianClosed(done: done), ChatJobNote.englishClosed(done: done), language: language)
        }
    }

    /// Hours and minutes for long jobs, the response format below an hour: "16 ч 48 мин" / "16h 48m".
    public static func duration(_ seconds: TimeInterval, language: AppLanguage = L10n.language) -> String {
        let total = Int(seconds.isFinite ? min(max(seconds, 0), 1e9) : 0)
        guard total >= 3_600 else { return ResponseTiming.duration(total, language: language) }
        let hours = total / 3_600, minutes = total % 3_600 / 60
        return L10n.text("\(hours) ч \(minutes) мин", "\(hours)h \(minutes)m", language: language)
    }
}
