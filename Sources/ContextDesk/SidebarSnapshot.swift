import Foundation
import SwiftUI
import ContextCore

/// What a sidebar chat row shows from the model besides the chat itself.
struct SidebarChatRow: Equatable, Identifiable {
    let chat: Chat
    var id: String { chat.id }
    let busy: Bool
    let pending: Bool
    let restartWaiting: Bool
    let browserOpen: Bool
    /// Being deleted, archived or reconfigured: the row is disabled.
    let changing: Bool
    /// The folder the chat works in, for the branch it left (`GitStatusStore.branchChange`).
    let workingDirectory: String?
    /// Favorites name their project.
    let projectName: String?
    let projectPath: String?
}

/// A project of the sidebar list with its shown chat rows.
struct SidebarProjectRow: Equatable, Identifiable {
    let project: Project
    var id: UUID { project.id }
    let expanded: Bool
    /// Rows under the header (`SidebarSection.limit`) and the project's chats in the list; the rest waits behind "Show more".
    let limit: Int
    let total: Int
    let rows: [SidebarChatRow]
    let hasChats: Bool
    /// A chat waits for an action or for the app restart (amber dot).
    let waiting: Bool
    let unread: Bool
    /// The project's folder is gone (`DeskModel.projectFolderMissing`).
    let missing: Bool
}

/// Everything the sidebar's project and chat list reads from the model, as values. `DeskView` builds it on each
/// publication and the list renders only from it (`SidebarRowsList`), so a publication that changes none of it, such as a
/// chat being opened elsewhere in the window or the composer's state, skips the whole list instead of re-rendering every
/// row and project header. Git, pull request and background wait badges come from Observation stores the rows read
/// directly; they refresh the rows on their own.
struct SidebarSnapshot: Equatable {
    var hasFavorites = false
    var favorites: [SidebarChatRow] = []
    var projects: [SidebarProjectRow] = []
    var matching = 0
    var hidden = 0
    /// Projects the user hid from the list; the button next to "Projects" shows them again.
    var hiddenProjects: [Project] = []
    var chatID: String?
    var projectID: UUID?
    /// The schedule, "Needs you" or archive page is open: no chat or project row is selected.
    var pageOpen = false
}

/// The list's own interaction state from `DeskView`, compared with the snapshot.
struct SidebarListState: Equatable {
    var selection = ChatSelection()
    var menuRowID: String?
    var dropTargetProjectID: UUID?
    var dropTargetChatID: String?
    var pressedRowID: String?
    var searching = false
    var reduceMotion = false
}

/// Renders `content` only when the snapshot or the list state changed; the content closure must read nothing else that
/// `ObservableObject`s publish (Observation stores are fine: their reads are tracked by this view).
struct SidebarRowsList<Content: View>: View, Equatable {
    let snapshot: SidebarSnapshot
    let state: SidebarListState
    @ViewBuilder let content: (SidebarSnapshot, SidebarListState) -> Content
    var body: some View { content(snapshot, state) }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot && lhs.state == rhs.state }
}

extension DeskModel {
    func sidebarSnapshot(_ listing: SidebarListing) -> SidebarSnapshot {
        let pendingChats = Set(pending.map(\.threadID)), restartWaiting = Set(restartWaitingChatIDs)
        func row(_ chat: Chat, favorite: Bool) -> SidebarChatRow {
            let project = favorite ? project(chat.projectID) : nil
            return SidebarChatRow(chat: chat, busy: isBusy(threadID: chat.id), pending: pendingChats.contains(chat.id),
                                  restartWaiting: restartWaiting.contains(chat.id), browserOpen: runningBrowserChats[chat.id] != nil,
                                  changing: isChangingChat(chat.id), workingDirectory: favorite ? nil : workingDirectory(forChat: chat.id),
                                  projectName: project?.name, projectPath: project?.path)
        }
        var snapshot = SidebarSnapshot()
        let pinned = state.visiblePinnedChats
        snapshot.hasFavorites = !pinned.isEmpty
        snapshot.favorites = pinned.filter { state.sidebarShowsFavorite($0, search: listing.search) }.map { row($0, favorite: true) }
        let listed = sidebarSections(listing)
        snapshot.matching = listed.matching; snapshot.hidden = listed.hidden
        let byProject = activeChatsByProject
        snapshot.projects = listed.sections.map { section in
            let chats = byProject[section.project.id] ?? []
            return SidebarProjectRow(project: section.project, expanded: section.expanded, limit: section.limit, total: section.chats.count,
                                     rows: section.chats.prefix(section.limit).map { row($0, favorite: false) }, hasChats: !chats.isEmpty,
                                     waiting: chats.contains { pendingChats.contains($0.id) || restartWaiting.contains($0.id) },
                                     unread: chats.contains(where: \.hasUnreadResponse), missing: projectFolderMissing(section.project))
        }
        snapshot.hiddenProjects = state.hiddenProjects
        snapshot.chatID = chatID; snapshot.projectID = projectID
        snapshot.pageOpen = showingJobs || showingAttention || showingArchive
        return snapshot
    }

    /// The idle chat's background wait line (`backgroundWaitNotice`) from a known busy flag.
    static func backgroundWaitText(_ count: Int) -> String {
        L10n.text("Агент ждёт фоновые задачи (\(count)) и продолжит сам, когда они завершатся. Писать можно как обычно.",
                  "The agent is waiting for background tasks (\(count)) and will continue on its own when they finish. You can still write as usual.")
    }
}
