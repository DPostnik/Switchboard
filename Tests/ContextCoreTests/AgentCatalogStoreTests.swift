import Foundation
import Testing
@testable import ContextCore

private func makeStore(_ host: CatalogHost, directory: URL, clock: CatalogClock) -> AgentCatalogStore {
    AgentCatalogStore(directory: directory, url: host.url("/registry.json"), configuration: host.configuration, timeout: 5,
                      now: { clock.now })
}

@Test func agentCatalogStoreFetchesOnlyOnRefreshAndReusesTheCacheForADay() async throws {
    let host = CatalogHost(), directory = try catalogTemporaryDirectory(), clock = CatalogClock()
    host.serve("/registry.json", body: try Data(contentsOf: catalogFixture), headers: ["ETag": "\"abc\"", "Last-Modified": "Mon, 02 Nov 2026 18:45:57 GMT"])
    let store = makeStore(host, directory: directory, clock: clock)
    #expect(await store.cached() == nil)
    #expect(host.requests.isEmpty)

    let first = try await store.refresh()
    #expect(first.catalog.entry("gemini")?.version == "0.66.0")
    #expect(!first.stale)
    #expect(host.requests.count == 1)
    #expect(host.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)

    clock.advance(23 * 3600)
    _ = try await store.refresh()
    #expect(host.requests.count == 1)
    let cached = try #require(await store.cached())
    #expect(!cached.stale)

    // A new store on the same folder reads the cache file.
    let reopened = makeStore(host, directory: directory, clock: clock)
    #expect(await reopened.cached()?.catalog.entries.count == 4)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog.json").path))
}

@Test func agentCatalogStoreRevalidatesAfterADayAndKeepsTheCopyOn304() async throws {
    let host = CatalogHost(), directory = try catalogTemporaryDirectory(), clock = CatalogClock()
    let body = try Data(contentsOf: catalogFixture)
    host.serve("/registry.json") { request in
        request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"" ? .init(status: 304)
            : .init(headers: ["ETag": "\"abc\"", "Last-Modified": "Mon, 02 Nov 2026 18:45:57 GMT"], body: body)
    }
    let store = makeStore(host, directory: directory, clock: clock)
    _ = try await store.refresh()
    clock.advance(25 * 3600)
    #expect(await store.cached()?.stale == true)
    let revalidated = try await store.refresh()
    #expect(host.requests.count == 2)
    #expect(host.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    #expect(host.requests[1].value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 02 Nov 2026 18:45:57 GMT")
    #expect(!revalidated.stale)
    #expect(revalidated.catalog.entries.count == 4)
    #expect(abs(revalidated.fetchedAt.timeIntervalSince(clock.now)) < 1)
    // Forced refresh asks again even when fresh.
    _ = try await store.refresh(force: true)
    #expect(host.requests.count == 3)
}

@Test func agentCatalogStoreReturnsTheCacheMarkedStaleWhenTheNetworkFails() async throws {
    let host = CatalogHost(), directory = try catalogTemporaryDirectory(), clock = CatalogClock()
    let body = try Data(contentsOf: catalogFixture)
    let mode = CatalogLocked(0)
    host.serve("/registry.json") { _ in
        switch mode.withLock({ $0 }) {
        case 0: .init(body: body)
        case 1: .init(fail: true)
        case 2: .init(status: 500)
        default: .init(body: Data("<html>oops</html>".utf8))
        }
    }
    let store = makeStore(host, directory: directory, clock: clock)
    _ = try await store.refresh()
    for next in 1...3 {
        mode.withLock { $0 = next }
        let snapshot = try await store.refresh(force: true)
        #expect(snapshot.stale)
        #expect(snapshot.failure != nil)
        #expect(snapshot.catalog.entries.count == 4)
    }
    // One request per refresh: no retries.
    #expect(host.requests.count == 4)
    // The bad answers never replaced the cached copy.
    #expect(await store.cached()?.catalog.entries.count == 4)
}

@Test func agentCatalogStoreThrowsWithoutACacheWhenTheNetworkFails() async throws {
    let host = CatalogHost(), directory = try catalogTemporaryDirectory(), clock = CatalogClock()
    host.serve("/registry.json") { _ in .init(fail: true) }
    let store = makeStore(host, directory: directory, clock: clock)
    await #expect(throws: AgentCatalogFetchFailure.self) { try await store.refresh() }
    #expect(host.requests.count == 1)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog.json").path))
}
