import Foundation
import ContextCore
import AgentContract

/// The chat notice when a Codex worker runs on the native sandbox instead of the external boundary (invariant 9): once per
/// session and reason, RU/EN, with the same text source as Claude (`ExternalSandboxPlanner.fallbackNotice`).
struct CodexBoundaryNotices {
    private var shown: [AgentSessionReference: String] = [:]

    /// Role-defined native paths are expected and only logged: an unrestricted role, a role without network, the command
    /// sandbox switched off. The others (trusted command outside the boundary, helper not verified, missing runtime) are
    /// shown, because the user can act on them.
    static func isShown(_ reason: ExternalSandboxPlanner.Ineligible) -> Bool {
        switch reason {
        case .unrestricted, .networkOff, .commandSandboxOff: false
        case .helper, .resourcesMissing, .trustedCommandOutside: true
        }
    }
    static func text(_ reason: ExternalSandboxPlanner.Ineligible, language: AppLanguage = L10n.language) -> String {
        ExternalSandboxPlanner.fallbackNotice(reason.description(language: language), sandbox: ("песочницей Codex", "the Codex sandbox"), language: language)
    }

    /// The notice to show for this launch, or nil. A launch under the boundary (nil reason) resets the session, so a later
    /// fallback is shown again.
    mutating func note(_ reason: ExternalSandboxPlanner.Ineligible?, session: AgentSessionReference) -> String? {
        guard let reason else { shown[session] = nil; return nil }
        guard Self.isShown(reason) else { return nil }
        let key = reason.description(language: .english)
        guard shown[session] != key else { return nil }
        shown[session] = key
        return Self.text(reason)
    }
}
