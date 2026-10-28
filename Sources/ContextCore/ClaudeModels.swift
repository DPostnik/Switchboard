import Foundation

/// The exact Claude Code build this app verifies before it dispatches anything.
///
/// Declared here, not in the adapter, so model and effort gating can consult it without the
/// application or core depending on the native runner.
public enum ClaudeRuntime {
    public static let pinnedVersion = "2.1.292"

    /// Numeric dotted-component comparison. A non-numeric component sorts as 0.
    public static func version(_ lhs: String, isAtLeast rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return true
    }
}

/// Reasoning effort for a Claude session, passed through to the CLI's `--effort`.
public enum ClaudeEffort: String, CaseIterable, Hashable, Sendable {
    case low, medium, high, xhigh, max

    public var title: String {
        switch self {
        case .low: return L10n.text("Низкое", "Low")
        case .medium: return L10n.text("Среднее", "Medium")
        case .high: return L10n.text("Высокое", "High")
        case .xhigh: return L10n.text("Повышенное", "Extra high")
        case .max: return L10n.text("Максимальное", "Maximum")
        }
    }

    /// Accepts only a level the CLI documents; anything else stays unset.
    public static func accepted(_ value: String?) -> ClaudeEffort? {
        guard let value, !value.isEmpty else { return nil }
        return ClaudeEffort(rawValue: value)
    }

    /// True for a value the adapter may forward: empty (CLI default) or a known level.
    public static func isDispatchable(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return true }
        return ClaudeEffort(rawValue: value) != nil
    }

    /// The composer's level when none is chosen.
    public static let defaultLevel: ClaudeEffort = .medium

    /// Composer resolution: an unset, blank or unrecognised value means the default level.
    public static func resolved(_ configured: String?) -> String {
        (accepted(configured) ?? defaultLevel).rawValue
    }
}

/// App-owned catalog of selectable Claude models.
///
/// The installed CLI exposes no model discovery (see `AGENT_CONTRACT.md`), so these entries
/// are suggestions for the single configured model string the adapter passes to `--model`.
/// An identifier outside the catalog stays valid and is preserved as typed; the catalog never
/// rewrites a configured value.
///
/// Each entry records the Claude Code build that first recognises it. The pinned CLI rejects a
/// model its own catalog does not describe, so newer models are shown but not selectable until
/// the pin moves.
public struct ClaudeModel: Hashable, Sendable, Identifiable {
    /// How the model handles reasoning. Depth is steered by `ClaudeEffort`.
    public enum Reasoning: String, Hashable, Sendable {
        /// Thinking is always on and cannot be turned off.
        case always
        /// Thinking is adaptive and the CLI may turn it off.
        case adaptive
        /// Manual extended thinking only; no adaptive mode.
        case extended

        public var title: String {
            switch self {
            case .always: return L10n.text("рассуждение всегда включено", "thinking always on")
            case .adaptive: return L10n.text("адаптивное рассуждение", "adaptive thinking")
            case .extended: return L10n.text("расширенное рассуждение", "extended thinking")
            }
        }
    }

    public let id: String
    public let name: String
    public let reasoning: Reasoning
    /// False for superseded generations that the provider still serves.
    public let isCurrent: Bool
    /// Earliest Claude Code build whose model catalog describes this identifier.
    public let minimumCLI: String

    public init(id: String, name: String, reasoning: Reasoning, isCurrent: Bool, minimumCLI: String) {
        self.id = id; self.name = name; self.reasoning = reasoning
        self.isCurrent = isCurrent; self.minimumCLI = minimumCLI
    }

    public var menuTitle: String { name + " · " + reasoning.title }

    public func isSupported(by cliVersion: String = ClaudeRuntime.pinnedVersion) -> Bool {
        ClaudeRuntime.version(cliVersion, isAtLeast: minimumCLI)
    }

    public func requirementNote(for cliVersion: String = ClaudeRuntime.pinnedVersion) -> String? {
        guard !isSupported(by: cliVersion) else { return nil }
        return L10n.text("требуется Claude Code \(minimumCLI)", "requires Claude Code \(minimumCLI)")
    }

    /// Documented as of 2026-10-07. Ordered as offered in the selector.
    ///
    /// `minimumCLI` is the build whose model catalog describes the identifier, checked against
    /// the installed CLI. On 2.1.260 both 5.5 models were absent and the API rejected
    /// `claude-opus-5-5` with "version 2.1.280 or newer is required"; 2.1.292 describes both and
    /// runs `claude-opus-5-5` end to end. Sonnet 5.5 is recorded at the version where its catalog
    /// entry was actually observed, because an undescribed model falls back to a 200K window.
    public static let catalog: [ClaudeModel] = [
        .init(id: "claude-opus-5-5", name: "Opus 5.5", reasoning: .always, isCurrent: true, minimumCLI: "2.1.280"),
        .init(id: "claude-sonnet-5-5", name: "Sonnet 5.5", reasoning: .always, isCurrent: true, minimumCLI: "2.1.292"),
        .init(id: "claude-fable-5-1", name: "Fable 5.1", reasoning: .always, isCurrent: true, minimumCLI: "2.1.260"),
        .init(id: "claude-haiku-4-5", name: "Haiku 4.5", reasoning: .extended, isCurrent: true, minimumCLI: "2.1.260"),
        .init(id: "claude-fable-5", name: "Fable 5", reasoning: .always, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-opus-5", name: "Opus 5", reasoning: .adaptive, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-sonnet-5", name: "Sonnet 5", reasoning: .adaptive, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-opus-4-8", name: "Opus 4.8", reasoning: .adaptive, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-opus-4-7", name: "Opus 4.7", reasoning: .adaptive, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-opus-4-6", name: "Opus 4.6", reasoning: .adaptive, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-sonnet-4-6", name: "Sonnet 4.6", reasoning: .adaptive, isCurrent: false, minimumCLI: "2.1.260"),
        .init(id: "claude-opus-4-5", name: "Opus 4.5", reasoning: .extended, isCurrent: false, minimumCLI: "2.1.260")
    ]

    public static var current: [ClaudeModel] { catalog.filter(\.isCurrent) }
    public static var previous: [ClaudeModel] { catalog.filter { !$0.isCurrent } }

    public static func entry(for id: String) -> ClaudeModel? {
        catalog.first { $0.id == id }
    }

    /// Label for a configured string. An unknown identifier is shown verbatim, never replaced.
    public static func title(for id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L10n.text("По умолчанию", "Default") }
        return entry(for: trimmed)?.name ?? trimmed
    }

    /// Reasoning line for a configured string; nil when the catalog does not describe it.
    public static func reasoningTitle(for id: String) -> String? {
        entry(for: id.trimmingCharacters(in: .whitespacesAndNewlines))?.reasoning.title
    }

    /// Why a configured model cannot run on the pinned CLI, if that is the case. An identifier
    /// outside the catalog returns nil: availability is proven by execution, not by this list.
    public static func requirementNote(for id: String, cliVersion: String = ClaudeRuntime.pinnedVersion) -> String? {
        entry(for: id.trimmingCharacters(in: .whitespacesAndNewlines))?.requirementNote(for: cliVersion)
    }

    /// The composer's model when none is chosen. Must be runnable on the pinned CLI.
    public static let defaultID = "claude-opus-5-5"

    /// Composer resolution: an unset or blank value, including the legacy empty field, means
    /// the default model. Any other identifier is kept verbatim.
    public static func resolved(_ configured: String?) -> String {
        let trimmed = (configured ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultID : trimmed
    }
}

/// The advisor a Claude chat consults at decision points (`advisorModel`). It is attached only to a
/// main model of a weaker family, so routine work on Sonnet gets Opus advice while Opus chats do not
/// spend limits on a second Opus. An unknown or default (empty) main model gets none.
public enum ClaudeAdvisor {
    /// Choices for the setting; an empty identifier means no advisor.
    public static let options: [(id: String, name: String)] = [("", L10n.text("Нет", "None")), ("opus", "Opus"), ("fable", "Fable")]

    public static func attached(_ setting: String?, mainModel: String) -> String? {
        guard let setting, !setting.isEmpty, let advisor = rank(setting), let main = rank(mainModel), advisor > main else { return nil }
        return setting
    }

    private static func rank(_ model: String) -> Int? {
        let name = model.lowercased()
        return ["haiku", "sonnet", "opus", "fable"].firstIndex { name.contains($0) }
    }
}
