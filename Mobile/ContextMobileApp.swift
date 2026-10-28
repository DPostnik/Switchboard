import SwiftUI
import Foundation
import PhotosUI
import ImageIO

@MainActor final class MobileModel: ObservableObject {
    @Published var url = UserDefaults.standard.string(forKey: "supabaseURL") ?? ""
    @Published var key = UserDefaults.standard.string(forKey: "supabaseKey") ?? ""
    @Published var email = ""
    @Published var password = ""
    @Published var devices: [RemoteDevice] = []
    @Published var commands: [RemoteCommand] = []
    @Published var status = ""
    @Published var connecting = false
    @Published var drafts: [String: String] = [:]
    @Published var photoDrafts: [String: [RemotePhoto]] = [:]
    @Published var signedIn = false
    @Published var sending = false
    @Published var unresolved: RemoteCommand?
    /// The cloud lookup did not find the unresolved command after its send had ended.
    @Published var undelivered = false
    /// The full unresolved command, photos included; the stored receipt omits photos.
    private var unsentBody: RemoteCommand?
    var api: RemoteAPI?
    var receiptStorage: RemoteSessionStorage = .keychain
    @Published var connectionState: RemoteConnectionState = .stopped
    @Published var onlineMacs: Set<String> = []
    private var realtime: RemoteRealtime?
    private let updates = RemoteEventWork()
    private var dirtyDevices: Set<String> = []
    private var dirtyCommands: Set<String> = []
    private var needsFullSync = false
    private var active = false
    private var lifecycle = UUID()
    private let phoneID = UUID().uuidString.lowercased()
    #if targetEnvironment(simulator)
    var previewFiles: [String: RemoteFile] = [:]
    #endif
    func restoreConnection() async {
        guard !signedIn else { return }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") { loadPreview(); return }
        #endif
        do {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mobile-setup.json")
            if let setup = try RemoteSetup.consume(file) {
                url = setup.url; key = setup.key; email = setup.email; password = setup.password
            }
            if !url.isEmpty && !key.isEmpty { await connect() }
        } catch { status = error.localizedDescription }
    }
    func connect() async {
        guard !connecting, !signedIn else { return }
        connecting = true
        defer { connecting = false }
        do {
            let client = try RemoteAPI(url: url, key: key)
            if !password.isEmpty { try await client.signIn(email: email, password: password) }
            password = ""
            _ = try await client.owner()
            let receipt = try receiptStorage.read("pending-command").map { try JSONDecoder().decode(RemoteCommand.self, from: $0) }
            api = client; signedIn = true
            UserDefaults.standard.set(url, forKey: "supabaseURL"); UserDefaults.standard.set(key, forKey: "supabaseKey")
            unresolved = receipt
            startConnection()
        } catch { password = ""; status = error.localizedDescription }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { startConnection() }
        else {
            lifecycle = UUID(); realtime?.stop(); updates.cancel()
            dirtyDevices = []; dirtyCommands = []; onlineMacs = []
        }
    }
    func startConnection() {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") { return }
        #endif
        guard signedIn, active, let api else { return }
        if realtime == nil {
            let channel = RemoteRealtime(role: "phone", device: phoneID,
                credentials: { try await api.realtimeCredentials() }, ready: { [weak self] in
                    try await api.checkRealtimeSchema()
                    try await self?.synchronize()
                })
            realtime = channel
            channel.onState = { [weak self] value in
                guard let self else { return }
                connectionState = value
                if value == .connecting { lifecycle = UUID(); updates.cancel(); dirtyDevices = []; dirtyCommands = []; needsFullSync = false }
                if value == .connected { status = ""; requestUpdates() }
            }
            channel.onError = { [weak self] error in self?.status = error.localizedDescription }
            channel.onPresence = { [weak self] value in self?.onlineMacs = value.macs }
            channel.onChange = { [weak self] event in
                guard let self, active else { return }
                if event.entity == "device" { dirtyDevices.insert(event.device) }
                else if let id = event.command, UUID(uuidString: id) != nil { dirtyCommands.insert(id) }
                requestUpdates()
            }
        }
        realtime?.start()
    }
    private func synchronize() async throws {
        guard active, let api else { throw CancellationError() }
        let ticket = lifecycle
        let fetched = try await api.devices().filter { $0.snapshot.version == 1 }
        var updated: [RemoteCommand] = []
        for device in fetched { updated += try await api.commands(device: device.id) }
        // An uncertain command may be older than the bounded recent-command list.
        if let unresolved, !updated.contains(where: { $0.id == unresolved.id }), let found = try await api.command(id: unresolved.id) {
            updated.append(found)
        }
        try Task.checkCancellation()
        guard active, ticket == lifecycle, signedIn, self.api === api else { throw CancellationError() }
        for value in fetched {
            if let previous = devices.first(where: { $0.id == value.id }),
               (previous.revision ?? 0) > (value.revision ?? 0) { continue }
            if let index = devices.firstIndex(where: { $0.id == value.id }) { devices[index] = value }
            else { devices.append(value) }
        }
        devices.removeAll { value in !fetched.contains { $0.id == value.id } }
        commands = updated
        try resolveDelivery()
    }
    private func requestUpdates() {
        guard active, connectionState == .connected,
              needsFullSync || !dirtyDevices.isEmpty || !dirtyCommands.isEmpty else { return }
        updates.enqueue(delay: .milliseconds(40), operation: { [weak self] in
            try await self?.applyChanges()
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    private func applyChanges() async throws {
        guard active, let api else { throw CancellationError() }
        let ticket = lifecycle
        if needsFullSync { needsFullSync = false; try await synchronize() }
        let deviceIDs = dirtyDevices; dirtyDevices = []
        let commandIDs = dirtyCommands; dirtyCommands = []
        for id in deviceIDs {
            let previous = devices.first { $0.id == id }
            let delta = try await api.changes(device: id, since: previous?.revision ?? -1)
            try Task.checkCancellation()
            guard active, ticket == lifecycle, self.api === api else { throw CancellationError() }
            if let delta {
                let current = devices.first { $0.id == id }
                let value = delta.applying(to: current)
                if let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = value }
                else { devices.append(value) }
            } else { devices.removeAll { $0.id == id }; commands.removeAll { $0.device == id } }
        }
        for id in commandIDs {
            let value = try await api.command(id: id)
            try Task.checkCancellation()
            guard active, ticket == lifecycle, self.api === api else { throw CancellationError() }
            if let value {
                if let index = commands.firstIndex(where: { $0.id == id }) { commands[index] = value }
                else { commands.insert(value, at: 0) }
            } else { commands.removeAll { $0.id == id } }
        }
        try resolveDelivery()
        commands = Array(commands.prefix(600))
    }
    private func resolveDelivery() throws {
        if let unresolved, commands.contains(where: { $0.id == unresolved.id }) {
            try clearReceipt()
        }
    }
    private func clearReceipt() throws {
        try receiptStorage.write(nil, "pending-command"); unresolved = nil; unsentBody = nil; undelivered = false
    }
    /// Looks the unresolved command up by ID. No send is in flight, so absence means the queue never stored it.
    func checkDelivery() async {
        guard let api, let pending = unresolved, !sending else { return }
        sending = true; defer { sending = false }
        do {
            if let found = try await api.command(id: pending.id) {
                if !commands.contains(where: { $0.id == found.id }) { commands.insert(found, at: 0) }
                try resolveDelivery()
            } else { undelivered = true }
            status = ""
        } catch { status = error.localizedDescription }
    }
    /// Sends the same command again. Its ID is the primary key, so the Mac can never receive it twice.
    var canResend: Bool { undelivered && unsentBody != nil && unsentBody?.id == unresolved?.id }
    func resendUndelivered() async {
        guard let api, canResend, let command = unsentBody, !sending else { return }
        sending = true; defer { sending = false }
        do { try await submit(command, using: api) } catch { status = error.localizedDescription }
    }
    func discardUndelivered() {
        guard undelivered, !sending else { return }
        do { try clearReceipt(); status = "" } catch { status = error.localizedDescription }
    }
    func refresh() async {
        guard active else { return }
        startConnection()
        needsFullSync = true; requestUpdates()
    }
    func send(device: RemoteDevice, chat: RemoteChat, kind: String, text: String = "", approval: String? = nil, photos: [RemotePhoto] = []) async -> Bool {
        guard let api, !sending, unresolved == nil else { return false }
        sending = true; defer { sending = false }
        do {
            let command = RemoteCommand(owner: try await api.owner(), device: device.id, project: chat.project, chat: chat.id, kind: kind, text: text, approval: approval, turn: chat.turn, photos: photos)
            try command.validate()
            if !photos.isEmpty {
                guard chat.supportsPhotos == true else { throw RemoteFailure.photoSetup }
                try await api.checkPhotoSchema()
            }
            try await submit(command, using: api)
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func createChat(device: RemoteDevice, project: RemoteProject, text: String, options: RemoteChatOptions? = nil) async -> RemoteCommand? {
        guard let api, !sending, unresolved == nil, project.canCreateChat == true else { return nil }
        sending = true; defer { sending = false }
        do {
            if options != nil { try await api.checkSettingsSchema() }
            let command = RemoteCommand.newChat(owner: try await api.owner(), device: device.id, project: project.id, text: text, options: options)
            try command.validate()
            try await submit(command, using: api)
            return command
        } catch { status = error.localizedDescription; return nil }
    }
    func configureChat(device: RemoteDevice, chat: RemoteChat, options: RemoteChatOptions, expected: RemoteChatSettings) async -> RemoteCommand? {
        guard let api, !sending, unresolved == nil, expected.canEdit else { return nil }
        sending = true; defer { sending = false }
        do {
            try await api.checkSettingsSchema()
            let command = RemoteCommand.configure(owner: try await api.owner(), device: device.id, project: chat.project, chat: chat.id, options: options, expected: expected)
            try command.validate()
            try await submit(command, using: api)
            return command
        } catch { status = error.localizedDescription; return nil }
    }
    func pendingSettings(device: String, chat: String) -> Bool {
        commands.contains { $0.device == device && $0.chat == chat && $0.kind == "configure" && ["pending", "claimed", "uncertain"].contains($0.status) }
    }
    private func submit(_ command: RemoteCommand, using api: RemoteAPI) async throws {
        // Save the stable ID before networking. Never resubmit after a transport failure.
        var receipt = command; receipt.photos = nil
        try receiptStorage.write(JSONEncoder().encode(receipt), "pending-command")
        unresolved = command; unsentBody = command; undelivered = false
        do { try await api.submit(command) }
        catch let failure as RemoteNotStored {
            // The server proved it stored nothing, so the receipt must not block later sends.
            try clearReceipt(); throw failure.cause
        }
        try clearReceipt()
        if !commands.contains(where: { $0.id == receipt.id }) { commands.insert(receipt, at: 0) }
        status = ""
        if self.api === api, active { dirtyCommands.insert(command.id); requestUpdates() }
    }
    /// File reads are idempotent and never reach an agent, so they skip the delivery receipt;
    /// after a failure the user may simply ask again (a new command).
    func requestFile(device: RemoteDevice, chat: RemoteChat, path: String) async throws -> String {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") {
            var done = RemoteCommand.file(owner: device.owner, device: device.id, project: chat.project, chat: chat.id, path: path)
            try done.validate()
            done.status = "submitted"; commands.insert(done, at: 0)
            previewFiles[done.id] = Self.previewFile(path)
            return done.id
        }
        #endif
        guard let api else { throw RemoteFailure.signedOut }
        let command = RemoteCommand.file(owner: try await api.owner(), device: device.id, project: chat.project, chat: chat.id, path: path)
        try command.validate()
        try await api.submit(command)
        if !commands.contains(where: { $0.id == command.id }) { commands.insert(command, at: 0) }
        if self.api === api, active { dirtyCommands.insert(command.id); requestUpdates() }
        return command.id
    }
    func takeFile(_ command: String) async throws -> RemoteFile? {
        #if targetEnvironment(simulator)
        if let file = previewFiles[command] { return file }
        #endif
        guard let api else { throw RemoteFailure.signedOut }
        return try await api.takeFile(command: command)
    }
    func approvalCommand(device: String, chat: String, approval: String) -> RemoteCommand? {
        commands.first { $0.device == device && $0.chat == chat && $0.approval.flatMap(UUID.init(uuidString:)) == UUID(uuidString: approval) }
    }
    func signOut() async {
        lifecycle = UUID(); realtime?.stop(); realtime = nil; updates.cancel()
        dirtyDevices = []; dirtyCommands = []; onlineMacs = []
        do { try await api?.signOut(); api = nil; signedIn = false; devices = []; commands = []; drafts = [:]; photoDrafts = [:] }
        catch { status = error.localizedDescription }
    }
}

@main struct ContextMobileApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MobileRoot(model: model)
                .environment(\.locale, Locale(identifier: L10n.language.rawValue))
                .task { model.setActive(phase == .active); await model.restoreConnection() }
                .onChange(of: phase) { _, value in
                    if value == .active { model.setActive(true) } else if value == .background { model.setActive(false) }
                }
        }
    }
}
struct MobileRoot: View {
    @ObservedObject var model: MobileModel
    @State private var search = ""
    @State private var settings = false
    @State private var creatingChat = false
    @State private var destination: MobileChatDestination?
    var body: some View {
        NavigationStack {
            Group {
                if model.signedIn {
                    List {
                        ForEach(model.devices) { device in
                            if device.snapshot.projects.isEmpty {
                                Section { } header: { ConnectionStatus(model: model, device: device, compact: true) }
                            }
                            ForEach(device.snapshot.projects) { project in
                                MobileProjectSection(project: project, deviceID: device.id,
                                    chats: device.snapshot.chats.filter { $0.project == project.id }, search: search,
                                    connection: project.id == device.snapshot.projects.first?.id ? ConnectionStatus(model: model, device: device, compact: true) : nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $search, prompt: L10n.text("Найти чат", "Find a chat"))
                    .refreshable { await model.refresh() }
                    .overlay {
                        if model.devices.isEmpty {
                            ContentUnavailableView(L10n.text("Подключи Mac", "Connect your Mac"), systemImage: "desktopcomputer",
                                description: Text(L10n.text("В настройках Switchboard на Mac выбери проекты и включи мобильный доступ.", "Select projects and enable mobile access in Switchboard settings on your Mac.")))
                        } else if !search.isEmpty && !model.devices.contains(where: { $0.snapshot.chats.contains(where: { $0.title.localizedCaseInsensitiveContains(search) }) }) {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                } else {
                    Form {
                        Section {
                            Label(L10n.text("Твои проекты всегда рядом", "Your projects, wherever you are"), systemImage: "macbook.and.iphone")
                                .font(.title3.weight(.semibold)).padding(.vertical, 12)
                            Text(L10n.text("Подключись к той же учётной записи, что и Switchboard на Mac.", "Connect with the same account as Switchboard on your Mac."))
                                .foregroundStyle(.secondary)
                        }
                        Section(L10n.text("Подключение", "Connection")) {
                            TextField("Supabase URL", text: $model.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(L10n.text("Публичный ключ", "Public key"), text: $model.key).textInputAutocapitalization(.never)
                            TextField(L10n.text("Почта", "Email"), text: $model.email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(L10n.text("Пароль", "Password"), text: $model.password)
                            Button { Task { await model.connect() } } label: {
                                HStack { Text(L10n.text("Подключиться", "Connect")); Spacer(); if model.connecting { ProgressView() } }
                            }.disabled(model.connecting || model.url.isEmpty || model.key.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle(model.signedIn ? L10n.text("Чаты", "Chats") : "Switchboard")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.signedIn {
                        Button { creatingChat = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel(L10n.text("Новый чат", "New chat")).accessibilityIdentifier("new-chat")
                            .disabled(model.devices.allSatisfy { $0.snapshot.projects.isEmpty })
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L10n.text("Настройки", "Settings"))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MobileNotice(model: model) }
            .sheet(isPresented: $settings) { MobileSettings(model: model) }
            .sheet(isPresented: $creatingChat) {
                MobileNewChatView(model: model) { command in
                    creatingChat = false
                    destination = MobileChatDestination(device: command.device, chat: command.chat)
                }
            }
            .navigationDestination(item: $destination) { target in
                MobileChatView(model: model, deviceID: target.device, chatID: target.chat)
            }
            .navigationDestination(for: MobileChatDestination.self) { target in
                MobileChatView(model: model, deviceID: target.device, chatID: target.chat)
            }
            #if targetEnvironment(simulator)
            .navigationDestination(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("-preview-chat") && model.signedIn)) {
                if let device = model.devices.first, let chat = device.snapshot.chats.first {
                    MobileChatView(model: model, deviceID: device.id, chatID: chat.id)
                }
            }
            #endif
        }
    }
}

struct MobileChatDestination: Hashable { let device: String; let chat: String }

/// Disclosure only changes presentation. The shared snapshot and live updates stay intact.
struct MobileProjectSection: View {
    let project: RemoteProject
    let deviceID: String
    let chats: [RemoteChat]
    let search: String
    /// The Mac's connection line, shown above the first project of that Mac.
    var connection: ConnectionStatus?
    @State private var visibleCount = 5
    private let pageSize = 5

    var body: some View {
        let matches = search.isEmpty ? chats : chats.filter { $0.title.localizedCaseInsensitiveContains(search) }
        let limit = search.isEmpty ? visibleCount : matches.count
        let remaining = max(0, matches.count - limit)
        let hiddenApprovals = matches.dropFirst(limit).filter { !$0.approvals.isEmpty }.count
        if !matches.isEmpty || search.isEmpty {
            Section {
                ForEach(matches.prefix(limit)) { chat in
                    NavigationLink(value: MobileChatDestination(device: deviceID, chat: chat.id)) {
                        ChatRow(chat: chat).equatable()
                    }.accessibilityIdentifier("chat-row-" + chat.id)
                }
                if matches.isEmpty { Text(L10n.text("Пока нет чатов", "No chats yet")).foregroundStyle(.secondary) }
                if remaining > 0 {
                    Button {
                        visibleCount += pageSize
                    } label: {
                        HStack {
                            Label(L10n.text("Показать ещё", "Show more"), systemImage: "chevron.down")
                            Spacer()
                            Text(L10n.text("Осталось: \(remaining)", "Remaining: \(remaining)"))
                                .foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("more-chats-" + project.id)
                }
                if search.isEmpty && visibleCount > pageSize && chats.count > pageSize {
                    Button {
                        visibleCount = pageSize
                    } label: {
                        Label(L10n.text("Свернуть", "Show fewer"), systemImage: "chevron.up")
                    }.accessibilityIdentifier("fewer-chats-" + project.id)
                }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    if let connection { connection.textCase(nil) }
                    HStack {
                        Text(project.name)
                        Spacer()
                        Text(matches.count.formatted())
                    }
                }
            } footer: {
                if hiddenApprovals > 0 {
                    Label(L10n.text("Скрытые чаты ждут ответа: \(hiddenApprovals)", "Hidden chats needing your attention: \(hiddenApprovals)"),
                          systemImage: "hand.raised")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("hidden-approvals-" + project.id)
                }
            }
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
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Проект", "Project")) {
                    Picker(L10n.text("Проект", "Project"), selection: $selection) {
                        ForEach(choices, id: \.id) { choice in
                            Text(choice.project.name + " · " + choice.device.name).tag(choice.id)
                        }
                    }.accessibilityIdentifier("new-chat-project")
                    Text(L10n.text("Чат создаётся на Mac. Модель определяет агента — Codex или Claude. Выбранные модель и доступ сохраняются для этого чата.", "The chat is created on your Mac. The model determines the agent: Codex or Claude. Your model and access choices are saved for this chat."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let choice = choices.first(where: { $0.id == selection }), let settings = choice.project.settings {
                    MobileOptionsSection(options: $options, models: choice.project.newChatModels ?? choice.project.models ?? [], projectAccess: settings.projectAccess)
                        .disabled(model.sending || !settings.canEdit)
                }
                Section(L10n.text("Первое сообщение", "First message")) {
                    TextField(L10n.text("Что нужно сделать?", "What would you like to do?"), text: $message, axis: .vertical)
                        .lineLimit(4...10).accessibilityIdentifier("new-chat-message")
                }
                if let choice = choices.first(where: { $0.id == selection }) {
                    if choice.project.canCreateChat != true {
                        Text(L10n.text("Обнови и открой Switchboard на Mac, подключи Codex или Claude и включи мобильный доступ.", "Update and open Switchboard on your Mac, connect Codex or Claude and enable mobile access."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            if let command = await model.createChat(device: choice.device, project: choice.project, text: message,
                                options: choice.project.settings == nil ? nil : options) { created(command) }
                        }
                    } label: {
                        HStack { Text(L10n.text("Создать и отправить", "Create and send")); Spacer(); if model.sending { ProgressView() } }
                    }.accessibilityIdentifier("create-chat")
                        .disabled(choice.project.canCreateChat != true || (choice.project.settings != nil && (choice.project.settings?.canEdit != true || options.model.isEmpty)) || model.sending || model.unresolved != nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                MobileNotice(model: model)
            }
            .navigationTitle(L10n.text("Новый чат", "New chat")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Отмена", "Cancel")) { dismiss() }.disabled(model.sending) } }
            .interactiveDismissDisabled(model.sending)
            .onAppear { if selection.isEmpty { selection = choices.first(where: { $0.project.canCreateChat == true })?.id ?? choices.first?.id ?? "" } }
            .onChange(of: selection) { _, _ in options = choices.first(where: { $0.id == selection })?.project.settings?.options ?? RemoteChatOptions(model: "") }
        }
    }
}

struct ChatRow: View, Equatable {
    let title: String
    let preview: String?
    let running: Bool
    let activity: String?
    let needsApproval: Bool
    let readOnly: Bool
    init(chat: RemoteChat) {
        title = chat.title; preview = chat.messages.last.map { MarkdownInline.plain($0.text) }
        running = chat.running; activity = chat.activity
        needsApproval = !chat.approvals.isEmpty; readOnly = chat.readOnly == true
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                Text(preview ?? L10n.text("Пока нет сообщений", "No messages yet"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if needsApproval {
                    Label(L10n.text("Нужен ответ", "Needs your attention"), systemImage: "hand.raised.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                } else if running {
                    Text(activity ?? L10n.text("Работает", "Working"))
                        .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
                }
                if readOnly {
                    Label(L10n.text("Только чтение", "Read-only"), systemImage: "lock")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).accessibilityIdentifier("read-only-badge")
                }
            }
            Spacer(minLength: 0)
            // One quiet status mark: orange when an answer is needed, a spinner while working.
            if needsApproval {
                Circle().fill(Color.orange).frame(width: 9, height: 9).padding(.top, 6).accessibilityHidden(true)
            } else if running {
                ProgressView().controlSize(.small).padding(.top, 2).accessibilityHidden(true)
            }
        }.padding(.vertical, 4)
    }
}

struct MobileOptionsSection: View {
    @Binding var options: RemoteChatOptions
    let models: [RemoteModelOption]
    let projectAccess: RemoteAccessMode
    var body: some View {
        Section(L10n.text("Настройки чата", "Chat settings")) {
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
    var body: some View {
        NavigationStack {
            Form {
                if let device = model.devices.first(where: { $0.id == deviceID }),
                   let chat = device.snapshot.chats.first(where: { $0.id == chatID }) {
                    MobileOptionsSection(options: $options, models: device.snapshot.projects.first(where: { $0.id == chat.project })?.models ?? [],
                                         projectAccess: expected.projectAccess)
                        .disabled(model.sending || receiptID != nil || chat.settings?.canEdit != true)
                    Text(L10n.text("Применяется со следующего сообщения. Настройки проекта не меняются.", "Applies from the next message. Project settings stay unchanged."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if chat.settings?.canEdit != true {
                        Text(L10n.text("Дождись окончания работы и ответь на ожидающие запросы, чтобы изменить настройки.", "Wait for the chat to finish and answer pending requests before changing settings."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { receiptID = await model.configureChat(device: device, chat: chat, options: options, expected: expected)?.id }
                    } label: {
                        HStack { Text(L10n.text("Сохранить", "Save")); Spacer(); if model.sending { ProgressView() } }
                    }.accessibilityIdentifier("save-chat-settings")
                        .disabled(options == expected.options || options.model.isEmpty || model.sending || model.unresolved != nil || receiptID != nil || chat.settings?.canEdit != true || model.pendingSettings(device: deviceID, chat: chatID))
                    if let receiptID, let receipt = model.commands.first(where: { $0.id == receiptID }) {
                        Text(settingsStatus(receipt.status, applied: chat.settings?.options == options))
                            .font(.footnote).accessibilityIdentifier("chat-settings-status")
                    }
                }
                MobileNotice(model: model)
            }
            .navigationTitle(L10n.text("Настройки чата", "Chat settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Готово", "Done")) { dismiss() }.disabled(model.sending) } }
            .interactiveDismissDisabled(model.sending)
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

struct ConnectionStatus: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    var compact = false
    var body: some View {
        let server = model.connectionState == .connected
        let host = server && model.onlineMacs.contains(device.id.lowercased())
        HStack(spacing: 10) {
            Circle().fill(host ? Color.green : .orange).frame(width: 7, height: 7)
            Text(server ? (host ? L10n.text("Mac на связи", "Mac connected") : L10n.text("Mac недоступен", "Mac unavailable")) : model.connectionState.text)
                .font(compact ? .footnote : .subheadline).foregroundStyle(compact ? .secondary : .primary)
            Spacer()
            if let date = ISO8601DateFormatter().date(from: device.seen) {
                Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Последнее обновление данных", "Last data update"))
            }
        }.accessibilityElement(children: .combine)
    }
}

struct MobileNotice: View {
    @ObservedObject var model: MobileModel
    var body: some View {
        if !model.status.isEmpty || model.unresolved != nil || (model.signedIn && model.connectionState != .connected) {
            VStack(alignment: .leading, spacing: 6) {
                if !model.status.isEmpty { Label(model.status, systemImage: "exclamationmark.circle") }
                else if model.connectionState != .connected { Label(model.connectionState.text, systemImage: "network") }
                if model.unresolved != nil {
                    if model.undelivered {
                        Text(L10n.text("Команды нет в облаке: Mac её не получит.", "The command is not in the cloud: the Mac will not receive it."))
                        HStack {
                            if model.canResend {
                                Button(L10n.text("Отправить снова", "Send again")) { Task { await model.resendUndelivered() } }
                            }
                            Button(L10n.text("Сбросить", "Discard"), role: .destructive) { model.discardUndelivered() }
                        }.buttonStyle(.bordered).disabled(model.sending)
                    } else {
                        Text(L10n.text("Доставка не подтверждена. Проверь историю на Mac перед новой отправкой.", "Delivery is unconfirmed. Check the history on your Mac before sending again."))
                        Button(L10n.text("Проверить доставку", "Check delivery")) { Task { await model.checkDelivery() } }
                            .buttonStyle(.bordered).disabled(model.sending)
                    }
                }
            }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.regularMaterial)
        }
    }
}

struct MobileSettings: View {
    @ObservedObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Уведомления", "Notifications")) {
                    Label(L10n.text("Push пока не подключены", "Push notifications are not connected"), systemImage: "bell.badge")
                    Text(L10n.text("Для уведомлений на заблокированном iPhone нужна подпись Apple Developer Program. Текущая бесплатная установка её не поддерживает.", "Notifications on a locked iPhone require Apple Developer Program signing. The current free installation does not support it."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("Язык", "Language")) {
                    Picker("Язык / Language", selection: Binding(get: { L10n.language.rawValue }, set: { UserDefaults.standard.set($0, forKey: AppLanguage.preferenceKey) })) {
                        Text("Русский").tag("ru"); Text("English").tag("en")
                    }
                    Text(L10n.text("Применится после перезапуска приложения.", "Applies after restarting the app.")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("История", "History")) {
                    Text(L10n.text("Здесь — последние 20 сообщений недавних чатов. Длинные сообщения сокращены до 2000 символов. Полная история остаётся на Mac. Файл проекта из ответа открывается нажатием на его путь.", "The latest 20 messages in recent chats are shown here. Long messages are limited to 2,000 characters. Full history stays on your Mac. Tap a project file path in an answer to open the file."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.signedIn {
                    Section {
                        Button(L10n.text("Выйти из аккаунта", "Sign out"), role: .destructive) { Task { await model.signOut(); dismiss() } }
                    }
                }
            }.navigationTitle(L10n.text("Настройки", "Settings")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Готово", "Done")) { dismiss() } } }
        }
    }
}

struct MobileChatView: View {
    @ObservedObject var model: MobileModel
    let deviceID: String
    let chatID: String
    @FocusState private var writing: Bool
    @State private var following = true
    @State private var atBottom = true
    @State private var jumpRequest = 0
    @State private var approvalJump = 0
    @State private var showingChatSettings = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var photoError: String?
    @State private var openedFile: OpenedFile?
    private var draftKey: String { deviceID + ":" + chatID }
    private var photos: [RemotePhoto] { model.photoDrafts[draftKey] ?? [] }
    private var canSend: Bool { !loadingPhotos && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty) }
    @StateObject private var scrollController = TranscriptScrollController()
    private var draft: Binding<String> {
        Binding(get: { model.drafts[deviceID + ":" + chatID] ?? "" }, set: { model.drafts[deviceID + ":" + chatID] = $0 })
    }
    var body: some View {
        if let device = model.devices.first(where: { $0.id == deviceID }), let chat = device.snapshot.chats.first(where: { $0.id == chatID }) {
            let project = device.snapshot.projects.first { $0.id == chat.project }
            let lastCommand = model.commands.first { $0.chat == chatID && $0.device == deviceID && $0.kind != "file" }
            VStack(spacing: 0) {
                if !(model.connectionState == .connected && model.onlineMacs.contains(device.id.lowercased())) {
                    ConnectionStatus(model: model, device: device).padding(.horizontal).padding(.vertical, 9).background(.bar)
                }
                if !chat.approvals.isEmpty {
                    Button { writing = false; approvalJump += 1 } label: {
                        Label(L10n.text("Ожидают подтверждения: \(chat.approvals.count)", "Awaiting approval: \(chat.approvals.count)"), systemImage: "hand.raised.fill")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.foregroundStyle(.orange).background(Color.orange.opacity(0.08)).accessibilityIdentifier("show-approvals")
                }
                GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(L10n.text("Последние сообщения · полная история на Mac", "Recent messages · full history on Mac"))
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 8)
                            let lastUser = chat.messages.last { $0.role == "user" }?.id
                            ForEach(chat.messages) { message in
                                MessageBubble(message: message, openFile: project?.canReadFiles == true ? { openedFile = OpenedFile(path: $0) } : nil)
                                    .environment(\.quoteSelection, QuoteSelectionAction { selection in
                                        draft.wrappedValue = QuoteSelectionAction.appending(selection, to: draft.wrappedValue)
                                        writing = true
                                    })
                                if message.id == lastUser, let status = sendStatus(lastCommand, chat: chat) {
                                    Text(status).font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -14)
                                        .accessibilityIdentifier("send-status")
                                }
                            }
                            if lastUser == nil, let status = sendStatus(lastCommand, chat: chat) {
                                Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                                    .accessibilityIdentifier("send-status")
                            }
                            if chat.running {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    HStack(spacing: 10) {
                                        ProgressView().controlSize(.small)
                                        Text(chat.activity ?? L10n.text("Агент работает…", "Agent is working…"))
                                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                        if let elapsed = chat.elapsed(now: context.date) {
                                            Text(elapsed).monospacedDigit().foregroundStyle(.tertiary).layoutPriority(1)
                                        }
                                    }.font(.subheadline)
                                }.accessibilityElement(children: .combine).accessibilityIdentifier("running-activity")
                            }
                            Color.clear.frame(height: 1).id("approvals")
                            ForEach(chat.approvals) { approval in
                                let response = model.approvalCommand(device: deviceID, chat: chatID, approval: approval.id)
                                VStack(alignment: .leading, spacing: 12) {
                                    Label(L10n.text("Требуется подтверждение", "Approval required"), systemImage: "hand.raised.fill")
                                        .font(.headline).foregroundStyle(.orange)
                                    SelectableText(text: MarkdownInline.uiKit(plain: approval.details, style: .footnote, monospaced: true))
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                                    HStack(spacing: 10) {
                                        Button(role: .destructive) {
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            Task { _ = await model.send(device: device, chat: chat, kind: "deny", approval: approval.id) }
                                        } label: { Text(L10n.text("Отклонить", "Decline")).frame(maxWidth: .infinity) }
                                            .buttonStyle(.bordered).accessibilityIdentifier("deny-approval")
                                        if approval.canAllow {
                                            Button {
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                Task { _ = await model.send(device: device, chat: chat, kind: "allow", approval: approval.id) }
                                            } label: { Text(L10n.text("Разрешить один раз", "Allow once")).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
                                                .buttonStyle(.borderedProminent).tint(.orange).accessibilityIdentifier("allow-approval")
                                        }
                                    }.controlSize(.large).disabled(model.sending || model.unresolved != nil || response.map { $0.status != "rejected" } == true)
                                    if let response { Text(commandLabel(response.status)).font(.caption).foregroundStyle(.secondary) }
                                    if !approval.canAllow {
                                        Text(L10n.text("Подтвердить этот запрос с телефона нельзя. Проверь полные детали на Mac или отклони запрос.", "This request cannot be approved on your phone. Review the full details on your Mac or decline it."))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding().background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                            }
                            if let command = lastCommand, !["send", "create"].contains(command.kind), command.approval == nil {
                                Text(command.kind == "configure" && command.status == "submitted" ? L10n.text("Настройки сохранены", "Settings saved") : commandLabel(command.status))
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            Color.clear.frame(height: 1).id("tail")
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: TranscriptBottomKey.self, value: geometry.frame(in: .named("transcript")).maxY)
                                })
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                            .frame(width: viewport.size.width)
                            .background(TranscriptScrollProbe(controller: scrollController))
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                            })
                    }
                    .coordinateSpace(name: "transcript")
                    .accessibilityIdentifier("conversation-scroll")
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(DragGesture().onChanged { _ in following = false })
                    .onPreferenceChange(TranscriptBottomKey.self) { bottom in
                        atBottom = bottom <= viewport.size.height + 24 && bottom >= 0
                        if atBottom { following = true }
                    }
                    .onPreferenceChange(TranscriptHeightKey.self) { _ in
                        if following { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    .onChange(of: viewport.size.height) { _, _ in
                        if following { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    .onChange(of: jumpRequest) { _, _ in
                        following = true
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                    .onChange(of: approvalJump) { _, _ in
                        following = false
                        proxy.scrollTo("approvals", anchor: .top)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom {
                            Button {
                                following = true
                                if !scrollController.jumpToBottom() { proxy.scrollTo("tail", anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down").font(.headline).padding(13).background(.regularMaterial, in: Circle())
                            }.padding().accessibilityLabel(L10n.text("К последнему сообщению", "Jump to latest message"))
                                .accessibilityIdentifier("jump-to-latest")
                        }
                    }
                }
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    MobileNotice(model: model)
                    if !photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(photos) { photo in
                                    if let image = UIImage(data: photo.data) {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(alignment: .topTrailing) {
                                                Button { model.photoDrafts[draftKey]?.removeAll { $0.id == photo.id } } label: {
                                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black)
                                                }.accessibilityLabel(L10n.text("Удалить фото", "Remove photo"))
                                            }
                                    }
                                }
                            }.padding(.top, 4)
                        }.frame(height: 72).disabled(model.sending || model.unresolved != nil || loadingPhotos)
                    }
                    if loadingPhotos { ProgressView(L10n.text("Подготовка фото…", "Preparing photos…")).font(.caption) }
                    if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
                    if chat.readOnly == true {
                        Label(RemoteChat.readOnlyNotice, systemImage: "clock.arrow.circlepath")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).accessibilityIdentifier("read-only-notice")
                    } else {
                    if let settings = chat.settings {
                        let access = settings.options.access ?? settings.projectAccess
                        let modelName = project?.models?.first { $0.id == settings.options.model }?.name ?? settings.options.model
                        HStack(spacing: 8) {
                            Button { showingChatSettings = true } label: {
                                ComposerChip(icon: access == .fullAccess ? "lock.open" : "lock", text: access.title)
                            }.accessibilityLabel(L10n.text("Доступ: ", "Access: ") + access.title).accessibilityIdentifier("chat-access-chip")
                            Button { showingChatSettings = true } label: {
                                ComposerChip(icon: "cpu", text: modelName.isEmpty ? L10n.text("Модель", "Model") : modelName)
                            }.accessibilityLabel(L10n.text("Настройки чата", "Chat settings") + ": " + modelName).accessibilityIdentifier("chat-settings")
                            if model.pendingSettings(device: deviceID, chat: chatID) {
                                ProgressView().controlSize(.mini)
                            }
                            Spacer()
                        }.buttonStyle(.plain)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, RemotePhoto.maximumCount - photos.count), matching: .images) {
                            Image(systemName: "photo.badge.plus").font(.title3).frame(width: 44, height: 44)
                        }.accessibilityLabel(L10n.text("Добавить фото", "Add photos")).accessibilityIdentifier("add-photos")
                            .disabled(loadingPhotos || photos.count >= RemotePhoto.maximumCount || chat.supportsPhotos != true)
                        TextField(L10n.text("Сообщение…", "Message…"), text: draft, axis: .vertical)
                            .lineLimit(1...6).focused($writing).padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityIdentifier("message-input")
                        if chat.running {
                            Button { Task { _ = await model.send(device: device, chat: chat, kind: "stop") } } label: {
                                Image(systemName: "stop.fill").frame(width: 44, height: 44).background(Color.red.opacity(0.12), in: Circle()).foregroundStyle(.red)
                            }.accessibilityLabel(L10n.text("Остановить", "Stop"))
                        } else {
                            Button {
                                let text = draft.wrappedValue
                                let submittedPhotos = photos
                                Task {
                                    if await model.send(device: device, chat: chat, kind: "send", text: text, photos: submittedPhotos) {
                                        if draft.wrappedValue == text { draft.wrappedValue = ""; writing = false }
                                        model.photoDrafts[draftKey]?.removeAll { photo in submittedPhotos.contains { $0.id == photo.id } }
                                        jumpRequest += 1
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                                    .foregroundStyle(.white).background(Color.accentColor, in: Circle())
                            }.disabled(!canSend || model.pendingSettings(device: deviceID, chat: chatID))
                                .opacity(canSend ? 1 : 0.4)
                                .accessibilityLabel(L10n.text("Отправить", "Send")).accessibilityIdentifier("send-message")
                        }
                    }
                    .disabled(model.sending || model.unresolved != nil)
                    }
                    if model.sending { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
            }
            .task(id: photoSelection) {
                guard !photoSelection.isEmpty else { return }
                loadingPhotos = true; photoError = nil
                defer { loadingPhotos = false }
                do {
                    var prepared: [RemotePhoto] = []
                    for item in photoSelection {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw RemoteFailure.invalidPhoto }
                        try Task.checkCancellation()
                        prepared.append(try Self.preparePhoto(data))
                    }
                    try Task.checkCancellation()
                    guard photos.count + prepared.count <= RemotePhoto.maximumCount else { throw RemoteFailure.invalidPhoto }
                    model.photoDrafts[draftKey, default: []].append(contentsOf: prepared)
                    photoSelection = []
                } catch is CancellationError { }
                catch { photoError = error.localizedDescription; photoSelection = [] }
            }
            .navigationTitle(chat.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(chat.title).font(.headline).lineLimit(1)
                        if let project { Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if writing {
                        Button { writing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                            .accessibilityLabel(L10n.text("Скрыть клавиатуру", "Hide keyboard"))
                    }
                }
            }
            .sheet(isPresented: $showingChatSettings) {
                if let settings = chat.settings {
                    MobileChatSettingsView(model: model, deviceID: deviceID, chatID: chatID, expected: settings, options: settings.options)
                }
            }
            .sheet(item: $openedFile) { file in
                MobileFileView(model: model, device: device, chat: chat, path: file.path)
            }
            #if targetEnvironment(simulator)
            .onAppear {
                // Visual checks: `-preview-file docs/plan.md` opens the viewer with synthetic content.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-preview-file"), index + 1 < arguments.count { openedFile = OpenedFile(path: arguments[index + 1]) }
            }
            #endif
        } else if let command = model.commands.first(where: { $0.device == deviceID && $0.chat == chatID && $0.createsChat }) ?? model.unresolved.flatMap({ $0.device == deviceID && $0.chat == chatID && $0.createsChat ? $0 : nil }) {
            VStack(spacing: 16) {
                if ["pending", "claimed", "submitted"].contains(command.status) { ProgressView() }
                Text(L10n.text("Новый чат", "New chat")).font(.title2)
                Text(commandLabel(command.status)).foregroundStyle(.secondary).accessibilityIdentifier("new-chat-status")
                Text(L10n.text("Чат откроется после обновления с Mac. Команда не отправляется повторно.", "The chat opens when your Mac publishes it. The command is not sent again."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                MobileNotice(model: model)
            }.padding()
        } else {
            ContentUnavailableView(L10n.text("Чат недоступен", "Chat unavailable"), systemImage: "bubble.left",
                description: Text(L10n.text("Проверь выбранные проекты на Mac.", "Check the selected projects on your Mac.")))
        }
    }
    private static func preparePhoto(_ data: Data) throws -> RemotePhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw RemoteFailure.invalidPhoto }
        let image = UIImage(cgImage: thumbnail)
        for quality in [0.85, 0.65, 0.45, 0.25] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= RemotePhoto.maximumBytes {
                let photo = RemotePhoto(data: jpeg); try photo.validate(); return photo
            }
        }
        throw RemoteFailure.invalidPhoto
    }
    /// Status of the last message sent from the phone, shown under it until the agent takes over.
    private func sendStatus(_ command: RemoteCommand?, chat: RemoteChat) -> String? {
        guard let command, ["send", "create"].contains(command.kind) else { return nil }
        if command.status == "submitted" && (chat.running || chat.messages.last?.role != "user") { return nil }
        return commandLabel(command.status)
    }
    private func commandLabel(_ status: String) -> String {
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

private struct TranscriptScrollProbe: UIViewRepresentable {
    let controller: TranscriptScrollController
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.controller = controller; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.attach() }
    final class Probe: UIView {
        weak var controller: TranscriptScrollController?
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { controller?.scrollView = scroll; return }
                ancestor = view.superview
            }
        }
    }
}

private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ComposerChip: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct OpenedFile: Identifiable {
    let id = UUID()
    let path: String
}

struct MessageBubble: View {
    let message: RemoteMessage
    /// Set when the Mac can send project files; otherwise path chips copy the path.
    var openFile: ((String) -> Void)?
    @State private var copiedPath = false
    var body: some View {
        if message.role == "user" {
            // The user's words stay literal, like on the Mac.
            HStack(alignment: .top) {
                Spacer(minLength: 56)
                // Long press selects a fragment; the selection menu copies, shares or quotes it.
                SelectableText(text: MarkdownInline.uiKit(plain: message.text), detectsLinks: true, hugsText: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityIdentifier("message-text-" + message.id)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("message-" + message.id)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownMessageView(text: message.text, identifier: "message-text-" + message.id)
                if message.truncated == true {
                    Label(L10n.text("Сокращено · полный текст на Mac", "Shortened · full text on Mac"), systemImage: "scissors")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("message-truncated-" + message.id)
                }
                HStack(spacing: 18) {
                    CopyControl(title: L10n.text("Копировать ответ", "Copy answer"), text: message.text, identifier: "copy-message-" + message.id)
                    ShareLink(item: message.text) { Label(L10n.text("Поделиться", "Share"), systemImage: "square.and.arrow.up").font(.caption.weight(.medium)) }
                    let links = Self.links(in: message.text)
                    if !links.isEmpty {
                        Menu { linkMenu(links) } label: { Label(L10n.text("Ссылки", "Links"), systemImage: "link").font(.caption.weight(.medium)) }
                            .accessibilityIdentifier("message-links-" + message.id)
                    }
                    if copiedPath { Text(L10n.text("Путь скопирован", "Path copied")).font(.caption) }
                }.labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                // The file lives on the Mac: open it through the Mac when it can send files, otherwise copy the path.
                guard let path = MarkdownInline.copiedValue(url) ?? MarkdownInline.filePath(url) else { return .systemAction }
                if let openFile { openFile(path); return .handled }
                UIPasteboard.general.string = path
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                copiedPath = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedPath = false }
                return .handled
            })
            .accessibilityElement(children: .contain).accessibilityIdentifier("message-" + message.id)
        }
    }
    // The answer itself has no long-press menu: long press selects text instead.
    @ViewBuilder private func linkMenu(_ links: [URL]) -> some View {
        Menu {
            ForEach(links, id: \.self) { url in
                Link(destination: url) { Label(MarkdownInline.shortened(url), systemImage: "safari") }
            }
        } label: { Label(L10n.text("Открыть ссылку", "Open link"), systemImage: "safari") }
        Menu {
            ForEach(links, id: \.self) { url in
                Button(MarkdownInline.shortened(url)) { UIPasteboard.general.url = url }
            }
        } label: { Label(L10n.text("Копировать ссылку", "Copy link"), systemImage: "link.badge.plus") }
    }
    static func links(in text: String) -> [URL] {
        guard text.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !result.contains(url) { result.append(url) }
            if result.count == 8 { break }
        }
        return result
    }
}

#if targetEnvironment(simulator)
extension MobileModel {
    func loadPreview() {
        var project = RemoteProject(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Switchboard", canCreateChat: true)
        project.models = [RemoteModelOption(id: "fixture-a", name: "Model A"), RemoteModelOption(id: "fixture-b", name: "Model B")]
        project.newChatModels = [RemoteModelOption(id: "fixture-a", name: "Model A", agent: RemoteModelOption.codexAgent),
                                 RemoteModelOption(id: "fixture-b", name: "Model B", agent: RemoteModelOption.codexAgent),
                                 RemoteModelOption(id: "fixture-claude", name: "Claude Model", agent: RemoteModelOption.claudeAgent)]
        project.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: true)
        project.canReadFiles = true
        var chat = RemoteChat(id: "preview-chat", project: project.id, title: L10n.text("Мобильное приложение", "Mobile app"), running: false,
            messages: [RemoteMessage(id: "m1", role: "user", text: L10n.text("Сделаем удобный интерфейс для iPhone. Поле ввода должно быть всегда под рукой.", "Let's make the iPhone interface comfortable. Keep the message field within reach.")),
                       RemoteMessage(id: "m2", role: "assistant", text: L10n.text("Готово. Теперь переписка занимает весь экран, а поле ввода закреплено внизу.\n\n**Что изменилось**\n• Поиск по чатам\n• Превью последних сообщений\n• Кнопка скрытия клавиатуры\n\nПосле отправки клавиатура закрывается автоматически.", "Done. The conversation now fills the screen, with the composer pinned at the bottom.\n\n**What's new**\n• Chat search\n• Latest message previews\n• A button to hide the keyboard\n\nThe keyboard closes automatically after sending."))], approvals: [])
        if ProcessInfo.processInfo.arguments.contains("-preview-long") {
            chat.messages = (0..<20).map { index in
                RemoteMessage(id: "long-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: "Message \(index)\n" + String(repeating: "Long transcript layout verification. ", count: index.isMultiple(of: 3) ? 70 : 10))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-preview-rich") {
            let answer = L10n.text("## Итог проверки\n\nСборка прошла, осталось **два** шага. Подробности — https://developer.apple.com/documentation/swiftui/grid и в `Sources/ContextCore/MobileRemote.swift`.\n\n- [x] Тесты ядра\n- [ ] Проверка на телефоне\n  - снимок экрана\n\n> [!WARNING]\n> Профиль подписи истекает 12.10.\n\n```swift\nlet limit = 2000 // phone history\nfunc clip(_ text: String) -> String { String(text.prefix(limit)) }\n```\n\n```bash\n$ zsh scripts/build-mobile.sh\nBUILD SUCCEEDED\n```\n\n| Проверка | Время, с |\n|---|---|\n| Ядро | 12 |\n| UI | 184 |",
                                   "## Check summary\n\nThe build passed, **two** steps remain. Details: https://developer.apple.com/documentation/swiftui/grid and `Sources/ContextCore/MobileRemote.swift`.\n\n- [x] Core tests\n- [ ] Phone check\n  - screenshot\n\n> [!WARNING]\n> The signing profile expires on Oct 12.\n\n```swift\nlet limit = 2000 // phone history\nfunc clip(_ text: String) -> String { String(text.prefix(limit)) }\n```\n\n```bash\n$ zsh scripts/build-mobile.sh\nBUILD SUCCEEDED\n```\n\n| Check | Time, s |\n|---|---|\n| Core | 12 |\n| UI | 184 |")
            var long = RemoteMessage(id: "rich-cut", role: "assistant", fullText: String(repeating: L10n.text("Длинный ответ. ", "Long answer. "), count: 160))
            long.text = String(long.text.prefix(120))
            chat.messages = [RemoteMessage(id: "rich-user", role: "user", text: L10n.text("Как прошла проверка?", "How did the check go?")),
                             RemoteMessage(id: "rich", role: "assistant", text: answer), long]
            chat.running = true
            chat.activity = "Bash · zsh scripts/test.sh --changed"
            chat.runningSince = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-75))
        }
        var projects = [project]
        if ProcessInfo.processInfo.arguments.contains("-preview-actions") {
            receiptStorage = RemoteSessionStorage(read: { _ in nil }, write: { _, _ in })
            chat.approvals = [RemoteApproval(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", details: "echo permission-fixture", canAllow: true)]
            var empty = project; empty.id = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"; empty.name = L10n.text("Пустой проект", "Empty project")
            projects.append(empty)
            if ProcessInfo.processInfo.arguments.contains("-preview-settings") { chat.approvals = [] }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MobilePreviewTransport.self]
            api = try? RemoteAPI(url: "https://preview.invalid", key: "sb_publishable_fixture", transport: URLSession(configuration: configuration),
                storage: RemoteSessionStorage(read: { _ in Data(#"{"access_token":"fixture","refresh_token":"fixture","expires_at":4102444800,"user":{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd"}}"#.utf8) }, write: { _, _ in }))
        }
        chat.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: chat.approvals.isEmpty)
        if ProcessInfo.processInfo.arguments.contains("-preview-read-only") { chat.readOnly = true; chat.supportsPhotos = false; chat.settings = nil }
        var chats = [chat]
        if ProcessInfo.processInfo.arguments.contains("-preview-project-list") {
            var second = project; second.id = "second-project"; second.name = "Second project"
            var empty = project; empty.id = "empty-project"; empty.name = "Empty project"
            projects = [project, second, empty]
            chats = [project, second].flatMap { item in
                (1...12).map { index in
                    RemoteChat(id: item.id + "-\(index)", project: item.id, title: "\(item.name) chat \(index)", running: true,
                        messages: [RemoteMessage(id: "list-message", role: "assistant", text: "Live preview \(index)")],
                        approvals: index == 12 ? [RemoteApproval(id: "list-approval", details: "Fixture", canAllow: true)] : [])
                }
            }
        }
        devices = [RemoteDevice(id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", owner: "dddddddd-dddd-dddd-dddd-dddddddddddd", snapshot: RemoteSnapshot(projects: projects, chats: chats))]
        connectionState = ProcessInfo.processInfo.arguments.contains("-preview-offline") ? .offline : .connected
        onlineMacs = Set(devices.map(\.id))
        signedIn = true
    }
}

extension MobileModel {
    /// Synthetic file content: Markdown for `.md`, a rendered page for `.pdf`, text otherwise.
    static func previewFile(_ path: String) -> RemoteFile {
        let name = (path as NSString).lastPathComponent
        switch (path as NSString).pathExtension.lowercased() {
        case "md":
            return RemoteFile(kind: .markdown, path: path, text: L10n.text("# План\n\nФайл с Mac, показан на телефоне.\n\n- Первый шаг\n- Второй шаг", "# Plan\n\nA file from the Mac, shown on the phone.\n\n- First step\n- Second step"), size: 120)
        case "pdf":
            let page = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                (name as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
            }
            return RemoteFile(kind: .pages, path: path, pages: [page, page], pageCount: 5, size: 90_000, truncated: true)
        default:
            return RemoteFile(kind: .text, path: path, text: (1...60).map { "let line\($0) = \($0) // preview" }.joined(separator: "\n"),
                              size: 600_000, truncated: true)
        }
    }
}

/// Simulator-only deterministic acknowledgement. No cloud or agent access in UI fixtures.
final class MobilePreviewTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let schema = request.url?.path == "/rest/v1/rpc/remote_settings_version"
        let code = schema ? 200 : request.httpMethod == "POST" && request.url?.path == "/rest/v1/remote_commands" ? 201 : 400
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if schema { client?.urlProtocol(self, didLoad: Data("1".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
