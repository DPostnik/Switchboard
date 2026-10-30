import Foundation
import Testing
@testable import ContextCore

private func idbConsentRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func idbEnvironment() throws -> (browserRoot: URL, environment: URL) {
    let browserRoot = idbConsentRoot()
    let env = browserRoot.appendingPathComponent("environments").appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
    return (browserRoot, env)
}

@Test func indexedDBConsentRejectsWildcardAndBadProfile() {
    #expect(throws: ChromeCookieError.invalidProfile) { _ = try ChromeIndexedDBConsent(profile: "Default", site: "*") }
    #expect(throws: ChromeCookieError.invalidProfile) { _ = try ChromeIndexedDBConsent(profile: "Nope", site: "example.com") }
    #expect(throws: ChromeCookieError.invalidProfile) { _ = try ChromeIndexedDBConsent(profile: "Default", site: "singlelabel") }
}

@Test func indexedDBConsentRoundTripsAndResolves() throws {
    let (browserRoot, env) = try idbEnvironment()
    defer { try? FileManager.default.removeItem(at: browserRoot) }
    let consent = try ChromeIndexedDBConsent(profile: "Default", site: "Example.com")
    try ChromeIndexedDBConsent.write(consent, folder: env, file: ChromeIndexedDBConsent.file(env))
    let loaded = try #require(try ChromeIndexedDBConsent.load(environment: env))
    #expect(loaded.site == "example.com" && loaded.profile == "Default")
    let scope = try #require(try ChromeIndexedDBConsent.resolve(site: "example.com", environment: env, browserRoot: browserRoot))
    #expect(scope.profile == "Default" && scope.site == "example.com")
    // A registrable-domain grant covers a subdomain; the cloned origin is the exact host.
    let sub = try #require(try ChromeIndexedDBConsent.resolve(site: "www.example.com", environment: env, browserRoot: browserRoot))
    #expect(sub.site == "www.example.com" && sub.profile == "Default")
    #expect(try ChromeIndexedDBConsent.resolve(site: "other.com", environment: env, browserRoot: browserRoot) == nil)
}

@Test func indexedDBConsentSignatureIsBoundToFolder() throws {
    let (browserRoot, env) = try idbEnvironment()
    defer { try? FileManager.default.removeItem(at: browserRoot) }
    let other = browserRoot.appendingPathComponent("environments").appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let consent = try ChromeIndexedDBConsent(profile: "Default", site: "example.com")
    try ChromeIndexedDBConsent.write(consent, folder: env, file: ChromeIndexedDBConsent.file(env))
    // Copying the signed file into a different environment must fail: the MAC binds the folder path.
    try FileManager.default.copyItem(at: ChromeIndexedDBConsent.file(env), to: ChromeIndexedDBConsent.file(other))
    #expect(throws: ChromeCookieError.unsignedPolicy) { _ = try ChromeIndexedDBConsent.load(environment: other) }
}

@Test func indexedDBConsentSignatureDiffersFromCookiePolicy() throws {
    let (browserRoot, env) = try idbEnvironment()
    defer { try? FileManager.default.removeItem(at: browserRoot) }
    // A cookie consent for the same site must not satisfy the IndexedDB load (distinct MAC domain).
    let cookie = try ChromeSessionImportPolicy(profile: "Default", site: "example.com")
    try ChromeSessionImportPolicy.write(cookie, folder: env, file: ChromeIndexedDBConsent.file(env))
    #expect(throws: ChromeCookieError.unsignedPolicy) { _ = try ChromeIndexedDBConsent.load(environment: env) }
}
