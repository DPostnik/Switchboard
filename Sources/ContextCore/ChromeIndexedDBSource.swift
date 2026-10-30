import Foundation

public struct ChromeIndexedDBInstallResult: Sendable, Equatable {
    public let storeName: String
    public let copiedBytes: Int
    public let blobCopied: Bool
}

/// Copies one origin's IndexedDB database from a regular Chrome profile into the chat browser's
/// profile, as a whole-store file clone. Unlike cookies and Local Storage, IndexedDB values are a
/// versioned binary serialization with no CDP write path, so the only transfer that does not require
/// decoding is a raw copy of the origin's `<key>.indexeddb.leveldb` directory (and its `.blob`
/// sidecar). This runs only in the manual importer, before the destination Chrome launches, and only
/// while the source Chrome is closed so the multi-file LevelDB snapshot is consistent.
///
/// Scope and limits: this is the user's own data on the user's own machine. It is a coarse copy of the
/// whole origin database, gated by the same per-site consent. Partitioned storage keys (origin plus a
/// different top-level site) are not matched; only the unpartitioned store of the origin is copied.
public enum ChromeIndexedDBSource {
    public static let maximumBytes = 512 * 1024 * 1024
    public static let maximumFiles = 50_000

    struct Store { let leveldb: URL; let blob: URL? }

    /// The unpartitioned store directory name, e.g. `https_example.com_0.indexeddb.leveldb`.
    static func canonicalName(scheme: String, host: String) -> String { "\(scheme)_\(host)_0.indexeddb.leveldb" }

    static func validOriginComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
    }

    /// Finds the origin's IndexedDB store in a source profile. Prefers the canonical unpartitioned name
    /// and otherwise matches a `<scheme>_<host>_…indexeddb.leveldb` directory, so a trailing index other
    /// than `_0` still resolves. Returns nil when no store exists.
    static func resolve(profile: String, root: URL = ChromeCookieSource.directory, scheme: String, host: String) throws -> Store? {
        guard ["http", "https"].contains(scheme), validOriginComponent(host) else { throw ChromeCookieError.invalidProfile }
        guard try ChromeCookieSource.profiles(root: root).contains(where: { $0.id == profile }) else { throw ChromeCookieError.invalidProfile }
        let base = root.appendingPathComponent(profile).appendingPathComponent("IndexedDB").standardizedFileURL
        guard base.resolvingSymlinksInPath().path == base.path, base.path.hasPrefix(root.standardizedFileURL.path + "/"),
              (try? base.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let prefix = "\(scheme)_\(host)_", suffix = ".indexeddb.leveldb"
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let canonical = canonicalName(scheme: scheme, host: host)
        let match = entries.first { $0.lastPathComponent == canonical }
            ?? entries.first { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
        guard let leveldb = match, isRealDirectory(leveldb) else { return nil }
        let blobURL = base.appendingPathComponent(leveldb.lastPathComponent.replacingOccurrences(of: suffix, with: ".indexeddb.blob"))
        let blob = isRealDirectory(blobURL) ? blobURL : nil
        return Store(leveldb: leveldb, blob: blob)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// The destination IndexedDB directory inside a chat browser environment (`testing-profile/Default`).
    static func destinationDirectory(environment: URL, browserRoot: URL = BrowserEnvironmentStore.directory) throws -> URL {
        let root = browserRoot.standardizedFileURL
        guard environment.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("environments").path,
              environment.resolvingSymlinksInPath().path == environment.path,
              UUID(uuidString: environment.lastPathComponent) != nil else { throw ChromeCookieError.missingEnvironment }
        return environment.appendingPathComponent("testing-profile").appendingPathComponent("Default").appendingPathComponent("IndexedDB")
    }

    /// Clones the origin's store into the destination profile. The caller holds the import lock and has
    /// ensured the destination Chrome is not running; a running source Chrome is refused so the copy is
    /// consistent. Replaces any existing store of the same name. Returns nil when the origin has no store.
    public static func install(profile: String, root: URL = ChromeCookieSource.directory, scheme: String, host: String,
                               environment: URL, browserRoot: URL = BrowserEnvironmentStore.directory,
                               sourceIsRunning: () -> Bool) throws -> ChromeIndexedDBInstallResult? {
        guard let store = try resolve(profile: profile, root: root, scheme: scheme, host: host) else { return nil }
        guard !sourceIsRunning() else { throw ChromeCookieError.sourceRunning }
        let destination = try destinationDirectory(environment: environment, browserRoot: browserRoot)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var budget = Budget(bytes: maximumBytes, files: maximumFiles)
        let targetLeveldb = destination.appendingPathComponent(store.leveldb.lastPathComponent)
        try replaceCopy(from: store.leveldb, to: targetLeveldb, budget: &budget)
        var blobCopied = false
        if let blob = store.blob {
            try replaceCopy(from: blob, to: destination.appendingPathComponent(blob.lastPathComponent), budget: &budget)
            blobCopied = true
        }
        return ChromeIndexedDBInstallResult(storeName: store.leveldb.lastPathComponent,
                                            copiedBytes: maximumBytes - budget.bytes, blobCopied: blobCopied)
    }

    private struct Budget { var bytes: Int; var files: Int }

    /// Removes any existing destination directory, scans the source tree (rejecting any symlink and
    /// enforcing the size and file-count budget), then clones it with a single `copyItem`.
    private static func replaceCopy(from source: URL, to target: URL, budget: inout Budget) throws {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        guard let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw ChromeCookieError.unavailable
        }
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw ChromeCookieError.unsupportedSchema }
            if values.isRegularFile == true {
                budget.files -= 1
                budget.bytes -= (values.fileSize ?? 0)
                guard budget.files >= 0, budget.bytes >= 0 else { throw ChromeCookieError.tooLarge }
            }
        }
        try FileManager.default.copyItem(at: source, to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    }
}
