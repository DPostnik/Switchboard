import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// Own mouse tracking instead of attaching a drag recognizer to a SwiftUI Button.
struct ProjectHeader<Content: View>: NSViewRepresentable {
    let project: Project
    let expanded: Bool
    let activate: () -> Void
    let move: (UUID) -> Bool
    let targeted: (Bool) -> Void
    /// The right-click menu, built when it opens; the same list as the row's "…" menu (`ProjectMenu.actions`).
    var actions: () -> [SidebarMenuAction] = { [] }
    /// Move up/down for VoiceOver, built when VoiceOver asks; sighted users reorder by dragging.
    var reorder: () -> [SidebarMenuAction] = { [] }
    var menuShown: (Bool) -> Void = { _ in }
    var hovered: (Bool) -> Void = { _ in }
    var pressed: (Bool) -> Void = { _ in }
    /// Extra tooltip lines under the path, such as the git status; the native view gets the tooltip, not its label.
    var details: String? = nil
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
        view.toolTip = [project.path, details].compactMap { $0 }.joined(separator: "\n")
        view.setAccessibilityHelp(details)
        view.activate = activate
        view.move = move
        view.targeted = targeted
        view.actions = actions
        view.reorder = reorder
        view.menuShown = menuShown
        view.hovered = hovered
        view.pressed = pressed
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(project.name)
        view.setAccessibilityValue(expanded ? L10n.text("Развёрнуто", "Expanded") : L10n.text("Свёрнуто", "Collapsed"))
    }
}

/// One project menu for the row's "…" button and its right-click menu, so both list the same items in the same order.
@MainActor enum ProjectMenu {
    static var hideTitle: String { L10n.text("Скрыть проект", "Hide project") }
    static var movedTitle: String { L10n.text("Папка переехала…", "Folder moved…") }
    static var movedHelp: String {
        L10n.text("Указать, где теперь папка проекта. Чаты продолжатся в ней; если там уже есть проект, они перейдут в него.",
                  "Choose where the project folder is now. The chats go on there; if a project already uses it, they move to that project.")
    }
    static var deleteTitle: String { L10n.text("Удалить проект…", "Delete project…") }
    static var deleteHelp: String {
        L10n.text("Чаты уйдут в архив, файлы останутся. Проект вернётся при восстановлении его чата.",
                  "The chats go to the archive and the files stay. The project comes back when one of its chats is restored.")
    }
    static var folderMissingHelp: String {
        L10n.text("Папка проекта не найдена. Если её переименовали или перенесли, выбери «Папка переехала…» в меню проекта.",
                  "The project folder was not found. If it was renamed or moved, choose Folder moved… in the project menu.")
    }
    static var removeHelp: String {
        L10n.text("Файлы и чаты сохранятся. Вернуть проект можно кнопкой скрытых проектов рядом с «Проекты».",
                  "Files and chats are kept. Show it again with the hidden projects button next to Projects.")
    }

    /// The hidden projects button's menu: one item per project, then "Show all" when there are several.
    static func hiddenActions(_ projects: [Project], show: @escaping (UUID) -> Void) -> [SidebarMenuAction] {
        var actions = projects.map { project in
            SidebarMenuAction(title: project.name, systemImage: "folder", help: project.path) { show(project.id) }
        }
        if projects.count > 1 {
            actions += [.separator, SidebarMenuAction(title: L10n.text("Показать все", "Show all"), systemImage: "eye") {
                projects.forEach { show($0.id) }
            }]
        }
        return actions
    }

    static func actions(path: String, hasChats: Bool, settings: @escaping () -> Void, newChat: @escaping () -> Void,
                        rename: @escaping () -> Void, selectAllChats: @escaping () -> Void,
                        remove: @escaping () -> Void, moved: @escaping () -> Void = {}, delete: @escaping () -> Void = {},
                        folderMissing: Bool = false) -> [SidebarMenuAction] {
        [
            SidebarMenuAction(title: L10n.text("Настройки проекта…", "Project settings…"), systemImage: "slider.horizontal.3", perform: settings),
            SidebarMenuAction(title: L10n.text("Новый чат", "New chat"), systemImage: "square.and.pencil", perform: newChat),
            .separator,
            SidebarMenuAction(title: L10n.text("Открыть в Finder", "Open in Finder"), systemImage: "folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            },
            SidebarMenuAction(title: EditorLauncher.openTitle, systemImage: "chevron.left.forwardslash.chevron.right",
                              enabled: EditorLauncher.preferred != nil) {
                EditorLauncher.open(path)
            },
            SidebarMenuAction(title: L10n.text("Скопировать путь", "Copy path"), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            SidebarMenuAction(title: L10n.text("Переименовать…", "Rename…"), systemImage: "pencil", perform: rename),
            SidebarMenuAction(title: L10n.text("Выделить все чаты", "Select all chats"), systemImage: "checkmark.circle",
                              enabled: hasChats, perform: selectAllChats),
            .separator,
            SidebarMenuAction(title: movedTitle, systemImage: folderMissing ? "exclamationmark.triangle" : "folder.badge.questionmark",
                              help: movedHelp, perform: moved),
            SidebarMenuAction(title: hideTitle, systemImage: "eye.slash",
                              help: removeHelp, perform: remove),
            SidebarMenuAction(title: deleteTitle, systemImage: "trash", help: deleteHelp, perform: delete),
        ]
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
    /// Reports when the pointer enters or leaves the row.
    var hovered: (Bool) -> Void = { _ in }
    /// Reports mouse-down until release or drag start, so the row darkens at once, as Finder rows do.
    var pressed: (Bool) -> Void = { _ in }
    var canDrag: Bool { true }
    /// Move up/down for VoiceOver; built only when VoiceOver reads the row's actions.
    var reorder: () -> [SidebarMenuAction] = { [] }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        SidebarMenuAction.accessibilityActions(reorder())
    }
    private var pressedEvent: NSEvent?
    private var startedDrag = false
    private var isHovered = false
    private var isPressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([dragType])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
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
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    // A row removed under the pointer gets no exit event.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false); setPressed(false) }
    }
    private func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value
        hovered(value)
    }
    private func setPressed(_ value: Bool) {
        guard value != isPressed else { return }
        isPressed = value
        pressed(value)
    }
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
        setPressed(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled, canDrag, let pressedEvent, !startedDrag else { return }
        let delta = NSPoint(x: event.locationInWindow.x - pressedEvent.locationInWindow.x,
                            y: event.locationInWindow.y - pressedEvent.locationInWindow.y)
        guard hypot(delta.x, delta.y) >= 4 else { return }
        startedDrag = true
        setPressed(false)
        startDrag(with: pressedEvent)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedEvent = nil; startedDrag = false; setPressed(false) }
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
    var actions: () -> [SidebarMenuAction] = { [] }
    static let pasteboardType = NSPasteboard.PasteboardType("local.daniil.switchboard.project-order")
    var projectID = UUID()
    var move: (UUID) -> Bool = { _ in false }
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
        SidebarMenuAction.menu(actions())
    }
}
