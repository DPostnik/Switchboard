import Foundation
import Testing
import AgentContract
@testable import ContextCore

@Test func scheduledBrowserCleanupSkipsMissingAndLegacyEnvironments() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "scheduled-cleanup")
    let absentRuntime = root.appendingPathComponent("absent-runtime")
    #expect(ScheduledBrowserCleanup.close(session: session, runtime: absentRuntime, root: root) == .notNeeded)
    _ = try BrowserEnvironmentStore.environment(session: session.nativeID, root: root)
    #expect(ScheduledBrowserCleanup.close(session: session, runtime: absentRuntime, root: root) == .notNeeded)
}

@Test func scheduledBrowserCleanupSkipsHumanAndRejectsUncertainty() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "scheduled-cleanup")
    let store = BrowserProfileStore(root: root)
    let grant = try store.prepareNew(project: root.path, connection: session.connection)
    try store.acknowledge(grant, session: session)
    let fence = store.environment(grant.environment).appendingPathComponent("executor-in-flight.json")
    try Data("{}".utf8).write(to: fence)
    let result = ScheduledBrowserCleanup.close(session: session, runtime: root, root: root)
    guard case .failed = result else { Issue.record("An uncertain operation must prevent cleanup"); return }
    #expect(FileManager.default.fileExists(atPath: fence.path))
    try FileManager.default.removeItem(at: fence)
    try store.humanControl(session: session, take: true)
    #expect(ScheduledBrowserCleanup.close(session: session, runtime: root, root: root) == .notNeeded)
    #expect(try store.current(session: session)?.state == .human)
}

@Test func scheduledBrowserCleanupDoesNotRaceCatalogOwnershipChanges() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "scheduled-cleanup")
    let store = BrowserProfileStore(root: root)
    let grant = try store.prepareNew(project: root.path, connection: session.connection)
    try store.acknowledge(grant, session: session)
    let held = try BrowserProfileFileLock(directory: root, name: "profiles.lock")
    defer { held.release() }
    guard case .failed = ScheduledBrowserCleanup.close(session: session, runtime: root, root: root) else {
        Issue.record("An ownership change in progress must prevent browser cleanup")
        return
    }
    #expect(try store.ownedGrant(session: session) == grant)
}
