import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

private func registry(geminiVersion: String) -> Data {
    Data("""
    {"version": "1.0.0", "agents": [
      {"id": "gemini", "name": "Gemini CLI", "version": "\(geminiVersion)", "description": "Google's official CLI for Gemini",
       "distribution": {"npx": {"package": "@google/gemini-cli@\(geminiVersion)", "args": ["--acp"]}}},
      {"id": "other", "name": "Other", "version": "1.0.0", "distribution": {"npx": {"package": "other-acp@1.0.0"}}}
    ]}
    """.utf8)
}

private let link = AgentCatalogLink(
    id: "gemini", verifiedVersions: ["0.66.0"],
    fallback: AgentCatalogEntry(id: "gemini", name: "Gemini CLI", version: "0.66.0",
                                distribution: .init(npx: .init(package: "@google/gemini-cli", version: "0.66.0", args: ["--acp"]))),
    checkEnvironment: [:])

@MainActor private func controller(_ host: CatalogHost, npm: NPMFixture, agents: URL, clock: CatalogClock) -> AgentCatalogController {
    AgentCatalogController(directory: agents,
                           store: AgentCatalogStore(directory: agents, url: host.url("/registry.json"), configuration: host.configuration,
                                                    timeout: 5, now: { clock.now }),
                           installer: AgentCatalogInstaller(directory: agents, npmCandidates: [npm.npm.path], environment: npm.environment(bin: "gemini")),
                           now: { clock.now })
}

@MainActor @Test func agentCatalogControllerInstallsTheVerifiedVersionWhenTheCatalogsIsRejected() async throws {
    let host = CatalogHost(), npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), clock = CatalogClock()
    host.serve("/registry.json", body: registry(geminiVersion: "0.67.0"))
    let catalog = controller(host, npm: npm, agents: agents, clock: clock)

    // Opening Settings with nothing installed reads the cache only.
    await catalog.checkForUpdatesIfDue()
    #expect(host.requests.isEmpty)
    #expect(catalog.snapshot == nil)

    let record = try #require(await catalog.install(link))
    #expect(record.version == "0.66.0")
    #expect(npm.calls.first?.last == "@google/gemini-cli@0.66.0")
    #expect(catalog.messages["gemini"]?.isError == false)
    #expect(catalog.messages["gemini"]?.text.contains("0.67.0") == true)
    #expect(catalog.records["gemini"]?.version == "0.66.0")
    // 0.67.0 is newer but outside the verified branch: listed, never offered as an update.
    #expect(catalog.updates["gemini"]?.available == "0.67.0")
    #expect(catalog.offeredUpdate(link) == nil)
    #expect(host.requests.count == 1)
}

@MainActor @Test func agentCatalogControllerOffersSameMinorUpdatesAndChecksAtMostDaily() async throws {
    let host = CatalogHost(), npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), clock = CatalogClock()
    let version = CatalogLocked("0.66.0")
    host.serve("/registry.json") { _ in .init(body: registry(geminiVersion: version.withLock { $0 })) }
    let catalog = controller(host, npm: npm, agents: agents, clock: clock)
    _ = try #require(await catalog.install(link))
    #expect(catalog.offeredUpdate(link) == nil)

    version.withLock { $0 = "0.66.1" }
    clock.advance(25 * 3600)
    await catalog.checkForUpdatesIfDue()
    #expect(host.requests.count == 2)
    #expect(catalog.offeredUpdate(link)?.available == "0.66.1")
    // Opening Settings again the same day makes no request.
    clock.advance(3600)
    await catalog.checkForUpdatesIfDue()
    #expect(host.requests.count == 2)

    let updated = try #require(await catalog.install(link))
    #expect(updated.version == "0.66.1")
    #expect(catalog.messages["gemini"]?.text.contains("0.66.0") == true)
    #expect(catalog.offeredUpdate(link) == nil)
    #expect(await catalog.remove("gemini"))
    #expect(catalog.records.isEmpty)
}

@MainActor @Test func agentCatalogControllerFallsBackToThePinnedPackageOffline() async throws {
    let host = CatalogHost(), npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), clock = CatalogClock()
    host.serve("/registry.json") { _ in .init(fail: true) }
    let catalog = controller(host, npm: npm, agents: agents, clock: clock)
    let record = try #require(await catalog.install(link))
    #expect(record.version == "0.66.0")
    #expect(host.requests.count == 1)

    // A failed install is reported once and not retried.
    let failing = AgentCatalogController(directory: agents, store: AgentCatalogStore(directory: agents, url: host.url("/registry.json"),
                                                                                     configuration: host.configuration, timeout: 5),
                                         installer: AgentCatalogInstaller(directory: agents, npmCandidates: [npm.npm.path],
                                                                          environment: npm.environment(mode: "fail", bin: "gemini")))
    #expect(await failing.install(link) == nil)
    #expect(failing.messages["gemini"]?.isError == true)
    #expect(npm.calls.count == 2)
    #expect(failing.records["gemini"]?.version == "0.66.0")
}
