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

    public static func delegatesByDefault(model: String, provider: Provider) -> Bool {
        provider == .codex ? isAstra(model) : model == "fable" || model.hasPrefix("claude-fable-")
    }

    public static func instructions(model: String, provider: Provider, useSubagents: Bool? = nil,
                                    language: AppLanguage = L10n.language) -> String {
        // Quote identifiers as data, including user-saved custom model names.
        let identifier = String(decoding: (try? JSONEncoder().encode(model)) ?? Data(), as: UTF8.self)
        let selected = model.isEmpty
            ? L10n.text("Для этого хода не задана явная замена модели; действует выбор CLI, чата или сервера. Не выдумывай её идентификатор.",
                        "No explicit model override was supplied for this turn; the CLI, thread or server selection applies. Do not invent its identifier.", language: language)
            : L10n.text("Выбранная в приложении модель для этого хода: \(identifier). Не спрашивай пользователя, какая модель выбрана.",
                        "The app-selected model for this turn is \(identifier). Do not ask the user which model is selected.", language: language)
        let role: String
        if useSubagents == false {
            role = L10n.text("Пользователь отключил подагентов для этого чата в Switchboard. Эта настройка имеет приоритет над постоянными правилами делегирования по модели. Выполняй порученную реализацию самостоятельно, без подагентов.",
                             "The user turned off subagents for this chat in Switchboard. This setting overrides standing model-based delegation rules. Perform authorized implementation directly, without subagents.", language: language)
        } else if useSubagents ?? delegatesByDefault(model: model, provider: provider) {
            let executor = provider == .codex ? "gpt-6.2-sol (fork_turns: \"none\")" : "Opus 5.5 (model: \"opus\")"
            let source = useSubagents == true
                ? L10n.text("Пользователь включил подагентов для этого чата в Switchboard. Эта настройка имеет приоритет над постоянными правилами делегирования по модели.",
                            "The user turned on subagents for this chat in Switchboard. This setting overrides standing model-based delegation rules.", language: language)
                : L10n.text("Действует постоянная инструкция пользователя о делегировании по модели.",
                            "The user's standing model-based delegation instruction applies.", language: language)
            role = source + " " + L10n.text("Порученную реализацию, включая мелкие исправления, передавай подагентам модели \(executor). Сам собирай контекст, планируй, координируй, проверяй результат и сообщай его. Обсуждение и запрос только плана не требуют запуска исполнителя. Если требуемое делегирование недоступно, сообщи о блокере.",
                                           "Delegate authorized implementation, including small fixes, to subagents on \(executor). Gather context, plan, coordinate, review, verify and report the result. Discussion and plan-only requests do not require an executor. If required delegation is unavailable, report the blocker.", language: language)
        } else {
            role = L10n.text("Эта выбранная модель сама по себе не включает роль оркестратора. Следуй задаче и инструкциям пользователя о делегировании.",
                             "This model selection does not itself activate the orchestrator role. Follow the task and the user's delegation instructions.", language: language)
        }
        let precedence = L10n.text("Явные указания пользователя о делегировании в этом чате или задаче имеют приоритет над настройкой Switchboard и постоянными правилами. Если пользователь просит выполнить работу самому, выполни её без подагентов. Если он задаёт модель исполнителя или способ делегирования, следуй его запросу в пределах указанной области и доступных возможностей. Если выполнить запрос так нельзя, сообщи о блокере перед любой заменой.",
                                   "Explicit user instructions about delegation for this chat or task take precedence over the Switchboard setting and standing defaults. If the user asks you to do the work yourself, implement it without subagents. If the user specifies an executor model or delegation setup, follow that request within its stated scope and available capabilities. If the request cannot be followed, report the blocker before making any substitution.", language: language)
        return openingMarker + "\n" + L10n.text("Контекст текущего хода Switchboard:", "Switchboard current-turn context:", language: language) + "\n" + selected + "\n"
            + L10n.text("Это выбор для основного чата, а не подтверждение фактической серверной модели. В этом чате новый контекст хода заменяет прежние сведения о выбранной модели и настройке подагентов. Подагенты не наследуют эту идентичность или роль: выполняй назначенную задачу как исполнитель, если ты подагент. Разрешения и требования подтверждения не меняются.",
                        "This selection describes the primary chat, not a verified provider backend model. In this chat, new current-turn context replaces older model-selection and subagent settings. Subagents do not inherit this identity or role: if you are a subagent, execute your assigned task directly. Permissions and approval requirements do not change.", language: language) + "\n" + role + "\n" + precedence + "\n" + closingMarker
    }
}
