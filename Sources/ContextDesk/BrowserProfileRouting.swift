import AppKit
import Foundation
import ContextCore

extension DeskModel {
    /// Polls which chats have a live browser so the sidebar and the Browsers menu can name its owner.
    func startBrowserActivityMonitor() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keys = Dictionary(state.chats.compactMap { chat in chat.nativeSession.map { (BrowserProfileStore.key($0), chat.id) } },
                                      uniquingKeysWith: { first, _ in first })
                let running = state.browserEnabled == true
                    ? await Task.detached { BrowserProfileStore().runningBrowsers() }.value : [:]
                let chats = Dictionary(running.compactMap { key, pid in keys[key].map { ($0, pid) } }, uniquingKeysWith: { first, _ in first })
                if chats != runningBrowserChats { runningBrowserChats = chats }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    /// Brings the chat's own Chrome for Testing to the front; false if it is not running.
    @discardableResult
    func showBrowser(chatID: String) -> Bool {
        guard let pid = runningBrowserChats[chatID], let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.google.chrome.for.testing" else { return false }
        app.unhide()
        return app.activate(options: [])
    }
    /// Resolved on demand: toolbars re-render on every keystroke, so they must not hash all chats up front.
    func browserProfileOwnerName(_ key: String) -> String? {
        state.chats.first { chat in chat.nativeSession.map { BrowserProfileStore.key($0) == key } ?? false }?.title
    }
    func changeBrowserProfile(chatID: String, action: BrowserProfileAction) async throws {
        guard !isBusy(threadID: chatID), !isChangingChat(chatID),
              !pending.contains(where: { $0.threadID == chatID }),
              let chat = state.chats.first(where: { $0.id == chatID }),
              let session = chat.nativeSession, [.originalCodex, .appClaude].contains(session.connection),
              let project = state.projects.first(where: { $0.id == chat.projectID }),
              let runtime = Bundle.main.resourceURL?.appendingPathComponent("BrowserRuntime"),
              state.browserEnabled == true else { throw BrowserProfileError.busy }
        configuringBrowserChats.insert(chatID)
        defer { configuringBrowserChats.remove(chatID) }
        let client = session.connection == .appClaude ? claudeConnection : connection
        let store = BrowserProfileStore()
        if try store.current(session: session) == nil {
            try await client.resume(session, projectPath: project.path, access: chat.resolvedAccessMode(in: project), route: chat.route ?? .direct)
        }
        try await Task.detached {
            switch action {
            case .rename(let name): try store.rename(session: session, name: name)
            case .release:
                try store.release(session: session) { try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime) }
            case .select(let id):
                try store.select(id, session: session, project: project.path) { try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime) }
            case .takeControl: try store.humanControl(session: session, take: true)
            case .returnControl: try store.humanControl(session: session, take: false)
            }
        }.value
        switch action {
        case .select, .returnControl:
            try await client.resume(session, projectPath: project.path, access: chat.resolvedAccessMode(in: project), route: chat.route ?? .direct)
        default: break
        }
    }
}
