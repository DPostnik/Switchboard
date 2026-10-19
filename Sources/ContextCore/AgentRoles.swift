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

    /// The profile for one project: extra roots and cookie sites come from the project, never from the agent.
    public func profile(for project: Project) -> AgentPermissionProfile {
        var result = profile
        if case .project = result.filesystem {
            let roots = acceptsExtraRoots ? (project.extraRoots ?? []).filter { $0.path.hasPrefix("/") } : []
            result.filesystem = .project(extraRoots: roots)
        }
        if case .sites = result.cookieImport {
            result.cookieImport = .sites((project.cookieSites ?? []).map { $0.lowercased() })
        }
        return result
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
                                 connectors: .read, cookieImport: .none, approvals: .never, subagentRole: AgentRoleID.reader, scratch: "research")),
        AgentRole(id: AgentRoleID.editor, titleRU: "Редактор", titleEN: "Editor",
                  summaryRU: "Файлы проекта с подтверждениями. Без команд (Claude), без сети и браузера.",
                  summaryEN: "Project files with approvals. No commands (Claude), no network, no browser.",
                  profile: .workspace(), acceptsExtraRoots: false),
        AgentRole(id: AgentRoleID.developer, titleRU: "Разработчик", titleEN: "Developer",
                  summaryRU: "Проект и объявленные папки, команды, сборка и сеть. Системные команды запрещены, опасные спрашивают.",
                  summaryEN: "The project and declared folders, commands, builds and network. System commands are denied, destructive ones ask.",
                  profile: .init(filesystem: .project(extraRoots: []), network: true, webSearch: true, shell: .on, projectWrites: .silent, browser: .app,
                                 connectors: .off, cookieImport: .none, approvals: .ask,
                                 commandInspection: .init(deny: ["sudo ", "launchctl ", "defaults write", "security ", "diskutil ", "git push --force", "git push -f", "osascript"],
                                                          ask: ["rm -rf", "git reset --hard", "git clean", "git push"]),
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
