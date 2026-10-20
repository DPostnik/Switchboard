import SwiftUI
import AppKit
import ContextCore
import AgentContract

/// Project defaults for chats and scheduled jobs, plus the folders outside the project a role may use.
/// Declared here by the user; an agent, a phone or a schedule-control request can never change them.
struct ProjectPermissionsView: View {
    @ObservedObject var model: DeskModel
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var chatRole: String
    @State private var jobRole: String
    @State private var extraRoots: [AgentPermissionProfile.Root]
    @State private var cookieSites: String
    /// Approvals as saved; a server whose `.mcp.json` entry changed since shows as off and must be approved again.
    @State private var mcpServers: [String: String]
    private let projectServers: [ProjectMCPServers.Server]

    init(model: DeskModel, project: Project) {
        self.model = model; self.project = project
        let catalog = model.roleCatalog
        _chatRole = State(initialValue: project.chatRole(catalog).id)
        _jobRole = State(initialValue: project.jobRole(catalog).id)
        _extraRoots = State(initialValue: project.extraRoots ?? [])
        _cookieSites = State(initialValue: (project.cookieSites ?? []).joined(separator: "\n"))
        _mcpServers = State(initialValue: project.mcpServers ?? [:])
        projectServers = ProjectMCPServers.servers(projectPath: project.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(L10n.text("Роли по умолчанию", "Default roles")) {
                    Picker(L10n.text("Новые чаты", "New chats"), selection: $chatRole) {
                        ForEach(model.roleCatalog.interactive) { role in Text(role.title).tag(role.id) }
                    }
                    Text(model.roleCatalog.role(chatRole)?.summary ?? "").font(.ui(.caption)).foregroundStyle(.secondary)
                    Picker(L10n.text("Задания по расписанию", "Scheduled jobs"), selection: $jobRole) {
                        ForEach(model.roleCatalog.scheduled) { role in Text(role.title).tag(role.id) }
                    }
                    Text(model.roleCatalog.role(jobRole)?.summary ?? "").font(.ui(.caption)).foregroundStyle(.secondary)
                    if model.roleCatalog.role(jobRole)?.profile.audit == true {
                        Text(L10n.text("Режим аудита: запуски идут без ограничений, а действия вне роли только записываются в журнал разрешений.",
                                       "Audit mode: runs stay unrestricted while actions outside the role are only recorded in the permissions ledger."))
                            .font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.text("Папки вне проекта", "Folders outside the project")) {
                    if extraRoots.isEmpty {
                        Text(L10n.text("Роли «Разработчик» и «Оператор рутин» видят только папку проекта. Добавь папки, которые нужны без подтверждений.",
                                       "The Developer and Routine operator roles see only the project folder. Add the folders they need without prompts."))
                            .font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    ForEach(extraRoots.indices, id: \.self) { index in
                        HStack {
                            Text(extraRoots[index].path).lineLimit(1).truncationMode(.middle).help(extraRoots[index].path)
                            Spacer()
                            Toggle(L10n.text("Запись", "Write"), isOn: $extraRoots[index].writable).toggleStyle(.checkbox)
                            Button { extraRoots.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                .accessibilityLabel(L10n.text("Убрать папку", "Remove folder"))
                        }
                    }
                    Button(L10n.text("Добавить папку…", "Add folder…")) { chooseFolder() }
                }
                Section(L10n.text("Сайты для импорта cookie", "Cookie import sites")) {
                    TextEditor(text: $cookieSites).frame(minHeight: 60).font(.ui(.body))
                    Text(L10n.text("По одному домену в строке, например linkedin.com. Роль «Оператор рутин» может импортировать сессию Chrome только для них.",
                                   "One domain per line, for example linkedin.com. The Routine operator role may import a Chrome session only for these."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Section(L10n.text("MCP-серверы проекта", "Project MCP servers")) {
                    if projectServers.isEmpty {
                        Text(L10n.text("В файле .mcp.json проекта нет серверов.", "The project's .mcp.json file has no servers."))
                            .font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    ForEach(projectServers, id: \.name) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(server.name, isOn: approval(server)).toggleStyle(.checkbox)
                            Text(server.summary).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                .help(server.summary)
                            if let saved = mcpServers[server.name], saved != server.fingerprint {
                                Text(L10n.text("Запись в .mcp.json изменилась после одобрения. Сервер выключен, пока ты не одобришь его снова.",
                                               "The .mcp.json entry changed after approval. The server stays off until you approve it again."))
                                    .font(.ui(.caption)).foregroundStyle(.orange)
                            }
                        }
                    }
                    Text(L10n.text("Одобренные серверы запускаются в чатах Claude этого проекта от твоего имени, их инструменты работают без подтверждений. Одобряй только серверы, которым доверяешь.",
                                   "Approved servers start in this project's Claude chats as your user, and their tools run without prompts. Approve only servers you trust."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.text("Отмена", "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Сохранить", "Save")) {
                    model.updateProjectRoles(project.id, chatRole: chatRole, jobRole: jobRole, extraRoots: extraRoots,
                                             cookieSites: cookieSites.split(whereSeparator: \.isNewline).map(String.init), mcpServers: mcpServers)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 520, height: 640)
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
}

/// Settings tab: what roles decided over the last days, from the capability ledger.
struct PermissionsLedgerView: View {
    @ObservedObject var model: DeskModel
    @State private var daily: [CapabilityDailyCount] = []
    @State private var recent: [CapabilityDecision] = []
    @State private var issue: String?

    var body: some View {
        Form {
            Section(L10n.text("Роли", "Roles")) {
                ForEach(model.roleCatalog.all) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.title).font(.ui(.body))
                        Text(role.summary).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("Роль чата выбирается в композере; роли проекта и папки вне проекта — в меню проекта «Разрешения…».",
                               "A chat's role is chosen in the composer; project defaults and folders outside the project are in the project menu under Permissions…"))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Section(L10n.text("Журнал за 7 дней", "Last 7 days")) {
                if let issue { Text(issue).font(.ui(.caption)).foregroundStyle(.red) }
                if daily.isEmpty { Text(L10n.text("Записей пока нет.", "No records yet.")).font(.ui(.caption)).foregroundStyle(.secondary) }
                ForEach(summary, id: \.key) { entry in
                    LabeledContent(entry.key) { Text("\(entry.count)") }
                }
            }
            Section(L10n.text("Последние решения", "Recent decisions")) {
                ForEach(Array(recent.prefix(100).enumerated()), id: \.offset) { _, decision in
                    HStack {
                        Text(decision.date, style: .time).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text(decision.roleID).frame(width: 110, alignment: .leading)
                        Text(decision.tool).frame(width: 150, alignment: .leading).lineLimit(1)
                        Text(Self.decisionTitle(decision.decision)).frame(width: 110, alignment: .leading)
                        Text(decision.target ?? "").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }.font(.ui(.caption))
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var summary: [(key: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in daily { counts["\(row.roleID) · \(Self.capabilityTitle(row.capability)) · \(Self.decisionTitle(row.decision))", default: 0] += row.count }
        return counts.map { (key: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count }
    }
    private func load() async {
        do {
            daily = try await model.capabilityLedger.daily(days: 7)
            recent = try await model.capabilityLedger.recent(days: 7, limit: 100)
            issue = await model.capabilityLedger.lastError
        } catch { issue = error.localizedDescription }
    }
    static func capabilityTitle(_ capability: AgentCapabilityRecord.Capability) -> String {
        switch capability {
        case .read: L10n.text("чтение", "read")
        case .writeInProject: L10n.text("запись в проекте", "write in project")
        case .writeOutside: L10n.text("запись вне проекта", "write outside")
        case .shell: L10n.text("команда", "command")
        case .network: L10n.text("сеть", "network")
        case .browser: L10n.text("браузер", "browser")
        case .connector: L10n.text("коннектор", "connector")
        case .connectorWrite: L10n.text("коннектор: запись", "connector write")
        case .subagent: L10n.text("подагент", "subagent")
        case .question: L10n.text("вопрос", "question")
        case .other: L10n.text("другое", "other")
        }
    }
    static func decisionTitle(_ decision: AgentCapabilityRecord.Decision) -> String {
        switch decision {
        case .used: L10n.text("выполнено", "used")
        case .allowed: L10n.text("разрешено", "allowed")
        case .asked: L10n.text("запрошено", "asked")
        case .denied: L10n.text("отклонено", "denied")
        case .wouldDeny: L10n.text("было бы отклонено", "would deny")
        case .unsupportedTool: L10n.text("инструмент вне роли", "tool outside role")
        case .hookDenied: L10n.text("команда отклонена", "command denied")
        case .hookAsked: L10n.text("команда на подтверждение", "command asked")
        }
    }
}
