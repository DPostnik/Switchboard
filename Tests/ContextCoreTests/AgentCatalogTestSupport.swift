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

let catalogSharedLauncher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fixture-launcher").path

/// A fake `npm` (Python): logs its arguments, then lays out `node_modules/<package>` with a `bin` like npm does. The
/// agent's command is a hard link to the shared, already-assessed fixture launcher (its script is `<path>.fixture`), so
/// no freshly written executable runs. FAKE_NPM_MODE: ok, fail, badcheck (the agent exits 1), nonode.
let catalogFakeNPM = """
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_NPM_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
mode = os.environ.get("FAKE_NPM_MODE", "ok")
if mode == "fail":
    print("npm ERR! code E404", file=sys.stderr); sys.exit(1)
if mode == "nonode":
    print("env: node: No such file or directory", file=sys.stderr); sys.exit(127)
prefix = args[args.index("--prefix") + 1]
name, version = args[-1].rsplit("@", 1)
binary = os.environ.get("FAKE_NPM_BIN", "agent")
package = os.path.join(prefix, "node_modules", *name.split("/"))
os.makedirs(package, exist_ok=True)
with open(os.path.join(package, "package.json"), "w") as f:
    json.dump({"name": name, "version": version, "bin": {binary: "cli.js"}}, f)
bins = os.path.join(prefix, "node_modules", ".bin")
os.makedirs(bins, exist_ok=True)
command = os.path.join(bins, binary)
os.link(os.environ["FAKE_LAUNCHER"], command)
with open(command + ".fixture", "w") as f:
    f.write("#!/bin/sh\\n" + ("exit 1\\n" if mode == "badcheck" else 'echo "' + version + '"\\n'))
"""

struct NPMFixture {
    let root: URL, npm: URL, log: URL
    init() throws {
        root = try catalogTemporaryDirectory()
        npm = root.appendingPathComponent("npm")
        log = root.appendingPathComponent("npm.log")
        try ("#!" + fixturePython + "\n" + catalogFakeNPM).write(to: npm, atomically: true, encoding: .utf8)
        try installFixtureExecutable(at: npm)
    }
    func environment(mode: String = "ok", bin: String = "agent") -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_NPM_LOG": log.path, "FAKE_NPM_MODE": mode, "FAKE_NPM_BIN": bin, "FAKE_LAUNCHER": catalogSharedLauncher,
         "npm_config_global": "true"]
    }
    var calls: [[String]] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]
        }
    }
}

