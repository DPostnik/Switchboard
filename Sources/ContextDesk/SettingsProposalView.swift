import SwiftUI
import ContextCore
import AgentContract
import ContextTranscript

/// Review of project settings an agent proposed. Nothing changes until the user presses Apply; Reject removes the proposal.
struct SettingsProposalView: View {
    @ObservedObject var model: DeskModel
    let review: SettingsProposalReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: .ui(14)) {
                    Text(L10n.text("Агент предлагает изменить настройки проектов", "An agent proposes project settings changes"))
                        .font(.ui(.title3).weight(.semibold)).foregroundStyle(DeskPalette.ink).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: .ui(4)) {
                        if let title = model.proposalChatTitle(review.chat) {
                            Text(L10n.text("Из чата «\(title)»", "From the chat “\(title)”")).font(.ui(.callout)).foregroundStyle(DeskPalette.inkSoft)
                        }
                        if let reason = review.reason {
                            Text(reason).font(.ui(.callout)).foregroundStyle(DeskPalette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        // No chat to continue: say so instead of leaving the user to wait for a continuation that never comes.
                        if review.requestingChat(in: model.state.chats) == nil {
                            Text(SettingsProposalReview.unknownAuthorNotice()).font(.ui(.callout)).foregroundStyle(DeskPalette.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(L10n.text("Ничего не изменится, пока ты не нажмёшь «Применить». Агент не может применить это сам.",
                                       "Nothing changes until you press Apply. The agent cannot apply this itself."))
                            .font(.ui(.caption)).foregroundStyle(DeskPalette.muted).fixedSize(horizontal: false, vertical: true)
                        SettingsProposalBoundarySummary(notes: model.settingsProposalBoundaryNotes[review.id] ?? [])
                    }
                    SettingsProposalChanges(review: review, notes: model.settingsProposalBoundaryNotes[review.id] ?? [])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, .ui(22)).padding(.vertical, .ui(20))
            }
            .background(DeskPalette.canvas)
            Divider()
            HStack(spacing: .ui(8)) {
                Spacer()
                Button(L10n.text("Отклонить", "Reject"), role: .cancel) { model.rejectSettingsProposal(review.id); dismiss() }
                    .buttonStyle(DeskButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(L10n.text("Применить", "Apply")) { model.applySettingsProposal(review.id); dismiss() }
                    .buttonStyle(DeskButtonStyle(kind: .primary)).disabled(review.projects.isEmpty)
            }
            .padding(.horizontal, .ui(16)).padding(.vertical, .ui(12))
            .background(DeskPalette.canvas)
        }
        .frame(width: 620, height: 520)
    }
}

/// The list of changes of one proposal, shared by the global sheet and the request card in a chat. Paths, commands and
/// project names are shown as data.
struct SettingsProposalChanges: View {
    let review: SettingsProposalReview
    /// `DeskModel.settingsProposalBoundaryNotes` for this review.
    var notes: [SettingsProposalBoundaryNote] = []

    var body: some View {
        ForEach(review.projects, id: \.projectID) { diff in projectCard(diff) }
        if !review.skipped.isEmpty {
            VStack(alignment: .leading, spacing: .ui(3)) {
                Text(L10n.text("Пропущено", "Skipped")).font(.ui(.callout).weight(.semibold))
                ForEach(review.skipped, id: \.self) { Text($0).font(.ui(.caption)).foregroundStyle(DeskPalette.attention) }
            }
        }
    }

    private func projectCard(_ diff: SettingsProposalReview.ProjectDiff) -> some View {
        VStack(alignment: .leading, spacing: .ui(5)) {
            Text(diff.name).font(.ui(.callout).weight(.semibold)).foregroundStyle(DeskPalette.ink)
            if let sandbox = diff.sandbox {
                line(sandbox ? "+" : "−", sandbox ? L10n.text("Включить песочницу команд", "Turn the command sandbox on")
                                                  : L10n.text("Выключить песочницу команд: команды увидят весь Mac", "Turn the command sandbox off: commands will see the whole Mac"),
                     warning: !sandbox)
            }
            ForEach(diff.addPresets, id: \.self) { id in
                line("+", L10n.text("Набор: ", "Set: ") + (AccessPresetCatalog.preset(id)?.title ?? id))
            }
            ForEach(diff.removePresets, id: \.self) { id in
                line("−", L10n.text("Убрать набор: ", "Remove set: ") + (AccessPresetCatalog.preset(id)?.title ?? id))
            }
            ForEach(diff.addFolders, id: \.path) { root in
                line("+", L10n.text("Папка: ", "Folder: ") + root.path + (root.writable ? L10n.text(" — чтение и запись", " — read and write") : L10n.text(" — только чтение", " — read only")),
                     warning: root.writable)
            }
            ForEach(diff.removeFolders, id: \.self) { line("−", L10n.text("Убрать папку: ", "Remove folder: ") + $0) }
            ForEach(diff.addCommands, id: \.self) { command in
                line("+", L10n.text("Вне песочницы без вопроса (доступ ко всему Mac): ", "Outside the sandbox without a prompt (access to the whole Mac): ") + command, warning: true)
                // Under the external boundary the command gains nothing or moves the chats off it: said before Apply, not after.
                ForEach(notes.filter { $0.projectID == diff.projectID && $0.command == command }, id: \.provider) { note in
                    Label { Text(note.text()).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.ui(.callout).weight(.semibold)).foregroundStyle(DeskPalette.attention)
                    .padding(.leading, .ui(14)).accessibilityLabel(note.text())
                }
            }
            ForEach(diff.removeCommands, id: \.self) { line("−", L10n.text("Убрать команду вне песочницы (доступ сужается): ", "Remove command outside the sandbox (access gets narrower): ") + $0) }
            // The secret of an added item becomes readable by the project's agents: warning weight, exact service as data.
            ForEach(diff.addKeychainItems, id: \.self) { line("+", KeychainItemRule.addLine($0), warning: true) }
            ForEach(diff.removeKeychainItems, id: \.self) { line("−", KeychainItemRule.removeLine($0)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, .ui(12)).padding(.vertical, .ui(10))
        .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private func line(_ sign: String, _ text: String, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: .ui(6)) {
            Text(sign).font(.ui(.callout).monospaced().weight(.semibold)).foregroundStyle(sign == "+" ? DeskPalette.accentDeep : DeskPalette.muted)
            Text(text).font(.ui(.callout)).foregroundStyle(warning ? DeskPalette.attention : DeskPalette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One bold line above the decision when an added trusted command gains nothing under the external boundary or moves the
/// project's chats off it; the per-command lines in the list say which and what to request instead. Apply stays enabled.
struct SettingsProposalBoundarySummary: View {
    let notes: [SettingsProposalBoundaryNote]

    var body: some View {
        if let text = Self.text(notes) {
            // This summary also sits outside the card's bounded scroll view. Let it accept
            // the proposed height: fixedSize would wrap it at the split view's zero-width
            // minimum-size probe and push the sidebar/composer outside the window again.
            Label { Text(text) } icon: { Image(systemName: "exclamationmark.octagon.fill") }
                .font(.ui(.callout).weight(.semibold)).foregroundStyle(DeskPalette.attention)
        }
    }

    static func text(_ notes: [SettingsProposalBoundaryNote], language: AppLanguage = L10n.language) -> String? {
        if notes.contains(where: { if case .leavesBoundary = $0.effect { true } else { false } }) {
            return L10n.text("Внимание: после применения чаты этого проекта уйдут с внешней границы (подробности рядом с командой).",
                             "Warning: applying this moves this project's chats off the external boundary (details next to the command).", language: language)
        }
        guard !notes.isEmpty else { return nil }
        return L10n.text("Внимание: под внешней границей добавленная команда не получит дополнительного доступа, и повтор шага не поможет (подробности рядом с командой).",
                         "Warning: under the external boundary the added command gets no extra access, so retrying the step will not help (details next to the command).", language: language)
    }
}

/// An access request in the chat that made it: the same list of changes as the sheet, the agent's reason as data, and
/// the user's decision. Apply saves the settings and the chat continues with the new access at its next turn; Reject tells
/// the chat the request was refused. Either way the chat receives one fixed app message.
struct SettingsProposalCard: View {
    @ObservedObject var model: DeskModel
    let review: SettingsProposalReview

    var body: some View {
        VStack(alignment: .leading, spacing: .ui(10)) {
            Label { Text(L10n.text("Агент просит доступ", "The agent asks for access")).foregroundStyle(DeskPalette.ink) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DeskPalette.attention)
            }.font(.ui(.headline))
            // Bound the entire review body. A vertically fixed reason outside the scroll view
            // wraps at the split view's minimum-width probe and inflates the whole window.
            ScrollView {
                VStack(alignment: .leading, spacing: .ui(8)) {
                    if let reason = review.reason {
                        Text(reason).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsProposalChanges(review: review, notes: model.settingsProposalBoundaryNotes[review.id] ?? [])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            // Outside the scroll view, so the consequence is seen without scrolling to the command.
            SettingsProposalBoundarySummary(notes: model.settingsProposalBoundaryNotes[review.id] ?? [])
            Text(L10n.text("Изменятся настройки проекта для всех его чатов. Ничего не изменится, пока ты не нажмёшь «Применить»; после этого чат продолжит задачу с новыми правами.",
                           "This changes the project settings for all its chats. Nothing changes until you press Apply; then the chat continues the task with the new access."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            HStack {
                Spacer(minLength: 0)
                Button(L10n.text("Отклонить", "Reject")) { model.rejectSettingsProposal(review.id) }.buttonStyle(DeskButtonStyle())
                Button(L10n.text("Применить", "Apply")) { model.applySettingsProposal(review.id) }
                    .buttonStyle(DeskButtonStyle(kind: .primary)).disabled(review.projects.isEmpty)
            }
        }
        .controlSize(.large).padding(16).background(DeskPalette.attentionWash, in: RoundedRectangle(cornerRadius: 14))
    }
}
