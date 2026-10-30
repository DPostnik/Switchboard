import CryptoKit
import Foundation
import Testing
import AgentContract
@testable import ContextCore

private struct ProfileFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("profiles-" + UUID().uuidString)
    var store: BrowserProfileStore { .init(root: root) }
    let a = AgentSessionReference(connection: .originalCodex, nativeID: "a")
    let b = AgentSessionReference(connection: .originalCodex, nativeID: "b")
    func start(_ session: AgentSessionReference) throws -> BrowserProfileGrant {
        let grant = try store.prepareNew(project: root.path, connection: session.connection)
        try store.acknowledge(grant, session: session)
        return grant
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func reusableProfilesPreserveDirectoryAndRejectOldOwnerAcrossRestart() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let first = try f.start(f.a)
    try f.store.rename(session: f.a, name: "Work")
    let path = f.store.environment(first.environment).appendingPathComponent("testing-profile")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    try Data("fixture site state".utf8).write(to: path.appendingPathComponent("fixture"))
    #expect(throws: BrowserProfileError.busy) {
        try f.store.prepareNew(project: f.root.path, connection: .originalCodex, selection: .init(id: first.environment), verifyClosed: { _ in })
    }
    try f.store.release(session: f.a, verifyClosed: { #expect($0 == f.store.environment(first.environment)) })
    let reloaded = BrowserProfileStore(root: f.root)
    let next = try reloaded.prepareNew(project: f.root.path, connection: .originalCodex, selection: .init(id: first.environment), verifyClosed: { _ in })
    #expect(next.environment == first.environment && next.generation != first.generation)
    #expect(throws: BrowserProfileError.released) { try reloaded.validate(first, environment: first.environment) }
    #expect(throws: BrowserProfileError.released) { try reloaded.validate(next, environment: next.environment) }
    try reloaded.acknowledge(next, session: f.b)
    try reloaded.validate(next, environment: next.environment)
    #expect(throws: BrowserProfileError.released) { try reloaded.prepare(session: f.a, project: f.root.path) }
    #expect(try Data(contentsOf: path.appendingPathComponent("fixture")) == Data("fixture site state".utf8))
}

@Test func profileBindingMigrationIsConnectionScopedAndPreservesLegacyDirectory() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let legacy = try BrowserEnvironmentStore.environment(session: f.a.nativeID, root: f.root)
    let first = try f.store.prepare(session: f.a, project: f.root.path)
    #expect(first.environment == legacy)
    try f.store.acknowledge(first, session: f.a)
    let other = AgentSessionReference(connection: .init(agent: .codex, id: UUID()), nativeID: f.a.nativeID)
    let second = try f.store.prepare(session: other, project: f.root.path)
    #expect(second.environment != legacy)
    #expect(BrowserProfileStore.key(f.a) != BrowserProfileStore.key(other))
    #expect(try BrowserEnvironmentStore.existingEnvironment(session: f.a.nativeID, root: f.root)?.lastPathComponent == legacy.uuidString.lowercased())
    #expect(throws: BrowserProfileError.scope) { try f.store.prepare(session: f.a, project: f.root.appendingPathComponent("another-project").path) }
}

@Test func memoizedProfileKeyKeepsPersistedFormat() throws {
    let session = AgentSessionReference(connection: .init(agent: .codex, id: UUID()), nativeID: "memo-" + UUID().uuidString)
    let data = try JSONEncoder().encode([session.connection.agent.rawValue, session.connection.id.uuidString.lowercased(), session.nativeID])
    let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(BrowserProfileStore.key(session) == expected)
    #expect(BrowserProfileStore.key(session) == expected)
    #expect(BrowserProfileStore.key(.init(connection: session.connection, nativeID: session.nativeID + "x")) != expected)
}

@Test func profileChangeRequiresClosedChromeAndAcknowledgementBeforeDispatch() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let first = try f.start(f.a)
    #expect(throws: BrowserProfileError.closeFirst) {
        try f.store.select(nil, session: f.a, project: f.root.path) { _ in throw BrowserProfileError.closeFirst }
    }
    #expect(try f.store.ownedGrant(session: f.a) == first)
    try f.store.select(nil, session: f.a, project: f.root.path, verifyClosed: { _ in })
    #expect(throws: BrowserProfileError.released) { try f.store.validate(first, environment: first.environment) }
    let next = try f.store.prepare(session: f.a, project: f.root.path)
    #expect(next.environment != first.environment)
    #expect(throws: BrowserProfileError.uncertain) { try f.store.prepare(session: f.a, project: f.root.path) }
    #expect(throws: BrowserProfileError.released) { try f.store.validate(next, environment: next.environment) }
    try f.store.acknowledge(next, session: f.a)
    #expect(try f.store.prepare(session: f.a, project: f.root.path) == next)
    #expect(throws: BrowserProfileError.uncertain) { try f.store.acknowledge(first, session: f.a) }
}

@Test func profileLocksAndUncertaintyNeverAffectIndependentProfile() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let a = try f.start(f.a), b = try f.start(f.b)
    let held = try BrowserProfileFileLock(directory: f.store.environment(a.environment), name: "operation.lock")
    #expect(throws: BrowserProfileError.busy) { try f.store.humanControl(session: f.a, take: true) }
    try f.store.humanControl(session: f.b, take: true)
    #expect(try f.store.current(session: f.b)?.state == .human)
    held.release()
    let fence = f.store.environment(a.environment).appendingPathComponent("executor-in-flight.json")
    try Data("{}".utf8).write(to: fence)
    #expect(throws: BrowserProfileError.uncertain) { try f.store.humanControl(session: f.a, take: true) }
    try f.store.validate(a, environment: a.environment)
    #expect(throws: BrowserProfileError.released) { try f.store.validate(b, environment: b.environment, allowHuman: true) }
}

@Test func humanControlRotatesLeaseAndReturnRequiresExplicitActivation() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let first = try f.start(f.a)
    try f.store.humanControl(session: f.a, take: true)
    let human = try f.store.ownedGrant(session: f.a, allowHuman: true)
    #expect(human.generation != first.generation)
    #expect(throws: BrowserProfileError.released) { try f.store.validate(human, environment: human.environment) }
    try f.store.validate(human, environment: human.environment, allowHuman: true)
    try f.store.humanControl(session: f.a, take: false)
    let returned = try f.store.prepare(session: f.a, project: f.root.path)
    try f.store.acknowledge(returned, session: f.a)
    #expect(returned.generation != human.generation)
    try f.store.validate(returned, environment: returned.environment)
}

@Test func profileCatalogCorruptionAndForeignScopeFailClosed() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let first = try f.start(f.a)
    try f.store.rename(session: f.a, name: "Work")
    try f.store.release(session: f.a, verifyClosed: { _ in })
    #expect(try f.store.profiles(project: f.root.appendingPathComponent("other").path, connection: .originalCodex).isEmpty)
    #expect(throws: BrowserProfileError.scope) {
        try f.store.select(first.environment, session: .init(connection: .init(agent: .claudeCode, id: UUID()), nativeID: "a"), project: f.root.path, verifyClosed: { _ in })
    }
    try Data("{broken}".utf8).write(to: f.root.appendingPathComponent("profiles.json"))
    #expect(throws: BrowserProfileError.storage) { try f.store.prepare(session: f.a, project: f.root.path) }
    #expect(throws: BrowserProfileError.storage) { try f.store.validate(nil, environment: first.environment) }
}

@Test func browserProfileErrorsHavePairedLocalizedRecovery() {
    for error in BrowserProfileError.allCases {
        #expect(!error.message(language: .russian).isEmpty)
        #expect(!error.message(language: .english).isEmpty)
        #expect(error.message(language: .russian) != error.message(language: .english))
    }
}

@Test func browserProfileSelectionRejectsUnsupportedProvidersAndScheduledJobs() {
    let context = AgentContext(connection: .originalCodex, accountRevision: UUID())
    func descriptor(_ capabilities: Set<AgentCapability>) -> AgentDescriptor {
        .init(context: context, identityMode: .appOwnedHome, capabilities: capabilities, permissions: .codexProjectPolicy, routes: [.direct])
    }
    func request(_ kind: AgentExecutionRequest.Kind) -> AgentExecutionRequest {
        .init(conversation: .init(), kind: kind, prompt: "", projectPath: "/tmp", permissions: .workspaceWrite(root: "/tmp", network: false, approval: .ask),
              model: .init(context: context, model: ""), route: .direct, browserProfile: .init(id: UUID()))
    }
    #expect(descriptor([.interactiveSessions]).validate(request(.interactive)) == .unsupported(.browserProfiles))
    #expect(descriptor([.interactiveSessions, .browserProfiles]).validate(request(.interactive)) == nil)
    #expect(descriptor([.scheduledExecution, .browserProfiles]).validate(request(.scheduled)) == .invalidInput)
}

@Test func runningBrowsersReportOnlyVerifiedChromeForTestingOfBoundSessions() throws {
    let f = ProfileFixture(); defer { f.cleanup() }
    let first = try f.start(f.a), second = try f.start(f.b)
    let chrome = f.root.appendingPathComponent("chrome-for-testing/154/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing").path
    func record(_ grant: BrowserProfileGrant, pid: Int, executable: String) throws {
        let directory = f.store.environment(grant.environment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": pid, "executable": executable])
            .write(to: directory.appendingPathComponent("testing-chrome-owner.json"))
    }
    try record(first, pid: 101, executable: chrome)
    try record(second, pid: 202, executable: chrome)
    // PID 202 now belongs to another program: it is not reported as this chat's browser.
    let paths: [Int32: String] = [101: chrome, 202: "/bin/sleep"]
    #expect(f.store.runningBrowsers { paths[$0] } == [BrowserProfileStore.key(f.a): 101])
    try record(second, pid: 202, executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    #expect(f.store.runningBrowsers { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }.isEmpty)
    #expect(BrowserProfileStore.executablePath(getpid()) != nil)
}
