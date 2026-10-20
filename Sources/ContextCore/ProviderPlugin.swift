import Foundation

public struct PluginTranslations: Codable, Sendable, Equatable {
    public let ru: String
    public let en: String
    public func text(language: AppLanguage = L10n.language) -> String { L10n.text(ru, en, language: language) }
    func isValid(maxLength: Int) -> Bool {
        !ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ru.count <= maxLength && en.count <= maxLength
    }
}

public struct PluginManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let title: String
    public let version: String
    public let executable: String
    public let arguments: [String]
    public let titleTranslations: PluginTranslations?
    public let descriptionTranslations: PluginTranslations?
    /// Absent on legacy manifests: protocol v1 already declares this fixed profile.
    public var optimizerRequirements: OptimizerRequirements? = nil
    public var requirements: OptimizerRequirements { optimizerRequirements ?? .processV1 }
    public func localizedTitle(language: AppLanguage = L10n.language) -> String {
        titleTranslations?.text(language: language) ?? title
    }

    public func validate() throws {
        guard schemaVersion == 1, id != "direct",
              id.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
              !title.isEmpty, title.count <= 100, !version.isEmpty, version.count <= 64,
              titleTranslations?.isValid(maxLength: 100) ?? true,
              descriptionTranslations?.isValid(maxLength: 512) ?? true,
              Self.isRelativePath(executable), arguments.count <= 16,
              arguments.allSatisfy({ $0.count <= 1024 && !$0.contains("\0") }) else {
            throw ClientFailure(L10n.text("Некорректный или несовместимый манифест плагина", "Invalid or incompatible plugin manifest"))
        }
    }
    private static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct ProviderPlugin: Identifiable, Sendable {
    public let manifest: PluginManifest
    public let directory: URL
    public var id: String { manifest.id }
    public var route: RequestRoute { RequestRoute(rawValue: id) }
    public init(directory: URL) throws {
        let file = directory.appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: file)
        guard data.count <= 65_536 else { throw ClientFailure(L10n.text("Слишком большой манифест плагина", "Plugin manifest is too large")) }
        manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        guard directory.lastPathComponent == manifest.id else { throw ClientFailure(L10n.text("ID плагина не совпадает с папкой установки", "Plugin ID does not match its installation folder")) }
        self.directory = directory
    }

}

public enum PluginCatalog {
    public static var defaultDirectory: URL { Locations.root.appendingPathComponent("plugins", isDirectory: true) }
    /// Discovery only reads manifests. It never executes newly discovered code.
    public static func scan(directory: URL) -> (plugins: [ProviderPlugin], issues: [String]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var plugins: [ProviderPlugin] = [], issues: [String] = []
            for folder in folders {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do { plugins.append(try ProviderPlugin(directory: folder)) }
                catch { issues.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            }
            return (plugins, issues)
        } catch { return ([], [error.localizedDescription]) }
    }
}

public struct PluginMetric: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let value: Int
    public let titleTranslations: PluginTranslations?
    public func localizedTitle(language: AppLanguage = L10n.language) -> String {
        titleTranslations?.text(language: language) ?? title
    }
}
public struct PluginStatus: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let pluginID: String
    public let pluginVersion: String
    public let instance: String
    public let detail: String
    public let metrics: [PluginMetric]
    public let detailTranslations: PluginTranslations?
    public func localizedDetail(language: AppLanguage = L10n.language) -> String {
        detailTranslations?.text(language: language) ?? detail
    }
}

/// Protocol v1: a separately installed executable serves a loopback Responses proxy.
public actor ProviderPluginRuntime {
    private let plugin: ProviderPlugin
    private let environment: [String: String]
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var endpoint: URL?
    private var instance = ""
    private var readyFile: URL?
    private let session: URLSession

    public init(plugin: ProviderPlugin, environment: [String: String]) {
        self.plugin = plugin
        self.environment = environment
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        session = URLSession(configuration: config, delegate: PluginHTTPDelegate(), delegateQueue: nil)
    }
    public func start() async throws -> URL {
        if let issue = OptimizerCompatibility.issue(agent: .codex, requirements: plugin.manifest.requirements) {
            throw ClientFailure(issue)
        }
        if let endpoint, process?.isRunning == true { _ = try await status(); return endpoint }
        stop()
        let executable = plugin.directory.appendingPathComponent(plugin.manifest.executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ClientFailure(L10n.text("Плагин не установлен полностью: \(plugin.manifest.localizedTitle())", "Plugin installation is incomplete: \(plugin.manifest.localizedTitle())")) }
        let root = plugin.directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        instance = UUID().uuidString
        let ready = root.appendingPathComponent("ready-\(instance).json")
        readyFile = ready
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executable
        child.arguments = plugin.manifest.arguments + ["--state", root.path, "--ready-file", ready.path,
            "--instance", instance, "--parent", String(ProcessInfo.processInfo.processIdentifier)]
        var env = environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"; env["PYTHONUNBUFFERED"] = "1"
        for key in ["LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        env.merge(ProcessLabels.environment()) { _, new in new }
        child.environment = env
        child.currentDirectoryURL = plugin.directory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        stderr.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        do {
            try child.run()
            process = child; output = stdout; errors = stderr
            for _ in 0..<600 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ClientFailure(L10n.text("Плагин завершился при запуске: \(plugin.manifest.localizedTitle()) (\(child.terminationStatus))", "Plugin exited during startup: \(plugin.manifest.localizedTitle()) (\(child.terminationStatus))")) }
                if let data = try? Data(contentsOf: ready), data.count <= 4096,
                   let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    guard value["instance"].string == instance, value["protocolVersion"].int == 1,
                          value["pluginID"].string == plugin.id,
                          let port = value["port"].int, (1...65535).contains(port) else {
                        throw ClientFailure(L10n.text("Несовместимый ответ плагина при запуске", "Incompatible plugin startup response"))
                    }
                    let url = URL(string: "http://127.0.0.1:\(port)")!
                    endpoint = url
                    _ = try await status()
                    return url
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ClientFailure(L10n.text("Плагин не успел запуститься: \(plugin.manifest.localizedTitle())", "Plugin startup timed out: \(plugin.manifest.localizedTitle())"))
        } catch { stop(); throw error }
    }
    public func status() async throws -> PluginStatus {
        guard process?.isRunning == true, let endpoint else { throw ClientFailure(L10n.text("Плагин остановлен: \(plugin.manifest.localizedTitle())", "Plugin is stopped: \(plugin.manifest.localizedTitle())")) }
        let (data, response) = try await session.data(from: endpoint.appendingPathComponent("contextdesk/status"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
              response.url?.host == "127.0.0.1", response.url?.port == endpoint.port else {
            throw ClientFailure(L10n.text("Плагин недоступен: \(plugin.manifest.localizedTitle())", "Plugin is unavailable: \(plugin.manifest.localizedTitle())"))
        }
        let value = try JSONDecoder().decode(PluginStatus.self, from: data)
        guard value.instance == instance, value.protocolVersion == 1, value.pluginID == plugin.id,
              value.pluginVersion == plugin.manifest.version, value.detail.count <= 1024,
              value.detailTranslations?.isValid(maxLength: 1024) ?? true,
              value.metrics.count <= 20, Set(value.metrics.map(\.id)).count == value.metrics.count,
              value.metrics.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && $0.title.count <= 100 && ($0.titleTranslations?.isValid(maxLength: 100) ?? true) }) else {
            throw ClientFailure(L10n.text("Ответ получен от несовместимого экземпляра плагина", "An incompatible plugin instance responded"))
        }
        return value
    }
    public func stop() {
        if process?.isRunning == true { process?.terminate() }
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        process = nil; output = nil; errors = nil; endpoint = nil
        if let readyFile { try? FileManager.default.removeItem(at: readyFile) }
        readyFile = nil
    }
}

private final class PluginHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
