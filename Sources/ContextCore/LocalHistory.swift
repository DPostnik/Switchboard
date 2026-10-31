import Foundation
import AgentContract
import CryptoKit

public enum LocalHistory {
    public static func snapshot(conversation: ConversationID, source: AgentSessionReference,
                                turns: [AgentHistoryTurn], timings: [String: ResponseTiming] = [:],
                                capturedAt: Date = Date()) throws -> AgentTranscriptSnapshot {
        let items = turns.flatMap { turn in
            var entries = turn.items
            for index in entries.indices { entries[index].turnID = turn.id }
            ResponseTiming.apply(turn.timing(fallback: timings[turn.id ?? ""]), to: &entries)
            return entries
        }
        return try snapshot(conversation: conversation, source: source, items: items,
                            completeness: turns.allSatisfy(\.isComplete) ? .complete : .partial, capturedAt: capturedAt)
    }

    public static func snapshot(conversation: ConversationID, source: AgentSessionReference,
                                items: [TranscriptItem], completeness: AgentTranscriptSnapshot.Completeness = .partial,
                                capturedAt: Date = Date()) throws -> AgentTranscriptSnapshot {
        // Tool bodies enter the store capped (`ActivityRetention`), whichever path recorded them.
        let normalized = items.map { entry in
            let item = ActivityRetention.cap(entry)
            return AgentTranscriptItem(id: item.id, kind: .init(rawValue: item.kind) ?? .activity,
                                       text: item.text, presentation: item)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let revision = SHA256.hash(data: try encoder.encode(normalized)).map { String(format: "%02x", $0) }.joined()
        return AgentTranscriptSnapshot(conversation: conversation, source: source, revision: revision,
                                       capturedAt: capturedAt, completeness: completeness, items: normalized)
    }

    public static func items(_ snapshot: AgentTranscriptSnapshot) -> [TranscriptItem] {
        snapshot.items.map { entry in
            var item = entry.presentation ?? TranscriptItem(id: entry.id, kind: entry.kind.rawValue, text: entry.text)
            item.id = entry.id; item.text = entry.text
            if item.agentName == nil && snapshot.source.connection.agent == .claudeCode { item.agentName = "Claude" }
            return item
        }
    }

    public static func notice(_ snapshot: AgentTranscriptSnapshot?, language: AppLanguage = L10n.language) -> String {
        guard let snapshot else {
            return L10n.text("Локальная история ещё не сохранена. Подключи исходного агента, чтобы загрузить её.",
                             "Local history has not been saved yet. Connect the original agent to load it.", language: language)
        }
        switch snapshot.completeness {
        case .complete:
            return L10n.text("Показана сохранённая история. Последние изменения могут отсутствовать.",
                             "Showing saved history. Recent changes may be missing.", language: language)
        case .partial:
            return L10n.text("Сохранена неполная история: часть сообщений, вложений или деталей инструментов может отсутствовать.",
                             "Saved history is incomplete: some messages, attachments or tool details may be missing.", language: language)
        case .unavailable:
            return L10n.text("История недоступна в локальном снимке. Подключи исходного агента для загрузки.",
                             "History is unavailable in the local snapshot. Connect the original agent to load it.", language: language)
        }
    }
}
