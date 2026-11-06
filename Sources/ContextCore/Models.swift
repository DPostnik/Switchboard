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
    /// Add-ons (`RoleAddOn` raw values; unknown ones are skipped) new chats get on top of the chat role; scheduled jobs never use them.
    public var chatRoleAddOns: [String]?
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
    /// Short line about the latest finished turn (`TurnRecap`), for the sidebar and notifications.
    public var recap: String?
    /// The latest turn ended with an error; cleared by the next successful turn.
    public var lastTurnFailed: Bool?
    /// The latest turn stopped on an exhausted usage limit; armed once the user asks to continue after the reset.
    public var limitResume: LimitResume?
    /// The user let this chat read the other chats through the chat directory tools.
    public var chatDirectoryAccess: Bool?
    /// A chat the archive opened to find other chats: its chat tools carry the search recipe.
    public var chatSearch: Bool?
    /// Started from the web client or brought back to it (`WebChats`); the web lists the chat while it stays active.
    public var webSince: Date?
    public var isWebVisible: Bool { WebChats.isVisible(updated: updated, webSince: webSince, archived: isArchived) }
    /// The git branch checked out in the project when the chat's latest turn started; nil outside a repository
    /// or on a detached HEAD.
    public var turnBranch: String?
    /// The chat works in its own git worktree instead of the project folder (`workingDirectory(in:)`); nil for the
    /// project folder.
    public var worktree: ChatWorktree?
    public var sidebarOrder: Int?
    public var pinned: Bool?
    public var isPinned: Bool { pinned == true }
    public var archived: Bool?
    public var isArchived: Bool { archived == true }
    /// True once the agent's own history file was reduced to headlines and metadata (`ActivityRetention`), so the
    /// launch cleanup skips the file without reading it; cleared when the chat leaves the archive.
    public var historyReduced: Bool?
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
    /// Add-ons on top of the role (`RoleAddOn`); nil follows the project's `chatRoleAddOns`.
    public var roleAddOns: [String]?
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
    /// Sent while the app was quitting, so nothing reached the agent; the next launch delivers it once the chat's agent is connected.
    public var heldForRestart: Bool?
    public init(id: String, threadID: String, projectID: UUID, text: String, model: String, effort: String) {
        self.id = id; self.threadID = threadID; self.projectID = projectID
        self.text = text; self.model = model; self.effort = effort
    }
}
public extension Array where Element == QueuedMessage {
    /// Moves a message to `position` among its own chat's messages; the drain sends each chat's first message next, so this
    /// is its delivery order. Other chats' messages keep their slots. `pinned` messages are already claimed for delivery:
    /// nil when one of them would move, or when the message is missing or already there.
    func movingQueued(_ id: String, toChatPosition position: Int, pinned: Set<String> = []) -> [QueuedMessage]? {
        guard let message = first(where: { $0.id == id }), !pinned.contains(id) else { return nil }
        let slots = indices.filter { self[$0].threadID == message.threadID }
        var chat = slots.map { self[$0] }
        guard let from = chat.firstIndex(where: { $0.id == id }) else { return nil }
        let to = Swift.min(Swift.max(position, 0), chat.count - 1)
        guard to != from else { return nil }
        chat.insert(chat.remove(at: from), at: to)
        // A claimed message keeps its place: nothing moves past it.
        for (offset, item) in chat.enumerated() where pinned.contains(item.id) {
            guard self[slots[offset]].id == item.id else { return nil }
        }
        var result = self
        for (slot, item) in zip(slots, chat) { result[slot] = item }
        return result
    }
}
public struct SavedState: Codable, Sendable {
    public var identityVersion: Int? = 2
    /// `model` and `defaultRoute` belong to this connection, never another engine.
    public var defaultConnection: AgentConnectionID? = .originalCodex
    public var claudeModel: String?
    /// Default model of new chats for agents whose models come from their sessions (Gemini CLI), by agent ID; absent or
    /// empty keeps the agent's own default. `model` stays the setting of the first agent with listed models.
    public var agentModels: [String: String]?
    /// Empty or absent keeps the CLI default reasoning effort.
    public var claudeEffort: String?
    /// Advisor for Claude chats on a weaker main model ("opus", "fable"); absent or empty runs without one.
    public var claudeAdvisor: String?
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
        Self.sidebarOrdered(chats.filter { $0.projectID == projectID && $0.isArchived == archived })
    }
    /// Sidebar order within a project: the saved order, new chats above it, the rest by last update.
    static func sidebarOrdered(_ chats: [Chat]) -> [Chat] {
        chats.sorted {
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
    /// Agents installed from the ACP agent catalog and the catalog cache (`AgentCatalogStore`, `AgentCatalogInstaller`).
    public static var agentsHome: URL { root.appendingPathComponent("agents", isDirectory: true) }
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
