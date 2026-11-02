import Foundation

/// One fake host for catalog and archive downloads: responses by path, every request recorded. No real network.
final class CatalogHost: @unchecked Sendable {
    struct Response { var status = 200; var headers: [String: String] = [:]; var body = Data(); var fail = false }
    let name = UUID().uuidString.lowercased() + ".invalid"
    private let lock = NSLock()
    private var responses: [String: (URLRequest) -> Response] = [:]
    private(set) var requestLog: [URLRequest] = []

    func serve(_ path: String, _ handler: @escaping (URLRequest) -> Response) { lock.withLock { responses[path] = handler } }
    func serve(_ path: String, body: Data, headers: [String: String] = [:]) { serve(path) { _ in Response(headers: headers, body: body) } }
    func url(_ path: String) -> URL { URL(string: "https://\(name)\(path)")! }
    var requests: [URLRequest] { lock.withLock { requestLog } }

    func respond(_ request: URLRequest) -> Response {
        lock.withLock {
            requestLog.append(request)
            return responses[request.url?.path ?? ""]?(request) ?? Response(status: 404)
        }
    }

    var configuration: URLSessionConfiguration {
        CatalogURLProtocol.hosts.withLock { $0[name] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return configuration
    }
    deinit { CatalogURLProtocol.hosts.withLock { $0[name] = nil } }
}

final class CatalogLocked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    static let hosts = CatalogLocked<[String: CatalogHost]>([:])
    static func host(_ request: URLRequest) -> CatalogHost? {
        guard let name = request.url?.host else { return nil }
        return hosts.withLock { $0[name] }
    }
    override class func canInit(with request: URLRequest) -> Bool { host(request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = Self.host(request) else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let response = host.respond(request)
        if response.fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                                              headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CatalogClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

func catalogTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}
