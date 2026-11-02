import Foundation
import AgentContract

/// Process-plugin v1 has one supported wire/auth profile. A manifest cannot grant support to an engine.
public struct OptimizerRequirements: Codable, Equatable, Sendable {
    public var protocolName: String
    public var authentication: String
    public var streaming: Bool
    public var toolCalls: Bool
    public init(protocolName: String, authentication: String, streaming: Bool, toolCalls: Bool) {
        self.protocolName = protocolName; self.authentication = authentication
        self.streaming = streaming; self.toolCalls = toolCalls
    }
    public static let processV1 = Self(protocolName: "openai-responses", authentication: "app-codex-openai", streaming: true, toolCalls: true)
}

public enum OptimizerCompatibility {
    public static func issue(agent: AgentID, requirements: OptimizerRequirements, language: AppLanguage = L10n.language) -> String? {
        guard agent == .codex else {
            return L10n.text("Для этого агента не проверен маршрут через оптимизаторы приложения.", "An app optimizer route has not been verified for this agent.", language: language)
        }
        guard requirements == .processV1 else {
            return L10n.text("Требования плагина несовместимы: нужны Responses, авторизация Codex приложения, потоковые ответы и вызовы инструментов.", "Plugin requirements are incompatible: Responses, app Codex authentication, streaming and tool calls are required.", language: language)
        }
        return nil
    }
    public static func summary(agent: AgentID, requirements: OptimizerRequirements, language: AppLanguage = L10n.language) -> String {
        issue(agent: agent, requirements: requirements, language: language) ?? L10n.text(
            "Профиль Codex / Responses v1 поддерживается. Доступность проверяется при подключении; экономия не гарантируется.",
            "The Codex / Responses v1 profile is supported. Availability is checked on connection; savings are not guaranteed.", language: language)
    }
}

extension JobEngine {
    /// Legacy engine values predate `AgentID`; any other engine value is its agent's ID.
    public var agentID: AgentID {
        switch self {
        case .codex: .codex
        case .claude: .claudeCode
        default: AgentID(rawValue: rawValue)
        }
    }
}
