import Foundation
import CryptoKit
import Security

/// App-owned consent metadata. No cookies or Keychain material are persisted here.
public struct ChromeSessionImportPolicy: Codable, Equatable, Sendable {
    public let profile: String
    public let site: String

    /// Wildcard site: any website, limited per import to the cookies Chrome would send to the agent tab's host.
    public static let anySite = "*"
    public var coversAnySite: Bool { site == Self.anySite }

    public init(profile: String, site: String) throws {
        let domain = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard domain == Self.anySite || Self.validDomain(domain),
              profile == "Default" || (profile.hasPrefix("Profile ") && !profile.dropFirst(8).isEmpty &&
                  profile.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber }) else { throw ChromeCookieError.invalidProfile }
        self.profile = profile
        self.site = domain
    }

    static func validDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return domain.utf8.count <= 253 && labels.count >= 2 &&
            labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
                $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
    }

    public static func includes(host: String, site: String) -> Bool {
        let host = host.lowercased().hasPrefix(".") ? String(host.lowercased().dropFirst()) : host.lowercased()
        return host == site || host.hasSuffix("." + site)
    }

    /// RFC 6265 domain matching: host-only cookies of exactly this host plus domain cookies of the host or its parents.
    /// Chrome never stores domain cookies on public suffixes, so this never spans unrelated sites.
    public static func sent(cookieHost: String, toPageHost page: String) -> Bool {
        let cookie = cookieHost.lowercased(), page = page.lowercased()
        guard cookie.hasPrefix(".") else { return cookie == page }
        let domain = String(cookie.dropFirst())
        return page == domain || page.hasSuffix("." + domain)
    }

    /// Resolves the source profile and cookie filter for an agent request: the chat's own policy first, then the
    /// app-wide policy saved in the browser root.
    public static func resolve(site: String, environment: URL, browserRoot: URL) throws -> (profile: String, site: String?, pageHost: String?)? {
        let host = site.lowercased()
        guard validDomain(host) else { return nil }
        for policy in [try load(environment: environment), try load(environment: browserRoot)].compactMap({ $0 }) {
            if policy.site == host { return (policy.profile, host, nil) }
            if policy.coversAnySite { return (policy.profile, nil, host) }
        }
        return nil
    }

    /// Reads a consent file and checks the app's signature over its content and folder (audit H2).
    public static func load(environment: URL) throws -> Self? {
        let file = environment.appendingPathComponent("chrome-session-import.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard file.resolvingSymlinksInPath().path == file.path,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else { throw ChromeCookieError.invalidProfile }
        let value = try JSONDecoder().decode(SignedFile.self, from: Data(contentsOf: file))
        let policy = try Self(profile: value.profile, site: value.site)
        guard let mac = value.mac, let key = try PolicySigning.existingKey(),
              PolicySigning.verify(mac, policy: policy, folder: environment, key: key) else { throw ChromeCookieError.unsignedPolicy }
        return policy
    }
    /// The file format: the policy plus an HMAC that binds it to its folder.
    struct SignedFile: Codable {
        let profile: String
        let site: String
        let mac: String?
    }
    static func write(_ policy: Self, folder: URL, file: URL) throws {
        let mac = PolicySigning.sign(policy, folder: folder, key: try PolicySigning.key())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(SignedFile(profile: policy.profile, site: policy.site, mac: mac)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func save(_ policy: Self?, environment: URL, grant: BrowserProfileGrant?,
                            browserRoot: URL = BrowserEnvironmentStore.directory) throws {
        let lock = try CookieImportLock(environment: environment, browserRoot: browserRoot)
        defer { lock.release() }
        guard let id = UUID(uuidString: environment.lastPathComponent) else { throw ChromeCookieError.missingEnvironment }
        try BrowserProfileStore(root: browserRoot).validate(grant, environment: id, allowHuman: true)
        let file = environment.appendingPathComponent("chrome-session-import.json")
        if let policy { try write(policy, folder: environment, file: file) }
        else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

extension ChromeSessionImportPolicy {
    /// App-wide consent shared by every chat browser; stored next to `environments/`, never inside a profile.
    public static func loadShared(browserRoot: URL = BrowserEnvironmentStore.directory) throws -> Self? {
        try load(environment: browserRoot)
    }

    public static func saveShared(_ policy: Self?, browserRoot: URL = BrowserEnvironmentStore.directory) throws {
        let file = browserRoot.appendingPathComponent("chrome-session-import.json")
        guard browserRoot.resolvingSymlinksInPath().path == browserRoot.path,
              file.resolvingSymlinksInPath().path == file.path else { throw ChromeCookieError.invalidProfile }
        if let policy {
            try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(policy, folder: browserRoot, file: file)
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Runs once, when the signing key is created: the consent files that already exist were written by the app
    /// before signing existed, so they are signed in place. Files appearing later are never blessed this way.
    /// Returns the folders whose files were signed.
    @discardableResult
    public static func adoptExistingPolicies(browserRoot: URL = BrowserEnvironmentStore.directory) throws -> [String] {
        try adoptExistingPolicies(browserRoot: browserRoot, existingKey: PolicySigning.existingKey, createKey: PolicySigning.key)
    }
    static func adoptExistingPolicies(browserRoot: URL, existingKey: () throws -> SymmetricKey?, createKey: () throws -> SymmetricKey) throws -> [String] {
        guard try existingKey() == nil else { return [] }
        let key = try createKey()
        var folders = [browserRoot]
        let environments = browserRoot.appendingPathComponent("environments")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: environments.path) {
            folders += names.filter { UUID(uuidString: $0) != nil }.map { environments.appendingPathComponent($0) }
        }
        var signed: [String] = []
        for folder in folders {
            let file = folder.appendingPathComponent("chrome-session-import.json")
            guard FileManager.default.fileExists(atPath: file.path), file.resolvingSymlinksInPath().path == file.path,
                  (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) ?? Int.max <= 4096,
                  let value = try? JSONDecoder().decode(SignedFile.self, from: Data(contentsOf: file)),
                  let policy = try? Self(profile: value.profile, site: value.site) else { continue }
            let mac = PolicySigning.sign(policy, folder: folder, key: key)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(SignedFile(profile: policy.profile, site: policy.site, mac: mac)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            signed.append(folder.path)
        }
        return signed
    }
}

/// HMAC key for consent files. In the built app it lives in the app's own Keychain item, which the native import
/// helper (the same signed binary) can read and an agent process cannot without a prompt. Outside an `.app` bundle
/// (unit tests, `swift run`) a fixed in-memory key is used, so tests never touch the real Keychain; the import
/// helper always runs from the bundle.
enum PolicySigning {
    static let service = "Switchboard.BrowserImportPolicy.v1"
    static let account = "hmac-key"
    static let memoryKey: SymmetricKey? = Bundle.main.bundleURL.pathExtension == "app"
        ? nil : SymmetricKey(data: SHA256.hash(data: Data("switchboard-unit-test-policy-key".utf8)))

    static func existingKey() throws -> SymmetricKey? {
        if let memoryKey { return memoryKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw ChromeCookieError.keychain }
        return SymmetricKey(data: data)
    }
    /// Existing key, or a new random one stored in the Keychain.
    static func key() throws -> SymmetricKey {
        if let memoryKey { return memoryKey }
        if let key = try existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChromeCookieError.keychain }
        return key
    }
    static func message(_ policy: ChromeSessionImportPolicy, folder: URL) -> Data {
        Data(["switchboard-import-policy-v1", folder.standardizedFileURL.resolvingSymlinksInPath().path, policy.profile, policy.site].joined(separator: "\n").utf8)
    }
    static func sign(_ policy: ChromeSessionImportPolicy, folder: URL, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: message(policy, folder: folder), using: key)).base64EncodedString()
    }
    static func verify(_ mac: String, policy: ChromeSessionImportPolicy, folder: URL, key: SymmetricKey) -> Bool {
        guard let data = Data(base64Encoded: mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(data, authenticating: message(policy, folder: folder), using: key)
    }
}

extension ChromeCookieImporter {
    /// The executor holds operation.lock and has verified the lease and owned endpoint.
    /// Secrets stay inside this native process and the destination CDP connection.
    public static func importSession(environment: URL, site: String, endpoint: URL,
                                     sourceIsRunning: @Sendable () -> Bool) async throws -> ChromeSessionImportResult {
        let root = BrowserEnvironmentStore.directory.standardizedFileURL
        guard environment.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("environments").path,
              environment.resolvingSymlinksInPath().path == environment.path,
              UUID(uuidString: environment.lastPathComponent) != nil,
              let scope = try ChromeSessionImportPolicy.resolve(site: site, environment: environment, browserRoot: root),
              endpoint.scheme == "ws", endpoint.host == "127.0.0.1", let port = endpoint.port,
              (1024...65535).contains(port), endpoint.path.hasPrefix("/devtools/browser/"),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw ChromeCookieError.invalidProfile }
        // Counted before any cookie is read, so an uncertain outcome also uses up the attempt (audit M7).
        try ChromeImportLedger.admit(environment: environment, site: scope.site ?? scope.pageHost ?? site)
        let read = try ChromeCookieSource.read(profile: scope.profile, site: scope.site, pageHost: scope.pageHost, sourceIsRunning: sourceIsRunning)
        guard !read.cookies.isEmpty else { throw ChromeCookieError.empty }
        let connection = try CookieCDP(endpoint: endpoint)
        defer { connection.close() }
        _ = try await connection.call("Browser.getVersion")
        let cookies = try await writeAndVerify(read, fence: environment.appendingPathComponent("executor-in-flight.json"), executorFence: true) { method, parameters in
            try await connection.call(method, parameters: parameters)
        }
        // Local Storage carries the login token for some sites. It rides on the same per-site consent,
        // but is additive: any failure leaves the verified cookie import untouched and simply transfers nothing.
        let localStorage = await importLocalStorage(connection: connection, profile: scope.profile,
                                                    host: scope.site ?? scope.pageHost ?? site, sourceIsRunning: sourceIsRunning)
        return ChromeSessionImportResult(cookies: cookies, localStorage: localStorage)
    }

    /// Finds the owned page at the site's origin, reads that origin's Local Storage from the source profile,
    /// and replays each item with `localStorage.setItem` inside the page, verifying by read-back. Never throws
    /// and never surfaces a protocol response: a remote value could hold a secret.
    static func importLocalStorage(connection: CookieCDP, profile: String, host: String,
                                   sourceIsRunning: @Sendable () -> Bool) async -> LocalStorageImportResult {
        do {
            let targets = try await connection.call("Target.getTargets")
            guard let target = targets["targetInfos"].array.first(where: { info in
                guard info["type"].string == "page", let url = info["url"].string,
                      let components = URLComponents(string: url), components.scheme == "https", let pageHost = components.host
                else { return false }
                return ChromeSessionImportPolicy.includes(host: pageHost, site: host)
            }), let targetID = target["targetId"].string else { return .none }
            let attached = try await connection.call("Target.attachToTarget", parameters: .object(["targetId": .string(targetID), "flatten": .bool(true)]))
            guard let sessionID = attached["sessionId"].string else { return .none }
            // Closing the whole CDP connection (importSession's defer) detaches every session, so no explicit detach.
            guard let origin = try await evaluate("location.origin", connection: connection, sessionID: sessionID)?.string,
                  let originHost = URLComponents(string: origin)?.host, ChromeSessionImportPolicy.includes(host: originHost, site: host) else { return .none }
            let read = try ChromeLocalStorageSource.read(profile: profile, originSerialized: origin, sourceIsRunning: sourceIsRunning)
            guard !read.items.isEmpty else { return LocalStorageImportResult(verified: 0, skipped: read.unsupported, unverified: 0) }
            let payload = JSONValue.array(read.items.map { .array([.string($0.key), .string($0.value)]) })
            let json = String(decoding: (try? JSONEncoder().encode(payload)) ?? Data(), as: UTF8.self)
            guard !json.isEmpty, json.utf8.count <= ChromeLocalStorageSource.maximumBytes else { return .none }
            // No eval/new Function, so a strict page CSP does not block the transfer.
            let expression = """
            (function(){try{var d=JSON.parse(\(jsStringLiteral(json)));var n=0;\
            for(var i=0;i<d.length;i++){try{localStorage.setItem(d[i][0],d[i][1]);\
            if(localStorage.getItem(d[i][0])===d[i][1]){n++;}}catch(e){}}return n;}catch(e){return -1;}})()
            """
            let verified = try await evaluate(expression, connection: connection, sessionID: sessionID)?.int ?? -1
            guard verified >= 0 else { return .none }
            return LocalStorageImportResult(verified: min(verified, read.items.count), skipped: read.unsupported,
                                            unverified: read.items.count - min(verified, read.items.count))
        } catch { return .none }
    }

    private static func evaluate(_ expression: String, connection: CookieCDP, sessionID: String) async throws -> JSONValue? {
        let result = try await connection.call("Runtime.evaluate", parameters: .object([
            "expression": .string(expression), "returnByValue": .bool(true), "userGesture": .bool(false)]), sessionId: sessionID)
        guard result["exceptionDetails"] == .null else { return nil }
        return result["result"]["value"]
    }

    /// Encodes a string as a JavaScript string literal, escaping the line separators JSON leaves raw.
    static func jsStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// Per-environment record of cookie imports, kept on disk so closing and reopening a tab does not reset the
/// limit (audit M7). The native helper is the only reader and writer. A site is imported at most once per window,
/// and at most `siteLimit` different sites per window, which bounds an "any site" policy.
public struct ChromeImportLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var site: String
        public var date: Date
    }
    public static let window: TimeInterval = 3600
    public static let siteLimit = 5
    public var entries: [Entry] = []

    static func file(_ environment: URL) -> URL { environment.appendingPathComponent("chrome-session-import-ledger.json") }

    /// Records the attempt or refuses it. An unreadable ledger refuses instead of starting over.
    public static func admit(environment: URL, site: String, now: Date = Date()) throws {
        let path = file(environment)
        var ledger = ChromeImportLedger()
        if FileManager.default.fileExists(atPath: path.path) {
            guard path.resolvingSymlinksInPath().path == path.path,
                  (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) ?? Int.max <= 65_536,
                  let stored = try? JSONDecoder().decode(ChromeImportLedger.self, from: Data(contentsOf: path)) else {
                throw ChromeCookieError.importLimit
            }
            ledger = stored
        }
        let host = site.lowercased()
        ledger.entries = ledger.entries.filter { now.timeIntervalSince($0.date) < window && $0.date <= now.addingTimeInterval(60) }
        guard !ledger.entries.contains(where: { $0.site == host }) else { throw ChromeCookieError.recentlyImported }
        guard Set(ledger.entries.map(\.site)).count < siteLimit else { throw ChromeCookieError.importLimit }
        ledger.entries.append(Entry(site: host, date: now))
        try JSONEncoder().encode(ledger).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
