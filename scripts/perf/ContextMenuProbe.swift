// Standalone context-menu cost probe. Self-contained (AppKit + SwiftUI only): it mirrors the menu patterns in
// Sources/ instead of linking the app, so it builds in seconds and never touches the app's build directory.
// Build and run through scripts/perf/profile-context-menus.py. Writes JSON to $SWITCHBOARD_MENU_REPORT.
//
// Mirrors (keep in sync when those files change):
//   SidebarMenuAction / SidebarMenuAction.menu       Sources/ContextDesk/ChatRow.swift:53-91, 146-158
//   chatActions / chatReorderActions                  Sources/ContextDesk/DeskView.swift:479-532
//   AppState.orderedChats                             Sources/ContextCore/Models.swift:169-178
//   DeskModel.canDeleteChat                           Sources/ContextDesk/DeskModel.swift:1095-1099
//   ProjectMenu.actions / "…" Menu                    Sources/ContextDesk/ProjectHeader.swift:65-90, DeskView.swift:390-400
//   SwiftUI .contextMenu rows                         ChatFilesView.swift:401,461,830; TurnChangesView.swift:356,393; ProjectFilesView.swift:213
//   transcript textView(_:menu:for:at:)               Sources/ContextTranscript/NativeTranscript.swift:1274-1345
import AppKit
import SwiftUI
import Darwin

// MARK: - Timing

@inline(__always) func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
@inline(__always) func wall() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
struct Sample { var wallMs: Double; var cpuMs: Double }
@MainActor func measure(_ body: () -> Void) -> Sample {
    let w = wall(), c = threadCPU()
    body()
    return Sample(wallMs: Double(wall() - w) / 1e6, cpuMs: Double(threadCPU() - c) / 1e6)
}
func median(_ values: [Double]) -> Double { let s = values.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

@MainActor enum Counters {
    static var rowBodies = 0
    static var menuClosures = 0      // .contextMenu { } content closure evaluations
    static var buttonMenuClosures = 0 // Menu { } (the "…" button) content closure evaluations
    static var eagerActionBuilds = 0 // [SidebarMenuAction] arrays built in body
    static func reset() { rowBodies = 0; menuClosures = 0; buttonMenuClosures = 0; eagerActionBuilds = 0 }
}

// MARK: - Mirrors of app types

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
            if action.isSeparator { menu.addItem(.separator()) }
            else if !action.children.isEmpty {
                let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                item.image = action.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                item.submenu = Self.menu(action.children)
                menu.addItem(item)
            } else { menu.addItem(ActionItem(action)) }
        }
        return menu
    }
    @MainActor static func accessibilityActions(_ actions: [SidebarMenuAction]) -> [NSAccessibilityCustomAction] {
        actions.filter { $0.enabled && !$0.isSeparator && $0.children.isEmpty }.map { action in
            NSAccessibilityCustomAction(name: action.title) { action.perform(); return true }
        }
    }
}
final class ActionItem: NSMenuItem {
    private let callback: () -> Void
    init(_ action: SidebarMenuAction) {
        callback = action.perform
        super.init(title: action.title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = action.enabled
        image = action.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        toolTip = action.help
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { callback() }
}

let russian = ProcessInfo.processInfo.environment["PROBE_LANG"] != "en"
@inline(__always) func text(_ ru: String, _ en: String) -> String { russian ? ru : en }

struct ProbeChat: Identifiable, Equatable {
    let id: String; let projectID: Int; let title: String; let updated: Date
    var sidebarOrder: Int?; var isArchived: Bool; var isPinned: Bool; var worktreePath: String?
}
struct ProbePending { let threadID: String }

@MainActor final class ProbeModel: ObservableObject {
    @Published var tick = 0
    var chats: [ProbeChat] = []
    var projects: [Int] = []
    var pending: [ProbePending] = (0..<3).map { ProbePending(threadID: "none-\($0)") }
    var runningBrowserChats: [String: Int32] = [:]
    var changing: Set<String> = []
    init(chats count: Int, projects: Int) {
        self.projects = Array(0..<projects)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        chats = (0..<count).map { i in
            ProbeChat(id: "chat-\(i)-" + String(repeating: "x", count: 20), projectID: i % projects,
                      title: "Чат номер \(i) с длинным заголовком", updated: base.addingTimeInterval(Double(-i * 37)),
                      sidebarOrder: i % 3 == 0 ? nil : i, isArchived: i % 4 == 3, isPinned: i % 50 == 0,
                      worktreePath: i % 7 == 0 ? "/tmp/worktrees/\(i)" : nil)
        }
    }
    func orderedChats(projectID: Int, archived: Bool) -> [ProbeChat] {
        chats.filter { $0.projectID == projectID && $0.isArchived == archived }.sorted {
            switch ($0.sidebarOrder, $1.sidebarOrder) {
            case let (a?, b?) where a != b: return a < b
            case (nil, _?): return true
            case (_?, nil): return false
            default: return $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated
            }
        }
    }
    func isChangingChat(_ id: String) -> Bool { changing.contains(id) }
    func canDeleteChat(_ id: String) -> Bool {
        chats.contains(where: { $0.id == id }) && !isChangingChat(id) && !pending.contains(where: { $0.threadID == id })
    }
    /// DeskView.chatActions mirror.
    func chatActions(_ chat: ProbeChat) -> [SidebarMenuAction] {
        Counters.eagerActionBuilds += 1
        var actions: [SidebarMenuAction] = []
        if runningBrowserChats[chat.id] != nil {
            actions += [SidebarMenuAction(title: text("Показать браузер этого чата", "Show this chat’s browser")) {}, .separator]
        }
        actions += [
            SidebarMenuAction(title: chat.isPinned ? text("Открепить из избранного", "Unpin from favorites") : text("Закрепить в избранном", "Pin to favorites")) { _ = chat },
            SidebarMenuAction(title: text("Переименовать…", "Rename…")) { _ = chat },
            SidebarMenuAction(title: chat.isArchived ? text("Восстановить из архива", "Restore from archive") : text("Архивировать", "Archive"), enabled: canDeleteChat(chat.id)) { _ = chat },
            SidebarMenuAction(title: text("Удалить чат…", "Delete chat…"), enabled: canDeleteChat(chat.id)) { _ = chat },
            .separator
        ]
        if let path = chat.worktreePath {
            actions += [SidebarMenuAction(title: text("Открыть worktree в Finder", "Show worktree in Finder"), help: path) {},
                        SidebarMenuAction(title: text("Скопировать путь", "Copy path"), help: path) {}, .separator]
        }
        let agents = [
            SidebarMenuAction(title: text("Скопировать ID чата", "Copy chat ID")) { _ = chat.id },
            SidebarMenuAction(title: text("Скопировать ссылку на чат для агента", "Copy chat reference for an agent")) { _ = chat },
            SidebarMenuAction(title: text("Дать доступ к другим чатам", "Give access to other chats")) { _ = chat.id },
        ]
        actions.append(.submenu(text("Для агентов", "For agents"), agents))
        return actions
    }
    /// DeskView.chatReorderActions mirror: one orderedChats (filter all chats + sort the project's) per row.
    func chatReorderActions(_ chat: ProbeChat) -> [SidebarMenuAction] {
        let siblings = orderedChats(projectID: chat.projectID, archived: chat.isArchived)
        guard let index = siblings.firstIndex(where: { $0.id == chat.id }) else { return [] }
        return [(-1, text("Переместить выше", "Move up")), (1, text("Переместить ниже", "Move down"))].compactMap { offset, title in
            guard siblings.indices.contains(index + offset) else { return nil }
            let target = siblings[index + offset].id
            return SidebarMenuAction(title: title) { _ = target }
        }
    }
    /// ProjectMenu.actions mirror (with the per-call UserDefaults read of EditorLauncher.preferred).
    func projectActions(_ project: Int) -> [SidebarMenuAction] {
        Counters.eagerActionBuilds += 1
        let hasChats = chats.contains { $0.projectID == project && !$0.isArchived }
        let preferred = UserDefaults.standard.string(forKey: "probe.preferredEditor")
        let enabled = UserDefaults.standard.string(forKey: "probe.preferredEditor") != nil || true
        return [
            SidebarMenuAction(title: text("Настройки проекта…", "Project settings…"), systemImage: "slider.horizontal.3") {},
            SidebarMenuAction(title: text("Новый чат", "New chat"), systemImage: "square.and.pencil") {},
            .separator,
            SidebarMenuAction(title: text("Открыть в Finder", "Open in Finder"), systemImage: "folder") {},
            SidebarMenuAction(title: text("Открыть в \(preferred ?? "VS Code")", "Open in \(preferred ?? "VS Code")"),
                              systemImage: "chevron.left.forwardslash.chevron.right", enabled: enabled) {},
            SidebarMenuAction(title: text("Скопировать путь", "Copy path"), systemImage: "doc.on.doc") {},
            SidebarMenuAction(title: text("Переименовать…", "Rename…"), systemImage: "pencil") {},
            SidebarMenuAction(title: text("Выделить все чаты", "Select all chats"), systemImage: "checkmark.circle", enabled: hasChats) {
                _ = self.orderedChats(projectID: project, archived: false)
            },
            .separator,
            SidebarMenuAction(title: text("Убрать проект из списка", "Remove project from list"), systemImage: "minus.circle",
                              help: text("Файлы и чаты сохранятся.", "Files and chats are kept.")) {},
        ]
    }
}

// MARK: - Sidebar mirror (NSViewRepresentable overlay with actions)

final class RowView: NSView {
    var actions: [SidebarMenuAction] = []
    var makeActions: (() -> [SidebarMenuAction])?
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func menu(for event: NSEvent) -> NSMenu? { SidebarMenuAction.menu(makeActions?() ?? actions) }
}
struct RowRep: NSViewRepresentable {
    let title: String
    let actions: [SidebarMenuAction]
    var makeActions: (() -> [SidebarMenuAction])? = nil
    var reorder: [SidebarMenuAction] = []
    var accessibility = true
    func makeNSView(context: Context) -> RowView { RowView() }
    func updateNSView(_ view: RowView, context: Context) {
        view.actions = actions
        view.makeActions = makeActions
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(title)
        if accessibility { view.setAccessibilityCustomActions(SidebarMenuAction.accessibilityActions(reorder)) }
    }
}
/// none: no actions and no accessibility setters; lazyQuiet: lazy menu without the per-update accessibility setter.
enum SidebarMode: String { case eager, lazy, lazyQuiet, none }
struct SidebarProbe: View {
    @ObservedObject var model: ProbeModel
    let mode: SidebarMode
    let perProject: Int  // visible chats per project (DeskView pages by 5; search shows all)
    let projectMenus: Bool
    var body: some View {
        let _ = model.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.projects, id: \.self) { project in
                    HStack {
                        Text("Project \(project)").frame(maxWidth: .infinity, alignment: .leading)
                            .overlay { RowRep(title: "Project \(project)", actions: mode == .eager ? model.projectActions(project) : [],
                                              makeActions: mode == .lazy || mode == .lazyQuiet ? { model.projectActions(project) } : nil,
                                              accessibility: mode == .eager || mode == .lazy) }
                        if projectMenus {
                            Menu {
                                let _ = { Counters.buttonMenuClosures += 1 }()
                                SidebarItems(actions: model.projectActions(project))
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }.frame(height: 32)
                    let chats = model.orderedChats(projectID: project, archived: false).prefix(perProject)
                    ForEach(chats) { chat in
                        let _ = { Counters.rowBodies += 1 }()
                        HStack { Image(systemName: "bubble.left"); Text(chat.title).lineLimit(1); Spacer() }
                            .frame(height: 28)
                            .overlay {
                                RowRep(title: chat.title,
                                       actions: mode == .eager ? model.chatActions(chat) : [],
                                       makeActions: mode == .lazy || mode == .lazyQuiet ? { model.chatActions(chat) } : nil,
                                       reorder: mode == .eager ? model.chatReorderActions(chat) : [],
                                       accessibility: mode == .eager || mode == .lazy)
                            }
                    }
                }
            }.padding(8)
        }
    }
}
struct SidebarItems: View {
    let actions: [SidebarMenuAction]
    var body: some View {
        ForEach(actions.indices, id: \.self) { index in
            let action = actions[index]
            if action.isSeparator { Divider() }
            else if !action.children.isEmpty { Menu(action.title) { SidebarItems(actions: action.children) } }
            else { Button(action.title, action: action.perform).disabled(!action.enabled) }
        }
    }
}

// MARK: - SwiftUI .contextMenu rows (chat files panel, diff lines, project files)

/// `listForSelection`: rows carry no menu; one List-level `.contextMenu(forSelectionType:)` builds it on right-click.
enum Container: String { case vstack, lazy, list, listForSelection }
@MainActor final class Tick: ObservableObject { @Published var value = 0 }
struct MenuRows: View {
    @ObservedObject var tick: Tick
    let count: Int
    let container: Container
    let withMenu: Bool
    var body: some View {
        switch container {
        case .vstack: ScrollView { VStack(spacing: 0) { rows } }
        case .lazy: ScrollView { LazyVStack(spacing: 0) { rows } }
        case .list: List { rows }
        case .listForSelection:
            List(selection: $selection) {
                ForEach(0..<count, id: \.self) { i in ProbeRow(index: i, tick: tick.value, withMenu: false) }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                if withMenu {
                    let _ = { Counters.menuClosures += 1 }()
                    Button(text("Показать изменения", "Show changes")) { _ = ids }
                    Button(text("Предпросмотр", "Preview")) {}
                    Menu(text("Открыть в", "Open In")) { ForEach(0..<4, id: \.self) { e in Button("Editor \(e)") {} } }
                    Divider()
                    Button(text("Скопировать относительный путь", "Copy Relative Path")) {}
                    Button(text("Скопировать абсолютный путь", "Copy Absolute Path")) {}
                }
            }
        }
    }
    @State private var selection: Set<Int> = []
    @ViewBuilder var rows: some View {
        ForEach(0..<count, id: \.self) { i in ProbeRow(index: i, tick: tick.value, withMenu: withMenu) }
    }
}
struct ProbeRow: View {
    let index: Int; let tick: Int; let withMenu: Bool
    var body: some View {
        let _ = { Counters.rowBodies += 1 }()
        let label = HStack(spacing: 5) {
            Image(systemName: "doc.text").frame(width: 15)
            Text("file-\(index).swift").lineLimit(1)
            Text("Sources/Module/Folder \(tick)").foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text("+\(index)").monospacedDigit()
        }.frame(height: 24).padding(.horizontal, 8)
        if withMenu {
            label.contextMenu {
                let _ = { Counters.menuClosures += 1 }()
                Button(text("Показать изменения", "Show changes")) {}
                Button(text("Предпросмотр", "Preview")) {}
                Button(text("Открыть в VS Code", "Open in VS Code")) {}
                Menu(text("Открыть в", "Open In")) {
                    ForEach(0..<4, id: \.self) { e in Button("Editor \(e)") {} }
                    Divider()
                    Button(text("Программа по умолчанию", "Default App")) {}
                }
                Button(text("Добавить в сообщение", "Add to Message")) {}
                Button(text("Показать в Finder", "Show in Finder")) {}
                Divider()
                Button(text("Скопировать относительный путь", "Copy Relative Path")) {}
                Button(text("Скопировать абсолютный путь", "Copy Absolute Path")) {}
            }
        } else { label }
    }
}

// MARK: - Transcript text view menu (NativeTranscript.textView(_:menu:for:at:) mirror)

let codeLineNumber = NSAttributedString.Key("probe.codeLineNumber")
final class TranscriptDelegate: NSObject, NSTextViewDelegate {
    var quoteLookups = 0
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        var items: [NSMenuItem] = []
        if let quote = selectedQuote(view) {
            _ = quote
            items.append(NSMenuItem(title: text("Попросить агента изменить", "Ask Agent to Edit"), action: nil, keyEquivalent: ""))
        }
        if let storage = view.textStorage, charIndex >= 0, charIndex < storage.length,
           let url = storage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL, url.isFileURL {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
                items.append(NSMenuItem(title: "Open in editor", action: nil, keyEquivalent: ""))
            }
        }
        if !items.isEmpty {
            items.append(.separator())
            for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        }
        return menu
    }
    private func selectedQuote(_ view: NSTextView) -> (text: String, lines: ClosedRange<Int>?)? {
        let range = view.selectedRange()
        guard range.length > 0, let storage = view.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let text = storage.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        func line(at index: Int) -> Int? {
            quoteLookups += 1
            var found: Int?
            storage.enumerateAttribute(codeLineNumber, in: NSRange(location: 0, length: index + 1), options: .reverse) { value, _, stop in
                if let number = value as? Int { found = number; stop.pointee = true }
            }
            return found
        }
        guard let first = line(at: range.location), let last = line(at: NSMaxRange(range) - 1) else { return (text, nil) }
        return (text, min(first, last)...max(first, last))
    }
}
@MainActor func transcriptStorage(messages: Int) -> NSTextStorage {
    let out = NSMutableAttributedString()
    let body = NSFont.systemFont(ofSize: 13), bold = NSFont.boldSystemFont(ofSize: 13)
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    for m in 0..<messages {
        out.append(NSAttributedString(string: "Message \(m)\n", attributes: [.font: bold]))
        for p in 0..<6 {
            out.append(NSAttributedString(string: "Paragraph \(p) of message \(m) with ", attributes: [.font: body]))
            out.append(NSAttributedString(string: "Sources/File\(p).swift", attributes: [.font: mono, .link: URL(fileURLWithPath: "/tmp/probe-missing/File\(p).swift")]))
            out.append(NSAttributedString(string: " and more prose to wrap across the line.\n", attributes: [.font: body]))
        }
    }
    return NSTextStorage(attributedString: out)
}

// MARK: - Harness

@MainActor final class Harness {
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 700), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    var results: [[String: Any]] = []

    func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        return host
    }
    func spin(_ seconds: Double = 0.02) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func flush(_ host: NSView) {
        RunLoop.current.run(mode: .default, before: Date())
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    }
    func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
        return nil
    }
    func rightClick(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    /// Time from a synthetic right-click to NSMenu tracking start, through the real event path; the menu is cancelled at once.
    func timeToMenuOpen(at point: NSPoint) -> (ms: Double?, cpuMs: Double, items: Int) {
        var opened: UInt64?; var items = 0; var tracked: NSMenu?
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard opened == nil, let menu = note.object as? NSMenu else { return }
                opened = wall(); items = menu.items.count; tracked = menu
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let start = wall(), cpu = threadCPU()
        // Cancelling inside the notification is ignored (the tracking loop has not started), so a timer that also
        // runs in the menu's event-tracking mode closes the menu; it exits the probe if a menu cannot be closed.
        let closer = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let tracked { tracked.cancelTrackingWithoutAnimation() }
                let elapsed = Double(wall() - start) / 1e9
                if elapsed > 1, let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: 0, context: nil, characters: "\u{1b}",
                                                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(escape, atStart: true)
                }
                if elapsed > 3 { fputs("probe: a context menu did not close; exiting\n", stderr); exit(3) }
            }
        }
        RunLoop.main.add(closer, forMode: .common)
        RunLoop.main.add(closer, forMode: .eventTracking)
        defer { closer.invalidate() }
        window.sendEvent(rightClick(at: point))
        let cpuMs = Double(threadCPU() - cpu) / 1e6
        spin(0.05)
        return (opened.map { Double($0 - start) / 1e6 }, cpuMs, items)
    }
    /// Direct `menu(for:)` on the deepest hit view and its ancestors (no tracking).
    func directMenu(at point: NSPoint) -> (Sample, Int) {
        let event = rightClick(at: point)
        var menu: NSMenu?
        let sample = measure {
            var view = window.contentView?.hitTest(window.contentView!.convert(point, from: nil))
            while let current = view, menu == nil { menu = current.menu(for: event); view = current.superview }
        }
        return (sample, menu?.items.count ?? -1)
    }
    func rowPoint(_ host: NSView, y fromTop: CGFloat) -> NSPoint {
        host.convert(NSPoint(x: 120, y: host.isFlipped ? fromTop : host.bounds.height - fromTop), to: nil)
    }

    // 1. SwiftUI .contextMenu rows: eagerness, body/layout cost, scroll, open time.
    func contextMenuRows() {
        let containers = (ProcessInfo.processInfo.environment["PROBE_CONTAINERS"] ?? "vstack,lazy,list,listForSelection")
            .split(separator: ",").compactMap { Container(rawValue: String($0)) }
        for container in containers {
            for count in [100, 1000] {
                for withMenu in [false, true] {
                    let tick = Tick()
                    Counters.reset()
                    var host: NSHostingView<MenuRows>!
                    let initial = measure { host = self.host(MenuRows(tick: tick, count: count, container: container, withMenu: withMenu)) }
                    let initialBodies = Counters.rowBodies, initialMenus = Counters.menuClosures
                    spin(0.1)
                    Counters.reset()
                    var updates: [Sample] = []
                    for _ in 0..<15 { tick.value += 1; updates.append(measure { flush(host) }) }
                    let updateBodies = Counters.rowBodies / 15, updateMenus = Counters.menuClosures / 15
                    Counters.reset()
                    var scroll = Sample(wallMs: 0, cpuMs: 0); var steps = 0
                    if let scrollView = scrollView(in: host), let document = scrollView.documentView {
                        let maxY = max(0, document.frame.height - scrollView.contentView.bounds.height)
                        var y: CGFloat = 0
                        scroll = measure {
                            while y < maxY && steps < 400 {
                                y = min(maxY, y + 60); steps += 1
                                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y)); scrollView.reflectScrolledClipView(scrollView.contentView)
                                flush(host)
                            }
                        }
                        scrollView.contentView.scroll(to: .zero); scrollView.reflectScrolledClipView(scrollView.contentView); flush(host)
                    }
                    let scrollBodies = Counters.rowBodies, scrollMenus = Counters.menuClosures
                    var open: [String: Any] = [:]
                    if withMenu {
                        Counters.reset()
                        let point = rowPoint(host, y: 60)
                        let direct = directMenu(at: point)
                        let menusOnDirect = Counters.menuClosures
                        Counters.reset()
                        var real: [Double] = []; var cpu: [Double] = []; var items = 0
                        for _ in 0..<5 { let r = timeToMenuOpen(at: point); if let ms = r.ms { real.append(ms) }; cpu.append(r.cpuMs); items = r.items }
                        open = ["direct_menu_for_ms": r3(direct.0.wallMs), "direct_items": direct.1, "menu_closures_on_direct": menusOnDirect,
                                "event_to_tracking_ms_median": real.isEmpty ? NSNull() : r3(median(real)), "opened": real.count,
                                "send_event_cpu_ms_median": r3(median(cpu)), "tracked_items": items,
                                "menu_closures_per_open": Double(Counters.menuClosures) / 5]
                    }
                    results.append(["scenario": "swiftui-contextMenu", "container": container.rawValue, "rows": count, "context_menu": withMenu,
                                    "initial_ms": r3(initial.wallMs), "initial_cpu_ms": r3(initial.cpuMs),
                                    "initial_row_bodies": initialBodies, "initial_menu_closures": initialMenus,
                                    "update_ms_median": r3(median(updates.map(\.wallMs))), "update_cpu_ms_median": r3(median(updates.map(\.cpuMs))),
                                    "update_row_bodies": updateBodies, "update_menu_closures": updateMenus,
                                    "scroll_steps": steps, "scroll_ms": r3(scroll.wallMs), "scroll_ms_per_step": steps > 0 ? r3(scroll.wallMs / Double(steps)) : 0,
                                    "scroll_row_bodies": scrollBodies, "scroll_menu_closures": scrollMenus, "open": open])
                    window.contentView = nil
                }
            }
        }
    }

    // 2. Sidebar: eager [SidebarMenuAction] per row on every publication vs lazy closure vs none.
    func sidebar() {
        for (chats, perProject, label) in [(800, 5, "800 chats, 8 projects x 5 rows (paged)"), (800, 100, "800 chats, search shows ~600 rows")] {
            for mode in [SidebarMode.none, .lazyQuiet, .lazy, .eager] {
                for projectMenus in [false, true] {
                    let model = ProbeModel(chats: chats, projects: 8)
                    Counters.reset()
                    var host: NSHostingView<SidebarProbe>!
                    let initial = measure { host = self.host(SidebarProbe(model: model, mode: mode, perProject: perProject, projectMenus: projectMenus)) }
                    spin(0.1)
                    Counters.reset()
                    var updates: [Sample] = []
                    for _ in 0..<15 { model.tick += 1; updates.append(measure { flush(host) }) }
                    let rows = Counters.rowBodies / 15, builds = Counters.eagerActionBuilds / 15, buttonMenus = Counters.buttonMenuClosures / 15
                    // Right-click the first chat row of project 0 (below the 32 pt header).
                    let point = rowPoint(host, y: 8 + 32 + 4 + 14)
                    Counters.reset()
                    let direct = directMenu(at: point)
                    results.append(["scenario": "sidebar", "fixture": label, "actions": mode.rawValue, "project_ellipsis_menus": projectMenus,
                                    "initial_ms": r3(initial.wallMs), "update_ms_median": r3(median(updates.map(\.wallMs))),
                                    "update_cpu_ms_median": r3(median(updates.map(\.cpuMs))), "update_chat_rows": rows,
                                    "update_action_arrays_built": builds, "update_ellipsis_menu_closures": buttonMenus,
                                    "right_click_menu_for_ms": r3(direct.0.wallMs), "right_click_items": direct.1])
                    window.contentView = nil
                }
            }
        }
    }

    // 3. Builder micro-benchmarks (no SwiftUI).
    func builders() {
        let model = ProbeModel(chats: 800, projects: 8)
        let chat = model.chats[1]
        func bench(_ name: String, _ n: Int, _ body: () -> Void) {
            body() // warm
            let s = measure { for _ in 0..<n { body() } }
            results.append(["scenario": "builder", "name": name, "iterations": n, "us_per_call": r3(s.wallMs * 1000 / Double(n))])
        }
        bench("chatActions (array only)", 2000) { _ = model.chatActions(chat) }
        bench("chatReorderActions (orderedChats over 800 chats)", 2000) { _ = model.chatReorderActions(chat) }
        bench("projectActions (array only)", 2000) { _ = model.projectActions(0) }
        bench("accessibilityActions(reorder) per updateNSView", 2000) { _ = SidebarMenuAction.accessibilityActions(model.chatReorderActions(chat)) }
        bench("SidebarMenuAction.menu(chatActions) -> NSMenu", 1000) { _ = SidebarMenuAction.menu(model.chatActions(chat)) }
        bench("SidebarMenuAction.menu(projectActions) -> NSMenu with 8 SF Symbols", 1000) { _ = SidebarMenuAction.menu(model.projectActions(0)) }
        bench("NSImage(systemSymbolName:) x1", 5000) { _ = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
        bench("FileManager.fileExists (missing path)", 5000) { _ = FileManager.default.fileExists(atPath: "/tmp/probe-missing/File1.swift") }
        bench("UserDefaults.string(forKey:)", 20000) { _ = UserDefaults.standard.string(forKey: "probe.preferredEditor") }
        // Sidebar body work per publication with eager actions: chatActions + chatReorderActions for every visible row.
        for rows in [40, 600] {
            let visible = Array(model.chats.filter { !$0.isArchived }.prefix(rows))
            bench("eager actions for \(rows) visible rows (one publication)", 20) {
                for c in visible { _ = model.chatActions(c); _ = SidebarMenuAction.accessibilityActions(model.chatReorderActions(c)) }
            }
        }
    }

    // 4. Transcript NSTextView menu.
    func transcriptMenu() {
        for messages in [200, 2000] {
            let storage = transcriptStorage(messages: messages)
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 660))
            textView.layoutManager?.replaceTextStorage(storage)
            textView.isEditable = false; textView.isSelectable = true
            let delegate = TranscriptDelegate()
            textView.delegate = delegate
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            scroll.documentView = textView
            window.contentView = scroll; window.orderFront(nil)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let point = textView.convert(NSPoint(x: 40, y: 30), to: nil)
            let event = rightClick(at: point)
            func run(_ label: String, select: NSRange) {
                textView.setSelectedRange(select)
                _ = textView.menu(for: event) // warm (Services etc.)
                delegate.quoteLookups = 0
                var s: [Double] = []; var items = 0
                for _ in 0..<10 { var m: NSMenu?; s.append(measure { m = textView.menu(for: event) }.wallMs); items = m?.items.count ?? -1 }
                let selectionAfterMenu = textView.selectedRange()
                // The app's delegate work alone, with the selection restored (menu(for:) may move it to the clicked word).
                textView.setSelectedRange(select)
                delegate.quoteLookups = 0
                let delegateMs = median((0..<10).map { _ in measure { _ = delegate.textView(textView, menu: NSMenu(), for: event, at: 5) }.wallMs })
                let lookups = delegate.quoteLookups / 10
                textView.setSelectedRange(select)
                let open = timeToMenuOpen(at: point)
                results.append(["scenario": "transcript-menu", "messages": messages, "length": storage.length, "case": label,
                                "menu_for_ms_median": r3(median(s)), "items": items,
                                "delegate_only_ms_median": r3(delegateMs), "delegate_line_lookups": lookups,
                                "selection_after_menu_for": NSStringFromRange(selectionAfterMenu),
                                "event_to_tracking_ms": open.ms.map(r3) ?? NSNull()])
            }
            run("no selection", select: NSRange(location: 0, length: 0))
            run("selection near the start", select: NSRange(location: 20, length: 40))
            run("selection at the end (reverse scan of whole prefix)", select: NSRange(location: storage.length - 60, length: 40))
            window.contentView = nil
        }
    }
}

@main struct ContextMenuProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { fputs("probe timed out\n", stderr); exit(2) }
        Task { @MainActor in
            let harness = Harness()
            let only = ProcessInfo.processInfo.environment["PROBE_ONLY"]
            if only == nil || only == "builders" { harness.builders() }
            if only == nil || only == "transcript" { harness.transcriptMenu() }
            if only == nil || only == "sidebar" { harness.sidebar() }
            if only == nil || only == "rows" { harness.contextMenuRows() }
            harness.window.orderOut(nil)
            let report: [String: Any] = ["date": Date().description, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                         "language": russian ? "ru" : "en", "results": harness.results,
                                         "scope": "Standalone mirror of Switchboard menu patterns; release build; main-thread wall and CPU time"]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_MENU_REPORT"] {
                try! data.write(to: URL(fileURLWithPath: path))
            } else { FileHandle.standardOutput.write(data) }
            exit(0)
        }
        app.run()
    }
}
