import CryptoKit
import Foundation
import Testing
import CSQLite
@testable import ContextCore

// OpenSSL-generated vectors; no user profiles or Keychain items are read.
private let domainCipher = "7631301ed2c90284df3c92295d12077eddf3a39d9f5e797292a851f735783b36e7d42c6816f7db3238d65468cc9683102bf787"
private let legacyCipher = "763130a114d6303d481cc497ab87aceb9aaafa"
private func hexData(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { offset in
        let index = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[index..<hex.index(index, offsetBy: 2)], radix: 16)!
    })
}
private func temporaryCookies() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Network"), withIntermediateDirectories: true)
    try Data(#"{"profile":{"info_cache":{"Default":{"name":"Fixture"},"../escape":{"name":"Bad"}}}}"#.utf8)
        .write(to: root.appendingPathComponent("Local State"))
    return root
}
private func fixtureDatabase(root: URL, schema: Int = 24, rows: String) throws -> URL {
    let file = root.appendingPathComponent("Default/Network/Cookies")
    var db: OpaquePointer?
    guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw ChromeCookieError.unavailable }
    defer { sqlite3_close(db) }
    let sql = """
    CREATE TABLE meta (key TEXT, value INTEGER);
    INSERT INTO meta VALUES ('version', \(schema));
    CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
      path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER,
      samesite INTEGER, top_frame_site_key TEXT, has_expires INTEGER);
    \(rows)
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ChromeCookieError.unavailable }
    return file
}

@Test func chromeEncryptionMatchesKnownVectorsAndBindsDomain() throws {
    let key = try ChromeCookieSource.deriveKey(Data("fixture-password".utf8))
    #expect(key == hexData("5d84e88b8d2628e23102b464d77a5bbd"))
    #expect(ChromeCookieSource.decrypt(hexData(domainCipher), key: key, host: ".example.test", schema: 24) == "fixture-secret")
    #expect(ChromeCookieSource.decrypt(hexData(domainCipher), key: key, host: ".other.test", schema: 24) == nil)
    #expect(ChromeCookieSource.decrypt(hexData(legacyCipher), key: key, host: ".example.test", schema: 23) == "fixture-secret")
    #expect(ChromeCookieSource.decrypt(hexData(legacyCipher), key: key, host: ".example.test", schema: 24) == nil)
    #expect(ChromeCookieSource.decrypt(hexData(domainCipher), key: Data(repeating: 0, count: 16), host: ".example.test", schema: 24) == nil)
}

@Test func chromeSnapshotPreservesScopeFlagsAndSkipsUnsupportedCookies() throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = """
    INSERT INTO cookies VALUES ('.example.test','domain','',X'\(domainCipher)','/private',13344474600000000,1,1,2,'',1);
    INSERT INTO cookies VALUES ('login.example.test','host','visible',X'','/',0,0,0,-1,'',0);
    INSERT INTO cookies VALUES ('expired.test','old','old',X'','/',11644473601000000,0,0,1,'',1);
    INSERT INTO cookies VALUES ('partition.test','part','value',X'','/',0,1,1,0,'https://top.test',0);
    INSERT INTO cookies VALUES ('future.test','unknown','',X'763230001122','/',0,1,1,0,'',0);
    INSERT INTO cookies VALUES ('invalid.test','bad',CAST(X'610062' AS TEXT),X'','/',0,0,0,1,'',0);
    """
    let file = try fixtureDatabase(root: root, rows: rows)
    let before = try Data(contentsOf: file)
    var keyReads = 0
    let read = try ChromeCookieSource.read(profile: "Default", root: root, now: 1_700_000_000, sourceIsRunning: { false }, key: {
        keyReads += 1
        return try ChromeCookieSource.deriveKey(Data("fixture-password".utf8))
    })
    #expect(keyReads == 1)
    #expect(read.cookies.count == 2)
    #expect(read.expired == 1 && read.partitioned == 1 && read.unsupported == 2)
    let domain = try #require(read.cookies.first)
    #expect(domain.parameters["domain"] == .string(".example.test"))
    #expect(domain.parameters["httpOnly"] == .bool(true))
    #expect(domain.parameters["secure"] == .bool(true))
    #expect(domain.parameters["sameSite"] == .string("Strict"))
    #expect(domain.parameters["path"] == .string("/private"))
    let host = read.cookies[1]
    #expect(host.parameters["domain"] == .null && host.parameters["expires"] == .null)
    #expect(host.parameters["url"] == .string("http://login.example.test/"))
    #expect(try Data(contentsOf: file) == before)
    #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
    #expect(try ChromeCookieSource.profiles(root: root).map(\.id) == ["Default"])
}

@Test func chromeSourceReadsWhileRunningAndRejectsInvalidProfilesBeforeKeychain() throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try fixtureDatabase(root: root, rows: "")
    var keyReads = 0
    let key = { keyReads += 1; return Data() }
    #expect(try ChromeCookieSource.read(profile: "Default", root: root, sourceIsRunning: { true }, key: key).cookies.isEmpty)
    try Data([1]).write(to: URL(fileURLWithPath: file.path + "-wal"))
    #expect(try ChromeCookieSource.read(profile: "Default", root: root, sourceIsRunning: { true }, key: key).cookies.isEmpty)
    #expect(try ChromeCookieSource.read(profile: "Default", root: root, sourceIsRunning: { false }, key: key).cookies.isEmpty)
    #expect(throws: ChromeCookieError.invalidProfile) {
        try ChromeCookieSource.read(profile: "../Default", root: root, sourceIsRunning: { false }, key: key)
    }
    #expect(keyReads == 0)
}

private func sha256(_ file: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: file))) }
private func emptySnapshotRoot() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

@Test func chromeRunningSnapshotReplaysWALWithoutTouchingProfile() throws {
    let root = try temporaryCookies(), snapshots = try emptySnapshotRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: snapshots) }
    let file = root.appendingPathComponent("Default/Network/Cookies"), wal = URL(fileURLWithPath: file.path + "-wal")
    // An open writer with checkpoints disabled keeps the cookie only in the WAL, as a running Chrome would.
    var writer: OpaquePointer?
    #expect(sqlite3_open(file.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    let sql = """
    PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
    CREATE TABLE meta (key TEXT, value INTEGER); INSERT INTO meta VALUES ('version', 24);
    CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER,
      is_httponly INTEGER, samesite INTEGER, top_frame_site_key TEXT, has_expires INTEGER);
    INSERT INTO cookies VALUES ('wal.example.test','sid','wal-only-value',X'','/',0,1,1,1,'',0);
    """
    #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
    #expect(try Data(contentsOf: file).range(of: Data("wal-only-value".utf8)) == nil)
    #expect(try Data(contentsOf: wal).range(of: Data("wal-only-value".utf8)) != nil)
    let hashes = (try sha256(file), try sha256(wal))
    let read = try ChromeCookieSource.read(profile: "Default", root: root, now: 1_700_000_000, site: nil, sourceIsRunning: { true },
                                           key: { Data() }, temporaryRoot: snapshots, afterCopy: { _ in })
    #expect(read.cookies.map(\.value) == ["wal-only-value"])
    #expect(try sha256(file) == hashes.0 && sha256(wal) == hashes.1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).isEmpty)
}

@Test func chromeSnapshotRetriesAndReportsAProfileThatKeepsChanging() throws {
    let root = try temporaryCookies(), snapshots = try emptySnapshotRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: snapshots) }
    let file = try fixtureDatabase(root: root, rows: "INSERT INTO cookies VALUES ('example.test','a','b',X'','/',0,0,0,1,'',0);")
    let wal = URL(fileURLWithPath: file.path + "-wal")
    try Data().write(to: wal)
    var attempts: [Int] = []
    #expect(throws: ChromeCookieError.sourceChanged) {
        try ChromeCookieSource.read(profile: "Default", root: root, now: 0, site: nil, sourceIsRunning: { true }, key: { Data() },
                                    temporaryRoot: snapshots, afterCopy: { attempt in
            attempts.append(attempt)
            let handle = try FileHandle(forWritingTo: wal)
            try handle.seekToEnd(); try handle.write(contentsOf: Data([UInt8(attempt)])); try handle.close()
        })
    }
    #expect(attempts == [1, 2, 3])
    try FileManager.default.removeItem(at: wal)
    // A single change during the first copy is absorbed by a retry.
    attempts = []
    let read = try ChromeCookieSource.read(profile: "Default", root: root, now: 0, site: nil, sourceIsRunning: { true }, key: { Data() },
                                           temporaryRoot: snapshots, afterCopy: { attempt in
        attempts.append(attempt)
        if attempt == 1 { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path) }
    })
    #expect(attempts == [1, 2] && read.cookies.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).isEmpty)
}

@Test func chromeCorruptSnapshotFailsAsChangedNotEmpty() throws {
    let root = try temporaryCookies(), snapshots = try emptySnapshotRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: snapshots) }
    let rows = (0..<200).map { "INSERT INTO cookies VALUES ('example.test','n\($0)','\(String(repeating: "v", count: 100))',X'','/',0,0,0,1,'',0);" }
    let file = try fixtureDatabase(root: root, rows: rows.joined(separator: "\n"))
    var bytes = try Data(contentsOf: file)
    #expect(bytes.count > 3 * 4096)
    bytes.replaceSubrange(4096..<4196, with: Data(repeating: 0xA5, count: 100))
    try bytes.write(to: file)
    let hash = try sha256(file)
    #expect(throws: ChromeCookieError.sourceChanged) {
        try ChromeCookieSource.read(profile: "Default", root: root, now: 0, site: nil, sourceIsRunning: { true }, key: { Data() },
                                    temporaryRoot: snapshots, afterCopy: { _ in })
    }
    #expect(try sha256(file) == hash)
    #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).isEmpty)
}

@Test func chromeUnreadableProfileIsRunningOnlyWhileChromeIsOpen() throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try fixtureDatabase(root: root, rows: "")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    #expect(throws: ChromeCookieError.sourceRunning) {
        try ChromeCookieSource.read(profile: "Default", root: root, sourceIsRunning: { true }, key: { Data() })
    }
    #expect(throws: ChromeCookieError.unavailable) {
        try ChromeCookieSource.read(profile: "Default", root: root, sourceIsRunning: { false }, key: { Data() })
    }
}

@Test func chromeUnknownSchemaAndSymlinkFailClosed() throws {
    let root = try temporaryCookies(), other = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
    let file = try fixtureDatabase(root: root, schema: 25, rows: "")
    #expect(throws: ChromeCookieError.self) { try ChromeCookieSource.decode(snapshot: file, now: 0, key: { Data() }) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("Default"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Default"), withDestinationURL: other)
    #expect(throws: ChromeCookieError.self) { try ChromeCookieSource.profiles(root: root) }
}

@Test func chromeCookieVerificationChecksValueScopeAndSession() {
    let cookie = ImportedChromeCookie(host: "example.test", name: "auth", value: "fixture", path: "/", secure: true, httpOnly: true, sameSite: "Lax", expires: nil)
    var stored = cookie.parameters.object
    stored["domain"] = .string("example.test"); stored["session"] = .bool(true)
    #expect(cookie.matches(.object(stored)))
    for (key, value) in [("domain", JSONValue.string(".example.test")), ("value", .string("changed")), ("session", .bool(false)), ("httpOnly", .bool(false))] {
        var modified = stored; modified[key] = value
        #expect(!cookie.matches(.object(modified)))
    }
}

@Test func chromeImportLockSerializesOnlyOneEnvironmentAndRejectsSymlinks() throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("environments/" + UUID().uuidString), b = root.appendingPathComponent("environments/" + UUID().uuidString)
    let first = try CookieImportLock(environment: a, browserRoot: root)
    defer { first.release() }
    #expect(throws: ChromeCookieError.self) { try CookieImportLock(environment: a, browserRoot: root) }
    let second = try CookieImportLock(environment: b, browserRoot: root)
    second.release()
    first.release()
    let again = try CookieImportLock(environment: a, browserRoot: root)
    again.release()
    try FileManager.default.removeItem(at: a.appendingPathComponent("operation.lock"))
    try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("operation.lock"), withDestinationURL: root.appendingPathComponent("Local State"))
    #expect(throws: ChromeCookieError.self) { try CookieImportLock(environment: a, browserRoot: root) }
}

@Test func chromeImportErrorsProvideBothLanguagesWithoutSecretValues() {
    let errors: [ChromeCookieError] = [.sourceRunning, .unavailable, .invalidProfile, .unsupportedSchema, .keychain, .sourceChanged, .tooLarge,
                                     .browserBusy, .destinationRunning, .uncertain, .connection, .missingEnvironment, .empty]
    for error in errors {
        #expect(!error.message(language: .russian).isEmpty)
        #expect(!error.message(language: .english).isEmpty)
        #expect(error.message(language: .russian) != error.message(language: .english))
        #expect(!error.message(language: .english).contains("fixture-secret"))
    }
}

private actor CookieWriteProbe {
    var methods: [String] = []
    let fail: String?
    let stored: [JSONValue]
    init(fail: String?, stored: [JSONValue] = []) { self.fail = fail; self.stored = stored }
    func call(_ method: String, _ parameters: JSONValue) throws -> JSONValue {
        methods.append(method)
        if method == fail { throw ClientFailure("fixture-secret must never appear in UI") }
        return method == "Storage.getCookies" ? .object(["cookies": .array(stored)]) : .object([:])
    }
}

@Test func chromeAmbiguousWriteIsFencedAndNeverReplayed() async throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    for failedMethod in ["Storage.setCookies", "Storage.getCookies"] {
        let fence = root.appendingPathComponent(UUID().uuidString)
        let probe = CookieWriteProbe(fail: failedMethod)
        do {
            _ = try await ChromeCookieImporter.writeAndVerify(.init(), fence: fence, call: { try await probe.call($0, $1) })
            Issue.record("Expected uncertain outcome")
        } catch {
            #expect(error is ChromeCookieError)
            #expect(!error.localizedDescription.contains("fixture-secret"))
        }
        #expect(FileManager.default.fileExists(atPath: fence.path))
        #expect(await probe.methods.filter { $0 == "Storage.setCookies" }.count == 1)
        do {
            _ = try await ChromeCookieImporter.writeAndVerify(.init(), fence: fence, call: { try await probe.call($0, $1) })
            Issue.record("Existing fence must block another write")
        } catch { #expect(error is ChromeCookieError) }
        #expect(await probe.methods.filter { $0 == "Storage.setCookies" }.count == 1)
        let saved = try String(contentsOf: fence, encoding: .utf8)
        #expect(!saved.contains("fixture-secret"))
    }
}

@Test func chromeConfirmedPartialWriteReportsCountsAndClearsFence() async throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    let cookie = ImportedChromeCookie(host: "example.test", name: "auth", value: "fixture", path: "/", secure: true, httpOnly: true, sameSite: nil, expires: nil)
    let probe = CookieWriteProbe(fail: nil)
    var read = ChromeCookieRead(); read.cookies = [cookie]; read.expired = 2
    let fence = root.appendingPathComponent("fence.json")
    let result = try await ChromeCookieImporter.writeAndVerify(read, fence: fence, call: { try await probe.call($0, $1) })
    #expect(result.verified == 0 && result.unverified == 1 && result.skipped == 2)
    #expect(!FileManager.default.fileExists(atPath: fence.path))
    #expect(await probe.methods == ["Storage.setCookies", "Storage.getCookies"])
}

@Test func agentImportFiltersBeforeDecryptingOtherSites() throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try fixtureDatabase(root: root, rows: """
    INSERT INTO cookies VALUES ('.linkedin.com','session','fixture',X'','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('www.linkedin.com','host','fixture2',X'','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('evillinkedin.com','other','',X'\(domainCipher)','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('linkedin.com.evil.test','other','',X'\(domainCipher)','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('.example.test','other','',X'\(domainCipher)','/',0,1,1,1,'',0);
    """)
    let read = try ChromeCookieSource.read(profile: "Default", root: root, site: "linkedin.com", sourceIsRunning: { false }, key: {
        Issue.record("Unrelated cookies must never be decrypted")
        throw ChromeCookieError.keychain
    })
    #expect(read.cookies.map(\.host) == [".linkedin.com", "www.linkedin.com"])
    #expect(read.skipped == 0)
}

@Test func agentImportPolicyRejectsPathsAndPersistsWithoutSecrets() throws {
    let policy = try ChromeSessionImportPolicy(profile: "Profile 2", site: " LinkedIn.COM ")
    #expect(policy.site == "linkedin.com")
    for site in ["", "com", "https://linkedin.com", "../linkedin.com", "linkedin.com:443", "linkedin..com", "*.linkedin.com", "-linkedin.com"] {
        #expect(throws: ChromeCookieError.self) { try ChromeSessionImportPolicy(profile: "Default", site: site) }
    }
    #expect(throws: ChromeCookieError.self) { try ChromeSessionImportPolicy(profile: "../Default", site: "linkedin.com") }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = root.appendingPathComponent("environments/" + UUID().uuidString.lowercased())
    try ChromeSessionImportPolicy.save(policy, environment: environment, grant: nil, browserRoot: root)
    #expect(try ChromeSessionImportPolicy.load(environment: environment) == policy)
    let file = environment.appendingPathComponent("chrome-session-import.json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try ChromeSessionImportPolicy.save(nil, environment: environment, grant: nil, browserRoot: root)
    #expect(try ChromeSessionImportPolicy.load(environment: environment) == nil)
}

@Test func agentImportReusesExecutorFenceAndDoesNotReplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fence = root.appendingPathComponent("executor-in-flight.json")
    let read = ChromeCookieRead(cookies: [.init(host: ".linkedin.com", name: "session", value: "fixture", path: "/", secure: true, httpOnly: true, sameSite: "Lax", expires: nil)])
    try Data(#"{"tool":"browser_action","state":"outcome_unknown"}"#.utf8).write(to: fence)
    await #expect(throws: ChromeCookieError.self) {
        try await ChromeCookieImporter.writeAndVerify(read, fence: fence, executorFence: true) { _, _ in
            Issue.record("Must not overwrite another operation's fence")
            return .null
        }
    }
    try Data(#"{"tool":"browser_import_session","state":"outcome_unknown"}"#.utf8).write(to: fence)
    await #expect(throws: ChromeCookieError.self) {
        try await ChromeCookieImporter.writeAndVerify(read, fence: fence, executorFence: true) { method, _ in
            #expect(method == "Storage.setCookies")
            throw ChromeCookieError.connection
        }
    }
    #expect(FileManager.default.fileExists(atPath: fence.path))
    await #expect(throws: ChromeCookieError.self) {
        try await ChromeCookieImporter.writeAndVerify(read, fence: fence, executorFence: true) { _, _ in
            Issue.record("Uncertain import must never be replayed")
            return .null
        }
    }
}

@Test func anySitePolicyImportsOnlyCookiesChromeWouldSendToThePage() throws {
    let root = try temporaryCookies()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try fixtureDatabase(root: root, rows: """
    INSERT INTO cookies VALUES ('.linkedin.com','parent','a',X'','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('www.linkedin.com','host','b',X'','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('.www.linkedin.com','domain','c',X'','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('login.linkedin.com','sibling','',X'\(domainCipher)','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('linkedin.com','apex','',X'\(domainCipher)','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('.evillinkedin.com','other','',X'\(domainCipher)','/',0,1,1,1,'',0);
    INSERT INTO cookies VALUES ('.www.linkedin.com.evil.test','other','',X'\(domainCipher)','/',0,1,1,1,'',0);
    """)
    let read = try ChromeCookieSource.read(profile: "Default", root: root, pageHost: "www.linkedin.com", sourceIsRunning: { true }, key: {
        Issue.record("Cookies Chrome would not send to the page must never be decrypted")
        throw ChromeCookieError.keychain
    })
    #expect(read.cookies.map(\.name) == ["parent", "host", "domain"])
    #expect(ChromeSessionImportPolicy.sent(cookieHost: ".LinkedIn.com", toPageHost: "linkedin.com"))
    #expect(!ChromeSessionImportPolicy.sent(cookieHost: "linkedin.com", toPageHost: "www.linkedin.com"))
}

@Test func anySitePolicyIsSharedAcrossChatsAndChatPolicyWins() throws {
    let policy = try ChromeSessionImportPolicy(profile: "Profile 2", site: " * ")
    #expect(policy.coversAnySite)
    for site in ["*.linkedin.com", "**", "*com"] {
        #expect(throws: ChromeCookieError.self) { try ChromeSessionImportPolicy(profile: "Default", site: site) }
    }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = root.appendingPathComponent("environments/" + UUID().uuidString.lowercased())
    #expect(try ChromeSessionImportPolicy.resolve(site: "github.com", environment: environment, browserRoot: root) == nil)
    try ChromeSessionImportPolicy.saveShared(policy, browserRoot: root)
    let file = root.appendingPathComponent("chrome-session-import.json")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try ChromeSessionImportPolicy.loadShared(browserRoot: root) == policy)
    let shared = try #require(try ChromeSessionImportPolicy.resolve(site: "WWW.GitHub.com", environment: environment, browserRoot: root))
    #expect(shared.profile == "Profile 2" && shared.site == nil && shared.pageHost == "www.github.com")
    // A wildcard never turns a non-domain request into an unfiltered read.
    for site in ["*", "", "localhost", "a..b", "-x.test"] {
        #expect(try ChromeSessionImportPolicy.resolve(site: site, environment: environment, browserRoot: root) == nil)
    }
    try ChromeSessionImportPolicy.save(try .init(profile: "Default", site: "linkedin.com"), environment: environment, grant: nil, browserRoot: root)
    let chat = try #require(try ChromeSessionImportPolicy.resolve(site: "linkedin.com", environment: environment, browserRoot: root))
    #expect(chat.profile == "Default" && chat.site == "linkedin.com" && chat.pageHost == nil)
    #expect(try ChromeSessionImportPolicy.resolve(site: "github.com", environment: environment, browserRoot: root)?.pageHost == "github.com")
    try ChromeSessionImportPolicy.saveShared(nil, browserRoot: root)
    #expect(try ChromeSessionImportPolicy.resolve(site: "github.com", environment: environment, browserRoot: root) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func importConsentFilesMustCarryTheAppSignatureForTheirOwnFolder() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = root.appendingPathComponent("environments/" + UUID().uuidString.lowercased())
    let other = root.appendingPathComponent("environments/" + UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let linkedin = try ChromeSessionImportPolicy(profile: "Default", site: "linkedin.com")
    try ChromeSessionImportPolicy.save(linkedin, environment: environment, grant: nil, browserRoot: root)
    let file = environment.appendingPathComponent("chrome-session-import.json")
    let stored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    #expect(stored["mac"].string?.isEmpty == false && stored["site"].string == "linkedin.com")
    // A file written by hand (the agent's own user) has no signature and is refused, not silently ignored.
    try Data(#"{"profile":"Default","site":"*"}"#.utf8).write(to: root.appendingPathComponent("chrome-session-import.json"))
    #expect(throws: ChromeCookieError.unsignedPolicy) { try ChromeSessionImportPolicy.loadShared(browserRoot: root) }
    // Editing the site of a signed file breaks the signature.
    var edited = stored.object; edited["site"] = .string("google.com")
    try JSONEncoder().encode(JSONValue.object(edited)).write(to: file)
    #expect(throws: ChromeCookieError.unsignedPolicy) { try ChromeSessionImportPolicy.load(environment: environment) }
    // A valid file copied into another folder (for example the app-wide root) does not carry over.
    try ChromeSessionImportPolicy.save(linkedin, environment: environment, grant: nil, browserRoot: root)
    try FileManager.default.copyItem(at: file, to: other.appendingPathComponent("chrome-session-import.json"))
    #expect(throws: ChromeCookieError.unsignedPolicy) { try ChromeSessionImportPolicy.load(environment: other) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("chrome-session-import.json"))
    try FileManager.default.copyItem(at: file, to: root.appendingPathComponent("chrome-session-import.json"))
    #expect(throws: ChromeCookieError.unsignedPolicy) { try ChromeSessionImportPolicy.loadShared(browserRoot: root) }
    #expect(throws: ChromeCookieError.unsignedPolicy) { try ChromeSessionImportPolicy.resolve(site: "linkedin.com", environment: other, browserRoot: root) }
    #expect(try ChromeSessionImportPolicy.load(environment: environment) == linkedin)
    #expect(!ChromeCookieError.unsignedPolicy.message(language: .russian).isEmpty && ChromeCookieError.unsignedPolicy.message(language: .russian) != ChromeCookieError.unsignedPolicy.message(language: .english))
}

@Test func existingConsentFilesAreSignedOnlyWhenTheKeyIsFirstCreated() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = root.appendingPathComponent("environments/" + UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
    try Data(#"{"profile":"Default","site":"*"}"#.utf8).write(to: root.appendingPathComponent("chrome-session-import.json"))
    try Data(#"{"site":"linkedin.com","profile":"Default"}"#.utf8).write(to: environment.appendingPathComponent("chrome-session-import.json"))
    try Data(#"{"site":"not a domain","profile":"Default"}"#.utf8).write(to: root.appendingPathComponent("environments/x.json"))
    let key = try #require(PolicySigning.memoryKey)
    // A key already exists: nothing is blessed.
    #expect(try ChromeSessionImportPolicy.adoptExistingPolicies(browserRoot: root, existingKey: { key }, createKey: { key }).isEmpty)
    #expect(throws: ChromeCookieError.unsignedPolicy) { try ChromeSessionImportPolicy.loadShared(browserRoot: root) }
    // First creation: both existing files are signed in place.
    var created = 0
    let signed = try ChromeSessionImportPolicy.adoptExistingPolicies(browserRoot: root, existingKey: { nil }, createKey: { created += 1; return key })
    #expect(created == 1 && Set(signed) == [root.path, environment.path])
    #expect(try ChromeSessionImportPolicy.loadShared(browserRoot: root)?.coversAnySite == true)
    #expect(try ChromeSessionImportPolicy.load(environment: environment)?.site == "linkedin.com")
}
