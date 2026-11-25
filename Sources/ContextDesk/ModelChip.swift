import SwiftUI
import ContextCore
import ContextTranscript

/// One composer chip for the model and the reasoning effort; in a new chat with several agents a provider toggle
/// (`AgentToggle`) precedes it, else the chip carries the provider's mark.
///
/// Claude: the CLI performs no model discovery, so the model list is a catalog of suggestions over
/// the same configured model string; an identifier outside the catalog can still be entered and is
/// preserved verbatim. A model the pinned Claude Code build does not describe is listed but not
/// selectable: the CLI rejects it before any turn runs.
///
/// Codex: current and previous models from the server, plus "Auto"; efforts come from the selected model.
///
/// Gemini (session models): the models its sessions report (the last list is remembered for new chats), plus "Auto"
/// for the agent's own default; a reasoning level only when the model lists one.
struct ModelChip: View {
    @ObservedObject var model: DeskModel
    @State private var entering = false
    @FocusState private var fieldFocused: Bool
    @State private var draft = ""
    @State private var showing = false
    @State private var previousExpanded = false
    /// The "Make default" row just used (true: this project, false: all projects), confirmed with a check.
    @State private var savedDefault: Bool?
    @State private var edge = CompactPopoverPlacement.fallback.edge
    @State private var height: CGFloat?
    @State private var maxHeight = CompactPopoverPlacement.fallback.maxHeight
    @State private var anchor = ScreenFrameProbe()

    /// The current agent offers the app's model catalog (Claude) instead of the engine's model list.
    private var catalog: AgentModelCatalog? { model.modelCatalog(model.currentAgent) }
    private var claude: Bool { catalog != nil }
    private var profile: AgentProfile? { model.profile(model.currentAgent) }
    private var newChat: Bool { model.chatID == nil }
    /// Codex lists its models only once connected; until then the chip has no model to show.
    private var showsModels: Bool { claude || !model.models.isEmpty }
    private var showsSubagentChoice: Bool {
        model.supportsSubagentChoice && model.selectedProject != nil && model.selectedChat?.isScheduledRecord != true
    }

    /// Chip label: "<model> · <effort>", or the model alone when the model has no effort levels.
    static func title(model: String, effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return model }
        return model + " · " + effort
    }

    private var modelTitle: String {
        if let catalog { return catalog.title(model.currentModel) }
        guard showsModels else { return model.currentAgentName }
        if model.currentModel.isEmpty { return L10n.text("Авто", "Auto") }
        return discoveredModelTitle(model.currentModel, displayName: model.models.first { $0.id == model.currentModel }?.displayName)
    }

    private var effortTitle: String? {
        if let catalog { return catalog.effortTitle(model.claudeEffort) ?? model.claudeEffort }
        guard showsModels, !model.supportedEfforts.isEmpty else { return nil }
        return model.effort.isEmpty ? L10n.text("Авто", "Auto") : model.effort
    }

    private var help: String {
        var lines: [String] = []
        if let catalog {
            let fallback = catalog.title(model.resolvedDefaultModel(model.currentAgent, project: model.projectID))
            let fallbackEffort = catalog.effortTitle(model.resolvedDefaultEffort(model.currentAgent, project: model.projectID)) ?? catalog.defaultEffort.title
            lines.append(L10n.text("Модель Claude для новых сообщений. Новый чат этого проекта начинается с \(fallback) · \(fallbackEffort.lowercased()).",
                                   "Claude model for new messages. A new chat in this project starts with \(fallback) · \(fallbackEffort.lowercased())."))
            let configured = model.currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty {
                lines.append(L10n.text("Выбрано: ", "Selected: ") + configured)
                if let reasoning = catalog.reasoningTitle(configured) { lines.append(reasoning) }
                if let note = catalog.requirementNote(configured) {
                    lines.append(L10n.text("Недоступно: ", "Unavailable: ") + note)
                }
            }
            lines.append(L10n.text("Усилие рассуждения Claude для новых сообщений. Низкое усилие экономит токены на простых задачах и подагентах.",
                                   "Claude reasoning effort for new messages. Low effort saves tokens on simple tasks and sub-agents."))
            lines.append(L10n.text("Выбор в новом чате действует только на этот чат. Умолчание меняется пунктами «Сделать по умолчанию» или в настройках проекта.",
                                   "A choice in a new chat applies to that chat only. Change the default with Make default or in the project settings."))
        } else {
            let name = model.currentAgentName
            lines.append(L10n.text("Модель и усилие рассуждения \(name) для новых сообщений.",
                                   "\(name) model and reasoning effort for new messages."))
            if model.traits(model.currentAgent).contains(.sessionModels) && model.models.isEmpty {
                lines.append(L10n.text("Список моделей появится после первого чата с \(name); до тех пор используется модель агента по умолчанию.",
                                       "The model list appears after the first \(name) chat; until then the agent's default model is used."))
            }
        }
        lines.append(newChat
            ? L10n.text("Провайдер нового чата", "Provider for the new chat") + ": " + model.currentAgentName
            : L10n.text("Провайдер этого чата", "Provider for this chat") + ": " + model.currentAgentName)
        return lines.joined(separator: "\n")
    }

    /// A new chat with more than one installed agent chooses the provider with the toggle.
    private var showsToggle: Bool { newChat && model.selectableAgentIDs.count > 1 }
    private var mark: AgentMark? {
        showsToggle ? nil : AgentMark(profile: model.profile(model.currentAgent), size: .ui(11))
    }

    var body: some View {
        HStack(spacing: .ui(4)) {
            if showsToggle && !entering { AgentToggle(model: model) }
            chip
        }
    }

    private var chip: some View {
        Group {
            if entering {
                TextField(L10n.text("Модель Claude", "Claude model"), text: $draft,
                          prompt: Text(catalog.map { $0.title($0.defaultModel) } ?? ""))
                    .onSubmit { commit() }
                    .onExitCommand { entering = false }
                    // The field replaces the list the user just chose from, so typing can start at once.
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .accessibilityLabel(L10n.text("Модель Claude", "Claude model"))
            } else if showsModels || showsSubagentChoice {
                Button {
                    if !showing {
                        previousExpanded = currentIsPrevious
                        savedDefault = nil
                        // Measured as it opens, without blank room: a popover that changes height after presentation
                        // leaves the screen, so expanding the previous generations later scrolls inside this height.
                        let placement = anchor.compactPlacement
                        edge = placement.edge
                        maxHeight = placement.maxHeight
                        height = FixedHeightPopover<EmptyView>.height(of: panel(previousExpanded: previousExpanded), placement: placement)
                    }
                    showing.toggle()
                } label: {
                    ChipLabel(title: Self.title(model: modelTitle, effort: effortTitle), mark: mark, chevron: true)
                }
                .buttonStyle(ChipButtonStyle()).fixedSize().pointingHandCursor()
                .background(ScreenFrameReader(probe: anchor))
                // A popover rather than a menu: choosing a model or a level keeps it open; an outside click or Escape closes it.
                .popover(isPresented: $showing, arrowEdge: edge) {
                    FixedHeightPopover(height: height, maxHeight: maxHeight) { panel(previousExpanded: previousExpanded) }
                }
                // A new agent rebuilds the chip.
                .id(model.currentAgent)
                .accessibilityLabel(L10n.text("Модель и рассуждение", "Model and reasoning"))
            } else {
                // The agent has no composer options yet.
                ChipLabel(title: modelTitle, mark: mark)
                    .font(.ui(.callout)).foregroundStyle(.secondary).padding(.horizontal, .ui(9))
            }
        }
        .frame(maxWidth: entering ? 190 : nil)
        .disabled(model.busy || model.sending)
        .help(help)
    }

    /// The chip's options stay open while the user makes selections.
    private func panel(previousExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let catalog {
                section(model.currentAgentName) {
                    ForEach(catalog.current) { entry($0) }
                    if !catalog.previous.isEmpty {
                        previousGenerations(expanded: previousExpanded)
                        if previousExpanded { ForEach(catalog.previous) { entry($0, indent: true) } }
                    }
                    ModelMenuRow(title: L10n.text("Другая модель…", "Other model…")) {
                        showing = false
                        draft = model.currentModel
                        entering = true
                    }
                }
                divider
                section(L10n.text("Рассуждение", "Reasoning")) {
                    ForEach(claudeEffortOptions(catalog), id: \.id) { level in
                        ModelMenuRow(title: level.title, selected: model.claudeEffort == level.id) {
                            select { model.selectClaudeEffort(level.id) }
                        }
                    }
                }
            } else if showsModels {
                section(model.currentAgentName) {
                    if let featured = profile?.featuredComposerModels, !featured.isEmpty {
                        groupedModelOptions(featured, previousExpanded: previousExpanded)
                    } else {
                        modelOption(L10n.text("Авто", "Auto"), id: "")
                        if !model.currentModel.isEmpty && !model.models.contains(where: { $0.id == model.currentModel }) {
                            modelOption(model.currentModel, id: model.currentModel)
                        }
                        ForEach(model.models, id: \.id) { modelOption($0.displayName, id: $0.id) }
                    }
                }
                if !model.supportedEfforts.isEmpty {
                    divider
                    section(L10n.text("Рассуждение", "Reasoning")) {
                        effortOption(L10n.text("Авто", "Auto"), id: "")
                        if !model.effort.isEmpty && !model.supportedEfforts.contains(model.effort)
                            && showsEffortOption(model.effort) {
                            effortOption(model.effort, id: model.effort)
                        }
                        ForEach(model.supportedEfforts.filter(showsEffortOption), id: \.self) { effortOption($0, id: $0) }
                    }
                }
            }
            if showsSubagentChoice {
                if showsModels { divider }
                Toggle(L10n.text("Использовать подагентов", "Use subagents"), isOn: Binding(
                    get: { model.currentChatUsesSubagents },
                    set: { model.setCurrentChatUsesSubagents($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.ui(.callout))
                .padding(.horizontal, .ui(6)).padding(.vertical, .ui(4))
                .help(L10n.text("Делегирование реализации для этого чата.", "Delegate implementation in this chat."))
            }
            if showsModels, let project = model.selectedProject {
                divider
                section(L10n.text("Для новых чатов", "For new chats")) {
                    ModelMenuRow(title: L10n.text("Сделать по умолчанию в проекте «\(project.name)»", "Make default in project “\(project.name)”"),
                                 confirmed: savedDefault == true) {
                        model.saveCurrentModelAsDefault(projectOnly: true)
                        savedDefault = true
                    }
                    ModelMenuRow(title: L10n.text("Сделать по умолчанию во всех проектах", "Make default in all projects"),
                                 confirmed: savedDefault == false) {
                        model.saveCurrentModelAsDefault(projectOnly: false)
                        savedDefault = false
                    }
                }
            }
        }
        .padding(.ui(6))
        .frame(width: .ui(290))
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, .ui(6)).padding(.top, .ui(3)).padding(.bottom, .ui(2))
            rows()
        }
    }

    private var divider: some View { Divider().padding(.vertical, .ui(4)) }

    /// The inline group of superseded models, in place of a submenu.
    private func previousGenerations(expanded: Bool) -> some View {
        ModelMenuRow(title: L10n.text("Предыдущие поколения", "Previous generations"), expanded: expanded) {
            previousExpanded.toggle()
        }
        .accessibilityValue(expanded ? L10n.text("Развёрнуто", "Expanded") : L10n.text("Свёрнуто", "Collapsed"))
    }

    /// The current model belongs to the previous generations, so the list opens with them expanded.
    private var currentIsPrevious: Bool {
        let id = model.currentModel
        if let catalog { return catalog.previous.contains { $0.id == id } }
        guard let featured = profile?.featuredComposerModels, !featured.isEmpty else { return false }
        return !featured.contains(id) && model.models.contains { $0.id == id }
    }

    /// A new model or level invalidates the "Make default" confirmation.
    private func select(_ change: () -> Void) {
        change()
        savedDefault = nil
    }

    @ViewBuilder private func groupedModelOptions(_ featuredIDs: [String], previousExpanded: Bool) -> some View {
        let featured = featuredIDs.compactMap { id in model.models.first { $0.id == id } }
        let previous = model.models.filter { !featuredIDs.contains($0.id) }
        modelOption(L10n.text("Авто", "Auto"), id: "")
        if !model.currentModel.isEmpty && !model.models.contains(where: { $0.id == model.currentModel }) {
            modelOption(discoveredModelTitle(model.currentModel), id: model.currentModel)
        }
        ForEach(featured, id: \.id) { modelOption(discoveredModelTitle($0.id, displayName: $0.displayName), id: $0.id) }
        if !previous.isEmpty {
            previousGenerations(expanded: previousExpanded)
            if previousExpanded {
                ForEach(previous, id: \.id) { modelOption($0.displayName, id: $0.id, indent: true) }
            }
        }
    }

    private func discoveredModelTitle(_ id: String, displayName: String? = nil) -> String {
        profile?.composerModelTitles[id] ?? displayName ?? id
    }

    private func modelOption(_ title: String, id: String, indent: Bool = false) -> some View {
        ModelMenuRow(title: title, selected: model.currentModel == id, indent: indent) {
            select { if model.currentModel != id { model.selectModel(id) } }
        }
    }

    private func effortOption(_ title: String, id: String) -> some View {
        ModelMenuRow(title: title, selected: model.effort == id) {
            select { model.effort = id }
        }
    }

    private func showsEffortOption(_ effort: String) -> Bool {
        profile?.hiddenComposerEfforts.contains(effort) != true
    }

    /// Maximum is hidden for every Claude model (user decision 2026-11-24); the CLI still accepts it.
    private func claudeEffortOptions(_ catalog: AgentModelCatalog) -> [AgentModelCatalog.Level] {
        catalog.efforts.filter { $0.id != "max" }
    }

    private func entry(_ item: AgentModelCatalog.Entry, indent: Bool = false) -> some View {
        let note = item.requirementNote
        return ModelMenuRow(title: note.map { item.menuTitle + " · " + $0 } ?? item.menuTitle,
                            selected: model.currentModel == item.id, indent: indent) {
            select { model.selectCurrentModel(item.id) }
        }
        .disabled(note != nil)
    }

    private func commit() {
        model.selectCurrentModel(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        entering = false
    }
}

/// One menu-like row of the model list: a check column for the chosen item, the title, and a trailing
/// confirmation check or a group's disclosure chevron.
private struct ModelMenuRow: View {
    let title: String
    var selected = false
    var indent = false
    var confirmed = false
    /// Expansion of a group row; nil for an ordinary item.
    var expanded: Bool? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: .ui(6)) {
                Image(systemName: "checkmark").font(.ui(size: 10, weight: .semibold))
                    .frame(width: .ui(12)).opacity(selected ? 1 : 0)
                Text(title).lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, indent ? CGFloat.ui(12) : 0)
                Spacer(minLength: .ui(4))
                if confirmed {
                    Image(systemName: "checkmark").font(.ui(size: 10, weight: .semibold)).foregroundStyle(DeskPalette.accent)
                }
                if let expanded {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.ui(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .font(.ui(.callout)).foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.horizontal, .ui(6)).padding(.vertical, .ui(4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && isEnabled ? DeskPalette.subtle : .clear, in: RoundedRectangle(cornerRadius: .ui(5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
