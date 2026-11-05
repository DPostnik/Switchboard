import SwiftUI
import Foundation

@main struct ContextMobileApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MobileLanguageRoot(model: model)
                .task { model.setActive(phase == .active); await model.restoreConnection() }
                .onChange(of: phase) { _, value in
                    if value == .active { model.setActive(true) } else if value == .background { model.setActive(false) }
                }
        }
    }
}

/// Applies a language change at once: `L10n` switches, and the screens are rebuilt with the new
/// identity (row bodies are equatable and would otherwise keep their old text). Model state, drafts
/// and the open Settings sheet survive; the navigation stack returns to the chat list, where Settings opens.
struct MobileLanguageRoot: View {
    @ObservedObject var model: MobileModel
    @State private var language = L10n.language
    @State private var settings = false
    var body: some View {
        MobileRoot(model: model, settings: $settings)
            .id(language)
            .environment(\.locale, language.locale)
            .sheet(isPresented: $settings) {
                MobileSettings(model: model, language: Binding(get: { language }, set: { value in
                    L10n.use(value)
                    UserDefaults.standard.set(value.rawValue, forKey: AppLanguage.preferenceKey)
                    language = value
                }))
                .id(language)
                .environment(\.locale, language.locale)
            }
    }
}

struct MobileRoot: View {
    @ObservedObject var model: MobileModel
    @Binding var settings: Bool
    @State private var search = ""
    @State private var creatingChat = false
    @State private var destination: MobileChatDestination?
    var body: some View {
        NavigationStack {
            Group {
                if model.signedIn {
                    MobileChatList(model: model, search: $search)
                        .searchable(text: $search, prompt: L10n.text("Найти чат", "Find a chat"))
                        .refreshable { await model.refresh() }
                } else {
                    MobileSignIn(model: model)
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
                        .accessibilityLabel(L10n.text("Настройки", "Settings")).accessibilityIdentifier("open-settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MobileAccountNotice(model: model) }
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
            // Visual checks: `-preview-new-chat` opens New chat once the fixtures are loaded.
            .onChange(of: model.signedIn) { _, value in
                if value && ProcessInfo.processInfo.arguments.contains("-preview-new-chat") { creatingChat = true }
            }
            .navigationDestination(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("-preview-chat") && model.signedIn)) {
                if let device = model.devices.first, let chat = device.snapshot.chats.first {
                    MobileChatView(model: model, deviceID: device.id, chatID: chat.id)
                }
            }
            #endif
        }
    }
}

struct MobileSignIn: View {
    @ObservedObject var model: MobileModel
    var body: some View {
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
