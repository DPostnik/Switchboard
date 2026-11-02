import Foundation

/// The catalog as last fetched, with how fresh it is.
public struct AgentCatalogSnapshot: Sendable, Equatable {
    public let catalog: AgentCatalog
    public let fetchedAt: Date
    /// Older than the reuse window, or the last refresh failed and this is the previous copy.
    public let stale: Bool
    /// Why the last refresh failed, when it did.
    public let failure: String?
}

public enum AgentCatalogFetchFailure: LocalizedError, Equatable, Sendable {
    case network(String)
    case status(Int)
    case tooLarge
    case notACatalog

    public var errorDescription: String? {
        switch self {
        case .network(let reason): L10n.text("Каталог агентов недоступен: \(reason)", "The agent catalog is unavailable: \(reason)")
        case .status(let code): L10n.text("Каталог агентов ответил с кодом \(code).", "The agent catalog answered with status \(code).")
        case .tooLarge: L10n.text("Каталог агентов слишком большой.", "The agent catalog is too large.")
        case .notACatalog: L10n.text("Ответ не похож на каталог агентов.", "The response is not an agent catalog.")
        }
    }
}

/// Fetches the ACP registry only when asked (`refresh`), with no timers or background polling (research section 10:
/// "only when the catalog is opened; 24 h cache"). The document is cached with its ETag, Last-Modified and fetch time in
/// `<agents>/catalog.json`; a copy younger than `maxAge` is reused without network, an older one is revalidated
/// (304 keeps it), and a failed request returns the cached copy marked stale.
public actor AgentCatalogStore {
    public static let registryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    public static let maxAge: TimeInterval = 24 * 60 * 60
    static let maxBytes = 8 * 1024 * 1024

    struct CacheFile: Codable {
        var fetchedAt: Date
        var etag: String?
        var lastModified: String?
        /// The registry document as received (UTF-8 JSON text), parsed again on read.
        var document: String
    }

    public let directory: URL
    let url: URL
    let session: URLSession
    let now: @Sendable () -> Date
    /// Network requests made, for tests.
    public private(set) var requests = 0

    public init(directory: URL = Locations.agentsHome, url: URL = AgentCatalogStore.registryURL,
                configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory; self.url = url; self.now = now
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public var cacheFile: URL { directory.appendingPathComponent("catalog.json") }

    /// The cached catalog without network; nil when there is none or it cannot be read.
    public func cached() -> AgentCatalogSnapshot? {
        guard let file = readCache(), let catalog = try? AgentCatalogParser.parse(Data(file.document.utf8)) else { return nil }
        return AgentCatalogSnapshot(catalog: catalog, fetchedAt: file.fetchedAt, stale: !isFresh(file.fetchedAt), failure: nil)
    }

    /// Reuses a cached copy younger than `maxAge` (unless `force`), otherwise requests the registry once, conditionally
    /// when a copy exists. Never retries. Throws only when the request fails and there is no cached copy.
    public func refresh(force: Bool = false) async throws -> AgentCatalogSnapshot {
        let existing = readCache()
        let parsed = existing.flatMap { try? AgentCatalogParser.parse(Data($0.document.utf8)) }
        if !force, let existing, let parsed, isFresh(existing.fetchedAt) {
            return AgentCatalogSnapshot(catalog: parsed, fetchedAt: existing.fetchedAt, stale: false, failure: nil)
        }
        do {
            let file = try await fetch(revalidating: parsed == nil ? nil : existing)
            let catalog = try AgentCatalogParser.parse(Data(file.document.utf8))
            try writeCache(file)
            return AgentCatalogSnapshot(catalog: catalog, fetchedAt: file.fetchedAt, stale: false, failure: nil)
        } catch {
            let failure = (error as? AgentCatalogFetchFailure) ?? .network(error.localizedDescription)
            guard let existing, let parsed else { throw failure }
            return AgentCatalogSnapshot(catalog: parsed, fetchedAt: existing.fetchedAt, stale: true, failure: failure.errorDescription)
        }
    }

    func fetch(revalidating existing: CacheFile?) async throws -> CacheFile {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = existing?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = existing?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        requests += 1
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw AgentCatalogFetchFailure.network((error as? URLError)?.localizedDescription ?? error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw AgentCatalogFetchFailure.network("no HTTP response") }
        if http.statusCode == 304, var existing {
            existing.fetchedAt = now()
            return existing
        }
        guard http.statusCode == 200 else { throw AgentCatalogFetchFailure.status(http.statusCode) }
        guard data.count <= Self.maxBytes else { throw AgentCatalogFetchFailure.tooLarge }
        guard let text = String(data: data, encoding: .utf8), (try? AgentCatalogParser.parse(data)) != nil else {
            throw AgentCatalogFetchFailure.notACatalog
        }
        return CacheFile(fetchedAt: now(), etag: http.value(forHTTPHeaderField: "ETag"),
                         lastModified: http.value(forHTTPHeaderField: "Last-Modified"), document: text)
    }

    func isFresh(_ fetchedAt: Date) -> Bool {
        let age = now().timeIntervalSince(fetchedAt)
        return age >= 0 && age < Self.maxAge
    }

    func readCache() -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheFile.self, from: data)
    }

    func writeCache(_ file: CacheFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: cacheFile, options: .atomic)
    }
}
