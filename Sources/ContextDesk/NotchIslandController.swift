import AppKit
import Combine
import SwiftUI
import ContextCore

/// What the island view renders; owned by the controller.
@MainActor final class NotchIslandState: ObservableObject {
    @Published var notch = NotchGeometry(width: 185, height: 32)
    @Published var chats: [NotchChat] = []
    @Published var actions: [PendingAction] = []
    @Published var summary = NotchSummary.idle
    @Published var mode = NotchMode.hidden
    @Published var peek: (chat: NotchChat, waiting: Bool)?
    /// The last announcement; the buddy jumps when it changes.
    @Published var celebratedAt: Date?
    let look = NotchLook()
    @Published var showingSettings = false
    @Published var preferences = NotchPreferences.load() {
        didSet { preferences.save() }
    }
    var onOpenChat: (String) -> Void = { _ in }
    var onAnswer: (PendingAction, AgentInteractionResponse) async -> String? = { _, _ in nil }
    var onPreferencesChanged: () -> Void = {}
    var onDisable: () -> Void = {}
}

/// A transparent panel over the MacBook notch. Only the built-in display with a cut-out gets it;
/// external screens are left alone. Window level, space behaviour and the click-through switch
/// follow Coucou (MIT, github.com/Louis-CFM/coucou).
@MainActor final class NotchIslandController {
    static let panelSize = CGSize(width: 520, height: 460)
    static let wing: CGFloat = 36
    static let expandedWidth: CGFloat = 440
    /// The island's one motion for opening, closing and switching panes: critically damped, so it
    /// settles without overshoot. Reduce Motion replaces it with a short fade.
    nonisolated static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1.0)
    }

    private let model: DeskModel
    private let state = NotchIslandState()
    private let panel: NotchPanel
    private var tracker = NotchTracker()
    private var observers: [AnyCancellable] = []
    private var monitors: [Any] = []
    private var hovering = false
    private var hoverTask: Task<Void, Never>?
    private var pinTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var pinnedOpen = false
    private var expandedHeight: CGFloat = 200
    private var screen: NSScreen?

    private static var running: NotchIslandController?
    private static var launch: (model: DeskModel, showMainWindow: () -> Void)?
    /// True while the Fringe app owns the notch; the island steps aside without changing the user's setting.
    private static var handedOff = false
    /// Starts once per process when enabled; reopening the main window keeps the same island.
    static func start(model: DeskModel, showMainWindow: @escaping () -> Void) {
        launch = (model, showMainWindow)
        guard running == nil, !handedOff, NotchPreferences.load().enabled else { return }
        running = NotchIslandController(model: model, showMainWindow: showMainWindow)
        running?.start()
    }
    /// Turning the island off tears down the window, its views and every observer, so it costs nothing.
    static func setEnabled(_ enabled: Bool) {
        var preferences = NotchPreferences.load()
        preferences.enabled = enabled
        preferences.save()
        if enabled, let launch { start(model: launch.model, showMainWindow: launch.showMainWindow) }
        if !enabled { running?.stop(); running = nil }
    }
    /// Fringe connected (true) or disconnected (false). Two panels never share the notch.
    static func setHandedOff(_ value: Bool) {
        guard handedOff != value else { return }
        handedOff = value
        if value { running?.stop(); running = nil } else if let launch { start(model: launch.model, showMainWindow: launch.showMainWindow) }
    }

    private init(model: DeskModel, showMainWindow: @escaping () -> Void) {
        self.model = model
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        let root = NotchIslandView(state: state, onHeight: { [weak self] in self?.expandedHeight = $0 })
            .environment(\.colorScheme, .dark)
            .environment(\.locale, L10n.locale)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        state.onOpenChat = { [weak self] id in
            showMainWindow()
            self?.collapse()
            Task { await model.focusAction(threadID: id) }
        }
        state.onAnswer = { action, response in await model.answer(action, result: response) }
        state.onPreferencesChanged = { [weak self] in self?.applyMode() }
        // Deferred: the island's own button must not destroy the view that is handling its click.
        state.onDisable = { DispatchQueue.main.async { NotchIslandController.setEnabled(false) } }
    }

    private func stop() {
        observers.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        [hoverTask, pinTask, peekTask].forEach { $0?.cancel() }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func start() {
        // Coalesce bursts of model changes (streamed deltas) into one snapshot.
        model.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.placePanel() }
            .store(in: &observers)
        // Mouse moves need no special permission; global covers other apps, local covers our panel.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.trackMouse(); return event
        }) { monitors.append(local) }
        placePanel()
        refresh()
    }

    // MARK: Snapshot

    /// The chats and requests worth showing over the notch; shared with the Fringe channel.
    struct Snapshot {
        /// Every chat with something to show, unordered.
        var chats: [NotchChat]
        /// At most eight, most urgent first.
        var ordered: [NotchChat]
        /// Pending requests of the ordered chats.
        var actions: [PendingAction]
        var working: Set<String>
        var waitingChats: Set<String>
    }

    static func snapshot(model: DeskModel) -> Snapshot {
        let projects = Dictionary(model.state.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let waitingChats = Set(model.pending.map(\.threadID))
        var chats: [NotchChat] = [], working: Set<String> = []
        for chat in model.state.chats where !chat.isArchived && !chat.isScheduledRecord {
            let running = model.isBusy(threadID: chat.id)
            if running { working.insert(chat.id) }
            guard let phase = NotchChat.phase(running: running, waiting: waitingChats.contains(chat.id), unread: chat.hasUnreadResponse) else { continue }
            let activity = model.runActivity(threadID: chat.id)
            chats.append(NotchChat(id: chat.id, title: chat.title, project: projects[chat.projectID] ?? "",
                                   phase: phase, activity: activity.status, since: activity.since, updated: chat.updated))
        }
        let ordered = NotchChat.ordered(chats)
        let visible = Set(ordered.map(\.id))
        return Snapshot(chats: chats, ordered: ordered, actions: model.pending.filter { visible.contains($0.threadID) },
                        working: working, waitingChats: waitingChats)
    }

    private func refresh() {
        let snapshot = Self.snapshot(model: model)
        if state.chats != snapshot.ordered { state.chats = snapshot.ordered }
        if state.actions.map(\.id) != snapshot.actions.map(\.id) { state.actions = snapshot.actions }
        let summary = NotchSummary(snapshot.ordered)
        if state.summary != summary { state.summary = summary }
        announce(tracker.update(working: snapshot.working, waitingRequests: Set(model.pending.map(\.id)), waitingChats: snapshot.waitingChats),
                 chats: snapshot.chats)
        applyMode()
    }

    private func announce(_ transition: NotchTransition, chats: [NotchChat]) {
        guard !transition.isEmpty else { return }
        let waiting = !transition.newlyWaiting.isEmpty
        let chatID = waiting ? model.pending.first { transition.newlyWaiting.contains($0.id) }?.threadID : transition.finished.first
        guard let chatID else { return }
        let chat = chats.first { $0.id == chatID }
            ?? model.state.chats.first { $0.id == chatID }.map { NotchChat(id: $0.id, title: $0.title, project: "", phase: .finished, updated: $0.updated) }
        guard let chat else { return }
        if state.preferences.sound { NSSound(named: waiting ? "Ping" : "Glass")?.play() }
        state.celebratedAt = Date()
        if waiting {
            // A request opens the island so it can be answered in place; leaving it closes again.
            pinnedOpen = true
            pinTask?.cancel()
            pinTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled, !self.hovering else { return }
                self.pinnedOpen = false; self.applyMode()
            }
        } else {
            state.peek = (chat, false)
            peekTask?.cancel()
            peekTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                self.state.peek = nil; self.applyMode()
            }
        }
    }

    // MARK: Mode and hit testing

    private func applyMode() {
        let resting = NotchPolicy.restingMode(summary: state.summary, preferences: state.preferences)
        let mode = NotchPolicy.mode(resting: resting, hovering: hovering, pinnedOpen: pinnedOpen, peeking: state.peek != nil)
        if mode != .expanded, state.showingSettings { state.showingSettings = false }
        if state.mode != mode {
            withAnimation(Self.animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { state.mode = mode }
        }
        updateClickThrough()
    }

    private func collapse() {
        pinnedOpen = false; pinTask?.cancel()
        hovering = false; hoverTask?.cancel()
        applyMode()
    }

    /// The island's area in screen coordinates for the current mode.
    private func islandRect(for mode: NotchMode) -> NSRect {
        let notch = state.notch, frame = panel.frame
        let size: CGSize = switch mode {
        case .hidden: CGSize(width: notch.width, height: notch.height)
        case .compact: CGSize(width: notch.width + Self.wing * 2, height: notch.height)
        case .peek: CGSize(width: notch.width + Self.wing * 2 + 80, height: notch.height + 30)
        case .expanded: CGSize(width: Self.expandedWidth, height: min(expandedHeight, Self.panelSize.height))
        }
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func trackMouse() {
        guard screen != nil else { return }
        let mouse = NSEvent.mouseLocation
        // Quantized so ordinary pointer motion redraws the buddy only when its gaze really moves.
        // A hidden island has no visible buddy, so its gaze waits for the next move after it shows.
        if state.mode != .hidden {
            let gaze = (max(-1, min(1, (mouse.x - panel.frame.midX) / 320)) * 8).rounded() / 8
            if state.look.x != gaze { state.look.x = gaze }
        }
        // Once open, the island stays open while the pointer is over it.
        let inside = islandRect(for: hovering || pinnedOpen ? .expanded : state.mode).insetBy(dx: -4, dy: -4).contains(mouse)
        if inside != hovering {
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                // A short delay keeps a pointer crossing the top edge from flashing the island open.
                try? await Task.sleep(for: .milliseconds(inside ? 120 : 350))
                guard let self, !Task.isCancelled else { return }
                self.hovering = inside
                if !inside { self.pinnedOpen = false; self.pinTask?.cancel() }
                self.applyMode()
            }
        }
        updateClickThrough()
    }

    /// The transparent panel lets clicks through everywhere except over the visible island.
    private func updateClickThrough() {
        let accepts = state.mode != .hidden && islandRect(for: state.mode).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
    }

    private func placePanel() {
        let builtIn = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let builtIn, let notch = NotchGeometry(screenWidth: builtIn.frame.width, safeAreaTop: builtIn.safeAreaInsets.top,
                                                    auxiliaryLeftWidth: builtIn.auxiliaryTopLeftArea?.width,
                                                    auxiliaryRightWidth: builtIn.auxiliaryTopRightArea?.width) else {
            // Lid closed or no notch: the island waits for the built-in display to return.
            screen = nil; panel.orderOut(nil); return
        }
        screen = builtIn
        state.notch = notch
        let frame = builtIn.frame
        panel.setFrame(NSRect(x: frame.midX - Self.panelSize.width / 2, y: frame.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        panel.orderFrontRegardless()
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Keep the panel in the menu-bar band instead of letting AppKit push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
