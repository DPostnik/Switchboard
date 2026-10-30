import SwiftUI
import ContextCore

/// Claude model selection for the composer. The CLI performs no model discovery, so this is a
/// catalog of suggestions over the same configured model string; an identifier outside the
/// catalog can still be entered and is preserved verbatim.
///
/// A model the pinned Claude Code build does not describe is listed but not selectable: the
/// CLI rejects it before any turn runs.
struct ClaudeModelSelector: View {
    @ObservedObject var model: DeskModel
    @State private var entering = false
    @FocusState private var fieldFocused: Bool
    @State private var draft = ""

    private var help: String {
        let fallback = ClaudeModel.title(for: ClaudeModel.defaultID)
        var lines = [L10n.text("Модель Claude для новых сообщений. По умолчанию — \(fallback).",
                               "Claude model for new messages. Default is \(fallback).")]
        let configured = model.currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            lines.append(L10n.text("Выбрано: ", "Selected: ") + configured)
            if let reasoning = ClaudeModel.reasoningTitle(for: configured) { lines.append(reasoning) }
            if let note = ClaudeModel.requirementNote(for: configured) {
                lines.append(L10n.text("Недоступно: ", "Unavailable: ") + note)
            }
        }
        lines.append(L10n.text("Глубину рассуждения задаёт соседний выбор усилия.",
                               "Reasoning depth comes from the effort control beside this one."))
        return lines.joined(separator: "\n")
    }

    private func entry(_ item: ClaudeModel) -> some View {
        let note = item.requirementNote()
        return Button(note.map { item.menuTitle + " · " + $0 } ?? item.menuTitle) {
            model.selectCurrentModel(item.id)
        }.disabled(note != nil)
    }

    var body: some View {
        Group {
            if entering {
                TextField(L10n.text("Модель Claude", "Claude model"), text: $draft,
                          prompt: Text(ClaudeModel.title(for: ClaudeModel.defaultID)))
                    .onSubmit { commit() }
                    .onExitCommand { entering = false }
                    // The field replaces the menu the user just chose from, so typing can start at once.
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .accessibilityLabel(L10n.text("Модель Claude", "Claude model"))
            } else {
                ChipMenu(title: ClaudeModel.title(for: model.currentModel)) {
                    ForEach(ClaudeModel.current) { entry($0) }
                    Menu(L10n.text("Предыдущие поколения", "Previous generations")) {
                        ForEach(ClaudeModel.previous) { entry($0) }
                    }
                    Divider()
                    Button(L10n.text("Другая модель…", "Other model…")) {
                        draft = model.currentModel
                        entering = true
                    }
                }
                .accessibilityLabel(L10n.text("Модель Claude", "Claude model"))
            }
        }
        .frame(maxWidth: entering ? 190 : nil)
        .disabled(model.busy)
        .help(help)
    }

    private func commit() {
        model.selectCurrentModel(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        entering = false
    }
}

/// Reasoning effort for a Claude session, forwarded to the CLI's `--effort`. Lower levels are
/// the control for sub-agent sessions that should spend fewer tokens.
struct ClaudeEffortPicker: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        ChipMenu(title: ClaudeEffort(rawValue: model.claudeEffort)?.title ?? model.claudeEffort) {
            Picker(L10n.text("Рассуждение", "Reasoning"),
                   selection: Binding(get: { model.claudeEffort }, set: { model.selectClaudeEffort($0) })) {
                ForEach(ClaudeEffort.allCases, id: \.rawValue) { level in
                    Text(level.title).tag(level.rawValue)
                }
            }.pickerStyle(.inline).labelsHidden()
        }
        .disabled(model.busy)
        .help(L10n.text("Усилие рассуждения Claude для новых сообщений. По умолчанию — \(ClaudeEffort.defaultLevel.title.lowercased()). Низкое усилие экономит токены на простых задачах и подагентах.",
                        "Claude reasoning effort for new messages. Default is \(ClaudeEffort.defaultLevel.title.lowercased()). Low effort saves tokens on simple tasks and sub-agents."))
    }
}
