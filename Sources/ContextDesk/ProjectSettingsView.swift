import SwiftUI
import AppKit
import ContextCore
import AgentContract
import ContextTranscript

/// Project settings sheet (project menu): default roles, folders outside the project, cookie import sites,
/// phone visibility and approved MCP servers. Declared here by the user; an agent, a phone or a schedule-control
/// request can never change them. Every edit applies on Save.
struct ProjectSettingsView: View {
    enum Pane: CaseIterable, Identifiable {
        case roles, browser, phone, advanced
        var id: Self { self }
        var title: String {
            switch self {
            case .roles: L10n.text("Что можно агентам", "What agents may do")
            case .browser: L10n.text("Браузер и вход", "Browser & sign-in")
            case .phone: L10n.text("Телефон", "Phone")
            case .advanced: L10n.text("Дополнительно", "Advanced")
            }
        }
    }

    @ObservedObject var model: DeskModel
    @ObservedObject private var phone: MobileRemoteHost
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var section: Pane = .roles
    @State private var chatRole: String
    @State private var jobRole: String
    @State private var extraRoots: [AgentPermissionProfile.Root]
    @State private var foldersExpanded = false
    @State private var cookieSites: String
    @FocusState private var cookieSitesFocused: Bool
    @State private var shownOnPhone: Bool
    private let initiallyShownOnPhone: Bool
    @State private var browserProfiles: [SavedProfile] = []
    @State private var browserProfilesIssue: String?
    /// Approvals as saved; a server whose `.mcp.json` entry changed since shows as off and must be approved again.
    @State private var mcpServers: [String: String]
    private let projectServers: [ProjectMCPServers.Server]

    init(model: DeskModel, project: Project) {
        self.model = model; self.project = project
        _phone = ObservedObject(wrappedValue: model.mobileRemote)
        let catalog = model.roleCatalog
        _chatRole = State(initialValue: project.chatRole(catalog).id)
        _jobRole = State(initialValue: project.jobRole(catalog).id)
        _extraRoots = State(initialValue: project.extraRoots ?? [])
        _cookieSites = State(initialValue: (project.cookieSites ?? []).joined(separator: "\n"))
        _mcpServers = State(initialValue: project.mcpServers ?? [:])
        let shown = model.mobileRemote.projects.contains(project.id.uuidString)
        _shownOnPhone = State(initialValue: shown)
        initiallyShownOnPhone = shown
        projectServers = ProjectMCPServers.servers(projectPath: project.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sectionList
                ScrollView {
                    VStack(alignment: .leading, spacing: .ui(14)) {
                        Text(section.title).font(.ui(.title3).weight(.semibold)).foregroundStyle(DeskPalette.ink)
                            .accessibilityAddTraits(.isHeader)
                        switch section {
                        case .roles: rolesPane
                        case .browser: browserPane
                        case .phone: phonePane
                        case .advanced: advancedPane
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, .ui(22)).padding(.vertical, .ui(20))
                }
                .background(DeskPalette.canvas)
            }
            Divider()
            HStack(spacing: .ui(8)) {
                Spacer()
                Button(L10n.text("Отмена", "Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(DeskButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(L10n.text("Сохранить", "Save")) { save() }
                    .buttonStyle(DeskButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, .ui(16)).padding(.vertical, .ui(12))
            .background(DeskPalette.canvas)
        }
        .frame(width: 760, height: 520)
        .onAppear(perform: loadBrowserProfiles)
    }

    // MARK: Sections

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: .ui(2)) {
            Text(project.name).font(.ui(.headline)).foregroundStyle(DeskPalette.ink).lineLimit(1).truncationMode(.middle)
                .help(project.path)
                .padding(.horizontal, .ui(10)).padding(.top, .ui(20)).padding(.bottom, .ui(12))
                .accessibilityAddTraits(.isHeader)
            ForEach(Pane.allCases) { item in
                SectionRow(title: item.title, selected: section == item) { section = item }
            }
            Spacer()
        }
        .padding(.horizontal, .ui(10))
        .frame(width: .ui(200), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(DeskPalette.sidebar)
    }

    private var rolesPane: some View {
        VStack(alignment: .leading, spacing: .ui(14)) {
            hint(L10n.text("Для новых чатов. Каждый чат может сменить роль чипом с замком.",
                           "Default for new chats. Each chat can change it with the lock chip."))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: .ui(10), alignment: .top), count: 3),
                      alignment: .leading, spacing: .ui(10)) {
                ForEach(model.roleCatalog.interactive) { role in
                    RoleCard(title: role.title, summary: Self.shortSummary(role), detail: role.summary, selected: chatRole == role.id) {
                        chatRole = role.id
                    }
                }
            }
            if let role = model.roleCatalog.role(chatRole) { hint(role.summary) }
            Divider()
            row(L10n.text("Задания по расписанию", "Scheduled jobs use"),
                L10n.text("Роль для заданий этого проекта", "Role for jobs of this project")) {
                Picker(L10n.text("Задания по расписанию", "Scheduled jobs use"), selection: $jobRole) {
                    ForEach(model.roleCatalog.scheduled) { role in Text(role.title).tag(role.id) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().pointingHandCursor()
            }
            if let role = model.roleCatalog.role(jobRole) {
                hint(role.summary)
                if role.profile.audit == true {
                    hint(L10n.text("Режим аудита: запуски идут без ограничений, а действия вне роли только записываются в журнал разрешений.",
                                   "Audit mode: runs stay unrestricted while actions outside the role are only recorded in the permissions ledger."))
                }
            }
            Divider()
            row(L10n.text("Папки вне проекта", "Folders outside the project"), foldersSummary) {
                Button(foldersExpanded ? L10n.text("Готово", "Done") : L10n.text("Изменить…", "Edit…")) {
                    foldersExpanded.toggle()
                }
                .buttonStyle(DeskButtonStyle(kind: .secondary))
                .accessibilityLabel(foldersExpanded ? L10n.text("Скрыть папки вне проекта", "Hide folders outside the project")
                                                    : L10n.text("Изменить папки вне проекта", "Edit folders outside the project"))
            }
            if foldersExpanded { folderEditor }
        }
    }

    private var folderEditor: some View {
        VStack(alignment: .leading, spacing: .ui(8)) {
            if extraRoots.isEmpty {
                hint(L10n.text("Роли «Разработчик» и «Оператор рутин» видят только папку проекта. Добавь папки, которые нужны без подтверждений.",
                               "The Developer and Routine operator roles see only the project folder. Add the folders they need without prompts."))
            }
            ForEach(extraRoots.indices, id: \.self) { index in
                HStack(spacing: .ui(10)) {
                    Image(systemName: "folder").foregroundStyle(DeskPalette.muted).accessibilityHidden(true)
                    Text(extraRoots[index].path).font(.ui(.callout)).lineLimit(1).truncationMode(.middle).help(extraRoots[index].path)
                    Spacer()
                    Toggle(L10n.text("Запись", "Write"), isOn: $extraRoots[index].writable).toggleStyle(.checkbox)
                    Button { extraRoots.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(PointerButtonStyle(base: .plain))
                        .accessibilityLabel(L10n.text("Убрать папку", "Remove folder"))
                        .help(L10n.text("Убрать папку", "Remove folder"))
                }
                .padding(.horizontal, .ui(10)).padding(.vertical, .ui(7))
                .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 8))
            }
            Button(L10n.text("Добавить папку…", "Add folder…")) { chooseFolder() }
                .buttonStyle(DeskButtonStyle(kind: .text))
        }
    }

    private var browserPane: some View {
        VStack(alignment: .leading, spacing: .ui(14)) {
            VStack(alignment: .leading, spacing: .ui(6)) {
                Text(L10n.text("Сайты для импорта cookie", "Cookie import sites")).font(.ui(.callout).weight(.semibold))
                TextEditor(text: $cookieSites)
                    .font(.ui(.body)).scrollContentBackground(.hidden).focused($cookieSitesFocused)
                    .padding(.ui(6)).frame(minHeight: 90, maxHeight: 120)
                    .modifier(DeskFieldChrome(focused: cookieSitesFocused))
                    .accessibilityLabel(L10n.text("Сайты для импорта cookie", "Cookie import sites"))
                hint(L10n.text("По одному домену в строке, например linkedin.com; этот список использует только роль «Оператор рутин», чтобы импортировать сессию Chrome.",
                               "One domain per line, for example linkedin.com; only the Routine operator role uses this list to import a Chrome session."))
            }
            Divider()
            VStack(alignment: .leading, spacing: .ui(6)) {
                Text(L10n.text("Сохранённые профили браузера", "Saved browser profiles")).font(.ui(.callout).weight(.semibold))
                if let browserProfilesIssue {
                    Text(browserProfilesIssue).font(.ui(.caption)).foregroundStyle(DeskPalette.problem).textSelection(.enabled)
                } else if browserProfiles.isEmpty {
                    hint(L10n.text("В этом проекте пока нет сохранённых профилей.", "This project has no saved profiles yet."))
                }
                ForEach(browserProfiles) { saved in
                    HStack(spacing: .ui(10)) {
                        Image(systemName: "globe").foregroundStyle(DeskPalette.browser).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(saved.profile.name ?? String(saved.profile.id.uuidString.prefix(8))).font(.ui(.callout))
                            Text(saved.agent + " · " + profileStatus(saved.profile)).font(.ui(.caption)).foregroundStyle(DeskPalette.muted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, .ui(10)).padding(.vertical, .ui(7))
                    .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }
                hint(L10n.text("Профиль выбирается в меню «Браузер» чата.", "Profiles are chosen from the chat's browser menu."))
            }
        }
    }

    private var phonePane: some View {
        VStack(alignment: .leading, spacing: .ui(10)) {
            Toggle(L10n.text("Показывать этот проект на телефоне", "Show this project on the phone"), isOn: $shownOnPhone)
                .toggleStyle(.switch).disabled(!phone.configured || !phone.projectsEditable)
            if !phone.configured {
                hint(L10n.text("Настрой мобильный доступ в Настройках → Дополнительно.", "Set up mobile access in Settings → Advanced."))
            } else if !phone.projectsEditable {
                hint(L10n.text("Мобильный доступ включён. Чтобы изменить список проектов на телефоне, выключи доступ в Настройках → Дополнительно.",
                               "Mobile access is on. To change which projects the phone shows, turn access off in Settings → Advanced."))
            } else {
                hint(L10n.text("Названия, последние сообщения и запросы подтверждения чатов этого проекта передаются в Supabase.",
                               "Names, recent messages and approval requests of this project's chats are sent to Supabase."))
            }
        }
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: .ui(10)) {
            Text(L10n.text("MCP-серверы проекта", "Project MCP servers")).font(.ui(.callout).weight(.semibold))
            if projectServers.isEmpty {
                hint(L10n.text("В файле .mcp.json проекта нет серверов.", "The project's .mcp.json file has no servers."))
            }
            ForEach(projectServers, id: \.name) { server in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(server.name, isOn: approval(server)).toggleStyle(.checkbox)
                    Text(server.summary).font(.ui(.caption)).foregroundStyle(DeskPalette.muted).lineLimit(2).truncationMode(.middle)
                        .help(server.summary)
                    if let saved = mcpServers[server.name], saved != server.fingerprint {
                        Text(L10n.text("Запись в .mcp.json изменилась после одобрения. Сервер выключен, пока ты не одобришь его снова.",
                                       "The .mcp.json entry changed after approval. The server stays off until you approve it again."))
                            .font(.ui(.caption)).foregroundStyle(DeskPalette.attention)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, .ui(10)).padding(.vertical, .ui(8))
                .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 8))
            }
            hint(L10n.text("Одобренные серверы запускаются в чатах Claude этого проекта от твоего имени, их инструменты работают без подтверждений. Одобряй только серверы, которым доверяешь.",
                           "Approved servers start in this project's Claude chats as your user, and their tools run without prompts. Approve only servers you trust."))
        }
    }

    // MARK: Pieces

    private func hint(_ text: String) -> some View {
        Text(text).font(.ui(.caption)).foregroundStyle(DeskPalette.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func row<Control: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: .ui(12)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.callout)).foregroundStyle(DeskPalette.ink)
                Text(subtitle).font(.ui(.caption)).foregroundStyle(DeskPalette.muted)
            }
            Spacer()
            control()
        }
    }

    private var foldersSummary: String {
        let writable = extraRoots.filter(\.writable).count
        if extraRoots.isEmpty { return L10n.text("Только папка проекта", "Project folder only") }
        return L10n.text("Папок: \(extraRoots.count) · с записью: \(writable)", "\(extraRoots.count) folders · \(writable) writable")
    }

    /// One line per preset for the cards; the full summary stays in the tooltip and under the grid.
    static func shortSummary(_ role: AgentRole) -> String {
        switch role.id {
        case AgentRoleID.reader: L10n.text("Читает и ищет; пишет только в research/", "Reads and searches; writes only to research/")
        case AgentRoleID.editor: L10n.text("Правит файлы проекта; без сети", "Edits project files; no network")
        case AgentRoleID.developer: L10n.text("Команды, сборка, сеть; опасное спрашивает", "Commands, builds, network; risky ones ask")
        case AgentRoleID.routineOperator: L10n.text("Для заданий по расписанию; не ждёт тебя", "For scheduled jobs; never waits for you")
        case AgentRoleID.fullOperator: L10n.text("Полный доступ и твой Chrome; только этот чат", "Full access, your Chrome; this chat only")
        default: role.summary
        }
    }

    private func approval(_ server: ProjectMCPServers.Server) -> Binding<Bool> {
        Binding(get: { mcpServers[server.name] == server.fingerprint },
                set: { mcpServers[server.name] = $0 ? server.fingerprint : nil })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Добавить", "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard !extraRoots.contains(where: { $0.path == path }), path != project.path else { return }
        extraRoots.append(.init(path: path, writable: false))
    }

    private func save() {
        model.updateProjectRoles(project.id, chatRole: chatRole, jobRole: jobRole, extraRoots: extraRoots,
                                 cookieSites: cookieSites.split(whereSeparator: \.isNewline).map(String.init), mcpServers: mcpServers)
        if shownOnPhone != initiallyShownOnPhone { phone.setProject(project.id, shown: shownOnPhone) }
        dismiss()
    }

    // MARK: Browser profiles (read-only)

    struct SavedProfile: Identifiable {
        let profile: BrowserProfile
        let agent: String
        var id: UUID { profile.id }
    }

    private func loadBrowserProfiles() {
        let store = BrowserProfileStore()
        do {
            browserProfiles = try [(AgentConnectionID.originalCodex, "Codex"), (AgentConnectionID.appClaude, "Claude")].flatMap { connection, agent in
                try store.profiles(project: project.path, connection: connection).map { SavedProfile(profile: $0, agent: agent) }
            }
            browserProfilesIssue = nil
        } catch { browserProfiles = []; browserProfilesIssue = error.localizedDescription }
    }

    private func profileStatus(_ profile: BrowserProfile) -> String {
        if let owner = profile.owner, let title = model.browserProfileOwnerName(owner) { return L10n.text("Чат: ", "Chat: ") + title }
        switch profile.state {
        case .available: return L10n.text("Доступен", "Available")
        case .active: return L10n.text("Управление у чата", "Controlled by a chat")
        case .human: return L10n.text("Ручное управление", "Manual control")
        case .pending: return L10n.text("Ожидает подключения", "Awaiting activation")
        case .configuring: return L10n.text("Подключение не подтверждено", "Activation not confirmed")
        }
    }
}

/// Left-column entry: selection fill on the active section, a lighter tint under the pointer.
private struct SectionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(.callout)).foregroundStyle(selected ? DeskPalette.ink : DeskPalette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, .ui(10)).padding(.vertical, .ui(7))
                .background(selected ? DeskPalette.selection : hovering ? DeskPalette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One role: title and one line of what it may do. Selected: moss wash with a 1.5 pt moss inner stroke.
private struct RoleCard: View {
    let title: String
    let summary: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: .ui(4)) {
                Text(title).font(.ui(.callout).weight(.semibold)).foregroundStyle(selected ? DeskPalette.accentDeep : DeskPalette.ink)
                Text(summary).font(.ui(.caption)).foregroundStyle(DeskPalette.inkSoft)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: .ui(58), alignment: .topLeading)
            .padding(.ui(10))
            .background(selected ? DeskPalette.accentWash : hovering ? DeskPalette.rowHover : DeskPalette.subtle,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DeskPalette.accent, lineWidth: 1.5).opacity(selected ? 1 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { hovering = $0 }
        .help(detail)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
