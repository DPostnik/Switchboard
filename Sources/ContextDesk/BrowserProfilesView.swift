import ContextTranscript
import SwiftUI
import ContextCore

enum BrowserProfileAction: Sendable {
    case rename(String), select(UUID?), release, takeControl, returnControl
}

struct BrowserProfilesView: View {
    let session: AgentSessionReference
    let project: String
    let ownerName: (String) -> String?
    let change: (BrowserProfileAction) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: BrowserProfile?
    @State private var profiles: [BrowserProfile] = []
    @State private var name = ""
    @State private var operating = false
    @State private var error: String?
    private var reference: AgentSessionReference { session }
    private var owned: Bool { current.map { BrowserProfileStore().owns($0, session: reference) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Профили браузера", "Browser profiles")).font(.ui(.title2).bold())
            Text(L10n.text("Сохранённый профиль сохраняет cookies и другие данные сайтов. Его можно использовать в следующих чатах этого проекта. Одновременно им управляет один чат.",
                           "A saved profile retains cookies and other site data. Reuse it in later chats in this project. One chat controls it at a time."))
            if let current {
                Text(L10n.text("Текущий профиль: ", "Current profile: ") + (current.name ?? String(current.id.uuidString.prefix(8)))).font(.ui(.headline))
                Text(owned ? status(current.state) : L10n.text("Управление передано другому чату или освобождено.", "Control was transferred to another chat or released."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                if owned {
                    HStack {
                        TextField(L10n.text("Название профиля", "Profile name"), text: $name)
                        Button(L10n.text("Сохранить название", "Save name")) { perform(.rename(name)) }
                    }
                    HStack {
                        if current.state == .human {
                            Button(L10n.text("Вернуть управление чату", "Return control to chat")) { perform(.returnControl) }
                        } else if current.state == .active {
                            Button(L10n.text("Взять управление вручную", "Take manual control")) { perform(.takeControl) }
                        }
                        Button(L10n.text("Освободить профиль", "Release profile")) { perform(.release) }
                            .disabled(current.name == nil)
                    }
                }
            } else {
                Text(L10n.text("Профиль будет зарегистрирован при первом действии ниже.", "The profile will be registered on your first action below."))
                HStack {
                    TextField(L10n.text("Название профиля", "Profile name"), text: $name)
                    Button(L10n.text("Сохранить профиль", "Save profile")) { perform(.rename(name)) }
                }
            }
            Divider()
            Text(L10n.text("Перед освобождением или сменой профиля закрой его Chrome через меню «Браузер». Данные сайтов останутся, но вход, зависящий от закрытой вкладки, может потребовать повторения.",
                           "Before releasing or switching profiles, close its Chrome from the Browser menu. Site data stays, but a sign-in tied to a closed tab may need to be repeated."))
                .font(.ui(.callout))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading) {
                                Text((profile.name ?? "") + " · " + String(profile.id.uuidString.prefix(8)))
                                Text(profile.owner == nil && profile.state == .available ? L10n.text("Доступен", "Available") : status(profile.state))
                                    .font(.ui(.caption)).foregroundStyle(.secondary)
                                if let owner = profile.owner, let title = ownerName(owner) {
                                    Text(L10n.text("Чат: ", "Chat: ") + title).font(.ui(.caption)).lineLimit(2)
                                }
                            }
                            Spacer()
                            Button(L10n.text("Выбрать", "Select")) { perform(.select(profile.id)) }
                                .disabled(profile.owner != nil && !BrowserProfileStore().owns(profile, session: reference))
                        }
                    }
                }
            }.frame(maxHeight: 190)
            Button(L10n.text("Новый отдельный профиль", "New separate profile")) { perform(.select(nil)) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L10n.text("Обновить", "Refresh")) { reload() }
                Spacer()
                if operating { ProgressView().uiSmallSpinner() }
                Button(L10n.text("Закрыть", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 590).disabled(operating)
        .interactiveDismissDisabled(operating)
        .onAppear { reload() }
    }
    private func status(_ state: BrowserProfile.State) -> String {
        switch state {
        case .active: return L10n.text("Управление у чата", "Controlled by a chat")
        case .human: return L10n.text("Ручное управление; действия агента остановлены", "Manual control; agent browser actions are paused")
        case .available: return L10n.text("Доступен", "Available")
        case .pending: return L10n.text("Ожидает подключения", "Awaiting activation")
        case .configuring: return L10n.text("Подключение не подтверждено", "Activation not confirmed")
        }
    }
    private func reload() {
        do {
            let store = BrowserProfileStore()
            current = try store.current(session: reference)
            profiles = try store.profiles(project: project, connection: reference.connection)
            name = current?.name ?? ""
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: BrowserProfileAction) {
        operating = true; error = nil
        Task {
            defer { operating = false; reload() }
            do { try await change(action) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct NewChatBrowserProfilePicker: View {
    let project: String
    let connection: AgentConnectionID
    let ownerName: (String) -> String?
    @Binding var selection: UUID?
    @State private var profiles: [BrowserProfile] = []
    @State private var error: String?
    var body: some View {
        Menu {
            Button(L10n.text("Новый отдельный профиль", "New separate profile")) { selection = nil }
            ForEach(profiles) { profile in
                Button((profile.name ?? "") + " · " + String(profile.id.uuidString.prefix(8)) +
                       (profile.owner.flatMap(ownerName).map { L10n.text(" — чат: ", " — chat: ") + $0 } ?? "")) { selection = profile.id }
                    .disabled(profile.state != .available || profile.owner != nil)
            }
            if let error { Text(error) }
            Button(L10n.text("Обновить профили", "Refresh profiles")) { reload() }
            Text(L10n.text("Для одного нового чата. Занятый профиль сначала освободи в его чате.",
                           "For one new chat. Release an occupied profile in its owning chat first."))
        } label: {
            Label(selection.flatMap { id in profiles.first { $0.id == id }?.name } ?? L10n.text("Отдельный браузер", "Separate browser"), systemImage: "globe")
        }
        .menuStyle(.borderlessButton).fixedSize().pointingHandCursor()
        .onAppear { reload() }
        .onChange(of: project) { _, _ in reload() }
        .onChange(of: connection) { _, _ in reload() }
    }
    private func reload() {
        do { profiles = try BrowserProfileStore().profiles(project: project, connection: connection); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
