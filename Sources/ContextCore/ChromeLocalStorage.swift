import Foundation

/// One Local Storage entry decoded from Chrome. Values stay in memory and travel only to the
/// app-owned Chrome endpoint, exactly like imported cookies.
public struct ImportedLocalStorageItem: Sendable, Equatable {
    public let key: String
    public let value: String
}

public struct ChromeLocalStorageRead: Sendable {
    public var items: [ImportedLocalStorageItem] = []
    /// Entries for the origin that could not be decoded into usable strings.
    public var unsupported = 0
}

/// Counts for the Local Storage half of a session import. Local Storage is best-effort: a failure here
/// never invalidates a cookie import, so all-zero counts simply mean nothing was transferred.
public struct LocalStorageImportResult: Codable, Equatable, Sendable {
    public let verified: Int
    public let skipped: Int
    public let unverified: Int
    public static let none = LocalStorageImportResult(verified: 0, skipped: 0, unverified: 0)
}

/// Both halves of a session import. Cookie counts keep their strict, non-replayed semantics; Local Storage
/// is additive and tolerant.
public struct ChromeSessionImportResult: Sendable {
    public let cookies: ChromeCookieImportResult
    public let localStorage: LocalStorageImportResult
}

/// Reads the Local Storage of one origin from a Chrome profile by copying the LevelDB directory
/// into a private snapshot and parsing it read-only (see ``ChromeLevelDB``). Chrome never encrypts
/// Local Storage values, so no Keychain material is involved. A torn or malformed snapshot throws
/// rather than yielding a partial list; the caller treats Local Storage as best-effort and keeps a
/// successful cookie import regardless.
public enum ChromeLocalStorageSource {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumItemBytes = 1024 * 1024
    public static let maximumItems = 5_000

    /// `originSerialized` must be the exact `location.origin` of the page (e.g. `https://example.com`).
    public static func read(profile: String, root: URL = ChromeCookieSource.directory, originSerialized origin: String,
                            sourceIsRunning: () -> Bool,
                            temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> ChromeLocalStorageRead {
        guard origin.allSatisfy({ $0.isASCII && !$0.isWhitespace }), !origin.isEmpty, origin.utf8.count <= 4096 else {
            throw ChromeCookieError.invalidProfile
        }
        let leveldb = try checkedLevelDB(profile: profile, root: root)
        let snapshot = try snapshotDirectory(leveldb, sourceIsRunning: sourceIsRunning, temporaryRoot: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let pairs: [(key: [UInt8], value: [UInt8])]
        do { pairs = try ChromeLevelDB.read(directory: snapshot) }
        catch { throw ChromeCookieError.unavailable }
        return decode(pairs, origin: origin)
    }

    private static func checkedLevelDB(profile: String, root: URL) throws -> URL {
        guard try ChromeCookieSource.profiles(root: root).contains(where: { $0.id == profile }) else { throw ChromeCookieError.invalidProfile }
        let dir = root.appendingPathComponent(profile).appendingPathComponent("Local Storage").appendingPathComponent("leveldb").standardizedFileURL
        guard dir.resolvingSymlinksInPath().path == dir.path,
              dir.path.hasPrefix(root.standardizedFileURL.path + "/"),
              (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ChromeCookieError.unavailable }
        return dir
    }

    /// Copies every regular file (never the LOCK) into a fresh private directory. A best-effort copy is
    /// enough: the reader fails loudly on a torn snapshot and Local Storage import is not retried.
    private static func snapshotDirectory(_ source: URL, sourceIsRunning: () -> Bool, temporaryRoot: URL) throws -> URL {
        let blocked = sourceIsRunning() ? ChromeCookieError.sourceRunning : .unavailable
        let entries = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        guard !entries.isEmpty else { throw blocked }
        let destination = temporaryRoot.appendingPathComponent("contextdesk-localstorage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var total = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "LOCK", name.rangeOfCharacter(from: CharacterSet(charactersIn: "/")) == nil,
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard let bytes = try? Data(contentsOf: entry) else { throw blocked }
            total += bytes.count
            guard bytes.count <= maximumBytes, total <= maximumBytes else { throw ChromeCookieError.tooLarge }
            guard FileManager.default.createFile(atPath: destination.appendingPathComponent(name).path, contents: bytes,
                                                 attributes: [.posixPermissions: 0o600]) else { throw ChromeCookieError.unavailable }
        }
        return destination
    }

    /// LevelDB data keys for Local Storage are `"_" + origin + 0x00 + <encoded key>`; values and the
    /// per-key suffix use a one-byte format marker (0 = UTF-16LE, 1 = Latin-1). The empty-key map marker
    /// and other origins are ignored.
    static func decode(_ pairs: [(key: [UInt8], value: [UInt8])], origin: String) -> ChromeLocalStorageRead {
        var result = ChromeLocalStorageRead()
        let prefix = [UInt8(0x5F)] + Array(origin.utf8) + [UInt8(0x00)]
        var seen = Set<String>()
        for pair in pairs {
            guard pair.key.count > prefix.count, Array(pair.key.prefix(prefix.count)) == prefix else { continue }
            guard let key = decodeString(Array(pair.key.dropFirst(prefix.count))), !key.isEmpty,
                  let value = decodeString(pair.value) else { result.unsupported += 1; continue }
            guard key.utf8.count <= maximumItemBytes, value.utf8.count <= maximumItemBytes else { result.unsupported += 1; continue }
            guard seen.insert(key).inserted, result.items.count < maximumItems else { continue }
            result.items.append(ImportedLocalStorageItem(key: key, value: value))
        }
        return result
    }

    static func decodeString(_ bytes: [UInt8]) -> String? {
        guard let marker = bytes.first else { return nil }
        let body = Array(bytes.dropFirst())
        switch marker {
        case 0x00:
            guard body.count % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            for index in stride(from: 0, to: body.count, by: 2) {
                units.append(UInt16(body[index]) | (UInt16(body[index + 1]) << 8))
            }
            // Reject malformed (e.g. unpaired surrogate) sequences by requiring a clean round-trip.
            let string = String(utf16CodeUnits: units, count: units.count)
            return Array(string.utf16) == units ? string : nil
        case 0x01:
            return String(String.UnicodeScalarView(body.map { Unicode.Scalar($0) }))
        default:
            return nil
        }
    }
}
