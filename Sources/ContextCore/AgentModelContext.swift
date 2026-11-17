import Foundation

/// App-selected model for one primary-chat turn, never a claim about the provider's resolved backend.
/// Kept out of persistent system instructions so a live model switch cannot leave stale identity there.
public enum AgentModelContext {
    public static let openingMarker = "<switchboard-current-turn-context>"
    public static let closingMarker = "</switchboard-current-turn-context>"

    public enum Provider: Sendable, Equatable { case codex, claude }

    /// GPT Astro / Astra of any generation (`gpt-6-astra`, `gpt-6.2-astra`); custom names stay plain models.
    static func isAstra(_ model: String) -> Bool {
        model.range(of: #"^gpt-[0-9]+(\.[0-9]+)?-astra$"#, options: .regularExpression) != nil
    }

    public static func instructions(model: String, provider: Provider, language: AppLanguage = L10n.language) -> String {
        // Quote identifiers as data, including user-saved custom model names.
        let identifier = String(decoding: (try? JSONEncoder().encode(model)) ?? Data(), as: UTF8.self)
        let selected = model.isEmpty
            ? L10n.text("Для этого хода не задана явная замена модели; действует выбор CLI, чата или сервера. Не выдумывай её идентификатор.",
                        "No explicit model override was supplied for this turn; the CLI, thread or server selection applies. Do not invent its identifier.", language: language)
            : L10n.text("Выбранная в приложении модель для этого хода: \(identifier). Не спрашивай пользователя, какая модель выбрана.",
                        "The app-selected model for this turn is \(identifier). Do not ask the user which model is selected.", language: language)
        let orchestrator = provider == .codex ? isAstra(model) : model == "fable" || model.hasPrefix("claude-fable-")
        let role: String
        if orchestrator {
            let executor = provider == .codex ? "gpt-6.2-sol (fork_turns: \"none\")" : "sonnet"
            role = L10n.text("Согласно постоянной инструкции пользователя, основной агент — оркестратор: любую порученную реализацию, включая мелкие исправления, передавай подагентам модели \(executor). Сам собирай контекст, планируй, координируй, проверяй результат и сообщай его. Обсуждение и запрос только плана не требуют запуска исполнителя. Если делегирование недоступно, сообщи блокер; не подменяй исполнителя собой.",
                             "Under the user's standing instruction, the primary agent is the orchestrator: delegate every authorized implementation, including small fixes, to subagents on \(executor). Gather context, plan, coordinate, review, verify and report the result. Discussion and plan-only requests do not require an executor. If delegation is unavailable, report the blocker; do not implement in the primary chat instead.", language: language)
        } else {
            role = L10n.text("Эта выбранная модель сама по себе не включает роль оркестратора. Следуй задаче и инструкциям пользователя о делегировании.",
                             "This model selection does not itself activate the orchestrator role. Follow the task and the user's delegation instructions.", language: language)
        }
        return openingMarker + "\n" + L10n.text("Контекст текущего хода Switchboard:", "Switchboard current-turn context:", language: language) + "\n" + selected + "\n"
            + L10n.text("Это выбор для основного чата, а не подтверждение фактической серверной модели. В этом чате новый контекст хода заменяет прежние сведения о выбранной модели. Подагенты не наследуют эту идентичность или роль: выполняй назначенную задачу как исполнитель, если ты подагент. Разрешения и требования подтверждения не меняются.",
                        "This selection describes the primary chat, not a verified provider backend model. In this chat, new current-turn context replaces older model-selection information. Subagents do not inherit this identity or role: if you are a subagent, execute your assigned task directly. Permissions and approval requirements do not change.", language: language) + "\n" + role + "\n" + closingMarker
    }
}
