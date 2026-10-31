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
        armShutdownDeadline()
        Task {
            if restarting {
                do {
                    guard let model else { throw RestartFailure.unavailable }
                    try await model.store.save(model.state)
                    // Recorded items are written about a second after they arrive; the relaunch must not lose them.
                    await model.store.flushTranscripts()
                    // Saving suspends; work may have arrived in the meantime.
                    guard model.readyForRestart else {
                        restart.terminating = false
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
                    model?.error = L10n.text("Не удалось подготовить перезапуск: ", "Could not prepare restart: ") + error.localizedDescription
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await model?.shutdown()
            // Items that arrived while shutting down are still pending in the store.
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
        if attention { await model?.openAttention(); return }
        await model?.focusAction(threadID: threadID)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

struct ContextDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DeskModel()
    init() {
        // Establish the app-scoped language before SwiftUI constructs native menus.
        L10n.language.save()
        // Keep native controls and TextKit consistent with the white workspace.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        Window("Switchboard", id: "main") {
            Group {
                if model.isBootstrapping {
                    StartupLoadingView()
                } else {
                    DeskView(model: model)
                }
            }
                .buttonStyle(PointerButtonStyle(base: .automatic))
                .modifier(InterfaceZoomed())
                .preferredColorScheme(.light)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 900, minHeight: 620)
                .modifier(MainWindowOpener(delegate: delegate))
                .task {
                    delegate.model = model
                    TranscriptLinks.openChat = { [weak model] id in model?.openChatLink(id) }
                    NotchIslandController.start(model: model, showMainWindow: { [weak delegate] in delegate?.showMainWindow() })
                    FringeLinkServer.start(model: model, showMainWindow: { [weak delegate] in delegate?.showMainWindow() })
                    await model.boot()
                }
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
            }
            CommandMenu(L10n.text("Браузеры", "Browsers")) {
                RunningBrowsersMenu(model: model)
            }
            CommandGroup(replacing: .help) {
                SettingsLink { Text("Язык / Language…") }
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("Открыть проект…", "Open Project…")) { model.openProject() }.keyboardShortcut("o")
                    .disabled(model.isBootstrapping)
                Button(L10n.text("Новый чат", "New chat")) { model.newChat() }.keyboardShortcut("n")
                    .disabled(model.isBootstrapping || model.selectedProject == nil)
            }
        }
        Settings {
            Group {
                if model.isBootstrapping { StartupLoadingView() }
                else { SettingsView(model: model, keepAwake: delegate.keepAwake) }
            }.buttonStyle(PointerButtonStyle(base: .automatic))
                .modifier(InterfaceZoomed())
                .preferredColorScheme(.light)
                .environment(\.locale, L10n.locale).frame(width: 720).padding(20)
        }
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
struct RunningBrowsersMenu: View {
    @ObservedObject var model: DeskModel
    var body: some View {
        let chats = model.state.chats.filter { model.runningBrowserChats[$0.id] != nil }
        if chats.isEmpty {
            Text(L10n.text("Нет открытых браузеров чатов", "No chat browsers are open"))
        } else {
            Text(L10n.text("Открыто браузеров: \(chats.count)", "Open browsers: \(chats.count)"))
            ForEach(chats) { chat in
                let project = model.state.projects.first { $0.id == chat.projectID }?.name
                Button([chat.title, project].compactMap { $0 }.joined(separator: " · ")) {
                    Task {
                        await model.openChat(chat)
                        model.showBrowser(chatID: chat.id)
                    }
                }
            }
        }
    }
}
