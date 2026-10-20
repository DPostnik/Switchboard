import Foundation
import AgentContract

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var accessMode: AccessMode?
    /// Default for interactive chats, independent of scheduled execution permissions.
    public var defaultChatAccessMode: AccessMode?
    /// Role defaults (`AgentRoleID`); nil falls back to the legacy access modes above.
    public var chatRoleID: String?
    public var jobRoleID: String?
    /// Folders outside the project a `developer` or `routine-operator` role may use; declared here, never by the agent.
    public var extraRoots: [AgentPermissionProfile.Root]?
    /// Sites a `routine-operator` job may import Chrome cookies for.
    public var cookieSites: [String]?
    /// Approved servers from the project's `.mcp.json`: name -> fingerprint of the approved entry (`ProjectMCPServers`).
    public var mcpServers: [String: String]?
    /// Sidebar visibility only; chats, permissions and scheduled work are retained.
    public var hidden: Bool?
    public var isHidden: Bool { hidden == true }
    public init(path: String) {
        self.id = UUID(); self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.name = URL(fileURLWithPath: path).lastPathComponent
    }
}
public enum AccessMode: String, Codable, CaseIterable, Sendable {
    case standard, fullAccess

    public var title: String { self == .fullAccess ? L10n.text("Полный доступ", "Full access") : L10n.text("С подтверждениями", "Ask for approval") }

}
public struct Chat: Identifiable, Codable, Hashable, Sendable {
    /// App identity; never pass this value directly to an engine.
    public var conversationID: ConversationID { ConversationID(id) }
    public var nativeSession: AgentSessionReference?
    public var handoffOrigin: HandoffProvenance?
    /// The latest completion remains unread until its transcript end is visible.
    public var unreadCompletionID: String?
    public var hasUnreadResponse: Bool { unreadCompletionID != nil }
    public var sidebarOrder: Int?
    public var pinned: Bool?
    public var isPinned: Bool { pinned == true }
    public var archived: Bool?
    public var isArchived: Bool { archived == true }
    public var route: RequestRoute?
    /// Read-only record of one Claude scheduled print run (the run ID). No engine session backs it:
    /// its transcript exists only in local history and it never dispatches or resumes work.
    public var scheduledRecord: UUID?
    public var isScheduledRecord: Bool { scheduledRecord != nil }
    public var id: String
    public var projectID: UUID
    public var title: String
    public var model: String
    public var effort: String?
    /// Missing legacy values do not inherit a folder-wide permission escalation.
    public var accessMode: AccessMode?
    /// Only an explicit true inherits; legacy records retain their stored permissions.
    public var inheritsProjectAccess: Bool?
    /// Explicit role (`AgentRoleID`); nil with `inheritsProjectAccess` follows the project, otherwise the legacy `accessMode`.
    public var roleID: String?
    /// Derived from the resolved role; kept for the phone protocol and older call sites.
    public func resolvedAccessMode(in project: Project, catalog: AgentRoleCatalog = AgentRoleCatalog()) -> AccessMode {
        resolvedRole(in: project, catalog: catalog).legacyAccessMode
    }
    public var updated: Date
    public init(id: String, projectID: UUID, title: String, model: String) {
        self.id = id; self.projectID = projectID; self.title = title; self.model = model; updated = Date()
        self.nativeSession = AgentSessionReference(connection: .originalCodex, nativeID: id)
    }
    public init(session: AgentSessionReference, projectID: UUID, title: String, model: String) {
        self.init(id: UUID().uuidString, projectID: projectID, title: title, model: model)
        nativeSession = session
    }
}
public struct QueuedMessage: Codable, Identifiable, Sendable, Equatable {
    /// `threadID` is the historical storage name for the app conversation key.
    public var conversationID: ConversationID { ConversationID(threadID) }
    public var id: String
    public var threadID: String
    public var projectID: UUID
    public var text: String
    public var model: String
    public var effort: String
    public init(id: String, threadID: String, projectID: UUID, text: String, model: String, effort: String) {
        self.id = id; self.threadID = threadID; self.projectID = projectID
        self.text = text; self.model = model; self.effort = effort
    }
}
public struct SavedState: Codable, Sendable {
    public var identityVersion: Int? = 2
    /// `model` and `defaultRoute` belong to this connection, never another engine.
    public var defaultConnection: AgentConnectionID? = .originalCodex
    public var claudeModel: String?
    /// Empty or absent keeps the CLI default reasoning effort.
    public var claudeEffort: String?
    public var browserEnabled: Bool?
    /// Absent means on: full-access Claude chats may use the user's Chrome via Claude in Chrome.
    public var userChromeEnabled: Bool?
    public var defaultRoute: RequestRoute?
    public var queuedMessages: [QueuedMessage]?
    /// Custom roles; presets always exist.
    public var roles: AgentRoleCatalog?
    /// Set once the legacy access modes were mapped to roles.
    public var roleMigration: RoleMigrationRecord?
    public var projects: [Project] = []
    public var chats: [Chat] = []
    public var model: String = ""
    public init() {}

    /// Move onto a project's position: before it when moving up, after it when moving down.
    @discardableResult public mutating func moveProject(_ id: UUID, to targetID: UUID) -> Bool {
        guard id != targetID,
              let source = projects.firstIndex(where: { $0.id == id }),
              let target = projects.firstIndex(where: { $0.id == targetID }) else { return false }
        let project = projects.remove(at: source)
        projects.insert(project, at: target)
        return true
    }

    public func orderedChats(projectID: UUID, archived: Bool) -> [Chat] {
        chats.filter { $0.projectID == projectID && $0.isArchived == archived }.sorted {
            switch ($0.sidebarOrder, $1.sidebarOrder) {
            case let (a?, b?) where a != b: return a < b
            case (nil, _?): return true // New chats appear above the saved order.
            case (_?, nil): return false
            default: return $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated
            }
        }
    }

    @discardableResult public mutating func moveChat(_ id: String, to targetID: String) -> Bool {
        guard id != targetID, let source = chats.first(where: { $0.id == id }),
              let target = chats.first(where: { $0.id == targetID }),
              source.projectID == target.projectID, source.isArchived == target.isArchived else { return false }
        var siblings = orderedChats(projectID: source.projectID, archived: source.isArchived)
        guard let from = siblings.firstIndex(where: { $0.id == id }),
              let to = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
        siblings.insert(siblings.remove(at: from), at: to)
        let ranks = Dictionary(uniqueKeysWithValues: siblings.enumerated().map { ($0.element.id, $0.offset) })
        for index in chats.indices {
            if let rank = ranks[chats[index].id] { chats[index].sidebarOrder = rank }
        }
        return true
    }

    @discardableResult public mutating func toggleChatPin(_ id: String) -> Bool {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return false }
        chats[index].pinned = !chats[index].isPinned
        return true
    }
}

public enum Locations {
    /// `SWITCHBOARD_DATA_ROOT` replaces the folder; the test runner sets it so tests never touch the user's data.
    public static var root: URL {
        if let override { return override }
        return applicationSupport.appendingPathComponent("Switchboard", isDirectory: true)
    }
    /// The data folder before the rename to Switchboard (2026-10-17). `LegacyDataMigration` moves it to `root`
    /// once and leaves a symbolic link here, so paths recorded in chats and other projects keep resolving.
    public static var legacyRoot: URL {
        if let override { return override.deletingLastPathComponent().appendingPathComponent("Context Desk", isDirectory: true) }
        return applicationSupport.appendingPathComponent("Context Desk", isDirectory: true)
    }
    private static var override: URL? {
        guard let path = ProcessInfo.processInfo.environment["SWITCHBOARD_DATA_ROOT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    public static var codexHome: URL { root.appendingPathComponent("codex", isDirectory: true) }
    public static var claudeHome: URL { root.appendingPathComponent("claude", isDirectory: true) }
    public static var automations: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/automations") }

}

extension ResponseTiming {
    public func label(language: AppLanguage = L10n.language) -> String {
        guard let elapsed = durationSeconds ?? startedAt.map({ completedAt.timeIntervalSince($0) }),
              elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else {
            return L10n.text("Работа завершена", "Work finished", language: language)
        }
        let duration = Self.duration(Int(elapsed), language: language)
        return L10n.text("Время работы: \(duration)", "Worked for \(duration)", language: language)
    }
    /// Compact elapsed time shared by finished responses and the live working row.
    public static func duration(_ seconds: Int, language: AppLanguage = L10n.language) -> String {
        seconds >= 60
            ? L10n.text("\(seconds / 60) мин \(seconds % 60) с", "\(seconds / 60)m \(seconds % 60)s", language: language)
            : L10n.text("\(seconds) с", "\(seconds)s", language: language)
    }
}
