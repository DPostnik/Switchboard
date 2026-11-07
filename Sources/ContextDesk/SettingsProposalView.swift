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
                        Text(L10n.text("Ничего не изменится, пока ты не нажмёшь «Применить». Агент не может применить это сам.",
                                       "Nothing changes until you press Apply. The agent cannot apply this itself."))
                            .font(.ui(.caption)).foregroundStyle(DeskPalette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(review.projects, id: \.projectID) { diff in projectCard(diff) }
                    if !review.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: .ui(3)) {
                            Text(L10n.text("Пропущено", "Skipped")).font(.ui(.callout).weight(.semibold))
                            ForEach(review.skipped, id: \.self) { Text($0).font(.ui(.caption)).foregroundStyle(DeskPalette.attention) }
                        }
                    }
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
                line("−", L10n.text("Набор: ", "Set: ") + (AccessPresetCatalog.preset(id)?.title ?? id))
            }
            ForEach(diff.addFolders, id: \.path) { root in
                line("+", L10n.text("Папка: ", "Folder: ") + root.path + (root.writable ? L10n.text(" — чтение и запись", " — read and write") : L10n.text(" — только чтение", " — read only")),
                     warning: root.writable)
            }
            ForEach(diff.removeFolders, id: \.self) { line("−", L10n.text("Папка: ", "Folder: ") + $0) }
            ForEach(diff.addCommands, id: \.self) { command in
                line("+", L10n.text("Вне песочницы без вопроса (доступ ко всему Mac): ", "Outside the sandbox without a prompt (access to the whole Mac): ") + command, warning: true)
            }
            ForEach(diff.removeCommands, id: \.self) { line("−", L10n.text("Команда вне песочницы: ", "Command outside the sandbox: ") + $0) }
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
