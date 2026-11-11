import Foundation
import ContextCore
import AgentContract

/// Role encoding for the Codex app server. The sandbox is enforced by the OS; the shell cannot be removed,
/// so `shell: off` is reported as an approximation rather than encoded.
/// Codex 0.167 loads allow-prefix rules from trusted config-layer `rules/*.rules` files, not thread overrides.
/// Never write project command exemptions into its shared app home: they would leak between projects and roles.
/// Shell-only preset paths also stay distinct from file-tool roots. Both gaps are declared by permission support.
extension AgentPermissionProfile {
    /// Project rules are loaded before the thread starts. A read-only/editor role must not
    /// inherit a project's outside-sandbox allow rules. Keep this override process-local;
    /// never rewrite shared home trust while other role processes are running.
    func codexProcessArguments(projectPath: String) throws -> [String] {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
        let profile = effective
        let trusted = profile.filesystem == .unrestricted || (profile.shell == .on && {
            if case .project = profile.filesystem { return true }; return false
        }())
        // The override parser treats quotes in dotted key segments literally. An inline
        // TOML table encodes the path as a key, including spaces and periods, correctly.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let key = String(decoding: try encoder.encode(project), as: UTF8.self)
        return ["-c", "projects={\(key)={trust_level=\"\(trusted ? "trusted" : "untrusted")\"}}"]
    }
    var codexSandbox: String {
        switch effective.filesystem {
        case .readOnly: return "read-only"
        case .project: return "workspace-write"
        case .unrestricted: return "danger-full-access"
        }
    }
    /// An unattended run never waits: actions outside the sandbox are refused by the engine instead of asked.
    var codexApprovalPolicy: String { effective.approvals == .ask ? "on-request" : "never" }
    public var codexThreadParameters: [String: JSONValue] { codexThreadParameters(external: false) }
    /// Under the external boundary the OS enforces the roots: nothing is asked, an action outside them fails.
    public func codexThreadParameters(external: Bool) -> [String: JSONValue] {
        ["approvalPolicy": .string(external ? "never" : codexApprovalPolicy), "sandbox": .string(codexSandbox)]
    }
    public func codexTurnParameters(projectPath: String, external: Bool = false) -> [String: JSONValue] {
        if external {
            return ["approvalPolicy": .string("never"),
                    "sandboxPolicy": .object(["type": .string("externalSandbox"), "networkAccess": .string(effective.network ? "enabled" : "restricted")])]
        }
        let policy: JSONValue
        switch effective.filesystem {
        case .readOnly: policy = .object(["type": .string("readOnly")])
        case .project(let roots):
            let writable = [projectPath] + roots.filter(\.writable).map(\.path)
            policy = .object(["type": .string("workspaceWrite"), "writableRoots": .array(writable.map(JSONValue.string)),
                              "networkAccess": .bool(effective.network)])
        case .unrestricted: policy = .object(["type": .string("dangerFullAccess")])
        }
        return ["approvalPolicy": .string(codexApprovalPolicy), "sandboxPolicy": policy]
    }
    /// Per-thread config keys merged over the browser table: the engine's web search and the app browser server.
    public var codexConfiguration: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        if !effective.webSearch { result["web_search"] = .string("disabled") }
        return result
    }
    /// `thread/start` and `thread/resume` config: the browser table, switched off when the role has no browser.
    public func codexThreadConfiguration(browser: JSONValue) -> JSONValue {
        var config = browser.object
        if effective.browser == .off, var server = config["mcp_servers.switchboard_browser"]?.object {
            server["enabled"] = .bool(false); server["required"] = .bool(false)
            config["mcp_servers.switchboard_browser"] = .object(server)
        }
        config.merge(codexConfiguration) { _, new in new }
        return .object(config)
    }
}

extension ProviderPlugin {
    public func providerArguments(endpoint: URL) throws -> [String] {
        try CodexOptimizerConfiguration.arguments(id: id, endpoint: endpoint)
    }
}

enum CodexOptimizerConfiguration {
    static func arguments(id: String, endpoint: URL) throws -> [String] {
        guard id != "direct", id.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil else { throw ConversationIdentity.unavailable }
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let port = endpoint.port, (1...65535).contains(port),
              endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil else { throw ClientFailure(L10n.text("Плагин должен использовать локальный адрес", "The plugin must use a local address")) }
        // Plugins expose Responses proxies. They cannot supply arbitrary Codex settings.
        let prefix = "model_providers." + RequestRoute(rawValue: id).providerID
        let values = ["\(prefix).name=\"OpenAI\"", "\(prefix).base_url=\"http://127.0.0.1:\(port)/v1\"",
                      "\(prefix).wire_api=\"responses\"", "\(prefix).requires_openai_auth=true",
                      "\(prefix).supports_websockets=true", "\(prefix).request_max_retries=0", "\(prefix).stream_max_retries=0"]
        return values.flatMap { ["-c", $0] }
    }
}

extension RequestRoute {
    // Input and resume on 0.167 check the provider selected at app-server launch.
    var launchArguments: [String] { ["-c", "model_provider=" + String(reflecting: providerID)] }
    public var providerID: String { self == .direct ? "openai" : "contextdesk_" + rawValue }
}
