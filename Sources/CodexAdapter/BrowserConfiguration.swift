import Foundation
import ContextCore

/// App-owned MCP launch settings. Never edits either Codex home or project policy.
public enum BrowserConfiguration {
    public static var directory: URL { Locations.root.appendingPathComponent("browser", isDirectory: true) }
    public static let parallelLimitKey = BrowserEnvironmentStore.parallelLimitKey

    public static func isInstalled(at root: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.json").path)
    }

    public static func arguments(enabled: Bool, resources: URL?, root: URL = directory,
                                 language: AppLanguage = L10n.language) throws -> [String] {
        let prefix = "mcp_servers.switchboard_browser"
        // No persistent MCP entry is written. Omitting our launch arguments is
        // sufficient when disabled; a transport-less disabled table is invalid.
        guard enabled else { return [] }
        guard let resources else {
            throw ClientFailure(L10n.text("Компонент браузера отсутствует в сборке приложения.", "The browser component is missing from this app build.", language: language))
        }
        let script = resources.appendingPathComponent("BrowserRuntime/server.py")
        guard FileManager.default.fileExists(atPath: script.path), isInstalled(at: root) else {
            throw ClientFailure(L10n.text("Сначала установи компонент Chrome DevTools по инструкции в настройках браузера.", "Install the Chrome DevTools component using the browser settings instructions first.", language: language))
        }
        let args = [script.path, "--root", root.path, "--language", language.rawValue]
        // JSON string/array literals are valid TOML here. They are passed as argv,
        // never shell source. No approval, sandbox or project-trust overrides.
        func encode<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        return [
            "\(prefix).command=\"/usr/bin/python3\"",
            "\(prefix).args=\(try encode(args))",
            "\(prefix).enabled=true",
            "\(prefix).startup_timeout_sec=30",
            "\(prefix).tool_timeout_sec=90"
        ].flatMap { ["-c", $0] }
    }

    static func threadConfiguration(resources: URL?, root: URL, environment: UUID?, grant: BrowserProfileGrant? = nil,
                                    policy: BrowserLaunchPolicy = .init(allowEval: false, allowUpload: false, importScope: .none)) throws -> JSONValue {
        guard let resources, let environment else {
            // A disabled table still needs a valid transport. Override saved
            // thread configuration explicitly without launching any process.
            return .object(["mcp_servers.switchboard_browser": .object([
                "command": .string("/usr/bin/false"), "args": .array([]),
                "enabled": .bool(false), "required": .bool(false)
            ])])
        }
        _ = try arguments(enabled: true, resources: resources, root: root)
        return .object(["mcp_servers.switchboard_browser": .object([
            "command": .string("/usr/bin/python3"),
            "args": .array(BrowserEnvironmentStore.serverArguments(resources: resources, root: root, environment: environment,
                                                                   grant: grant, policy: policy).map(JSONValue.string)),
            "enabled": .bool(true), "required": .bool(true),
            "startup_timeout_sec": .number(30), "tool_timeout_sec": .number(90)
        ])])
    }
}
