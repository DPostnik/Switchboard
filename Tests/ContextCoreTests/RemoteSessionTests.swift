import Foundation
import Testing
@testable import ContextCore

private final class RemoteAuthFixture: @unchecked Sendable {
    let lock = NSLock()
    var saved: Data?
    var refreshes = 0
    var failRefresh = false
    var failStorage = false
    var writes: [Data?] = []
    var submitStatus = 201
    var submits = 0
    func respond(_ request: URLRequest) -> (Int, Data) {
        if request.httpMethod == "POST" && request.url!.path.hasSuffix("/remote_commands") {
            return lock.withLock { submits += 1; return (submitStatus, Data()) }
        }
        if request.url!.path.contains("/token") {
            let refresh = request.url!.query!.contains("refresh_token")
            if refresh { lock.withLock { refreshes += 1 }; Thread.sleep(forTimeInterval: 0.1) }
            if refresh && failRefresh { return (503, Data()) }
            return (200, try! JSONSerialization.data(withJSONObject: [
                "access_token": refresh ? "new" : "old", "refresh_token":"fixture-refresh",
                "expires_at": refresh ? Date().timeIntervalSince1970 + 3600 : 0,
                "user":["id":"11111111-1111-1111-1111-111111111111"]
            ]))
        }
        return (200, Data("[]".utf8))
    }
    var storage: RemoteSessionStorage {
        RemoteSessionStorage(read: { _ in self.lock.withLock { self.saved } }, write: { data, _ in
            try self.lock.withLock {
                if data != nil && self.failStorage && self.refreshes > 0 { throw RemoteFailure.keychain(-25293) }
                self.writes.append(data)
                self.saved = data
            }
        })
    }
}
private final class AuthFixtureRegistry: @unchecked Sendable {
    let lock = NSLock()
    var entries: [String: RemoteAuthFixture] = [:]
    func get(_ host: String) -> RemoteAuthFixture? { lock.withLock { entries[host] } }
    func set(_ host: String, _ value: RemoteAuthFixture?) { lock.withLock { entries[host] = value } }
}
private final class AuthURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = AuthFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.get(request.url!.host!) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession can deliver a cancelled request after its test has torn
        // down the registry. This is an expected sign-out race, not a fixture.
        guard let fixture = Self.registry.get(request.url!.host!) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        let (code, data) = fixture.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func fixtureAPI(_ fixture: RemoteAuthFixture, host: String) throws -> RemoteAPI {
    AuthURLProtocol.registry.set(host, fixture)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AuthURLProtocol.self]
    return try RemoteAPI(url: "https://" + host, key: "sb_publishable_fixture",
                         transport: URLSession(configuration: configuration), storage: fixture.storage)
}

@Test func remoteRESTAndSocketShareOnePersistedTokenRefresh() async throws {
    let fixture = RemoteAuthFixture(); let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    async let devices = api.devices()
    async let token = api.realtimeCredentials()
    let (_, credentials) = try await (devices, token)
    #expect(credentials.token == "new")
    #expect(fixture.lock.withLock { fixture.refreshes } == 1)
    let saved = try #require(fixture.lock.withLock { fixture.saved })
    #expect((try JSONSerialization.jsonObject(with: saved) as? [String: Any])?["access_token"] as? String == "new")
    let writes = fixture.lock.withLock { fixture.writes }
    #expect(writes.count == 3)
    #expect(writes[1] == Data())
    #expect(writes.allSatisfy { $0 != nil })
}

@Test func remoteAmbiguousRefreshIsNeverRetried() async throws {
    let fixture = RemoteAuthFixture(); fixture.failRefresh = true
    let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    for _ in 0..<2 {
        do { _ = try await api.realtimeCredentials(); Issue.record("Expected signed out") }
        catch RemoteFailure.signedOut {}
    }
    #expect(fixture.lock.withLock { fixture.refreshes } == 1)
    #expect(fixture.lock.withLock { fixture.saved } == Data())
    let restored = try fixtureAPI(fixture, host: host)
    do { _ = try await restored.realtimeCredentials(); Issue.record("An uncertain refresh was restored") }
    catch RemoteFailure.signedOut {}
    #expect(fixture.lock.withLock { fixture.refreshes } == 1)
}

@Test func remoteSignOutDuringRefreshCannotRestoreSession() async throws {
    let fixture = RemoteAuthFixture(); let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    let task = Task { try await api.realtimeCredentials() }
    for _ in 0..<100 {
        if fixture.lock.withLock({ fixture.refreshes > 0 }) { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    try await api.signOut()
    do { _ = try await task.value; Issue.record("A signed-out refresh completed") }
    catch RemoteFailure.signedOut {}
    #expect(fixture.lock.withLock { fixture.saved } == nil)
    do { _ = try await api.owner(); Issue.record("Signed out API has an owner") }
    catch RemoteFailure.signedOut {}
}

@Test func remoteRefreshStorageFailureIsPreservedForAllWaiters() async throws {
    let fixture = RemoteAuthFixture(); fixture.failStorage = true
    let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    let tasks = (0..<2).map { _ in Task { try await api.realtimeCredentials() } }
    for task in tasks {
        do { _ = try await task.value; Issue.record("A token escaped failed persistence") }
        catch RemoteFailure.keychain(let code) { #expect(code == -25293) }
    }
    #expect(fixture.lock.withLock { fixture.refreshes } == 1)
}

@Test func remoteRestoredIdentityDoesNotRefreshBeforeNetworkIsAvailable() async throws {
    let fixture = RemoteAuthFixture(); let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    let restored = try fixtureAPI(fixture, host: host)
    #expect(try await restored.owner() == "11111111-1111-1111-1111-111111111111")
    #expect(fixture.lock.withLock { fixture.refreshes } == 0)
}

@Test func remoteRefreshRequiresPersistedInvalidationBeforeSending() async throws {
    let fixture = RemoteAuthFixture(); let host = UUID().uuidString.lowercased() + ".invalid"
    let initial = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await initial.signIn(email: "fixture", password: "fixture")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AuthURLProtocol.self]
    let storage = fixture.storage
    let api = try RemoteAPI(url: "https://" + host, key: "sb_publishable_fixture",
                            transport: URLSession(configuration: configuration),
                            storage: RemoteSessionStorage(read: storage.read, write: { data, account in
        if data == Data() { throw RemoteFailure.keychain(-25293) }
        try storage.write(data, account)
    }))
    do { _ = try await api.realtimeCredentials(); Issue.record("Refresh escaped failed invalidation") }
    catch RemoteFailure.keychain(let code) { #expect(code == -25293) }
    #expect(fixture.lock.withLock { fixture.refreshes } == 0)
}

@Test func remoteSubmitReportsOnlyProvenNonStorage() async throws {
    let command = RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString,
                                chat: UUID().uuidString, kind: "send", text: "Fixture")
    for (code, notStored) in [(400, true), (401, true), (403, true), (408, false), (500, false), (504, false)] {
        let fixture = RemoteAuthFixture(); fixture.submitStatus = code
        let host = UUID().uuidString.lowercased() + ".invalid"
        let api = try fixtureAPI(fixture, host: host)
        defer { AuthURLProtocol.registry.set(host, nil) }
        try await api.signIn(email: "fixture", password: "fixture")
        do { try await api.submit(command); Issue.record("Expected a failure for \(code)") }
        catch let failure as RemoteNotStored {
            #expect(notStored, "Status \(code) must stay unknown")
            guard case RemoteFailure.request(code) = failure.cause else { Issue.record("Wrong cause for \(code)"); continue }
        } catch {
            #expect(!notStored, "Status \(code) proves nothing was stored")
        }
    }
}

@Test func remoteSubmitConflictMeansTheCommandIsStored() async throws {
    let fixture = RemoteAuthFixture(); fixture.submitStatus = 409
    let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    try await api.submit(RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString,
                                       chat: UUID().uuidString, kind: "send", text: "Fixture"))
}

@Test func remoteSubmitWithoutSessionNeverSends() async throws {
    let fixture = RemoteAuthFixture(); fixture.failRefresh = true
    let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try fixtureAPI(fixture, host: host)
    defer { AuthURLProtocol.registry.set(host, nil) }
    try await api.signIn(email: "fixture", password: "fixture")
    do {
        try await api.submit(RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString,
                                           chat: UUID().uuidString, kind: "send", text: "Fixture"))
        Issue.record("Expected not stored")
    } catch let failure as RemoteNotStored {
        guard case RemoteFailure.signedOut = failure.cause else { Issue.record("Wrong cause"); return }
    }
    #expect(fixture.lock.withLock { fixture.submits } == 0)
}
