import AppKit
import Combine
import ContextCore

/// Writes pending recorded transcript items at once when they would otherwise wait for the store's flush interval:
/// the chat being left on a chat switch, and every chat when the app resigns active or the Mac goes to sleep.
/// Quit flushes on its own (`AppDelegate.applicationShouldTerminate`); a finished turn is written by its history refresh.
@MainActor final class TranscriptFlushTriggers {
    private static var current: TranscriptFlushTriggers?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var chatChanges: AnyCancellable?

    /// Replaces the previous triggers (the main window's task runs again after the window is reopened).
    static func install(_ model: DeskModel) {
        current?.stop()
        current = TranscriptFlushTriggers(model: model)
    }

    private init(model: DeskModel) {
        let store = model.store
        var previous = model.chatID
        // `$chatID` emits the new value before it is set.
        chatChanges = model.$chatID.sink { next in
            guard next != previous else { return }
            if let left = previous { Task { await store.flushTranscript(conversationID: left) } }
            previous = next
        }
        let all: @Sendable (Notification) -> Void = { _ in Task { await store.flushTranscripts() } }
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main, using: all)))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: all)))
    }

    private func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []; chatChanges = nil
    }
}
