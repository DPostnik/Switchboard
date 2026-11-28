import Foundation
import AgentContract
import CryptoKit

public enum ArchiveSummaryStatus: String, Codable, Sendable {
    case queued, reading, generating, ready, failed, uncertain, stale

    public func label(language: AppLanguage = L10n.language) -> String {
        switch self {
        case .queued: L10n.text("Итог в очереди", "Summary queued", language: language)
        case .reading: L10n.text("Подготовка переписки…", "Preparing conversation…", language: language)
        case .generating: L10n.text("Подготовка итога…", "Preparing summary…", language: language)
        case .ready: L10n.text("Краткий итог готов", "Summary ready", language: language)
        case .failed: L10n.text("Не удалось подготовить итог", "Summary failed", language: language)
        case .uncertain: L10n.text("Результат запроса неизвестен", "Request outcome unknown", language: language)
        case .stale: L10n.text("Итог требует обновления", "Summary needs updating", language: language)
        }
    }
}

public struct SummaryActivity: Codable, Equatable, Sendable {
    public var goal: String
    public var actions: [String]
    public var outcome: String
    public var unfinished: [String]
    public var reusableSteps: [String]
    public var variableInputs: [String]
    public var evidence: [String]
}

public struct SummaryContent: Codable, Equatable, Sendable {
    public var overview: String
    public var activities: [SummaryActivity]
}

public struct SummaryPart: Codable, Equatable, Sendable {
    public var sourceDigest: String
    public var content: SummaryContent
    public var tokens: TokenCounters?
    public var seconds: Double
    public init(sourceDigest: String, content: SummaryContent, tokens: TokenCounters?, seconds: Double) {
        self.sourceDigest = sourceDigest; self.content = content; self.tokens = tokens; self.seconds = seconds
    }
}

public struct ArchiveSummaryRecord: Codable, Equatable, Identifiable, Sendable {
    public var conversationID: ConversationID { ConversationID(threadID) }
    public var id: String { threadID }
    public var threadID: String
    public var projectID: UUID
    public var attempt = UUID()
    public var status: ArchiveSummaryStatus = .queued
    public var sourceDigest = ""
    public var recipeDigest = ""
    public var sourceReferences: [String] = []
    public var sourceTurnDates: [String: Double]?
    public var omittedDetails = false
    public var partCount = 0
    public var parts: [SummaryPart] = []
    public var updatedAt = Date()
    public var issue: String?
    public var cancelledByUser: Bool?
    public var model = ""
    public var route = RequestRoute.direct
    public init(threadID: String, projectID: UUID) { self.threadID = threadID; self.projectID = projectID }

    public mutating func enqueue() {
        attempt = UUID(); status = .queued; issue = nil; cancelledByUser = nil; updatedAt = Date()
    }

    public mutating func cancelQueued(at date: Date) {
        guard status == .queued else { return }
        status = .stale
        issue = nil
        cancelledByUser = true
        updatedAt = date
    }

    public func statusLabel() -> String {
        cancelledByUser == true ? L10n.text("Подготовка отменена", "Summary cancelled") : status.label()
    }

    public mutating func recover() {
        if status == .reading { status = .queued }
        // A durable generating checkpoint may precede a sent turn. Never replay it.
        if status == .generating { status = .uncertain }
    }
}

public struct SummarySource: Sendable {
    public struct Fragment: Codable, Sendable {
        public var reference: String
        public var kind: String
        public var text: String
        public init(reference: String, kind: String, text: String) {
            self.reference = reference; self.kind = kind; self.text = text
        }
    }
    public struct Chunk: Sendable {
        public var fragments: [Fragment]
        public var digest: String
        public var json: String
    }
    public var digest: String
    public var references: [String] = []
    public var chunks: [Chunk] = []
    public var turnDates: [String: Double] = [:]
    public var omittedDetails: Bool

    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Bound normalized fragments without depending on an engine's history protocol.
    public init(digest: String, fragments: [Fragment], turnDates: [String: Double], omittedDetails: Bool) throws {
        self.digest = digest; self.turnDates = turnDates; self.omittedDetails = omittedDetails
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        references = fragments.map(\.reference)
        chunks = []
        var group: [Fragment] = [], size = 0
        func appendChunk() throws {
            guard !group.isEmpty else { return }
            let data = try encoder.encode(group)
            chunks.append(Chunk(fragments: group, digest: Self.hash(data), json: String(decoding: data, as: UTF8.self)))
            group = []; size = 0
        }
        for fragment in fragments {
            let count = try encoder.encode(fragment).count
            guard count <= 48_000 else {
                throw ClientFailure(L10n.text("Фрагмент истории превышает размер запроса итога", "A history fragment exceeds the summary input limit"))
            }
            if size + count > 48_000 { try appendChunk() }
            group.append(fragment); size += count
        }
        try appendChunk()
    }
}

public struct ArchiveSummaryRecipe: Sendable {
    public let instructions: String
    public let schema: JSONValue
    public let digest: String

    public init(directory: URL) throws {
        let instructions = try Data(contentsOf: directory.appendingPathComponent("SKILL.md"))
        let schema = try Data(contentsOf: directory.appendingPathComponent("schema.json"))
        guard instructions.count < 64_000, schema.count < 64_000 else {
            throw ClientFailure(L10n.text("Слишком большой файл навыка", "Skill file is too large"))
        }
        self.instructions = String(decoding: instructions, as: UTF8.self)
        self.schema = try JSONDecoder().decode(JSONValue.self, from: schema)
        digest = SummarySource.hash(instructions + schema)
    }

    public func validate(_ text: String, chunk: SummarySource.Chunk) throws -> SummaryContent {
        guard text.utf8.count <= 64_000 else { throw invalidResult() }
        let result = try JSONDecoder().decode(SummaryContent.self, from: Data(text.utf8))
        let references = Set(chunk.fragments.map(\.reference))
        guard !result.overview.isEmpty, result.overview.count <= 2000, result.activities.count <= 30 else { throw invalidResult() }
        for activity in result.activities {
            let strings = [activity.goal, activity.outcome] + activity.actions + activity.unfinished + activity.reusableSteps + activity.variableInputs
            guard !activity.goal.isEmpty, strings.allSatisfy({ $0.count <= 2000 }), strings.count <= 100,
                  !activity.evidence.isEmpty, activity.evidence.count <= 100,
                  activity.evidence.allSatisfy({ references.contains($0) }) else { throw invalidResult() }
        }
        return result
    }

    private func invalidResult() -> ClientFailure {
        ClientFailure(L10n.text("Итог не прошёл проверку формата или ссылок", "Summary failed format or source-reference validation"))
    }
}
