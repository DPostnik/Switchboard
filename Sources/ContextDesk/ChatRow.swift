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
    let actions: [ChatRowAction]
    /// Favorites only open the chat: no reordering or multi-selection.
    var favorite = false
    var menuShown: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ChatRowView {
        ChatRowView()
    }
    func updateNSView(_ view: ChatRowView, context: Context) {
        view.chatID = chat.id
        view.projectID = chat.projectID
        view.archived = chat.isArchived
        view.title = chat.title
        view.toolTip = chat.title
        view.isInteractionEnabled = enabled
        view.activate = activate
        view.select = select
        view.move = move
        view.targeted = targeted
        view.actions = actions
        view.favorite = favorite
        view.menuShown = menuShown
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(chat.title)
        view.setAccessibilityEnabled(enabled)
    }
}

enum ChatRowSelection { case toggle, extend }

struct ChatRowAction {
    let title: String
    var enabled = true
    let perform: () -> Void
}

final class ChatRowView: SidebarRowView {
    static let pasteboardType = NSPasteboard.PasteboardType("local.daniil.switchboard.chat-order")
    var chatID = ""
    var projectID = UUID()
    var archived = false
    var move: (String) -> Bool = { _ in false }
    var select: (ChatRowSelection) -> Void = { _ in }
    var actions: [ChatRowAction] = []
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
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions { menu.addItem(ChatActionMenuItem(action)) }
        return menu
    }
}

private final class ChatActionMenuItem: NSMenuItem {
    private let callback: () -> Void
    init(_ action: ChatRowAction) {
        callback = action.perform
        super.init(title: action.title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = action.enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { callback() }
}
