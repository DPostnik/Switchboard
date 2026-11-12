import SwiftUI
import AppKit
import ContextCore
import AgentContract
import ContextTranscript

/// Settings tab: what roles decided over the last days, from the capability ledger.
struct PermissionsLedgerView: View {
    @ObservedObject var model: DeskModel
    @State private var daily: [CapabilityDailyCount] = []
    @State private var recent: [CapabilityDecision] = []
    @State private var interruptions = 0
    @State private var issue: String?

    var body: some View {
        Form {
            Section(L10n.text("Роли", "Roles")) {
                ForEach(model.roleCatalog.all) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.title).font(.ui(.body))
                        Text(role.summary).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("Роль чата выбирается в композере; роли проекта и папки вне проекта — в меню проекта «Настройки проекта…».",
                               "A chat's role is chosen in the composer; project defaults and folders outside the project are in the project menu under Project settings…"))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Section(L10n.text("Журнал за 7 дней", "Last 7 days")) {
                if let issue { Text(issue).font(.ui(.caption)).foregroundStyle(DeskPalette.problem) }
                LabeledContent(L10n.text("Запросы, переданные пользователю", "Requests presented to the user")) {
                    Text("\(interruptions)")
                }
                Text(L10n.text("Каждый запрос учитывается один раз, включая MCP-формы и вопросы. Старые записи без события показа в этот счётчик не входят. Ниже показано число событий, включая ответы и результаты.",
                               "Each request counts once, including MCP forms and questions. Older records without a presentation event are excluded. The counts below include response and result events."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                if daily.isEmpty { Text(L10n.text("Записей пока нет.", "No records yet.")).font(.ui(.caption)).foregroundStyle(.secondary) }
                ForEach(summary, id: \.key) { entry in
                    LabeledContent(entry.key) { Text("\(entry.count)") }
                }
            }
            Section(L10n.text("Последние решения", "Recent decisions")) {
                ForEach(Array(recent.prefix(100).enumerated()), id: \.offset) { _, decision in
                    HStack {
                        Text(decision.date, style: .time).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text(decision.roleID).frame(width: 110, alignment: .leading)
                        Text(decision.tool).frame(width: 150, alignment: .leading).lineLimit(1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.decisionTitle(decision.decision))
                            if let stage = decision.stage { Text(Self.stageTitle(stage)).foregroundStyle(.secondary) }
                        }.frame(width: 110, alignment: .leading)
                        Text(decision.target ?? "").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }.font(.ui(.caption)).help(Self.evidence(decision))
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var summary: [(key: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in daily { counts["\(row.roleID) · \(Self.capabilityTitle(row.capability)) · \(Self.decisionTitle(row.decision))", default: 0] += row.count }
        return counts.map { (key: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count }
    }
    private func load() async {
        do {
            daily = try await model.capabilityLedger.daily(days: 7)
            recent = try await model.capabilityLedger.recent(days: 7, limit: 100)
            interruptions = try await model.capabilityLedger.interruptions(days: 7)
            issue = await model.capabilityLedger.lastError
        } catch { issue = error.localizedDescription }
    }
    static func capabilityTitle(_ capability: AgentCapabilityRecord.Capability) -> String {
        switch capability {
        case .read: L10n.text("чтение", "read")
        case .writeInProject: L10n.text("запись в проекте", "write in project")
        case .writeOutside: L10n.text("запись вне проекта", "write outside")
        case .shell: L10n.text("команда", "command")
        case .network: L10n.text("сеть", "network")
        case .browser: L10n.text("браузер", "browser")
        case .connector: L10n.text("коннектор", "connector")
        case .connectorWrite: L10n.text("коннектор: запись", "connector write")
        case .subagent: L10n.text("подагент", "subagent")
        case .question: L10n.text("вопрос", "question")
        case .other: L10n.text("другое", "other")
        }
    }
    static func decisionTitle(_ decision: AgentCapabilityRecord.Decision) -> String {
        switch decision {
        case .used: L10n.text("вызвано", "invoked")
        case .allowed: L10n.text("разрешено", "allowed")
        case .asked: L10n.text("запрошено", "asked")
        case .denied: L10n.text("отклонено", "denied")
        case .wouldDeny: L10n.text("было бы отклонено", "would deny")
        case .unsupportedTool: L10n.text("инструмент вне роли", "tool outside role")
        case .hookDenied: L10n.text("команда отклонена", "command denied")
        case .hookAsked: L10n.text("команда на подтверждение", "command asked")
        case .answered: L10n.text("ответ выбран", "answer selected")
        }
    }

    static func stageTitle(_ stage: AgentCapabilityRecord.Stage) -> String {
        switch stage {
        case .requested: L10n.text("получен запрос", "request received")
        case .presented: L10n.text("передано пользователю", "presented to user")
        case .responded: L10n.text("ответ отправлен", "response sent")
        case .started: L10n.text("запуск", "started")
        case .completed: L10n.text("завершение", "completed")
        case .resolved: L10n.text("запрос закрыт", "request closed")
        }
    }

    static func evidence(_ decision: CapabilityDecision) -> String {
        var lines = [decision.source, decision.requestID, decision.ruleID, decision.reason].compactMap { $0 }
        if let outcome = decision.outcome {
            let title: String = switch outcome {
            case .succeeded: L10n.text("Успешно", "Succeeded")
            case .failed: L10n.text("Ошибка", "Failed")
            case .cancelled: L10n.text("Отменено", "Cancelled")
            case .unknown: L10n.text("Результат неизвестен", "Outcome unknown")
            }
            lines.append(title)
        }
        return lines.joined(separator: "\n")
    }
}
