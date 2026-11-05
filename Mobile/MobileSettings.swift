import SwiftUI

struct MobileSettings: View {
    @ObservedObject var model: MobileModel
    @Binding var language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
                    } label: {
                        Label("Язык / Language", systemImage: "globe")
                    }.accessibilityIdentifier("language-picker")
                } header: {
                    Text(L10n.text("Язык", "Language"))
                } footer: {
                    Text(L10n.text("Меняется сразу. Твои сообщения и ответы агентов не переводятся.", "Changes right away. Your messages and agent answers are not translated."))
                }
                Section {
                    Label(L10n.text("Push пока не подключены", "Push notifications are not connected"), systemImage: "bell.badge")
                } header: {
                    Text(L10n.text("Уведомления", "Notifications"))
                } footer: {
                    Text(L10n.text("Для уведомлений на заблокированном iPhone нужна подпись Apple Developer Program. Текущая бесплатная установка её не поддерживает.", "Notifications on a locked iPhone require Apple Developer Program signing. The current free installation does not support it."))
                }
                Section {
                    Label(L10n.text("Последние 20 сообщений", "The latest 20 messages"), systemImage: "clock.arrow.circlepath")
                } header: {
                    Text(L10n.text("История", "History"))
                } footer: {
                    Text(L10n.text("Здесь — последние 20 сообщений недавних чатов. Длинные сообщения сокращены до 2000 символов. Полная история остаётся на Mac. Файл проекта из ответа открывается нажатием на его путь.", "The latest 20 messages in recent chats are shown here. Long messages are limited to 2,000 characters. Full history stays on your Mac. Tap a project file path in an answer to open the file."))
                }
                if model.signedIn {
                    Section {
                        Button(L10n.text("Выйти из аккаунта", "Sign out"), role: .destructive) { Task { await model.signOut(); dismiss() } }
                    }
                }
            }
            .navigationTitle(L10n.text("Настройки", "Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Готово", "Done")) { dismiss() } } }
        }
    }
}

struct MobileOptionsSection: View {
    @Binding var options: RemoteChatOptions
    let models: [RemoteModelOption]
    let projectAccess: RemoteAccessMode
    var body: some View {
        Section {
            Picker(L10n.text("Модель", "Model"), selection: $options.model) {
                if !models.contains(where: { $0.id == options.model }) {
                    Text(options.model.isEmpty ? L10n.text("Недоступна", "Unavailable") : options.model).tag(options.model)
                }
                // Models tagged with agents are grouped, so the choice shows which agent runs the chat.
                let agents = models.reduce(into: [String]()) { if !$0.contains($1.agentTitle) { $0.append($1.agentTitle) } }
                if models.contains(where: { $0.agent != nil }) {
                    ForEach(agents, id: \.self) { agent in
                        Section(agent) { ForEach(models.filter { $0.agentTitle == agent }) { Text($0.name).tag($0.id) } }
                    }
                } else {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
            }.accessibilityIdentifier("chat-model")
            if let agent = models.first(where: { $0.id == options.model && $0.agent != nil })?.agentTitle {
                Text(L10n.text("Агент: \(agent)", "Agent: \(agent)")).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat-agent")
            }
            Picker(L10n.text("Доступ к системе", "System access"), selection: Binding(
                get: { options.access?.rawValue ?? "" }, set: { options.access = RemoteAccessMode(rawValue: $0) })) {
                Text(L10n.text("По умолчанию проекта", "Project default") + ": " + projectAccess.title).tag("")
                ForEach(RemoteAccessMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }.accessibilityIdentifier("chat-access")
            if (options.access ?? projectAccess) == .fullAccess {
                Text(L10n.text("Команды, файлы и сеть доступны без подтверждений агента.", "Commands, files and network access are allowed without agent approvals."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.text("Настройки чата", "Chat settings"))
        }
    }
}

struct MobileChatSettingsView: View {
    @ObservedObject var model: MobileModel
    let deviceID: String
    let chatID: String
    @State var expected: RemoteChatSettings
    @State var options: RemoteChatOptions
    @State private var receiptID: String?
    @Environment(\.dismiss) private var dismiss
    private var key: MobileChatKey { MobileChatKey(device: deviceID, chat: chatID) }
    var body: some View {
        NavigationStack {
            Form {
                if let device = model.devices.first(where: { $0.id == deviceID }),
                   let chat = device.snapshot.chats.first(where: { $0.id == chatID }) {
                    MobileOptionsSection(options: $options, models: device.snapshot.projects.first(where: { $0.id == chat.project })?.models ?? [],
                                         projectAccess: expected.projectAccess)
                        .disabled(model.isSending(key) || receiptID != nil || chat.settings?.canEdit != true)
                    Section {
                        Button {
                            Task { receiptID = await model.configureChat(device: device, chat: chat, options: options, expected: expected)?.id }
                        } label: {
                            HStack { Text(L10n.text("Сохранить", "Save")); Spacer(); if model.isSending(key) { ProgressView() } }
                        }.accessibilityIdentifier("save-chat-settings")
                            .disabled(options == expected.options || options.model.isEmpty || model.isBlocked(key) || receiptID != nil || chat.settings?.canEdit != true || model.pendingSettings(device: deviceID, chat: chatID))
                        if let receiptID, let receipt = model.commands.first(where: { $0.id == receiptID }) {
                            Text(settingsStatus(receipt.status, applied: chat.settings?.options == options))
                                .font(.footnote).accessibilityIdentifier("chat-settings-status")
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Применяется со следующего сообщения. Настройки проекта не меняются.", "Applies from the next message. Project settings stay unchanged."))
                            if chat.settings?.canEdit != true {
                                Text(L10n.text("Дождись окончания работы и ответь на ожидающие запросы, чтобы изменить настройки.", "Wait for the chat to finish and answer pending requests before changing settings."))
                            }
                        }
                    }
                    let receipt = model.receipt(key)
                    if receipt != nil || model.chatErrors[key] != nil {
                        Section { MobileDeliveryNotice(model: model, key: key, receipt: receipt) }
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(L10n.text("Настройки чата", "Chat settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Готово", "Done")) { dismiss() }.disabled(model.isSending(key)) } }
            .interactiveDismissDisabled(model.isSending(key))
        }
    }
    private func settingsStatus(_ status: String, applied: Bool) -> String {
        switch status {
        case "pending", "claimed": L10n.text("Настройки ожидают Mac", "Settings waiting for Mac")
        case "submitted": applied ? L10n.text("Настройки сохранены", "Settings saved") : L10n.text("Ожидаем обновления с Mac", "Waiting for the Mac update")
        case "rejected": L10n.text("Настройки не применены: чат занят или данные изменились. Закрой и снова открой настройки.", "Settings not applied: the chat is busy or has changed. Close and reopen settings.")
        default: L10n.text("Результат неизвестен. Проверь настройки на Mac; автоматического повтора нет.", "Outcome unknown. Check settings on your Mac; no automatic retry.")
        }
    }
}

struct MobileNewChatView: View {
    @ObservedObject var model: MobileModel
    let created: (RemoteCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ""
    @State private var message = ""
    @State private var options = RemoteChatOptions(model: "")
    private var choices: [(id: String, device: RemoteDevice, project: RemoteProject)] {
        model.devices.flatMap { device in device.snapshot.projects.map { (device.id + ":" + $0.id, device, $0) } }
    }
    private var choice: (id: String, device: RemoteDevice, project: RemoteProject)? { choices.first { $0.id == selection } }
    private var sending: Bool { choice.map { model.isSending(MobileModel.creationKey(device: $0.device.id, project: $0.project.id)) } ?? false }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.text("Проект", "Project"), selection: $selection) {
                        ForEach(choices, id: \.id) { choice in
                            Text(choice.project.name + " · " + choice.device.name).tag(choice.id)
                        }
                    }.accessibilityIdentifier("new-chat-project")
                } header: {
                    Text(L10n.text("Проект", "Project"))
                } footer: {
                    Text(L10n.text("Чат создаётся на Mac. Модель определяет агента — Codex или Claude. Выбранные модель и доступ сохраняются для этого чата.", "The chat is created on your Mac. The model determines the agent: Codex or Claude. Your model and access choices are saved for this chat."))
                }
                if let choice, let settings = choice.project.settings {
                    MobileOptionsSection(options: $options, models: choice.project.newChatModels ?? choice.project.models ?? [], projectAccess: settings.projectAccess)
                        .disabled(sending || !settings.canEdit)
                }
                Section(L10n.text("Первое сообщение", "First message")) {
                    TextField(L10n.text("Что нужно сделать?", "What would you like to do?"), text: $message, axis: .vertical)
                        .lineLimit(4...10).accessibilityIdentifier("new-chat-message")
                }
                if let choice {
                    let key = MobileModel.creationKey(device: choice.device.id, project: choice.project.id)
                    let pending = model.creationReceipt(device: choice.device.id, project: choice.project.id)
                    Section {
                        Button {
                            Task {
                                if let command = await model.createChat(device: choice.device, project: choice.project, text: message,
                                    options: choice.project.settings == nil ? nil : options) { created(command) }
                            }
                        } label: {
                            HStack { Text(L10n.text("Создать и отправить", "Create and send")); Spacer(); if sending { ProgressView() } }
                        }.accessibilityIdentifier("create-chat")
                            .disabled(choice.project.canCreateChat != true || (choice.project.settings != nil && (choice.project.settings?.canEdit != true || options.model.isEmpty)) || sending || pending != nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        if choice.project.canCreateChat != true {
                            Text(L10n.text("Обнови и открой Switchboard на Mac, подключи Codex или Claude и включи мобильный доступ.", "Update and open Switchboard on your Mac, connect Codex or Claude and enable mobile access."))
                        } else if pending != nil {
                            Text(L10n.text("Новый чат в этом проекте ещё не подтверждён. Разберись с ним, прежде чем создавать следующий.", "A new chat in this project is still unconfirmed. Resolve it before creating another one."))
                        }
                    }
                    // Creation errors are kept per project; the unconfirmed chat's own checks report in its chat.
                    if model.chatErrors[key] != nil {
                        Section { MobileDeliveryNotice(model: model, key: key, receipt: nil) }
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                    if let pending {
                        Section { MobileDeliveryNotice(model: model, key: MobileChatKey(pending), receipt: pending) }
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(L10n.text("Новый чат", "New chat")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Отмена", "Cancel")) { dismiss() }.disabled(sending) } }
            .interactiveDismissDisabled(sending)
            .onAppear { if selection.isEmpty { selection = choices.first(where: { $0.project.canCreateChat == true })?.id ?? choices.first?.id ?? "" } }
            .onChange(of: selection) { _, _ in options = choice?.project.settings?.options ?? RemoteChatOptions(model: "") }
        }
    }
}
