import SwiftUI
import ContextCore

/// One composer chip for the model, the reasoning effort and, in a new chat, the agent.
///
/// Claude: the CLI performs no model discovery, so the model list is a catalog of suggestions over
/// the same configured model string; an identifier outside the catalog can still be entered and is
/// preserved verbatim. A model the pinned Claude Code build does not describe is listed but not
/// selectable: the CLI rejects it before any turn runs.
///
/// Codex: the models the server lists, plus "Auto"; efforts come from the selected model.
struct ModelChip: View {
    @ObservedObject var model: DeskModel
    @State private var entering = false
    @FocusState private var fieldFocused: Bool
    @State private var draft = ""

    /// The current agent offers the app's model catalog (Claude) instead of the engine's model list.
    private var claude: Bool { model.traits(model.currentAgent).contains(.catalogModels) }
    private var newChat: Bool { model.chatID == nil }
    /// Codex lists its models only once connected; until then the chip has no model to show.
    private var showsModels: Bool { claude || !model.models.isEmpty }

    /// Chip label: "<model> · <effort>", or the model alone when the model has no effort levels.
    static func title(model: String, effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return model }
        return model + " · " + effort
    }

    private var modelTitle: String {
        if claude { return ClaudeModel.title(for: model.currentModel) }
        guard showsModels else { return model.currentAgentName }
        if model.currentModel.isEmpty { return L10n.text("Авто", "Auto") }
        return model.models.first { $0.id == model.currentModel }?.displayName ?? model.currentModel
    }

    private var effortTitle: String? {
        if claude { return ClaudeEffort(rawValue: model.claudeEffort)?.title ?? model.claudeEffort }
        guard showsModels, !model.supportedEfforts.isEmpty else { return nil }
        return model.effort.isEmpty ? L10n.text("Авто", "Auto") : model.effort
    }

    private var help: String {
        var lines: [String] = []
        if claude {
            let fallback = ClaudeModel.title(for: ClaudeModel.defaultID)
            lines.append(L10n.text("Модель Claude для новых сообщений. По умолчанию — \(fallback).",
                                   "Claude model for new messages. Default is \(fallback)."))
            let configured = model.currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty {
                lines.append(L10n.text("Выбрано: ", "Selected: ") + configured)
                if let reasoning = ClaudeModel.reasoningTitle(for: configured) { lines.append(reasoning) }
                if let note = ClaudeModel.requirementNote(for: configured) {
                    lines.append(L10n.text("Недоступно: ", "Unavailable: ") + note)
                }
            }
            lines.append(L10n.text("Усилие рассуждения Claude для новых сообщений. По умолчанию — \(ClaudeEffort.defaultLevel.title.lowercased()). Низкое усилие экономит токены на простых задачах и подагентах.",
                                   "Claude reasoning effort for new messages. Default is \(ClaudeEffort.defaultLevel.title.lowercased()). Low effort saves tokens on simple tasks and sub-agents."))
        } else {
            lines.append(L10n.text("Модель и усилие рассуждения Codex для новых сообщений.",
                                   "Codex model and reasoning effort for new messages."))
        }
        lines.append(newChat
            ? L10n.text("Провайдер нового чата", "Provider for the new chat") + ": " + model.currentAgentName
            : L10n.text("Провайдер этого чата", "Provider for this chat") + ": " + model.currentAgentName)
        return lines.joined(separator: "\n")
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
            } else if showsModels || newChat {
                ChipMenu(title: Self.title(model: modelTitle, effort: effortTitle), systemImage: "sparkle") { menu }
                    .accessibilityLabel(L10n.text("Модель и рассуждение", "Model and reasoning"))
            } else {
                // An existing Codex chat before the model list arrives: nothing to choose.
                ChipLabel(title: modelTitle, systemImage: "sparkle")
                    .font(.ui(.callout)).foregroundStyle(.secondary).padding(.horizontal, .ui(9))
            }
        }
        .frame(maxWidth: entering ? 190 : nil)
        .disabled(model.busy || model.sending)
        .help(help)
    }

    @ViewBuilder private var menu: some View {
        if claude {
            Section {
                ForEach(ClaudeModel.current) { entry($0) }
                Menu(L10n.text("Предыдущие поколения", "Previous generations")) {
                    ForEach(ClaudeModel.previous) { entry($0) }
                }
                Button(L10n.text("Другая модель…", "Other model…")) {
                    draft = model.currentModel
                    entering = true
                }
            } header: { Text(model.currentAgentName) }
            Section {
                Picker(L10n.text("Рассуждение", "Reasoning"),
                       selection: Binding(get: { model.claudeEffort }, set: { model.selectClaudeEffort($0) })) {
                    ForEach(ClaudeEffort.allCases, id: \.rawValue) { level in
                        Text(level.title).tag(level.rawValue)
                    }
                }.pickerStyle(.inline).labelsHidden()
            } header: { Text(L10n.text("Рассуждение", "Reasoning")) }
        } else if showsModels {
            Section {
                Picker(L10n.text("Модель", "Model"), selection: Binding(get: { model.currentModel }, set: { model.selectModel($0) })) {
                    Text(L10n.text("Авто", "Auto")).tag("")
                    if !model.currentModel.isEmpty && !model.models.contains(where: { $0.id == model.currentModel }) {
                        Text(model.currentModel).tag(model.currentModel)
                    }
                    ForEach(model.models, id: \.self) { entry in Text(entry.displayName).tag(entry.id) }
                }.pickerStyle(.inline).labelsHidden()
            } header: { Text(model.currentAgentName) }
            if !model.supportedEfforts.isEmpty {
                Section {
                    Picker(L10n.text("Рассуждение", "Reasoning"), selection: Binding(get: { model.effort }, set: { model.effort = $0 })) {
                        Text(L10n.text("Авто", "Auto")).tag("")
                        if !model.effort.isEmpty && !model.supportedEfforts.contains(model.effort) {
                            Text(model.effort).tag(model.effort)
                        }
                        ForEach(model.supportedEfforts, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                } header: { Text(L10n.text("Рассуждение", "Reasoning")) }
            }
        }
        // The agent is fixed once the chat exists.
        if newChat {
            Section {
                Picker(L10n.text("Агент", "Agent"), selection: Binding(get: { model.currentAgent }, set: { model.selectAgent($0) })) {
                    ForEach(model.agentIDs, id: \.self) { id in Text(model.agentName(id)).tag(id) }
                }.pickerStyle(.inline).labelsHidden()
            } header: { Text(L10n.text("Агент", "Agent")) }
        }
    }

    private func entry(_ item: ClaudeModel) -> some View {
        let note = item.requirementNote()
        return Toggle(note.map { item.menuTitle + " · " + $0 } ?? item.menuTitle,
                      isOn: Binding(get: { model.currentModel == item.id }, set: { _ in model.selectCurrentModel(item.id) }))
            .disabled(note != nil)
    }

    private func commit() {
        model.selectCurrentModel(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        entering = false
    }
}
