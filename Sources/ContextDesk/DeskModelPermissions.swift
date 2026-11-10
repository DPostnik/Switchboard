import Foundation
import AgentContract
import ContextCore

extension DeskModel {
    /// Observe saved policy without answering a provider request. A matching app grant cannot override
    /// a mandatory provider approval or establish authority for a different working directory.
    func commandAssessment(for action: PendingAction) -> AgentCommandPolicy.Assessment? {
        guard let command = action.interaction.command,
              let cwd = action.interaction.workingDirectory, cwd.hasPrefix("/"),
              let chat = state.chats.first(where: { $0.id == action.threadID }),
              let project = state.projects.first(where: { $0.id == chat.projectID }),
              URL(fileURLWithPath: cwd).standardizedFileURL.path == URL(fileURLWithPath: project.path).standardizedFileURL.path,
              let support = agentState(action.interaction.session.connection).descriptor?.permissions else { return nil }
        let profile = chat.resolvedRole(in: project, catalog: roleCatalog)
            .profile(for: project, addOns: chat.resolvedAddOns(in: project))
        return AgentCommandPolicy(profile).assessInvocation(command: command, support: support)
    }

    func permissionExplanation(for action: PendingAction) -> String? {
        if let assessment = commandAssessment(for: action), !assessment.ruleIDs.isEmpty {
            switch assessment.decision {
            case .unsupportedGrant:
                return L10n.text("Запуск содержит команду из разрешений проекта, но этот провайдер не поддерживает такие разрешения для отдельного чата. Требуется подтверждение провайдера.",
                                 "This invocation contains a command from the project's grants, but this provider cannot apply those grants to an individual chat. Provider approval is required.")
            case .providerApprovalRequired, .granted:
                return L10n.text("Запуск содержит команду из разрешений проекта. Провайдер запросил отдельное подтверждение выполнения.",
                                 "This invocation contains a command from the project's grants. The provider requested separate execution approval.")
            case .notGranted: break
            }
        }
        if action.interaction.origin == .tool {
            return L10n.text("Запрос получен от инструмента. Подключение инструмента не заменяет подтверждение конкретной операции.",
                             "This request came from a tool. Connecting a tool does not replace approval for a specific operation.")
        }
        return nil
    }

    /// One event per newly queued interaction, shared by all adapters. No prompt text or answers are persisted.
    func recordPresentedInteraction(_ action: PendingAction) {
        guard let chat = state.chats.first(where: { $0.id == action.threadID }),
              let project = state.projects.first(where: { $0.id == chat.projectID }) else { return }
        let role = chat.resolvedRole(in: project, catalog: roleCatalog)
        let run = jobLedger.runs.first { $0.threadID == chat.id && $0.status.active }?.id
        let connection = action.interaction.session.connection
        let record = AgentCapabilityRecord(tool: "interaction", capability: .other, decision: .asked,
            turn: action.interaction.turn, requestID: action.interaction.auditRequestID ?? action.id, source: action.interaction.auditSource,
            stage: .presented, ruleID: commandAssessment(for: action)?.ruleIDs.first)
        let decision = CapabilityDecision(chatID: chat.id, runID: run, projectID: project.id, roleID: role.id,
            agent: profile(connection)?.engine.rawValue ?? connection.agent.rawValue, record: record, audit: role.profile.audit)
        Task { [capabilityLedger] in await capabilityLedger.record(decision) }
    }
}
