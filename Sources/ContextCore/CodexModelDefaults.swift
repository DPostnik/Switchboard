import Foundation
import AgentContract

public enum CodexModelDefaults {
    public static let model = "gpt-6.2-sol"
    /// The app default before GPT-6.2 Sol; stored choices that still name it move once (user decision 2026-11-17).
    public static let previousSol = "gpt-6.1-sol"

    /// Keep valid saved choices. Prefer Sol when the previous model is absent from the engine's catalog.
    public static func resolve(_ saved: String, available models: [AgentModelInfo]) -> String {
        guard !models.contains(where: { $0.id == saved }) else { return saved }
        return (models.first { $0.id == model } ?? models.first { $0.isDefault } ?? models.first)?.id ?? saved
    }
}

extension SavedState {
    /// Applies the user's new app default once, without changing chat or project choices or another agent's settings.
    @discardableResult public mutating func applyCodexSolDefault() -> Bool {
        guard codexSolDefaultApplied != true else { return false }
        model = CodexModelDefaults.model
        codexSolDefaultApplied = true
        return true
    }

    /// Moves the app default and project Codex defaults from GPT-6.1 Sol to GPT-6.2 Sol once.
    /// Other models, existing chats and later explicit choices stay as they are.
    @discardableResult public mutating func applyCodexSol62Default() -> Bool {
        guard codexSol62DefaultApplied != true else { return false }
        if model == CodexModelDefaults.previousSol { model = CodexModelDefaults.model }
        for index in projects.indices where projects[index].chatModels?[AgentID.codex.rawValue]?.model == CodexModelDefaults.previousSol {
            projects[index].chatModels?[AgentID.codex.rawValue]?.model = CodexModelDefaults.model
        }
        codexSol62DefaultApplied = true
        return true
    }
}
