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
    /// Hosts that publish roles get `MobileRoleSection` instead of the legacy access picker.
    var showsAccess = true
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
            if showsAccess {
                Picker(L10n.text("Доступ к системе", "System access"), selection: Binding(
                    get: { options.access?.rawValue ?? "" }, set: { options.access = RemoteAccessMode(rawValue: $0) })) {
                    Text(L10n.text("По умолчанию проекта", "Project default") + ": " + projectAccess.title).tag("")
                    ForEach(RemoteAccessMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("chat-access")
            }
            if showsAccess && (options.access ?? projectAccess) == .fullAccess {
                Text(L10n.text("Команды, файлы и сеть доступны без подтверждений агента.", "Commands, files and network access are allowed without agent approvals."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.text("Настройки чата", "Chat settings"))
        }
    }
}

/// Role and add-ons, for hosts that publish them. Roles never go above the project default (the host lists only
/// those); add-ons follow `RemoteChatSettings.addOnChoices`: on only within the project default, off always.
struct MobileRoleSection: View {
    @Binding var options: RemoteChatOptions
    /// The settings the choice starts from: a chat's published settings, or the project's for a new chat.
    let settings: RemoteChatSettings
    /// Add-ons the project default grants (the project's published list); nil for a new chat, whose list holds only those.
    var granted: [String]?
    /// New chat: add-ons left equal to the project default stay unset, so the chat follows the project.
    var followsProject = false
    static func shows(_ settings: RemoteChatSettings) -> Bool { !(settings.roles ?? []).isEmpty || !(settings.addOns ?? []).isEmpty }
    var body: some View {
        let roles = settings.roles ?? []
        let projectName = roles.first { $0.id == settings.projectRole }?.name
        let selected = options.addOns ?? (followsProject ? settings.projectAddOns ?? [] : [])
        let choices = settings.addOnChoices(selected: selected, granted: granted)
        Section {
            if !roles.isEmpty {
                Picker(L10n.text("Роль", "Role"), selection: Binding(get: { options.role ?? "" }, set: { id in
                    options.role = id.isEmpty ? nil : id
                    // The role wins over the legacy access mode; the one the chat already has keeps its published pair.
                    options.access = options.role == settings.options.role ? settings.options.access : nil
                })) {
                    Text(projectName.map { $0 + " · " + L10n.text("по умолчанию", "default") } ?? L10n.text("По умолчанию проекта", "Project default")).tag("")
                    ForEach(roles) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("chat-role")
            }
            ForEach(choices) { choice in
                Toggle(isOn: Binding(get: { choice.isOn }, set: { on in
                    let next = settings.addOns(selected, setting: choice.id, on: on, granted: granted)
                    options.addOns = followsProject && Set(next) == Set(settings.projectAddOns ?? []) ? nil : next
                })) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                        Text(choice.option.name)
                        if let summary = choice.option.summary, !summary.isEmpty {
                            Text(summary).font(.footnote).foregroundStyle(.secondary)
                        }
                        if !choice.isOn && !choice.canTurnOn {
                            Text(L10n.text("Не входит в настройки проекта по умолчанию. Включить можно на Mac.", "Not part of the project default. Turn it on on the Mac."))
                                .font(.footnote).foregroundStyle(.orange)
                        } else if choice.outsideDefault {
                            Text(L10n.text("Включено на Mac сверх настроек проекта. После выключения включить снова можно только на Mac.", "Turned on at the Mac beyond the project default. Once off, only the Mac can turn it on again."))
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        }
                    } icon: {
                        Image(systemName: choice.option.symbol ?? "puzzlepiece.extension")
                    }
                }
                .disabled(!choice.isOn && !choice.canTurnOn)
                .accessibilityIdentifier("chat-add-on-" + choice.id)
            }
        } header: {
            Text(L10n.text("Роль и дополнения", "Role and add-ons"))
        } footer: {
            Text(L10n.text("Роль не выше роли проекта по умолчанию. С телефона включаются только дополнения из настроек проекта по умолчанию; выключить можно любое.",
                           "Roles go up to the project default. From the phone you can turn on only add-ons the project default includes; any add-on can be turned off."))
        }
    }
}

struct MobileChatSettingsView: View {
    @ObservedObject var model: MobileModel
    let deviceID: String
    let chatID: String
    @State var expected: RemoteChatSettings
    @State var options: RemoteChatOptions
    /// Add-ons the project default grants; see `MobileRoleSection.granted`.
    var granted: [String]? = nil
    @State private var receiptID: String?
    @Environment(\.dismiss) private var dismiss
    private var key: MobileChatKey { MobileChatKey(device: deviceID, chat: chatID) }
    var body: some View {
        NavigationStack {
            Form {
                if let device = model.devices.first(where: { $0.id == deviceID }),
                   let chat = device.snapshot.chats.first(where: { $0.id == chatID }) {
                    let locked = model.isSending(key) || receiptID != nil || chat.settings?.canEdit != true
                    MobileOptionsSection(options: $options, models: device.snapshot.projects.first(where: { $0.id == chat.project })?.models ?? [],
                                         projectAccess: expected.projectAccess, showsAccess: (expected.roles ?? []).isEmpty)
                        .disabled(locked)
                    if MobileRoleSection.shows(expected) {
                        MobileRoleSection(options: $options, settings: expected, granted: granted)
                            .disabled(locked)
                    }
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
                    MobileOptionsSection(options: $options, models: choice.project.newChatModels ?? choice.project.models ?? [], projectAccess: settings.projectAccess,
                                         showsAccess: (settings.roles ?? []).isEmpty)
                        .disabled(sending || !settings.canEdit)
                    if MobileRoleSection.shows(settings) {
                        MobileRoleSection(options: $options, settings: settings, followsProject: true)
                            .disabled(sending || !settings.canEdit)
                    }
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
