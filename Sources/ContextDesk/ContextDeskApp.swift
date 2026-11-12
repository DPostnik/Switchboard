import ContextCore
import ContextTranscript
import SwiftUI
import AppKit
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: DeskModel?
    let keepAwake = KeepAwake()
    let restart = AppRestartController()
    private var shutdownDeadline: DispatchWorkItem?
    /// SwiftUI's openWindow, captured from a scene view: after Cmd+W the main window is gone
    /// and only the scene can recreate it, so AppKit lookups through `windows` find nothing.
    var openMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.setActivationPolicy(.regular)
        restart.start(delegate: self)
        nightlyTestsObserver = NightlyTestsReport.observe()
        Perf.start()
    }
    private var nightlyTestsObserver: NSObjectProtocol?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(); return false }
        return true
    }
    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let openMainWindow { openMainWindow() }
        else { NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if restart.terminating { return .terminateLater }
        if let model, model.anyBusy || !model.backgroundWorkChatIDs.isEmpty {
            let alert = NSAlert(); alert.messageText = L10n.text("Задача ещё выполняется", "A task is still running")
            alert.informativeText = L10n.text("Выход остановит подключение к Codex и задания Claude Code. Скрыть окно можно без остановки.", "Quitting will close the Codex connection and stop Claude Code tasks. You can hide the window without stopping them.")
            alert.addButton(withTitle: L10n.text("Выйти", "Quit"))
            alert.addButton(withTitle: L10n.text("Остаться", "Stay")).keyEquivalent = "\u{1b}"
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        // A user's quit wins over a pending restart: the restart path would cancel it while work runs.
        let restarting = restart.restartingNow
        if !restarting && restart.requested { restart.cancel() }
        restart.terminating = true
        AppLog.lifecycle.notice("Quit started (restart: \(restarting, privacy: .public))")
        // The window stays responsive for the seconds the shutdown takes; a message sent now is held for the next launch.
        model?.shuttingDown = true
        armShutdownDeadline()
        Task {
            if restarting {
                do {
                    guard let model else { throw RestartFailure.unavailable }
                    try await model.store.save(model.state)
                    // Coalesced state saves and recorded items are written with a delay; the relaunch must not lose them.
                    await model.flushPersist()
                    await model.store.flushTranscripts()
                    // Saving suspends; work may have arrived in the meantime.
                    guard model.readyForRestart else {
                        restart.terminating = false
                        model.shuttingDown = false
                        model.releaseQueueHeldForRestart()
                        disarmShutdownDeadline("work arrived while saving")
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    restart.saveContinuation()
                    try restart.launchHelper()
                } catch {
                    restart.terminating = false
                    restart.cancel()
                    try? FileManager.default.removeItem(at: RestartContinuation.file)
                    disarmShutdownDeadline("restart preparation failed")
                    model?.shuttingDown = false
                    model?.releaseQueueHeldForRestart()
                    model?.error = L10n.text("Не удалось подготовить перезапуск: ", "Could not prepare restart: ") + error.localizedDescription
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await model?.shutdown()
            // State changes and items that arrived while shutting down are still pending.
            await model?.flushPersist()
            await model?.store.flushTranscripts()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    // Quit runs in terminateLater state where the app ignores input and Cmd+Q, so a stalled
    // shutdown step would otherwise need Force Quit. The deadline runs off the main thread.
    private func armShutdownDeadline() {
        shutdownDeadline?.cancel()
        let item = DispatchWorkItem(block: Self.exitAfterStalledShutdown)
        shutdownDeadline = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15, execute: item)
    }
    // Nonisolated so the off-main deadline never asserts main-actor isolation.
    nonisolated private static func exitAfterStalledShutdown() {
        AppLog.lifecycle.fault("Shutdown did not finish within 15 s; exiting without the remaining steps")
        _exit(0)
    }
    private func disarmShutdownDeadline(_ reason: String) {
        shutdownDeadline?.cancel(); shutdownDeadline = nil
        AppLog.lifecycle.notice("Quit cancelled: \(reason, privacy: .public)")
    }
    func applicationWillTerminate(_ notification: Notification) { keepAwake.stop() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if NightlyTestsReport.isReport(response.notification.request.content.userInfo) {
            await MainActor.run { NightlyTestsReport.openLog() }
            return
        }
        let threadID = response.notification.request.content.userInfo["threadID"] as? String ?? ""
        let attention = response.notification.request.content.userInfo["attentionID"] != nil
        await MainActor.run { showMainWindow() }
        if let value = response.notification.request.content.userInfo["jobID"] as? String,
           let jobID = UUID(uuidString: value),
           await model?.jobLedger.jobs.contains(where: { $0.id == jobID }) == true {
            await model?.openScheduledJob(jobID); return
        }
        if attention { await model?.openAttention(); return }
        await model?.focusAction(threadID: threadID)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

struct ContextDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Held for the app's lifetime but not observed: the App body, and with it every menu command, no longer
    /// re-evaluates on model changes. The window, the settings scene and the menus observe what they need.
    @State private var model: DeskModel
    init() {
        // Establish the app-scoped language before SwiftUI constructs native menus.
        L10n.language.save()
        // Keep native controls and TextKit consistent with the white workspace.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        _model = State(initialValue: DeskModel())
    }

    var body: some Scene {
        Window("Switchboard", id: "main") {
            MainWindowContent(model: model, delegate: delegate)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(before: .appTermination) {
                RestartMenu(restart: delegate.restart)
                Divider()
            }
            CommandGroup(before: .windowList) {
                MainWindowMenuItem()
                Divider()
            }
            CommandGroup(after: .toolbar) {
                InterfaceZoomMenu()
                Divider()
                ChatFilesMenuItem()
                Divider()
            }
            CommandMenu(L10n.text("Браузеры", "Browsers")) {
                RunningBrowsersMenu(model: model, browsers: model.browsersMenu)
            }
            CommandGroup(replacing: .help) {
                SettingsLink { Text("Язык / Language…") }
            }
            CommandGroup(after: .newItem) {
                ChatCommands(model: model, menu: model.menu)
            }
            CommandGroup(after: .textEditing) {
                FindCommand()
            }
            CommandMenu(L10n.text("Переход", "Go")) {
                NavigationCommands(model: model, menu: model.menu)
            }
        }
        Settings {
            SettingsContent(model: model, keepAwake: delegate.keepAwake)
        }
    }
}

/// The main window's root; observes the model so the loading screen gives way to the desk.
private struct MainWindowContent: View {
    @ObservedObject var model: DeskModel
    let delegate: AppDelegate
    var body: some View {
        Group {
            if model.isBootstrapping {
                StartupLoadingView()
            } else {
                DeskView(model: model)
                    .overlay { CommandPaletteHost(model: model, navigation: model.navigation) }
            }
        }
            .buttonStyle(PointerButtonStyle(base: .automatic))
            .modifier(InterfaceZoomed())
            .preferredColorScheme(.light)
            .environment(\.locale, L10n.locale)
            .frame(minWidth: 900, minHeight: 620)
            .background(MainWindowPlacer())
            .modifier(MainWindowOpener(delegate: delegate))
            .task {
                delegate.model = model
                TranscriptFlushTriggers.install(model)
                MemoryPressureRelief.install(model)
                TranscriptLinks.openChat = { [weak model] id in model?.openChatLink(id) }
                TranscriptLinks.openTurnChanges = { [weak model] chatID, changes, file in
                    if let model { TurnChangesWindow.show(changes, chatID: chatID, model: model, file: file) }
                }
                TurnChangesWindow.showMainWindow = { [weak delegate] in delegate?.showMainWindow() }
                TranscriptImagePaths.openImage = { [weak model] url in
                    ImageViewerState.shared.show(url, gallery: model.map { ImageViewerState.gallery($0.transcript.items) } ?? [])
                }
                EditorLauncher.projectFolders = { [weak model] in
                    guard let model else { return [] }
                    return model.state.projects.map(\.path) + model.state.chats.compactMap { $0.worktree?.workingDirectory }
                }
                NotchIslandController.start(model: model, showMainWindow: { [weak delegate] in delegate?.showMainWindow() })
                FringeLinkServer.start(model: model, showMainWindow: { [weak delegate] in delegate?.showMainWindow() })
                await model.boot()
            }
    }
}

private struct SettingsContent: View {
    @ObservedObject var model: DeskModel
    let keepAwake: KeepAwake
    var body: some View {
        Group {
            if model.isBootstrapping { StartupLoadingView() }
            else { SettingsView(model: model, keepAwake: keepAwake) }
        }.buttonStyle(PointerButtonStyle(base: .automatic))
            .tint(DeskPalette.accent)
            .modifier(InterfaceZoomed())
            .preferredColorScheme(.light)
            .environment(\.locale, L10n.locale).frame(width: 760).padding(20)
    }
}

/// File menu items that depend on the model; they observe `AppMenuState`, which publishes only when they flip.
private struct ChatCommands: View {
    let model: DeskModel
    @ObservedObject var menu: AppMenuState
    var body: some View {
        Button(L10n.text("Открыть проект…", "Open Project…")) { model.openProject() }.keyboardShortcut("o")
            .disabled(!menu.ready)
        Button(L10n.text("Новый чат", "New chat")) { model.newChat() }.keyboardShortcut("n")
            .disabled(!menu.ready || !menu.hasProject)
    }
}

private struct RestartMenu: View {
    @ObservedObject var restart: AppRestartController
    var body: some View {
        Button(restart.requested
               ? L10n.text("Перезапуск ожидает завершения задач…", "Restart waiting for tasks…")
               : L10n.text("Перезапустить после завершения задач", "Restart after tasks finish")) { restart.enqueueRestart() }
            .disabled(restart.requested)
        if restart.requested && !restart.blockers.isEmpty {
            Section(L10n.text("Ждёт", "Waiting for")) {
                ForEach(restart.blockers, id: \.self) { Text($0) }
            }
        }
        if !restart.continuationChatIDs.isEmpty {
            Section(L10n.text("Продолжат после перезапуска", "Will continue after restart")) {
                ForEach(restart.continuationChatIDs, id: \.self) { id in
                    Text(restart.continuationTitles[id] ?? id)
                }
            }
        }
        Button(L10n.text("Отменить ожидающий перезапуск", "Cancel pending restart")) { restart.cancel() }
            .disabled(!restart.requested)
    }
}

/// Hands the scene's openWindow to the app delegate for Dock and notification reopen.
private struct MainWindowOpener: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { [openWindow] in delegate.openMainWindow = { openWindow(id: "main") } }
    }
}

private struct MainWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L10n.text("Главное окно", "Main Window")) { openWindow(id: "main") }
            .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(L10n.text("Загружаем Switchboard…", "Loading Switchboard…")).font(.ui(.headline))
            Text(L10n.text("Подключаемся и проверяем аккаунт", "Connecting and checking your account")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeskPalette.canvas)
        .accessibilityElement(children: .combine)
    }
}

/// Names the chat behind each running Chrome for Testing; choosing one opens the chat and shows its browser.
/// It observes `RunningBrowsersState` only, so a model change that leaves the browsers alone does not rebuild it.
struct RunningBrowsersMenu: View {
    let model: DeskModel
    @ObservedObject var browsers: RunningBrowsersState
    var body: some View {
        let entries = browsers.entries
        if entries.isEmpty {
            Text(L10n.text("Нет открытых браузеров чатов", "No chat browsers are open"))
        } else {
            Text(L10n.text("Открыто браузеров: \(entries.count)", "Open browsers: \(entries.count)"))
            ForEach(entries) { entry in
                Button(entry.label) {
                    Task {
                        guard let chat = model.chat(entry.id) else { return }
                        await model.openChat(chat)
                        model.showBrowser(chatID: entry.id)
                    }
                }
            }
        }
    }
}

/// The Browsers menu's rows (chat title · project), published only when they change.
@MainActor final class RunningBrowsersState: ObservableObject {
    struct Entry: Equatable, Identifiable {
        let id: String
        let label: String
    }
    @Published private(set) var entries: [Entry] = []
    func update(_ entries: [Entry]) {
        if self.entries != entries { self.entries = entries }
    }
}
