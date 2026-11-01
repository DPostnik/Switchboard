import AppKit
import SwiftUI
import ContextCore

/// Transparent native interaction surface; SwiftUI owns the visible label and its size.
struct ChatRow: NSViewRepresentable {
    let chat: Chat
    let enabled: Bool
    let activate: () -> Void
    var select: (ChatRowSelection) -> Void = { _ in }
    let move: (String) -> Bool
    let targeted: (Bool) -> Void
    let actions: [SidebarMenuAction]
    /// Move up/down for VoiceOver; sighted users reorder by dragging.
    var reorder: [SidebarMenuAction] = []
    /// Favorites only open the chat: no reordering or multi-selection.
    var favorite = false
    var menuShown: (Bool) -> Void = { _ in }
    var hovered: (Bool) -> Void = { _ in }
    var pressed: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ChatRowView {
        ChatRowView()
    }
    func updateNSView(_ view: ChatRowView, context: Context) {
        view.chatID = chat.id
        view.projectID = chat.projectID
        view.archived = chat.isArchived
        view.title = chat.title
        view.toolTip = chat.worktree.map { chat.title + "\n" + WorktreeText.tooltip($0) } ?? chat.title
        view.isInteractionEnabled = enabled
        view.activate = activate
        view.select = select
        view.move = move
        view.targeted = targeted
        view.actions = actions
        view.favorite = favorite
        view.menuShown = menuShown
        view.hovered = hovered
        view.pressed = pressed
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(chat.title)
        view.setAccessibilityEnabled(enabled)
        view.setAccessibilityCustomActions(SidebarMenuAction.accessibilityActions(reorder))
    }
}

enum ChatRowSelection { case toggle, extend }

/// One item of a sidebar row's menu: an action, a separator or a submenu (`children`).
/// The same list feeds the native right-click menu and, for projects, the SwiftUI "…" menu.
struct SidebarMenuAction {
    let title: String
    var systemImage: String? = nil
    var enabled = true
    var help: String? = nil
    var children: [SidebarMenuAction] = []
    var isSeparator = false
    let perform: () -> Void

    static var separator: SidebarMenuAction { SidebarMenuAction(title: "", isSeparator: true) {} }
    static func submenu(_ title: String, _ children: [SidebarMenuAction]) -> SidebarMenuAction {
        SidebarMenuAction(title: title, children: children) {}
    }

    @MainActor static func menu(_ actions: [SidebarMenuAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            if action.isSeparator {
                menu.addItem(.separator())
            } else if !action.children.isEmpty {
                let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                item.image = action.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                item.submenu = Self.menu(action.children)
                menu.addItem(item)
            } else {
                menu.addItem(SidebarMenuActionItem(action))
            }
        }
        return menu
    }

    /// Enabled plain actions as VoiceOver custom actions.
    @MainActor static func accessibilityActions(_ actions: [SidebarMenuAction]) -> [NSAccessibilityCustomAction] {
        actions.filter { $0.enabled && !$0.isSeparator && $0.children.isEmpty }.map { action in
            NSAccessibilityCustomAction(name: action.title) { action.perform(); return true }
        }
    }
}

/// SwiftUI rendering of a `SidebarMenuAction` list, for `Menu` content.
struct SidebarMenuItems: View {
    let actions: [SidebarMenuAction]
    var body: some View {
        ForEach(actions.indices, id: \.self) { index in
            let action = actions[index]
            if action.isSeparator {
                Divider()
            } else if !action.children.isEmpty {
                Menu(action.title) { SidebarMenuItems(actions: action.children) }
            } else if let help = action.help {
                button(action).help(help)
            } else {
                button(action)
            }
        }
    }
    private func button(_ action: SidebarMenuAction) -> some View {
        Button(action: action.perform) {
            if let icon = action.systemImage { Label(action.title, systemImage: icon) } else { Text(action.title) }
        }.disabled(!action.enabled)
    }
}

final class ChatRowView: SidebarRowView {
    static let pasteboardType = NSPasteboard.PasteboardType("local.daniil.switchboard.chat-order")
    var chatID = ""
    var projectID = UUID()
    var archived = false
    var move: (String) -> Bool = { _ in false }
    var select: (ChatRowSelection) -> Void = { _ in }
    var actions: [SidebarMenuAction] = []
    var favorite = false
    override var dragType: NSPasteboard.PasteboardType { Self.pasteboardType }
    override var dragID: String { chatID }
    override var dragGroup: String { favorite ? "favorites" : projectID.uuidString + (archived ? ":archive" : ":active") }
    override var canDrag: Bool { !favorite }
    override func performMove(from source: SidebarRowView) -> Bool {
        guard !favorite, let source = source as? ChatRowView else { return false }
        return move(source.chatID)
    }
    override func click(modifiers: NSEvent.ModifierFlags) {
        if favorite { activate() }
        else if modifiers.contains(.command) { select(.toggle) }
        else if modifiers.contains(.shift) { select(.extend) }
        else { activate() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isInteractionEnabled else { return nil }
        return SidebarMenuAction.menu(actions)
    }
}

private final class SidebarMenuActionItem: NSMenuItem {
    private let callback: () -> Void
    init(_ action: SidebarMenuAction) {
        callback = action.perform
        super.init(title: action.title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = action.enabled
        image = action.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        toolTip = action.help
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { callback() }
}
