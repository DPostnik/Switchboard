import Foundation

/// Settings → Browser applies a changed browser setting by reconnecting Codex, as the former
/// "Apply browser setting" button did. A reconnect ends the agent server and clears its pending
/// approvals and background work, so it waits until the app is idle by the same check the
/// idle restart uses. Nothing is retried: a turn that starts first simply postpones the reconnect.
/// Changes made within a moment of each other are applied by one reconnect.
@MainActor final class BrowserSettingApply: ObservableObject {
    static let shared = BrowserSettingApply()
    /// A change is saved but Codex still runs with the previous browser setting.
    @Published private(set) var pending = false
    private weak var model: DeskModel?
    private var timer: Timer?
    private var changedAt = Date.distantPast
    private let isIdle: @MainActor (DeskModel) -> Bool
    private let apply: @MainActor (DeskModel) async -> Void
    static let settle: TimeInterval = 1.5

    init(isIdle: @escaping @MainActor (DeskModel) -> Bool = { $0.readyForRestart },
         apply: @escaping @MainActor (DeskModel) async -> Void = { await $0.reconnectSharedEngines() }) {
        self.isIdle = isIdle; self.apply = apply
    }

    func schedule(model: DeskModel, now: Date = Date()) {
        self.model = model
        pending = true; changedAt = now
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.applyIfIdle() }
        }
    }

    /// Starts the reconnect once the change has settled and the app is idle; returns that task.
    @discardableResult func applyIfIdle(now: Date = Date()) -> Task<Void, Never>? {
        guard pending, let model else { stopTimer(); return nil }
        guard now.timeIntervalSince(changedAt) >= Self.settle, isIdle(model) else { return nil }
        pending = false; stopTimer()
        // connect() checks its own guard before its first suspension; a chat that became busy keeps it pending.
        return Task { [weak self, isIdle, apply] in
            guard isIdle(model) else { self?.schedule(model: model); return }
            await apply(model)
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
