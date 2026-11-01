import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

@MainActor private func fixtureModel() -> (DeskModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (DeskModel(store: AppStore(file: root.appendingPathComponent("metadata.sqlite")), summaryResources: nil), root)
}

@Test @MainActor func browserSettingWaitsForIdleAndAppliesOnce() async {
    let (model, root) = fixtureModel()
    defer { try? FileManager.default.removeItem(at: root) }
    var idle = false, applied = 0
    let applier = BrowserSettingApply(isIdle: { _ in idle }, apply: { _ in applied += 1 })
    let start = Date()
    applier.schedule(model: model, now: start)
    applier.schedule(model: model, now: start.addingTimeInterval(0.5))
    #expect(applier.pending)
    // A busy app keeps the change pending; nothing is started.
    #expect(applier.applyIfIdle(now: start.addingTimeInterval(10)) == nil)
    #expect(applier.pending && applied == 0)
    // Idle, but the last change has not settled yet.
    idle = true
    #expect(applier.applyIfIdle(now: start.addingTimeInterval(1)) == nil)
    // Two changes are applied by one reconnect.
    await applier.applyIfIdle(now: start.addingTimeInterval(3))?.value
    #expect(!applier.pending && applied == 1)
    #expect(applier.applyIfIdle(now: start.addingTimeInterval(10)) == nil)
    #expect(applied == 1)
}

@Test @MainActor func browserSettingStaysPendingWhenAChatStartsBeforeTheReconnect() async {
    let (model, root) = fixtureModel()
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0, applied = 0
    // Idle at the timer check, busy by the time the reconnect task runs.
    let applier = BrowserSettingApply(isIdle: { _ in checks += 1; return checks == 1 }, apply: { _ in applied += 1 })
    let start = Date()
    applier.schedule(model: model, now: start)
    await applier.applyIfIdle(now: start.addingTimeInterval(3))?.value
    #expect(applied == 0)
    #expect(applier.pending)
}

@Test @MainActor func browserSettingDefaultUsesTheRestartIdleCheck() {
    let (model, root) = fixtureModel()
    defer { try? FileManager.default.removeItem(at: root) }
    // A model that has not finished launching is not idle, so the default applier does not reconnect.
    #expect(!model.readyForRestart)
    let applier = BrowserSettingApply()
    applier.schedule(model: model, now: Date.distantPast)
    #expect(applier.applyIfIdle() == nil)
    #expect(applier.pending)
}
