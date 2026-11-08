import Foundation
import AgentContract

public enum CodexModelDefaults {
    public static let model = "gpt-6.1-sol"

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
}
