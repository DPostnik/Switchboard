import SwiftUI
import ContextCore

/// The stopped chat's usage-limit notice: the reset time and one click to continue after it, or the armed plan with Cancel.
struct LimitResumeBar: View {
    @ObservedObject var model: DeskModel
    let chat: Chat
    let columnWidth: CGFloat

    var body: some View {
        if let resume = chat.limitResume, !chat.isArchived, !model.isBusy(threadID: chat.id) {
            let now = Date()
            HStack(alignment: .firstTextBaseline, spacing: .ui(12)) {
                if let due = resume.continueAt {
                    Label(LimitResume.armedText(due, now: now), systemImage: "clock").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L10n.text("Отменить", "Cancel")) { model.cancelLimitResume(chat.id) }
                        .controlSize(.small).fixedSize()
                        .help(L10n.text("Не отправлять продолжение. Предложение останется в чате.",
                                        "Do not send the continuation. The offer stays in the chat."))
                } else {
                    let reset = model.limitResumeReset(chat, now: now)
                    Label(LimitResume.offerText(reset: reset, now: now), systemImage: "hourglass").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if reset != nil {
                        Button { model.armLimitResume(chat.id) } label: {
                            Label(L10n.text("Продолжить после сброса", "Continue after reset"), systemImage: "clock.arrow.circlepath")
                        }
                        .controlSize(.small).fixedSize()
                        .help(L10n.text("Через минуту после сброса лимита отправит в этот чат: «\(LimitResume.message())» Если ты напишешь сам или чат будет занят, отправки не будет.",
                                        "A minute after the limit resets, sends to this chat: \"\(LimitResume.message())\" Nothing is sent if you write yourself or the chat is busy."))
                    }
                    Button { model.dropLimitResume(chat.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(PointerButtonStyle(base: .plain))
                        .help(L10n.text("Скрыть", "Dismiss"))
                        .accessibilityLabel(L10n.text("Скрыть", "Dismiss"))
                }
            }
            .font(.ui(.callout))
            .frame(maxWidth: columnWidth, alignment: .leading).padding(.horizontal, .ui(24)).padding(.vertical, .ui(8))
        }
    }
}
