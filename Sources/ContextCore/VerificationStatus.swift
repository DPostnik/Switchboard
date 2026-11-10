import Foundation

/// Read-only projection written atomically by the project verification coordinator.
public struct VerificationStatus: Decodable, Sendable {
    public let schemaVersion: Int
    public let tasks: [Entry]
    public let batches: [Batch]?
    public struct Batch: Decodable, Identifiable, Sendable {
        public let id: String
        public let status: String
        public let created_at: Double
        public let started_at: Double?
        public let finished_at: Double?
        public var waitingSeconds: Int { Self.elapsed(from: created_at, to: started_at ?? finished_at ?? Date().timeIntervalSince1970) }
        public var runningSeconds: Int? {
            started_at.map { Self.elapsed(from: $0, to: finished_at ?? Date().timeIntervalSince1970) }
        }
        private static func elapsed(from start: Double, to end: Double) -> Int {
            let seconds = end - start
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int(min(seconds, 315_576_000_000))
        }
    }
    public struct Entry: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let status: String
        public let blocker: String?
    }
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1 else { throw StatusError.unsupportedVersion }
        return value
    }
    public enum StatusError: Error { case unsupportedVersion }
    public static func title(_ status: String, language: AppLanguage = L10n.language) -> String {
        let pair: (String, String)
        switch status {
        case "queued", "ready": pair = ("Готово к проверке", "Ready for verification")
        case "waiting", "waiting_dependencies": pair = ("Ожидает зависимость", "Waiting for dependency")
        case "planned": pair = ("В очереди проверки", "Verification queued")
        case "running": pair = ("Идёт проверка", "Verification running")
        case "passed", "verified": pair = ("Проверено", "Verified")
        case "awaiting_live", "awaiting_live_verification": pair = ("Нужна проверка в приложении", "App verification needed")
        case "failed": pair = ("Нужно исправление", "Fix needed")
        case "flaky": pair = ("Нестабильная проверка", "Unstable check")
        case "interrupted": pair = ("Прервано; результат не подтверждён", "Interrupted; result unconfirmed")
        case "blocked", "conflict": pair = ("Проверка заблокирована", "Verification blocked")
        case "cancelled": pair = ("Отменено", "Cancelled")
        case "published": pair = ("Опубликовано", "Published")
        default: pair = ("Неизвестное состояние", "Unknown status")
        }
        return L10n.text(pair.0, pair.1, language: language)
    }
}
