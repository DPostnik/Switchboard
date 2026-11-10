import ContextTranscript
import SwiftUI
import ContextCore

struct ActionView: View {
    let action: PendingAction
    @ObservedObject var model: DeskModel
    @State private var answers: [String: String] = [:]
    @State private var validation: String?
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(action.title).foregroundStyle(DeskPalette.ink) } icon: { Image(systemName: "exclamationmark.diamond.fill").foregroundStyle(DeskPalette.attention) }
                .font(.ui(.headline))
            if let explanation = model.permissionExplanation(for: action) {
                Text(explanation).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            switch action.interaction.kind {
            case .questions(let fields):
                questionFields(fields, onSubmit: { submitAnswers(fields) })
                answerButton(fields)
            case .form(let message, let fields):
                Text(message).textSelection(.enabled)
                questionFields(fields, onSubmit: { submitAnswers(fields) })
                answerButton(fields)
                declineButton
            case .link(let message, let url):
                Text(message).textSelection(.enabled)
                Link(L10n.text("Открыть страницу инструмента", "Open tool page"), destination: url).pointingHandCursor()
                Button(L10n.text("Действие выполнено", "Action completed")) { submit(.completed) }.buttonStyle(DeskButtonStyle(kind: .primary))
                declineButton
            case .unsupported(let message):
                Text(message).textSelection(.enabled)
                unsupportedMessage
                declineButton
            case .approval(let canAllow):
                if let reason = action.interaction.reason { Text(reason).textSelection(.enabled) }
                DisclosureGroup(L10n.text("Детали запроса", "Request details")) {
                    ScrollView { Text(action.interaction.details).font(.ui(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 160).padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                }.disclosureGroupStyle(PointerDisclosureStyle())
                if !canAllow { unsupportedMessage }
                HStack {
                    declineButton
                    if canAllow {
                        if action.interaction.canAllowTurn {
                            Button(L10n.text("Разрешить до конца хода", "Allow for this turn")) { submit(.allowTurn) }.buttonStyle(DeskButtonStyle())
                                .help(L10n.text("Этот и следующие запросы того же инструмента в этом ходе", "This and later requests of the same tool in this turn"))
                        }
                        if action.interaction.canAllowChat {
                            Button(L10n.text("Разрешить в этом чате", "Allow in this chat")) { submit(.allowChat) }.buttonStyle(DeskButtonStyle())
                                .help(L10n.text("Этот и следующие вызовы инструментов этого браузера в этом чате, пока Switchboard не перезапустится",
                                                "This and later calls to this browser's tools in this chat until Switchboard restarts"))
                        }
                        Button(L10n.text("Разрешить один раз", "Allow once")) { submit(.allowOnce) }
                            .buttonStyle(DeskButtonStyle(kind: .primary))
                    }
                }
            }
            if let validation { Text(validation).font(.ui(.caption)).foregroundStyle(DeskPalette.problem) }
        }.textFieldStyle(.roundedBorder).controlSize(.large).padding(16).background(DeskPalette.attentionWash, in: RoundedRectangle(cornerRadius: 14)).disabled(submitting)
    }
    private var unsupportedMessage: some View {
        Text(L10n.text("Этот запрос нельзя подтвердить в приложении. Его можно отклонить и продолжить разговор.", "This request cannot be approved in the app. You can decline it and continue the conversation.")).font(.ui(.caption))
    }
    private var declineButton: some View { Button(L10n.text("Отклонить", "Decline")) { submit(.deny) }.buttonStyle(DeskButtonStyle()) }
    private func questionFields(_ fields: [AgentInteraction.Field], onSubmit: @escaping () -> Void) -> some View {
        ForEach(fields) { field in
            Text(field.text).textSelection(.enabled)
            // Each option is a row: the label is the answer, the description explains it, the preview opens for the selected row.
            ForEach(Array(field.options.enumerated()), id: \.offset) { _, option in
                optionRow(option, selected: answers[field.id] == option.label) { answers[field.id] = option.label }
            }
            // Return submits the answers like the button instead of leaving the card silently open.
            Group {
                if field.secret { SecureField(L10n.text("Твой ответ", "Your answer"), text: binding(field.id)) }
                else { TextField(L10n.text("Твой ответ", "Your answer"), text: binding(field.id)) }
            }.onSubmit(onSubmit)
        }
    }
    @ViewBuilder private func optionRow(_ option: AgentInteraction.Field.Option, selected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? DeskPalette.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    if let description = option.description {
                        Text(description).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(selected ? DeskPalette.accentWash : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(PointerButtonStyle(base: .plain))
        if selected, let preview = option.preview {
            ScrollView {
                Text(preview).font(.ui(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160).padding(8).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func answerButton(_ fields: [AgentInteraction.Field]) -> some View {
        Button(L10n.text("Ответить", "Submit answer")) { submitAnswers(fields) }
            .buttonStyle(DeskButtonStyle(kind: .primary))
    }
    private func submitAnswers(_ fields: [AgentInteraction.Field]) {
        guard !submitting else { return }
        guard fields.allSatisfy({ !$0.required || !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            validation = L10n.text("Заполни обязательные поля", "Fill in the required fields"); return
        }
        submit(.answers(answers))
    }
    private func binding(_ id: String) -> Binding<String> { Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }) }
    private func submit(_ value: AgentInteractionResponse) {
        submitting = true; validation = nil
        Task {
            if let failure = await model.answer(action, result: value) { validation = failure }
            submitting = false
        }
    }
}
