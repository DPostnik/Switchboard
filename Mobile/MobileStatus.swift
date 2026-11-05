import SwiftUI

/// Shared wording for command states.
enum MobileText {
    static func command(_ status: String) -> String {
        switch status {
        case "pending": L10n.text("Ожидает Mac", "Waiting for Mac")
        case "claimed": L10n.text("Получено Mac", "Received by Mac")
        case "submitted": L10n.text("Передано агенту", "Submitted to agent")
        case "stop_requested": L10n.text("Остановка запрошена", "Stop requested")
        case "rejected": L10n.text("Команда отклонена: чат недоступен, занят или запрос устарел", "Command rejected: chat unavailable, busy or request stale")
        default: L10n.text("Результат неизвестен · проверь Mac", "Outcome unknown · check your Mac")
        }
    }
}

extension RemoteChat {
    /// The agent running this chat, when the snapshot shows it: Codex chats carry settings with a
    /// model of a known agent, read-only records come from Claude scheduled runs. Otherwise unknown.
    func agentTitle(in project: RemoteProject?) -> String? {
        if readOnly == true { return "Claude" }
        guard let model = settings?.options.model else { return nil }
        let known = (project?.newChatModels ?? []) + (project?.models ?? [])
        return known.first { $0.id == model }?.agentTitle ?? "Codex"
    }
    var runningStart: Date? {
        guard running, let runningSince else { return nil }
        return ISO8601DateFormatter().date(from: runningSince)
    }
}

/// One line about the server and one Mac: shown at the top of the chat list and, when not connected, in a chat.
struct ConnectionStatus: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    var showsName = false
    var body: some View {
        let server = model.connectionState == .connected
        let host = server && model.onlineMacs.contains(device.id.lowercased())
        let text = server ? (host ? L10n.text("Mac на связи", "Mac connected") : L10n.text("Mac недоступен", "Mac unavailable")) : model.connectionState.text
        HStack(spacing: 8) {
            Circle().fill(host ? Color.green : .orange).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(showsName ? device.name + " · " + text : text)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let date = ISO8601DateFormatter().date(from: device.seen) {
                Text(date, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(L10n.text("Последнее обновление данных", "Last data update") + ": " + date.formatted(.relative(presentation: .named).locale(L10n.locale)))
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-status")
    }
}

/// Errors and the delivery receipt of one chat (or of new chats in one project), with the next step.
/// An unconfirmed command blocks only this chat; nothing is resent automatically.
struct MobileDeliveryNotice: View {
    @ObservedObject var model: MobileModel
    let key: MobileChatKey
    /// The receipt to explain; nil shows only errors.
    let receipt: RemoteCommand?
    var body: some View {
        let error = model.chatErrors[key]
        if error != nil || receipt != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        .accessibilityIdentifier("chat-error")
                }
                if let receipt {
                    let undelivered = model.isUndelivered(receipt)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(undelivered ? L10n.text("Команды нет в облаке", "The command is not in the cloud")
                                          : L10n.text("Доставка не подтверждена", "Delivery unconfirmed"),
                              systemImage: undelivered ? "icloud.slash" : "questionmark.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(!undelivered
                             ? L10n.text("Новые команды в этом чате ждут проверки. Проверь доставку; повторной отправки без тебя не будет.", "New commands in this chat wait for this check. Check delivery; nothing is resent without you.")
                             : model.canResend(receipt)
                             ? L10n.text("Mac её не получит. Отправь снова или сбрось её — другие чаты не затронуты.", "Your Mac will not receive it. Send it again or discard it; other chats are not affected.")
                             // After a relaunch the phone keeps only the text (photos are never stored), so it cannot resend.
                             : L10n.text("Mac её не получит. Сбрось её и напиши сообщение заново — другие чаты не затронуты.", "Your Mac will not receive it. Discard it and write the message again; other chats are not affected."))
                            .foregroundStyle(.secondary)
                        if !receipt.text.isEmpty {
                            Text(receipt.text).lineLimit(2).foregroundStyle(.secondary).italic()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 8) {
                        if undelivered {
                            if model.canResend(receipt) {
                                Button(L10n.text("Отправить снова", "Send again")) { Task { await model.resendUndelivered(receipt) } }
                                    .buttonStyle(.borderedProminent).accessibilityIdentifier("resend-command")
                            }
                            Button(L10n.text("Сбросить", "Discard"), role: .destructive) { model.discardUndelivered(receipt) }
                                .buttonStyle(.bordered).accessibilityIdentifier("discard-command")
                        } else {
                            Button(L10n.text("Проверить доставку", "Check delivery")) { Task { await model.checkDelivery(receipt) } }
                                .buttonStyle(.bordered).accessibilityIdentifier("check-delivery")
                        }
                        if model.isSending(key) { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.small)
                    .disabled(model.isSending(key))
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(receipt == nil ? 0 : 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("delivery-notice")
        }
    }
}

/// Account and connection errors that belong to no chat.
struct MobileAccountNotice: View {
    @ObservedObject var model: MobileModel
    var body: some View {
        if !model.status.isEmpty {
            Label(model.status, systemImage: "exclamationmark.circle")
                .font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
                .accessibilityIdentifier("account-notice")
        }
    }
}
