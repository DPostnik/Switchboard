import AppKit
import Combine
import ContextCore
import ContextTranscript
import SwiftUI

/// Keyboard navigation shared by the menu commands, the command palette and the window: whether the palette is open,
/// the sidebar's visible list for the chat shortcuts, and requests for sheets and popovers that `DeskView` owns.
@MainActor final class DeskNavigation: ObservableObject {
    @Published var paletteShown = false
    /// Mirrored by `DeskView`; not published, so the sidebar's own changes re-render nothing else.
    var sidebar = SidebarListing()
    let requests = PassthroughSubject<DeskViewRequest, Never>()
}

/// Something only the window can show: the usage popover in the sidebar dock or a project's settings sheet.
enum DeskViewRequest {
    case usage
    case projectSettings(UUID)
}

extension DeskModel {
    /// The Schedule page from the sidebar dock.
    func openSchedule() {
        showingArchive = false; showingAttention = false; showingJobs = true
        Task { await refreshJobs() }
    }

    /// True while a page (archive, schedule, needs you) covers the chat.
    private var showingPage: Bool { showingArchive || showingJobs || showingAttention }

    /// Cmd+1…9: the N-th chat row of the sidebar as it is shown, favorites first.
    func openSidebarChat(number: Int) {
        let rows = state.sidebarChatRows(navigation.sidebar)
        guard number >= 1, rows.indices.contains(number - 1) else { return }
        openChatFromKeyboard(rows[number - 1])
    }

    /// Previous or next chat in sidebar order, wrapping at the ends.
    func openAdjacentChat(offset: Int) {
        let current = showingPage ? nil : chatID
        guard let id = state.adjacentSidebarChat(from: current, offset: offset, listing: navigation.sidebar) else { return }
        openChatFromKeyboard(id)
    }

    private func openChatFromKeyboard(_ id: String) {
        guard let chat = state.chats.first(where: { $0.id == id }) else { return }
        if chatID == id && !showingPage { return }
        Task { await openChat(chat) }
    }

    /// Cmd+F: the find bar of the focused document preview or of the open chat.
    static func showFind() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let target = TranscriptScrollView.findTarget(in: window) { target.showFind() } else { NSSound.beep() }
    }
}

/// The Go menu: command palette, previous/next chat and chats by sidebar position. Menu items show the shortcuts.
struct NavigationCommands: View {
    let model: DeskModel
    @ObservedObject var menu: AppMenuState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L10n.text("Палитра команд…", "Command Palette…")) {
            // The palette lives in the main window; after Cmd+W this brings the window back first.
            openWindow(id: "main")
            model.navigation.paletteShown.toggle()
        }
        .keyboardShortcut("k", modifiers: .command).disabled(!menu.ready)
        Divider()
        // "{" and "}" are what Shift+[ and Shift+] type; AppKit matches the typed character, shown as ⇧⌘[ and ⇧⌘].
        Button(L10n.text("Предыдущий чат", "Previous Chat")) { model.openAdjacentChat(offset: -1) }
            .keyboardShortcut("{", modifiers: .command).disabled(!menu.ready)
        Button(L10n.text("Следующий чат", "Next Chat")) { model.openAdjacentChat(offset: 1) }
            .keyboardShortcut("}", modifiers: .command).disabled(!menu.ready)
        Menu(L10n.text("Чат по номеру в списке", "Chat by Sidebar Position")) {
            ForEach(1...9, id: \.self) { number in
                Button(L10n.text("Чат \(number)", "Chat \(number)")) { model.openSidebarChat(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }.disabled(!menu.ready)
    }
}

/// Edit menu: Cmd+F searches the conversation (or the focused document preview).
struct FindCommand: View {
    var body: some View {
        Button(L10n.text("Найти…", "Find…")) { DeskModel.showFind() }
            .keyboardShortcut("f", modifiers: .command)
    }
}
