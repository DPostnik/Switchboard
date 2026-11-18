import Foundation
import Testing
@testable import ContextCore

@Test func scheduledImportPreservesPromptAndLegacyDefaults() throws {
    var job = ManagedJob(); job.name = "Fixture"; job.prompt = "Read only. Never send messages."; job.projectID = UUID()
    #expect(try job.browserExecutionPrompt() == job.prompt)
    let legacy = try JSONEncoder().encode(job)
    #expect(try JSONDecoder().decode(ManagedJob.self, from: legacy).browserSessionImport == nil)
    job.browserSessionImport = try .init(profile: "Profile 2", site: "linkedin.com")
    try job.validate()
    let restored = try JSONDecoder().decode(ManagedJob.self, from: JSONEncoder().encode(job))
    #expect(restored == job)
    let ru = try job.browserExecutionPrompt(language: .russian)
    let en = try job.browserExecutionPrompt(language: .english)
    #expect(ru.hasPrefix(job.prompt) && en.hasPrefix(job.prompt) && ru != en)
    #expect(en.contains("browser_import_session") && en.contains("Every run may import cookies"))
    #expect(en.contains("once with your tab's session and current expectedURL"))
    #expect(en.contains("or close regular Chrome") && en.contains("External actions require separate authorization"))
    job.engine = .claude
    try job.validate()
    let claude = ScheduledBrowserImport.instructions(try #require(job.browserSessionImport), tool: ScheduledBrowserImport.claudeImportTool, language: .english)
    #expect(claude.contains("call mcp__switchboard_browser__browser_import_session once with"))
    #expect(ScheduledBrowserImport.instructions(try #require(job.browserSessionImport), tool: ScheduledBrowserImport.claudeImportTool, language: .russian)
        .contains("вызови mcp__switchboard_browser__browser_import_session"))
    let any = try ChromeSessionImportPolicy(profile: "Default", site: ChromeSessionImportPolicy.anySite)
    #expect(ScheduledBrowserImport.instructions(any, language: .english).contains("any site the task needs"))
    #expect(ScheduledBrowserImport.instructions(any, language: .russian).contains("любого нужного сайта"))
    job.browserSessionImport = any
    try job.validate()
    job.browserSessionImport = try JSONDecoder().decode(ChromeSessionImportPolicy.self, from: Data(#"{"profile":"Default","site":"not a domain"}"#.utf8))
    #expect(throws: (any Error).self) { try job.validate() }
}

@Test func scheduledImportPropagatesToFreshProfilesWithoutSharingCookies() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserProfileStore(root: root)
    let policy = try ChromeSessionImportPolicy(profile: "Default", site: "linkedin.com")
    var paths: [URL] = []
    for id in ["run-one", "run-two", "unrelated"] {
        let session = AgentSessionReference(connection: .originalCodex, nativeID: id)
        let grant = try store.prepareNew(project: root.path, connection: .originalCodex)
        try store.acknowledge(grant, session: session)
        let path = store.environment(grant.environment)
        paths.append(path)
        #expect(try ChromeSessionImportPolicy.load(environment: path) == nil)
        if id != "unrelated" {
            try ScheduledBrowserImport.install(policy, session: session, browserEnabled: true, root: root)
            #expect(try ChromeSessionImportPolicy.load(environment: path) == policy)
        }
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("testing-profile").path))
    }
    #expect(Set(paths).count == 3)
    #expect(try ChromeSessionImportPolicy.load(environment: paths[2]) == nil)
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "unrelated")
    #expect(throws: (any Error).self) { try ScheduledBrowserImport.install(policy, session: session, browserEnabled: false, root: root) }
    #expect(try ChromeSessionImportPolicy.load(environment: paths[2]) == nil)
    // Claude Code scheduled runs use the app Claude connection; foreign connections stay rejected.
    let claude = AgentSessionReference(connection: .appClaude, nativeID: "scheduled-run")
    let grant = try store.prepareNew(project: root.path, connection: .appClaude)
    try store.acknowledge(grant, session: claude)
    try ScheduledBrowserImport.install(policy, session: claude, browserEnabled: true, root: root)
    #expect(try ChromeSessionImportPolicy.load(environment: store.environment(grant.environment)) == policy)
    let foreign = AgentSessionReference(connection: .init(agent: .claudeCode, id: UUID()), nativeID: "scheduled-run")
    #expect(throws: (any Error).self) { try ScheduledBrowserImport.install(policy, session: foreign, browserEnabled: true, root: root) }
}

@Test @MainActor func schedulerConfiguresBrowserImportThroughOwnerWithoutRunningTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    var job = ManagedJob(); job.name = "Fixture"; job.prompt = "Read only"; job.projectID = UUID()
    job.model = "fixture-model"; job.effort = "medium"
    _ = try await store.save(job)
    job = try #require(try await store.load().jobs.first)
    let policy = try ChromeSessionImportPolicy(profile: "Default", site: "linkedin.com")
    let inbox = root.appendingPathComponent("control")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    func request(_ fields: [String: Any]) throws -> UUID {
        let id = UUID()
        var body: [String: Any] = ["version": 1, "id": id.uuidString, "expires": Date().addingTimeInterval(60).timeIntervalSinceReferenceDate,
                                  "operation": "browser-import", "expected": try JSONSerialization.jsonObject(with: JSONEncoder().encode(job))]
        body.merge(fields) { _, new in new }
        let path = inbox.appendingPathComponent(id.uuidString + ".request.json")
        try JSONSerialization.data(withJSONObject: body).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return id
    }
    func response(_ id: UUID) throws -> ScheduleControlReply {
        try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: inbox.appendingPathComponent(id.uuidString + ".response.json")))
    }
    let id = try request(["browserSessionImport": ["profile": "Default", "site": "linkedin.com"]])
    try await ScheduleControl.drain(directory: inbox) { input in
        let updated = try ScheduleControl.updated(input, originalPaused: false)
        return try await store.save(updated, expected: input.expected).jobs
    }
    let result = try #require(try response(id).jobs?.first)
    #expect(result.browserSessionImport == policy)
    var expected = job; expected.browserSessionImport = policy
    #expect(result == expected)
    #expect(try await store.load().runs.isEmpty)
    job = result
    let invalid = try request(["browserSessionImport": ["profile": "Default", "site": "linkedin.com"], "enabled": true])
    try await ScheduleControl.drain(directory: inbox) { _ in Issue.record("Mixed permission updates must be rejected"); return [] }
    #expect(try response(invalid).status == "rejected")
    let revoked = try request(["clearBrowserSessionImport": true])
    try await ScheduleControl.drain(directory: inbox) { input in
        try await store.save(ScheduleControl.updated(input, originalPaused: false), expected: input.expected).jobs
    }
    #expect(try response(revoked).jobs?.first?.browserSessionImport == nil)
    await store.release()
}

@Test func scheduledPreflightTransfersOnlyPolicySiteOnceBeforeDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserProfileStore(root: root)
    let session = AgentSessionReference(connection: .appClaude, nativeID: "preflight-run")
    let grant = try store.prepareNew(project: root.path, connection: .appClaude)
    try store.acknowledge(grant, session: session)
    let policy = try ChromeSessionImportPolicy(profile: "Profile 2", site: "linkedin.com")
    let runtime = root.appendingPathComponent("runtime")
    let cookie = ImportedChromeCookie(host: ".linkedin.com", name: "li_at", value: "secret", path: "/", secure: true, httpOnly: true, sameSite: nil, expires: nil)
    final class Calls: @unchecked Sendable { var reads: [[String]] = []; var transfers = 0 }
    let calls = Calls()
    let read: @Sendable (String, String) throws -> ChromeCookieRead = { profile, site in
        calls.reads.append([profile, site]); return ChromeCookieRead(cookies: [cookie])
    }
    let imported = await ScheduledBrowserImport.preflight(policy, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: read, transfer: { _, environment, owned in
            calls.transfers += 1
            #expect(environment == store.environment(grant.environment) && owned == grant)
            return ChromeCookieImportResult(verified: 1, skipped: 0, unverified: 0)
        })
    #expect(imported == .imported(verified: 1))
    #expect(calls.reads == [["Profile 2", "linkedin.com"]] && calls.transfers == 1)
    // Wildcard policies keep the agent-driven import; nothing is read up front.
    let any = try ChromeSessionImportPolicy(profile: "Default", site: ChromeSessionImportPolicy.anySite)
    #expect(await ScheduledBrowserImport.preflight(any, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: read, transfer: { _, _, _ in Issue.record("no transfer"); throw ChromeCookieError.connection }) == .skipped)
    #expect(calls.reads.count == 1)
    // Definite failures block; an unconfirmed write is reported as uncertain and never retried.
    #expect(await ScheduledBrowserImport.preflight(policy, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: { _, _ in throw ChromeCookieError.keychain }, transfer: { _, _, _ in throw ChromeCookieError.connection }) == .blocked(.keychain))
    #expect(await ScheduledBrowserImport.preflight(policy, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: { _, _ in ChromeCookieRead() }, transfer: { _, _, _ in Issue.record("no transfer"); throw ChromeCookieError.connection }) == .blocked(.empty))
    let before = calls.transfers
    #expect(await ScheduledBrowserImport.preflight(policy, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: read, transfer: { _, _, _ in calls.transfers += 1; throw ChromeCookieError.uncertain }) == .uncertain)
    #expect(calls.transfers == before + 1)
    // A full browser limit is refused before launch: cookies are read once, admission waits for a slot,
    // and without one the agent keeps its own import step.
    final class Attempts: @unchecked Sendable { var reads = 0; var sends = 0; var waits = 0 }
    let full = Attempts()
    #expect(await ScheduledBrowserImport.preflight(policy, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: { _, _ in full.reads += 1; return ChromeCookieRead(cookies: [cookie]) },
        transfer: { _, _, _ in
            full.sends += 1
            if full.sends < 3 { throw ChromeCookieError.browserLimit }
            return ChromeCookieImportResult(verified: 1, skipped: 0, unverified: 0)
        }, wait: { full.waits += 1 }) == .imported(verified: 1))
    #expect(full.reads == 1 && full.sends == 3 && full.waits == 2)
    let never = Attempts()
    #expect(await ScheduledBrowserImport.preflight(policy, session: session, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: read, transfer: { _, _, _ in never.sends += 1; throw ChromeCookieError.browserLimit },
        slotWaits: 3, wait: { never.waits += 1 }) == .skipped)
    #expect(never.sends == 4 && never.waits == 3)
    let stranger = AgentSessionReference(connection: .appClaude, nativeID: "no-environment")
    #expect(await ScheduledBrowserImport.preflight(policy, session: stranger, runtime: runtime, maxBrowsers: 2, root: root,
        sourceIsRunning: { true }, read: read, transfer: { _, _, _ in throw ChromeCookieError.connection }) == .blocked(.missingEnvironment))
}

@Test func scheduledPreflightReplacesImportStepInBothLanguages() throws {
    let policy = try ChromeSessionImportPolicy(profile: "Default", site: "linkedin.com")
    let tool = ScheduledBrowserImport.claudeImportTool
    for language in [AppLanguage.russian, .english] {
        var job = ManagedJob()
        job.engine = .claude
        job.browserSessionImport = policy
        job.prompt = JobPrecondition.prompt("Use only the sources with new items.", output: "mail: 2 new items", language: language)
        let markers = AttentionMarkers.instructions(language: language)
        let prompt = try job.browserExecutionPrompt(language: language) + "\n\n" + markers
        let imported = ScheduledBrowserImport.applying(.imported(verified: 7), policy: policy, to: prompt, tool: tool, language: language)
        #expect(imported.hasPrefix(job.prompt) && imported.hasSuffix(markers))
        #expect(imported.contains("```\nmail: 2 new items\n```"))
        #expect(!imported.contains(ScheduledBrowserImport.instructions(policy, tool: tool, language: language)))
        #expect(imported.contains("linkedin.com"))
        let blocked = ScheduledBrowserImport.applying(.blocked(.keychain), policy: policy, to: prompt, tool: tool, language: language)
        #expect(blocked.contains(ChromeCookieError.keychain.message(language: language)))
        #expect(ScheduledBrowserImport.applying(.skipped, policy: policy, to: prompt, tool: tool, language: language) == prompt)
        // A prompt without the standard paragraph still receives the outcome.
        #expect(ScheduledBrowserImport.applying(.uncertain, policy: policy, to: "Plain", tool: tool, language: language).hasPrefix("Plain\n\n"))
    }
    let en = ScheduledBrowserImport.instructions(policy, preflight: .imported(verified: 3), tool: tool, language: .english)
    let ru = ScheduledBrowserImport.instructions(policy, preflight: .imported(verified: 3), tool: tool, language: .russian)
    #expect(en.contains("Only if the task needs this site, open it and check protected content"))
    #expect(ru.contains("Только если задаче нужен этот сайт, открой его и проверь защищённое содержимое"))
    #expect(en.contains("Do not call \(tool) in this run") && en.contains("sign in to linkedin.com in regular Chrome"))
    #expect(ru.contains("Не вызывай \(tool) в этом запуске") && ru.contains("войти в linkedin.com в обычном Chrome"))
    #expect(en.contains("External actions require separate authorization") && ru.contains("Для внешних действий требуется отдельное разрешение"))
}
