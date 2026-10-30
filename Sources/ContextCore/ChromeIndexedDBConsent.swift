import Foundation
import CryptoKit

/// App-owned, user-granted permission to carry one site's IndexedDB from a Chrome profile into a chat browser.
///
/// IndexedDB is kept apart from the cookie + Local Storage consent on purpose. It is a coarser, whole-origin
/// file clone with no live-tab write path, so it is a separate, explicit grant the user turns on per site. There
/// is no wildcard: IndexedDB needs an exact origin, so "any site" is never accepted. The file is signed with a
/// distinct MAC domain, so a cookie grant can never be read as an IndexedDB grant or the reverse.
public struct ChromeIndexedDBConsent: Codable, Equatable, Sendable {
    public let profile: String
    public let site: String
    static let signingPrefix = "switchboard-indexeddb-import-policy-v1"

    public init(profile: String, site: String) throws {
        let domain = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard domain != ChromeSessionImportPolicy.anySite, ChromeSessionImportPolicy.validDomain(domain),
              profile == "Default" || (profile.hasPrefix("Profile ") && !profile.dropFirst(8).isEmpty &&
                  profile.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber }) else { throw ChromeCookieError.invalidProfile }
        self.profile = profile
        self.site = domain
    }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("chrome-indexeddb-import.json") }

    /// Reads and signature-checks the IndexedDB grant for a folder (a chat environment or the browser root).
    public static func load(environment: URL) throws -> Self? {
        let file = file(environment)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard file.resolvingSymlinksInPath().path == file.path,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else { throw ChromeCookieError.invalidProfile }
        let value = try JSONDecoder().decode(ChromeSessionImportPolicy.SignedFile.self, from: Data(contentsOf: file))
        let consent = try Self(profile: value.profile, site: value.site)
        guard let mac = value.mac, let key = try PolicySigning.existingKey(),
              PolicySigning.verify(prefix: signingPrefix, mac, profile: consent.profile, site: consent.site, folder: environment, key: key)
        else { throw ChromeCookieError.unsignedPolicy }
        return consent
    }

    /// Resolves the source profile for a page host: the chat's own grant first, then the app-wide grant in the
    /// browser root. A grant for a registrable domain covers its subdomains (like the cookie policy), and the
    /// returned site is the exact origin host to clone. Returns nil when the user has not granted it.
    public static func resolve(site: String, environment: URL, browserRoot: URL) throws -> (profile: String, site: String)? {
        let host = site.lowercased()
        guard ChromeSessionImportPolicy.validDomain(host) else { return nil }
        for consent in [try load(environment: environment), try load(environment: browserRoot)].compactMap({ $0 })
        where ChromeSessionImportPolicy.includes(host: host, site: consent.site) {
            return (consent.profile, host)
        }
        return nil
    }

    static func write(_ consent: Self, folder: URL, file: URL) throws {
        let mac = PolicySigning.sign(prefix: signingPrefix, profile: consent.profile, site: consent.site, folder: folder, key: try PolicySigning.key())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ChromeSessionImportPolicy.SignedFile(profile: consent.profile, site: consent.site, mac: mac)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func save(_ consent: Self?, environment: URL, grant: BrowserProfileGrant?,
                            browserRoot: URL = BrowserEnvironmentStore.directory) throws {
        let lock = try CookieImportLock(environment: environment, browserRoot: browserRoot)
        defer { lock.release() }
        guard let id = UUID(uuidString: environment.lastPathComponent) else { throw ChromeCookieError.missingEnvironment }
        try BrowserProfileStore(root: browserRoot).validate(grant, environment: id, allowHuman: true)
        let file = file(environment)
        if let consent { try write(consent, folder: environment, file: file) }
        else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// App-wide IndexedDB grant shared by every chat browser; stored next to `environments/`, never inside a profile.
    public static func loadShared(browserRoot: URL = BrowserEnvironmentStore.directory) throws -> Self? {
        try load(environment: browserRoot)
    }

    public static func saveShared(_ consent: Self?, browserRoot: URL = BrowserEnvironmentStore.directory) throws {
        let file = file(browserRoot)
        guard browserRoot.resolvingSymlinksInPath().path == browserRoot.path,
              file.resolvingSymlinksInPath().path == file.path else { throw ChromeCookieError.invalidProfile }
        if let consent {
            try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(consent, folder: browserRoot, file: file)
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
