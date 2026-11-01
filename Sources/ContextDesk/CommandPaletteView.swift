import AppKit
import ContextCore
import ContextTranscript
import SwiftUI

/// Cmd+K: a search field over the main window that opens chats, projects and pages. Matching and order come from
/// `PaletteSearch`; every entry runs the same model call as its sidebar control.
struct CommandPaletteHost: View {
    let model: DeskModel
    @ObservedObject var navigation: DeskNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .top) {
            if navigation.paletteShown {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { navigation.paletteShown = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                CommandPalette(model: model, navigation: navigation)
                    .padding(.top, .ui(64))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(DeskMotion.standard(reduceMotion, response: 0.2), value: navigation.paletteShown)
    }
}

private struct PaletteEntry: Identifiable {
    enum Status { case running, needsYou, unread }
    let id: String
    let icon: String
    let title: String
    var subtitle = ""
    var status: Status?
    var shortcut: String?
    let perform: () -> Void
}

private struct PaletteSection: Identifiable {
    let id: String
    let title: String
    let entries: [PaletteEntry]
}

private struct PaletteAction {
    let id: String
    let icon: String
    let title: String
    /// Extra words that find the action in either language; not shown.
    let keywords: String
    var subtitle = ""
    var shortcut: String?
    let perform: () -> Void
}

private struct CommandPalette: View {
    @ObservedObject var model: DeskModel
    let navigation: DeskNavigation
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selectedID: String?
    /// Full-text hits from the local chat index and the query they answer.
    @State private var messageHits: (query: String, hits: [ChatSearchIndex.Hit]) = ("", [])
    @State private var keys = PaletteKeys()
    @FocusState private var focused: Bool

    private static let chatLimit = 8, projectLimit = 6, messageLimit = 6

    var body: some View {
        let sections = self.sections
        let entries = sections.flatMap(\.entries)
        let current = selectedID.flatMap { id in entries.first { $0.id == id } } ?? entries.first
        VStack(spacing: 0) {
            HStack(spacing: .ui(10)) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Чаты, проекты и действия", "Chats, projects and actions"), text: $query)
                    .textFieldStyle(.plain).font(.ui(.title3)).focused($focused)
                    .accessibilityLabel(L10n.text("Палитра команд", "Command palette"))
            }
            .padding(.horizontal, .ui(16)).padding(.vertical, .ui(14))
            DeskPalette.border.frame(height: 1)
            if entries.isEmpty {
                Text(L10n.text("Ничего не найдено", "Nothing found"))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, .ui(24))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(section.title).sidebarSectionHeader().padding(.horizontal, .ui(8))
                                ForEach(section.entries) { entry in
                                    row(entry, selected: entry.id == current?.id).id(entry.id)
                                }
                            }
                        }
                        .padding(.ui(8))
                    }
                    .frame(maxHeight: .ui(420))
                    .onChange(of: current?.id) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            DeskPalette.border.frame(height: 1)
            Text(L10n.text("↑↓ выбрать · ↩ открыть · Esc закрыть", "↑↓ select · ↩ open · Esc close"))
                .font(.ui(.caption)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, .ui(16)).padding(.vertical, .ui(8))
        }
        .frame(width: .ui(620))
        .background(DeskPalette.canvas, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DeskPalette.border))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .background(WindowReader { keys.window = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onChange(of: query) { _, _ in selectedID = nil }
        .onAppear {
            keys.start(handle: handle)
            focused = true
            // The field may join the window only after this pass.
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { keys.stop() }
        .task(id: query) { await searchMessages(query) }
    }

    private func row(_ entry: PaletteEntry, selected: Bool) -> some View {
        Button { run(entry) } label: {
            HStack(spacing: .ui(10)) {
                Image(systemName: entry.icon).foregroundStyle(.secondary).frame(width: .ui(18))
                VStack(alignment: .leading, spacing: .ui(1)) {
                    Text(entry.title).lineLimit(1).foregroundStyle(DeskPalette.ink)
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: .ui(8))
                if let status = entry.status { statusLabel(status) }
                if let shortcut = entry.shortcut {
                    Text(shortcut).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
            .font(.ui(.callout))
            .padding(.horizontal, .ui(10)).padding(.vertical, .ui(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DeskPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selectedID = entry.id } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func statusLabel(_ status: PaletteEntry.Status) -> some View {
        let (title, color): (String, Color) = switch status {
        case .needsYou: (L10n.text("Ждёт тебя", "Needs you"), DeskPalette.attention)
        case .running: (L10n.text("Работает", "Running"), DeskPalette.muted)
        case .unread: (L10n.text("Непрочитано", "Unread"), DeskPalette.accent)
        }
        HStack(spacing: .ui(4)) {
            Circle().fill(color).frame(width: .ui(7), height: .ui(7))
            Text(title).font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }

    // MARK: Entries

    private var sections: [PaletteSection] {
        let hidden = Set(model.state.projects.filter(\.isHidden).map(\.id))
        let projects = Dictionary(model.state.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let active = model.state.chats.filter { !$0.isArchived && !hidden.contains($0.projectID) }
        let chatsByID = Dictionary(model.state.chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let chatIDs = PaletteSearch.rank(active.map { PaletteSearch.Candidate(id: $0.id, title: $0.title, detail: projects[$0.projectID]?.name ?? "", recency: $0.updated) },
                                         query: query, limit: Self.chatLimit)
        let chats = chatIDs.compactMap { chatsByID[$0] }.map { chatEntry($0, project: projects[$0.projectID]) }

        let lastActivity = Dictionary(active.map { ($0.projectID, $0.updated) }, uniquingKeysWith: { max($0, $1) })
        let visible = model.state.visibleProjects
        let projectIDs = PaletteSearch.rank(visible.map { PaletteSearch.Candidate(id: $0.id, title: $0.name, detail: $0.path, recency: lastActivity[$0.id]) },
                                            query: query, limit: Self.projectLimit)
        let projectEntries = projectIDs.compactMap { projects[$0] }.map { project in
            PaletteEntry(id: "project:\(project.id)", icon: "folder", title: project.name, subtitle: (project.path as NSString).abbreviatingWithTildeInPath) {
                model.selectProject(project.id)
            }
        }

        let actions = self.actions
        let actionIDs = PaletteSearch.rank(actions.map { PaletteSearch.Candidate(id: $0.id, title: $0.title, detail: $0.keywords) }, query: query)
        let actionEntries = actionIDs.compactMap { id in actions.first { $0.id == id } }.map { action in
            PaletteEntry(id: "action:\(action.id)", icon: action.icon, title: action.title, subtitle: action.subtitle, shortcut: action.shortcut, perform: action.perform)
        }

        var messageEntries: [PaletteEntry] = []
        if messageHits.query == query {
            let listed = Set(chatIDs)
            for hit in messageHits.hits where messageEntries.count < Self.messageLimit && !listed.contains(hit.chatID) {
                guard let chat = chatsByID[hit.chatID], !hidden.contains(chat.projectID) else { continue }
                let base = chatEntry(chat, project: projects[chat.projectID])
                messageEntries.append(PaletteEntry(id: "message:\(chat.id)", icon: chat.isArchived ? "archivebox" : "text.magnifyingglass",
                                                   title: chat.title, subtitle: hit.snippet, status: base.status, perform: base.perform))
            }
        }

        return [
            PaletteSection(id: "chats", title: L10n.text("Чаты", "Chats"), entries: chats),
            PaletteSection(id: "projects", title: L10n.text("Проекты", "Projects"), entries: projectEntries),
            PaletteSection(id: "actions", title: L10n.text("Действия", "Actions"), entries: actionEntries),
            PaletteSection(id: "messages", title: L10n.text("В сообщениях", "In messages"), entries: messageEntries),
        ].filter { !$0.entries.isEmpty }
    }

    private func chatEntry(_ chat: Chat, project: Project?) -> PaletteEntry {
        let status: PaletteEntry.Status? =
            model.pending.contains { $0.threadID == chat.id } || model.restartWaitingChatIDs.contains(chat.id) ? .needsYou
            : model.isBusy(threadID: chat.id) ? .running
            : chat.hasUnreadResponse ? .unread : nil
        return PaletteEntry(id: "chat:\(chat.id)", icon: chat.isPinned ? "pin" : "bubble.left", title: chat.title,
                            subtitle: project?.name ?? "", status: status) {
            Task {
                await model.openChat(chat)
                if model.chatID == chat.id { model.focusComposer() }
            }
        }
    }

    /// The sidebar's pages and the File menu's commands; unavailable ones are left out.
    private var actions: [PaletteAction] {
        let project = model.selectedProject
        let navigation = navigation
        var actions: [PaletteAction] = []
        if let project {
            actions.append(PaletteAction(id: "new-chat", icon: "square.and.pencil", title: L10n.text("Новый чат", "New chat"),
                                         keywords: "new chat новый чат", subtitle: project.name, shortcut: "⌘N") { [model] in model.newChat() })
        }
        actions.append(PaletteAction(id: "open-project", icon: "folder.badge.plus", title: L10n.text("Открыть проект…", "Open project…"),
                                     keywords: "open add project открыть добавить проект", shortcut: "⌘O") { [model] in
            // The open panel is modal; let the palette close first.
            DispatchQueue.main.async { model.openProject() }
        })
        actions.append(PaletteAction(id: "needs-you", icon: "tray", title: L10n.text("Ждёт тебя", "Needs you"),
                                     keywords: "needs you attention inbox ждёт тебя внимание") { [model] in model.openAttention() })
        actions.append(PaletteAction(id: "schedule", icon: "calendar", title: L10n.text("Расписание", "Schedule"),
                                     keywords: "schedule scheduled jobs расписание задания") { [model] in model.openSchedule() })
        actions.append(PaletteAction(id: "archive", icon: "archivebox", title: L10n.text("Архив", "Archive"),
                                     keywords: "archive архив") { [model] in model.openArchive() })
        actions.append(PaletteAction(id: "usage", icon: "chart.bar", title: L10n.text("Usage и лимиты", "Usage and limits"),
                                     keywords: "usage limits лимиты расход") { navigation.requests.send(.usage) })
        actions.append(PaletteAction(id: "settings", icon: "gearshape", title: L10n.text("Настройки…", "Settings…"),
                                     keywords: "settings preferences настройки", shortcut: "⌘,") { [openSettings] in openSettings() })
        if let project {
            actions.append(PaletteAction(id: "project-settings", icon: "slider.horizontal.3", title: L10n.text("Настройки проекта…", "Project settings…"),
                                         keywords: "project settings permissions roles настройки проекта права роли", subtitle: project.name) {
                navigation.requests.send(.projectSettings(project.id))
            })
        }
        if model.chatID != nil && !model.showingArchive && !model.showingJobs && !model.showingAttention {
            actions.append(PaletteAction(id: "find", icon: "text.magnifyingglass", title: L10n.text("Найти в чате", "Find in chat"),
                                         keywords: "find search найти поиск", shortcut: "⌘F") {
                // After the palette's field gives up focus, the find bar takes it.
                DispatchQueue.main.async { TranscriptScrollView.chatTranscript?.showFind() }
            })
        }
        return actions
    }

    // MARK: Behaviour

    private func run(_ entry: PaletteEntry) {
        keys.performed = true
        navigation.paletteShown = false
        entry.perform()
    }

    /// Keys typed into the search field: arrows move, Return opens, Esc closes. False once the palette is closing.
    private func handle(_ key: PaletteKeys.Key) -> Bool {
        guard navigation.paletteShown else { return false }
        let entries = sections.flatMap(\.entries)
        let index = selectedID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
        switch key {
        case .up: if !entries.isEmpty { selectedID = entries[max(0, index - 1)].id }
        case .down: if !entries.isEmpty { selectedID = entries[min(entries.count - 1, index + 1)].id }
        case .open: if entries.indices.contains(index) { run(entries[index]) }
        case .close: navigation.paletteShown = false
        }
        return true
    }

    private func searchMessages(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { messageHits = (query, []); return }
        // Wait for a pause in typing; each keystroke cancels the previous search.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let hits = (try? await model.chatSearchIndex.search(text, limit: 40)) ?? []
        guard !Task.isCancelled else { return }
        messageHits = (query, hits)
    }
}

/// Watches key presses in the palette's window while it is open. A local monitor sees them before the window's
/// key equivalents, so Esc closes the palette and does not reach a preview's close button underneath.
@MainActor private final class PaletteKeys {
    enum Key { case up, down, open, close }
    weak var window: NSWindow?
    /// The palette ran an entry; focus then belongs to whatever the entry opened.
    var performed = false
    private var monitor: Any?
    private weak var previousResponder: NSResponder?

    func start(handle: @escaping @MainActor (Key) -> Bool) {
        stop()
        performed = false
        var responder = (window ?? NSApp.keyWindow)?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSResponder }
        previousResponder = responder
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            // Text being composed by an input method keeps its keys.
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            let key: Key? = switch (event.keyCode, flags) {
            case (126, []): .up
            case (125, []): .down
            case (36, []), (76, []): .open
            case (53, []): .close
            case (35, .control): .up // Ctrl+P
            case (45, .control): .down // Ctrl+N
            default: nil
            }
            guard let key, handle(key) else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Closed without running anything: focus returns where it was, such as the composer.
        if !performed, let window, let view = previousResponder as? NSView, view.window === window {
            window.makeFirstResponder(view)
        }
        previousResponder = nil
    }
}

/// Reports the hosting window once the view is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { WindowProbe(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowProbe: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { found(window) }
        }
    }
}
