import AppKit
import SwiftUI
import ContextCore

/// Own mouse tracking instead of attaching a drag recognizer to a SwiftUI Button.
struct ProjectHeader<Content: View>: NSViewRepresentable {
    let project: Project
    let expanded: Bool
    let activate: () -> Void
    let move: (UUID) -> Bool
    let targeted: (Bool) -> Void
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    var remove: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    var menuShown: (Bool) -> Void = { _ in }
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ProjectHeaderView {
        let view = ProjectHeaderView()
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    func updateNSView(_ view: ProjectHeaderView, context: Context) {
        (view.subviews.first as? NSHostingView<Content>)?.rootView = content
        view.projectID = project.id
        view.title = project.name
        view.toolTip = project.path
        view.activate = activate
        view.move = move
        view.targeted = targeted
        view.moveUp = moveUp
        view.moveDown = moveDown
        view.remove = remove
        view.rename = rename
        view.menuShown = menuShown
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(project.name)
        view.setAccessibilityValue(expanded ? L10n.text("Развёрнуто", "Expanded") : L10n.text("Свёрнуто", "Collapsed"))
    }
}

class SidebarRowView: NSView, NSDraggingSource {
    var dragType: NSPasteboard.PasteboardType { .init("local.daniil.switchboard.sidebar-row") }
    var dragID: String { "" }
    var dragGroup: String { "" }
    var isInteractionEnabled = true {
        didSet {
            if oldValue != isInteractionEnabled { window?.invalidateCursorRects(for: self) }
        }
    }
    func performMove(from source: SidebarRowView) -> Bool { false }
    var title = ""
    var activate: () -> Void = {}
    var targeted: (Bool) -> Void = { _ in }
    /// Reports while this row's context menu is open, so the row can show which item the menu acts on.
    var menuShown: (Bool) -> Void = { _ in }
    var canDrag: Bool { true }
    private var pressedEvent: NSEvent?
    private var startedDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([dragType])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The label is display-only: mouse events must reach this tracking view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isInteractionEnabled && !visibleRect.isEmpty {
            addCursorRect(visibleRect, cursor: .pointingHand)
        }
    }
    override func accessibilityPerformPress() -> Bool { guard isInteractionEnabled else { return false }; activate(); return true }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menuShown(true)
    }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        menuShown(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        pressedEvent = event
        startedDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled, canDrag, let pressedEvent, !startedDrag else { return }
        let delta = NSPoint(x: event.locationInWindow.x - pressedEvent.locationInWindow.x,
                            y: event.locationInWindow.y - pressedEvent.locationInWindow.y)
        guard hypot(delta.x, delta.y) >= 4 else { return }
        startedDrag = true
        startDrag(with: pressedEvent)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedEvent = nil; startedDrag = false }
        guard isInteractionEnabled, pressedEvent != nil, !startedDrag,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        click(modifiers: event.modifierFlags)
    }
    func click(modifiers: NSEvent.ModifierFlags) { activate() }
    func startDrag(with event: NSEvent) {
        let payload = NSPasteboardItem()
        payload.setString(dragID, forType: dragType)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        (title as NSString).draw(at: NSPoint(x: 12, y: max(0, bounds.midY - 8)),
                                withAttributes: [.font: NSFont.systemFont(ofSize: InterfaceZoom.shared.scaled(13)), .foregroundColor: NSColor.labelColor])
        image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pressedEvent = nil
        startedDrag = false
        targeted(false)
    }

    func acceptedSource(_ source: Any?, pasteboard: NSPasteboard) -> SidebarRowView? {
        guard isInteractionEnabled, let source = source as? SidebarRowView, source.isInteractionEnabled,
              let window, source.window === window, source.dragType == dragType,
              source.dragGroup == dragGroup, source.dragID != dragID,
              pasteboard.pasteboardItems?.count == 1,
              pasteboard.string(forType: dragType) == source.dragID else { return nil }
        return source
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let valid = acceptedSource(sender.draggingSource, pasteboard: sender.draggingPasteboard) != nil
        targeted(valid)
        return valid ? .move : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptedSource(sender.draggingSource, pasteboard: sender.draggingPasteboard) != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        targeted(false)
        guard let source = acceptedSource(sender.draggingSource, pasteboard: sender.draggingPasteboard) else { return false }
        return performMove(from: source)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { targeted(false) }

}

class ProjectHeaderView: SidebarRowView {
    var remove: (() -> Void)?
    var rename: (() -> Void)?
    static let pasteboardType = NSPasteboard.PasteboardType("local.daniil.switchboard.project-order")
    var projectID = UUID()
    var move: (UUID) -> Bool = { _ in false }
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    override var dragType: NSPasteboard.PasteboardType { Self.pasteboardType }
    override var dragID: String { projectID.uuidString }
    override var dragGroup: String { "projects" }
    func sourceID(_ source: Any?, pasteboard: NSPasteboard) -> UUID? {
        (acceptedSource(source, pasteboard: pasteboard) as? ProjectHeaderView)?.projectID
    }
    override func performMove(from source: SidebarRowView) -> Bool {
        guard let source = source as? ProjectHeaderView else { return false }
        return move(source.projectID)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let renameItem = menu.addItem(withTitle: L10n.text("Переименовать…", "Rename…"), action: #selector(performRename), keyEquivalent: "")
        renameItem.target = self; renameItem.isEnabled = rename != nil
        menu.addItem(.separator())
        let up = menu.addItem(withTitle: L10n.text("Переместить выше", "Move up"), action: #selector(performMoveUp), keyEquivalent: "")
        up.target = self; up.isEnabled = moveUp != nil
        let down = menu.addItem(withTitle: L10n.text("Переместить ниже", "Move down"), action: #selector(performMoveDown), keyEquivalent: "")
        down.target = self; down.isEnabled = moveDown != nil
        menu.addItem(.separator())
        let removeItem = menu.addItem(withTitle: L10n.text("Убрать проект из списка", "Remove project from list"), action: #selector(performRemove), keyEquivalent: "")
        removeItem.target = self; removeItem.isEnabled = remove != nil
        removeItem.toolTip = L10n.text("Файлы и чаты сохранятся. Вернуть проект можно через «Добавить проект».", "Files and chats are kept. Restore it with Add project.")
        return menu
    }
    @objc private func performMoveUp() { moveUp?() }
    @objc private func performMoveDown() { moveDown?() }
    @objc private func performRemove() { remove?() }
    @objc private func performRename() { rename?() }
}
