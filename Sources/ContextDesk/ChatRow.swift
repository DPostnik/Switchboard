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
    /// The right-click menu, built when it opens: building every row's menu on every render cost more than the rows.
    let actions: () -> [SidebarMenuAction]
    /// Move up/down for VoiceOver, built when VoiceOver asks; sighted users reorder by dragging.
    var reorder: () -> [SidebarMenuAction] = { [] }
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
        view.reorder = reorder
        view.favorite = favorite
        view.menuShown = menuShown
        view.hovered = hovered
        view.pressed = pressed
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(chat.title)
        view.setAccessibilityEnabled(enabled)
    }
}

enum ChatRowSelection { case toggle, extend }

/// One item of a sidebar row's menu: an action, a separator or a submenu (`children`).
/// The same list feeds the native right-click menu and, for projects, the "…" button (`SidebarMenuButton`).
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
                item.image = action.systemImage.flatMap { symbol($0) }
                item.submenu = Self.menu(action.children)
                menu.addItem(item)
            } else {
                menu.addItem(SidebarMenuActionItem(action))
            }
        }
        return menu
    }

    @MainActor private static var symbols: [String: NSImage] = [:]
    /// Menu icons by symbol name; looking a symbol up took most of a project menu's build time.
    @MainActor static func symbol(_ name: String) -> NSImage? {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbols[name] = image
        return image
    }

    /// Pops the menu under `view`, as a pull-down button does.
    @MainActor static func popUp(_ actions: [SidebarMenuAction], below view: NSView) {
        guard !actions.isEmpty else { return }
        let menu = menu(actions)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }

    /// Enabled plain actions as VoiceOver custom actions.
    @MainActor static func accessibilityActions(_ actions: [SidebarMenuAction]) -> [NSAccessibilityCustomAction] {
        actions.filter { $0.enabled && !$0.isSeparator && $0.children.isEmpty }.map { action in
            NSAccessibilityCustomAction(name: action.title) { action.perform(); return true }
        }
    }
}

/// A "…" button whose menu is built when it is clicked, from the same list as the row's right-click menu.
struct SidebarMenuButton<Label: View>: View {
    let actions: () -> [SidebarMenuAction]
    var menuShown: (Bool) -> Void = { _ in }
    @ViewBuilder var label: Label
    @State private var anchor = SidebarMenuAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            menuShown(true)
            SidebarMenuAction.popUp(actions(), below: view)
            menuShown(false)
        } label: { label }
        .buttonStyle(PointerButtonStyle(base: .plain))
        .background(SidebarMenuAnchorView(anchor: anchor))
    }
}

final class SidebarMenuAnchor {
    weak var view: NSView?
}

private struct SidebarMenuAnchorView: NSViewRepresentable {
    let anchor: SidebarMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

final class ChatRowView: SidebarRowView {
    static let pasteboardType = NSPasteboard.PasteboardType("local.daniil.switchboard.chat-order")
    var chatID = ""
    var projectID = UUID()
    var archived = false
    var move: (String) -> Bool = { _ in false }
    var select: (ChatRowSelection) -> Void = { _ in }
    var actions: () -> [SidebarMenuAction] = { [] }
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
        return SidebarMenuAction.menu(actions())
    }
}

private final class SidebarMenuActionItem: NSMenuItem {
    private let callback: () -> Void
    @MainActor init(_ action: SidebarMenuAction) {
        callback = action.perform
        super.init(title: action.title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = action.enabled
        image = action.systemImage.flatMap { SidebarMenuAction.symbol($0) }
        toolTip = action.help
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { callback() }
}
