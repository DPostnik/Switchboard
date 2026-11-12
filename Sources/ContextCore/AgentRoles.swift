import Foundation
import AgentContract

/// A named permission profile. Presets cover the observed workloads (`docs/agent-roles-plan.md`, 4.2);
/// a project fills in its extra roots and cookie sites when the role is resolved.
public struct AgentRole: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var titleRU: String
    public var titleEN: String
    public var summaryRU: String
    public var summaryEN: String
    public var profile: AgentPermissionProfile
    public var builtin: Bool
    /// Whether the project's declared extra roots apply; the editor stays strictly inside the project.
    public var acceptsExtraRoots: Bool
    public init(id: String, titleRU: String, titleEN: String, summaryRU: String, summaryEN: String, profile: AgentPermissionProfile, builtin: Bool = true, acceptsExtraRoots: Bool = true) {
        self.id = id; self.titleRU = titleRU; self.titleEN = titleEN; self.summaryRU = summaryRU; self.summaryEN = summaryEN
        self.profile = profile; self.builtin = builtin; self.acceptsExtraRoots = acceptsExtraRoots
    }
    public func title(language: AppLanguage = L10n.language) -> String { L10n.text(titleRU, titleEN, language: language) }
    public var title: String { title() }
    public func summary(language: AppLanguage = L10n.language) -> String { L10n.text(summaryRU, summaryEN, language: language) }
    public var summary: String { summary() }
    /// The permission vocabulary the rest of the app and the phone still understand.
    public var legacyAccessMode: AccessMode { profile.effective.isUnrestricted ? .fullAccess : .standard }
    /// Roles ordered by reach; a phone or a scheduled job can never select one above the project default.
    public var rank: Int { AgentRoleID.order.firstIndex(of: id) ?? AgentRoleID.order.count }

    /// The profile for one project: extra roots, cookie sites and approved MCP servers come from the project, never from the agent.
    /// `sharedRoots` are the app-level folders for every project (`SavedState.sharedRoots`); they join the project's own
    /// folders for roles that accept extra roots and never reach the Editor or the Reader.
    public func profile(for project: Project, sharedRoots: [AgentPermissionProfile.Root] = []) -> AgentPermissionProfile {
        var result = profile
        if case .project = result.filesystem {
            let roots = acceptsExtraRoots ? SharedRoots.merged(project: project, shared: sharedRoots) : []
            result.filesystem = .project(extraRoots: roots)
            // Commands of a role with a shell are confined to the project, its folders and its presets.
            if result.shell == .on { result.commandSandbox = project.commandSandbox(extraRoots: roots) }
        }
        if case .sites = result.cookieImport {
            result.cookieImport = .sites((project.cookieSites ?? []).map { $0.lowercased() })
        }
        result.mcpServers = project.mcpServers.flatMap { $0.isEmpty ? nil : $0 }
        return result
    }
    /// The project profile widened by the chat's add-ons; the rest of the role stays as it is.
    public func profile(for project: Project, addOns: Set<RoleAddOn>, sharedRoots: [AgentPermissionProfile.Root] = []) -> AgentPermissionProfile {
        var result = profile(for: project, sharedRoots: sharedRoots)
        guard !result.audit else { return result }
        for addOn in addOns { addOn.apply(to: &result) }
        return result
    }
}

/// An extra permission a chat adds to its role instead of switching to a wider one.
public enum RoleAddOn: String, Codable, CaseIterable, Identifiable, Sendable {
    /// claude.ai connectors (Gmail, Calendar…): reads run silently, sends and other writes are asked.
    case mail
    /// The user's own Chrome next to the app's browser.
    case userChrome

    public var id: String { rawValue }
    public func title(language: AppLanguage = L10n.language) -> String {
        switch self {
        case .mail: L10n.text("Почта и коннекторы", "Mail and connectors", language: language)
        case .userChrome: L10n.text("Мой Chrome", "My Chrome", language: language)
        }
    }
    public var title: String { title() }
    /// The SF Symbol the role chip shows after the role's name.
    public var symbol: String {
        switch self {
        case .mail: "envelope"
        case .userChrome: "globe"
        }
    }
    public func summary(language: AppLanguage = L10n.language) -> String {
        switch self {
        case .mail: L10n.text("Gmail, Календарь и другие коннекторы: чтение без вопросов, отправка и изменения с подтверждением.",
                              "Gmail, Calendar and other connectors: reads without prompts, sends and changes ask first.", language: language)
        case .userChrome: L10n.text("Агент может работать в вашем Chrome, где вы уже вошли на сайты.",
                                    "The agent can work in your Chrome, where you are already signed in to sites.", language: language)
        }
    }
    public var summary: String { summary() }
    /// Widens only; a role that already allows more keeps it.
    public func apply(to profile: inout AgentPermissionProfile) {
        switch self {
        case .mail: if profile.connectors == .off || profile.connectors == .read { profile.connectors = .askWrites }
        case .userChrome: profile.browser = .appAndUserChrome
        }
    }
}

public enum AgentRoleID {
    public static let reader = "reader", editor = "editor", developer = "developer", routineOperator = "routine-operator", fullOperator = "operator"
    public static let order = [reader, editor, developer, routineOperator, fullOperator]
}

public struct AgentRoleCatalog: Codable, Hashable, Sendable {
    public var custom: [AgentRole]
    public init(custom: [AgentRole] = []) { self.custom = custom }

    public static let presets: [AgentRole] = [
        AgentRole(id: AgentRoleID.reader, titleRU: "Читатель", titleEN: "Reader",
                  summaryRU: "Чтение, поиск в сети и браузер приложения без подтверждений. Записывает только в папку research внутри проекта.",
                  summaryEN: "Reads, searches the web and uses the app browser without prompts. Writes only to the research folder inside the project.",
                  profile: .init(filesystem: .readOnly, network: true, webSearch: true, shell: .off, projectWrites: .silent, browser: .app,
                                 connectors: .read, cookieImport: .any, approvals: .never, subagentRole: AgentRoleID.reader, scratch: "research")),
        AgentRole(id: AgentRoleID.editor, titleRU: "Редактор", titleEN: "Editor",
                  summaryRU: "Правит файлы проекта без подтверждений. Без команд (Claude) и без сети.",
                  summaryEN: "Edits project files without prompts. No commands (Claude), no network.",
                  profile: .workspace(), acceptsExtraRoots: false),
        AgentRole(id: AgentRoleID.developer, titleRU: "Разработчик", titleEN: "Developer",
                  summaryRU: "Проект и объявленные папки, команды, сборка и сеть. Системные команды запрещены, опасные спрашивают.",
                  summaryEN: "The project and declared folders, commands, builds and network. System commands are denied, destructive ones ask.",
                  profile: .init(filesystem: .project(extraRoots: []), network: true, webSearch: true, shell: .on, projectWrites: .silent, browser: .app,
                                 connectors: .off, cookieImport: .any, approvals: .ask,
                                 commandInspection: .init(deny: ["sudo ", "launchctl ", "defaults write", "security ", "diskutil ", "git push --force", "git push -f", "osascript"],
                                                          ask: ["rm -rf", "rm -fr", "rm -r ", "git reset --hard", "git clean"]),
                                 subagentRole: AgentRoleID.developer)),
        AgentRole(id: AgentRoleID.routineOperator, titleRU: "Оператор рутин", titleEN: "Routine operator",
                  summaryRU: "Для заданий по расписанию: браузер приложения, коннекторы только на чтение, команды без системных. Действия вне роли откладываются, запуск не ждёт.",
                  summaryEN: "For scheduled jobs: app browser, read-only connectors, commands without system changes. Actions outside the role are deferred; a run never waits.",
                  profile: .init(filesystem: .project(extraRoots: []), network: true, webSearch: true, shell: .on, projectWrites: .silent, browser: .app,
                                 connectors: .read, cookieImport: .sites([]), approvals: .blocked,
                                 commandInspection: .init(deny: ["sudo ", "launchctl ", "defaults write", "security ", "diskutil ", "git push --force", "git push -f", "osascript", "rm -rf /"]),
                                 subagentRole: AgentRoleID.reader, audit: true)),
        AgentRole(id: AgentRoleID.fullOperator, titleRU: "Оператор", titleEN: "Operator",
                  summaryRU: "Полный доступ без подтверждений: команды, сеть, коннекторы, Chrome пользователя. Только для этого чата.",
                  summaryEN: "Full access without prompts: commands, network, connectors, the user's Chrome. For this chat only.",
                  profile: .unrestricted)
    ]

    public var all: [AgentRole] { Self.presets + custom.filter { role in !Self.presets.contains { $0.id == role.id } } }
    public func role(_ id: String?) -> AgentRole? { id.flatMap { key in all.first { $0.id == key } } }
    public static func preset(_ id: String) -> AgentRole { presets.first { $0.id == id }! }
    /// Roles the composer offers for an interactive chat.
    public var interactive: [AgentRole] { all }
    /// Roles a scheduled job may run with; `operator` needs the desktop UI and is never a job default by migration.
    public var scheduled: [AgentRole] { all.filter { $0.id != AgentRoleID.fullOperator } }
}

extension AccessMode {
    /// The role an old access mode stands for.
    public var legacyRoleID: String { self == .fullAccess ? AgentRoleID.fullOperator : AgentRoleID.editor }
}

extension Project {
    public func chatRole(_ catalog: AgentRoleCatalog) -> AgentRole {
        catalog.role(chatRoleID) ?? AgentRoleCatalog.preset((defaultChatAccessMode ?? .standard).legacyRoleID)
    }
    public func jobRole(_ catalog: AgentRoleCatalog) -> AgentRole {
        catalog.role(jobRoleID) ?? AgentRoleCatalog.preset((accessMode ?? .standard).legacyRoleID)
    }
}

extension Chat {
    /// Explicit role, else the project default when the chat inherits, else the legacy stored mode.
    public func resolvedRole(in project: Project, catalog: AgentRoleCatalog) -> AgentRole {
        if let role = catalog.role(roleID) { return role }
        if inheritsProjectAccess == true { return project.chatRole(catalog) }
        return AgentRoleCatalog.preset((accessMode ?? .standard).legacyRoleID)
    }
    public var inheritsProjectRole: Bool { roleID == nil && inheritsProjectAccess == true }
    public func resolvedAddOns(in project: Project) -> Set<RoleAddOn> { Set((roleAddOns ?? project.chatRoleAddOns ?? []).compactMap(RoleAddOn.init(rawValue:))) }
}

/// One-time mapping of stored access modes to explicit roles; reversible while the access fields stay populated.
public struct RoleMigrationRecord: Codable, Hashable, Sendable {
    public var date: Date
    public var chats: [String: Int]
    public var projects: [String: Int]
    public var jobs: [String: Int]
    public init(date: Date, chats: [String: Int], projects: [String: Int], jobs: [String: Int]) {
        self.date = date; self.chats = chats; self.projects = projects; self.jobs = jobs
    }
}

extension SavedState {
    public var roleCatalog: AgentRoleCatalog { roles ?? AgentRoleCatalog() }

    /// Maps legacy access modes to roles once. Chats keep their behaviour: `standard` -> editor, `fullAccess` -> operator,
    /// inherited stays inherited. Job defaults of `fullAccess` become `routine-operator` in audit mode, which still runs
    /// unrestricted; that is the one deliberate mapping beyond the old vocabulary and it is recorded.
    public mutating func migrateRoles(now: Date = Date()) -> Bool {
        guard roleMigration == nil else { return false }
        var chatCounts: [String: Int] = [:], projectCounts: [String: Int] = [:], jobCounts: [String: Int] = [:]
        for index in chats.indices where chats[index].roleID == nil {
            let chat = chats[index]
            let key: String
            if chat.inheritsProjectAccess == true { key = "inherited" }
            else {
                let role = (chat.accessMode ?? .standard).legacyRoleID
                chats[index].roleID = role; key = (chat.accessMode?.rawValue ?? "none") + "->" + role
            }
            chatCounts[key, default: 0] += 1
        }
        for index in projects.indices {
            if projects[index].chatRoleID == nil, let mode = projects[index].defaultChatAccessMode {
                projects[index].chatRoleID = mode.legacyRoleID
                projectCounts[mode.rawValue + "->" + mode.legacyRoleID, default: 0] += 1
            }
            if projects[index].jobRoleID == nil, let mode = projects[index].accessMode {
                let role = mode == .fullAccess ? AgentRoleID.routineOperator : AgentRoleID.editor
                projects[index].jobRoleID = role
                jobCounts[mode.rawValue + "->" + role, default: 0] += 1
            }
        }
        roleMigration = RoleMigrationRecord(date: now, chats: chatCounts, projects: projectCounts, jobs: jobCounts)
        return true
    }
}

/// Folders the user grants to every project (Settings → Advanced → Folders for every project). They behave exactly like a
/// project's own folders; the app's data folder, any folder containing it and the home folder itself are refused.
public enum SharedRoots {
    public enum Refusal: Equatable, Sendable {
        case notAbsolute, home, dataFolder
        public func message(_ path: String, language: AppLanguage = L10n.language) -> String {
            switch self {
            case .notAbsolute:
                L10n.text("Папка «\(path)» не добавлена: нужен полный путь.", "The folder “\(path)” was not added: a full path is required.", language: language)
            case .home:
                L10n.text("Домашнюю папку целиком нельзя открыть всем проектам. Выбери папку внутри неё.",
                          "The whole home folder cannot be opened to every project. Choose a folder inside it.", language: language)
            case .dataFolder:
                L10n.text("Папка «\(path)» содержит данные приложения или лежит внутри них, поэтому её нельзя открыть всем проектам.",
                          "The folder “\(path)” holds or lies inside the app's data, so it cannot be opened to every project.", language: language)
            }
        }
    }
    /// The suggested first entry shown as a hint; nothing is granted until the user adds a folder.
    public static let suggestedPath = "~/Public/self-projects"

    /// The stored form: `~` expanded, `.`/`..` and a trailing slash removed, like project folders.
    public static func canonical(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = trimmed == "~" ? home : trimmed.hasPrefix("~/") ? home + trimmed.dropFirst() : trimmed
        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Why a folder cannot be shared with every project, or nil when it can.
    public static func refusal(_ path: String, home: String = NSHomeDirectory(), dataRoots: [String]? = nil) -> Refusal? {
        let candidate = canonical(path, home: home)
        guard candidate.hasPrefix("/") else { return .notAbsolute }
        func resolved(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path }
        let forms = Set([candidate, resolved(candidate)])
        if forms.contains(canonical(home)) || forms.contains(resolved(home)) { return .home }
        let protected = (dataRoots ?? defaultDataRoots(home: home)).flatMap { [canonical($0, home: home), resolved($0)] }
        func related(_ a: String, _ b: String) -> Bool { a == b || a == "/" || b.hasPrefix(a + "/") || a.hasPrefix(b + "/") }
        if forms.contains(where: { form in protected.contains { related(form, $0) } }) { return .dataFolder }
        return nil
    }
    /// The app's data folder (also when the test runner moves it) and the pre-rename alias.
    public static func defaultDataRoots(home: String = NSHomeDirectory()) -> [String] {
        let support = home + "/Library/Application Support"
        return [Locations.root.path, Locations.legacyRoot.path, support + "/Switchboard", support + "/Context Desk"]
    }
    /// The stored folders that may be applied: canonical, refused ones dropped, one entry per path.
    public static func usable(_ roots: [AgentPermissionProfile.Root], home: String = NSHomeDirectory(), dataRoots: [String]? = nil) -> [AgentPermissionProfile.Root] {
        var result: [AgentPermissionProfile.Root] = []
        for root in roots where refusal(root.path, home: home, dataRoots: dataRoots) == nil {
            let path = canonical(root.path, home: home)
            if let index = result.firstIndex(where: { $0.path == path }) { result[index].writable = result[index].writable || root.writable }
            else { result.append(.init(path: path, writable: root.writable)) }
        }
        return result
    }
    /// The project's own folders followed by the shared ones; a folder in both keeps write access if either grants it.
    static func merged(project: Project, shared: [AgentPermissionProfile.Root]) -> [AgentPermissionProfile.Root] {
        var result = (project.extraRoots ?? []).filter { $0.path.hasPrefix("/") }
        let projectPath = canonical(project.path)
        for root in usable(shared) where root.path != projectPath {
            if let index = result.firstIndex(where: { canonical($0.path) == root.path }) { result[index].writable = result[index].writable || root.writable }
            else { result.append(root) }
        }
        return result
    }
}
