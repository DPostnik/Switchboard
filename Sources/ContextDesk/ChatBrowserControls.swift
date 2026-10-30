import AppKit
import SwiftUI
import ContextCore

/// Controls are bound to the saved native session, never the currently focused window.
struct ChatBrowserControls: View {
    let session: AgentSessionReference
    let project: String
    let busy: Bool
    let ownerName: (String) -> String?
    let changeProfile: (BrowserProfileAction) async throws -> Void
    @State private var running: Bool?
    @State private var operating = false
    @State private var error: String?
    @State private var importingCookies = false
    @State private var showingProfiles = false

    var body: some View {
        Menu {
            Text(running == true ? L10n.text("Браузер открыт", "Browser is open") :
                 running == false ? L10n.text("Браузер закрыт", "Browser is closed") :
                 L10n.text("Состояние не проверено", "Status not checked"))
            Button(L10n.text("Показать браузер", "Show browser")) { perform(show: true) }
            Button(L10n.text("Скрыть браузер", "Hide browser")) { perform(hide: true) }
            Button(L10n.text("Проверить состояние", "Check status")) { perform() }
            Button(L10n.text("Закрыть браузер", "Close browser")) { perform(close: true) }
                .disabled(busy)
            Divider()
            Button(L10n.text("Профили и управление…", "Profiles and control…")) { showingProfiles = true }
                .disabled(busy)
            Button(L10n.text("Импортировать только cookies…", "Import cookies only…")) { importingCookies = true }
                .disabled(busy)
            Text(L10n.text("Следующее обращение агента откроет новый сеанс с тем же профилем.",
                           "The next explicit browser open starts a new session with the same profile."))
        } label: {
            Label(L10n.text("Браузер", "Browser"), systemImage: "globe")
        }
        .menuStyle(.borderlessButton).fixedSize().pointingHandCursor()
        .disabled(operating)
        .id(session)
        .sheet(isPresented: $importingCookies) {
            ChromeCookieImportView(session: session) { perform() }
        }
        .sheet(isPresented: $showingProfiles) {
            BrowserProfilesView(session: session, project: project, ownerName: ownerName, change: changeProfile)
        }
        .alert(L10n.text("Браузер чата", "Chat browser"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L10n.text("Закрыть", "Dismiss")) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func perform(show: Bool = false, hide: Bool = false, close: Bool = false) {
        guard !operating, !close || !busy else { return }
        operating = true
        let reference = session
        let resources = Bundle.main.resourceURL
        Task {
            defer { operating = false }
            do {
                guard let root = try BrowserEnvironmentStore.existingEnvironment(session: reference),
                      let resources else {
                    running = false
                    if show { error = L10n.text("Браузер откроется при первом обращении агента.", "The browser opens on the agent’s first browser request.") }
                    return
                }
                let output = try await Task.detached {
                    let store = BrowserProfileStore()
                    let grant = try store.current(session: reference) == nil ? nil : store.ownedGrant(session: reference, allowHuman: true)
                    return try BrowserProfileControl.status(environment: root,
                        runtime: resources.appendingPathComponent("BrowserRuntime"), grant: grant, close: close)
                }.value
                if let message = output.error { error = message; running = nil; return }
                running = output.running
                if show || hide {
                    guard output.running == true, let pid = output.pid,
                          let app = NSRunningApplication(processIdentifier: pid),
                          app.bundleIdentifier == "com.google.chrome.for.testing" else {
                        error = L10n.text("Браузер этого чата сейчас закрыт.", "This chat’s browser is currently closed.")
                        return
                    }
                    if hide {
                        let sent = app.hide()
                        // AppKit may report false even after the app becomes hidden.
                        try await Task.sleep(for: .milliseconds(150))
                        if !sent && !app.isHidden {
                            error = L10n.text("Не удалось скрыть браузер. Он продолжает работать.",
                                              "Could not hide the browser. It is still running.")
                        }
                    } else {
                        app.unhide()
                        app.activate(options: [])
                    }
                }
            } catch {
                self.error = L10n.text("Не удалось проверить браузер: ", "Could not check the browser: ") + error.localizedDescription
                running = nil
            }
        }
    }
}
