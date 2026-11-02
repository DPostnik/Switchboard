import Foundation
import AgentContract
import ContextCore

/// The ACP v1 protocol as this adapter knows it, in one place.
///
/// `agentMethods`, `clientMethods`, `protocolMethods` and `sessionUpdates` list everything the pinned schema release declares
/// (`schema/v1/schema.json` of agent-client-protocol, schema 1.29.1, wire protocolVersion 1), handled or deliberately refused.
/// Anything else an agent sends is drift: requests are still refused with -32601 and notifications still dropped, but each is
/// counted in `CompatibilityDrift` by name only. ACPSnapshotTests checks this file against
/// Tests/Fixtures/compat/acp-v1-<schemaVersion>.json (scripts/compat-snapshot.py acp); keep both in step with the code.
enum ACPProtocolSurface {
    static let schemaVersion = "1.29.1"
    static let protocolVersion = 1

    /// Methods the agent implements (client to agent).
    static let agentMethods: Set<String> = [
        "authenticate", "initialize", "logout", "session/cancel", "session/close", "session/delete", "session/list", "session/load",
        "session/new", "session/prompt", "session/resume", "session/set_config_option", "session/set_mode"
    ]
    /// Methods the client implements (agent to client).
    static let clientMethods: Set<String> = [
        "elicitation/complete", "elicitation/create", "fs/read_text_file", "fs/write_text_file", "session/request_permission",
        "session/update", "terminal/create", "terminal/kill", "terminal/output", "terminal/release", "terminal/wait_for_exit"
    ]
    static let protocolMethods: Set<String> = ["$/cancel_request"]
    static let sessionUpdates: Set<String> = [
        "agent_message_chunk", "agent_thought_chunk", "available_commands_update", "compaction_summary_chunk", "compaction_update",
        "config_option_update", "current_mode_update", "notice", "plan", "session_info_update", "tool_call", "tool_call_update",
        "usage_update", "user_message_chunk"
    ]

    // What the adapter actually uses.

    /// Requests the adapter sends; each only after checking the capability that advertises it.
    static let sentRequests: Set<String> = [
        "initialize", "authenticate", "logout", "session/new", "session/load", "session/resume", "session/prompt", "session/set_config_option"
    ]
    static let sentNotifications: Set<String> = ["session/cancel"]
    /// Agent requests that get a real answer. Every other known client method is refused with -32601: this client does
    /// not advertise file system, terminal or elicitation support, so a compliant agent never sends them.
    static let answeredRequests: Set<String> = ["session/request_permission"]
    static var refusedRequests: Set<String> { clientMethods.subtracting(answeredRequests).subtracting(["session/update", "elicitation/complete"]) }
    /// Updates that become `AgentEvent`s with the current contract. The others are known, kept in adapter state where useful
    /// (config options, commands, title, mode) and counted as "not yet surfaced", never as drift.
    static let surfacedUpdates: Set<String> = [
        "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan", "usage_update", "compaction_update"
    ]
    /// Root -> field paths the decoders read. Roots: `response:<method>`, `request:<client method>` (params of an agent request),
    /// `notification:<method>` (params) and `update:<session update kind>`; `*` steps into an array element.
    static let reads: [String: [String]] = [
        "response:initialize": ["protocolVersion", "agentInfo.name", "agentInfo.version", "authMethods.*.id", "authMethods.*.name",
                                "authMethods.*.type", "agentCapabilities.loadSession", "agentCapabilities.sessionCapabilities.resume",
                                "agentCapabilities.auth.logout", "agentCapabilities.promptCapabilities.image"],
        "response:session/new": ["sessionId", "configOptions.*.id", "configOptions.*.name", "configOptions.*.category", "configOptions.*.type",
                                 "configOptions.*.currentValue", "configOptions.*.options.*.value", "configOptions.*.options.*.name",
                                 "configOptions.*.options.*.options.*.value"],
        "response:session/load": ["configOptions"],
        "response:session/resume": ["configOptions"],
        "response:session/prompt": ["stopReason"],
        "response:session/set_config_option": ["configOptions"],
        "response:authenticate": [], "response:logout": [],
        "notification:session/update": ["sessionId", "update"],
        "notification:$/cancel_request": ["requestId"],
        "request:session/request_permission": ["sessionId", "toolCall.toolCallId", "toolCall.title", "toolCall.kind", "toolCall.locations.*.path",
                                               "toolCall.rawInput", "options.*.optionId", "options.*.name", "options.*.kind"],
        "update:agent_message_chunk": ["content.type", "content.text", "messageId"],
        "update:agent_thought_chunk": ["content.type", "content.text", "messageId"],
        "update:tool_call": ["toolCallId", "title", "kind", "status", "locations.*.path", "locations.*.line", "rawInput", "content.*.type"],
        "update:tool_call_update": ["toolCallId", "title", "kind", "status", "content.*.type", "content.*.content.text", "content.*.path",
                                    "content.*.oldText", "content.*.newText", "content.*.terminalId", "locations.*.path", "rawOutput"],
        "update:plan": ["entries.*.content", "entries.*.status", "entries.*.priority"],
        "update:usage_update": ["used", "size"],
        "update:config_option_update": ["configOptions"],
        "update:session_info_update": ["title"],
        "update:available_commands_update": ["availableCommands.*.name", "availableCommands.*.description"],
        "update:current_mode_update": ["currentModeId"],
        "update:compaction_update": ["compactionId", "status"]
    ]
    /// Fields of the sent requests, checked against the same snapshot (`params:<method>`).
    static let writes: [String: [String]] = [
        "params:initialize": ["protocolVersion", "clientCapabilities.fs.readTextFile", "clientCapabilities.fs.writeTextFile",
                              "clientCapabilities.terminal", "clientCapabilities.auth.terminal", "clientInfo.name", "clientInfo.title", "clientInfo.version"],
        "params:authenticate": ["methodId"],
        "params:session/new": ["cwd", "mcpServers"],
        "params:session/load": ["sessionId", "cwd", "mcpServers"],
        "params:session/resume": ["sessionId", "cwd", "mcpServers"],
        "params:session/prompt": ["sessionId", "prompt.*.type", "prompt.*.text"],
        "params:session/set_config_option": ["sessionId", "configId", "value"],
        "params:session/cancel": ["sessionId"],
        "response:session/request_permission": ["outcome.outcome", "outcome.optionId"]
    ]

    /// Drift in one inbound request or notification, as (category, name). Missing-field names are `method:path`.
    /// Only fields the decoders depend on are checked; the list is short on purpose.
    static func drift(_ message: JSONValue) -> [(CompatibilityDrift.Category, String)] {
        let method = message["method"].string ?? "", params = message["params"]
        var found: [(CompatibilityDrift.Category, String)] = []
        func require(_ present: Bool, _ path: String) { if !present { found.append((.missingField, method + ":" + path)) } }
        if message["jsonrpc"].string != "2.0" { found.append((.missingField, method + ":jsonrpc")) }
        if message["id"] != .null {
            guard clientMethods.contains(method) else { return found + [(.serverRequest, method)] }
            if method == "session/request_permission" {
                require(params["sessionId"].string != nil, "sessionId")
                require(params["toolCall"]["toolCallId"].string != nil, "toolCall.toolCallId")
                require(params["options"] != .null, "options")
            }
            return found
        }
        guard clientMethods.contains(method) || protocolMethods.contains(method) else { return found + [(.notification, method)] }
        guard method == "session/update" else { return found }
        require(params["sessionId"].string != nil, "sessionId")
        let update = params["update"], kind = update["sessionUpdate"].string ?? ""
        guard sessionUpdates.contains(kind) else { return found + [(.itemType, kind)] }
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk", "user_message_chunk": require(update["content"]["type"].string != nil, kind + ".content.type")
        case "tool_call", "tool_call_update": require(update["toolCallId"].string != nil, kind + ".toolCallId")
        case "usage_update":
            require(update["used"].int != nil, kind + ".used"); require(update["size"].int != nil, kind + ".size")
        case "plan": require(update["entries"] != .null, kind + ".entries")
        default: break
        }
        return found
    }

    static func record(_ message: JSONValue, agent: AgentID, version: String?, into drift: CompatibilityDrift) {
        for (category, name) in Self.drift(message) { drift.record(agent, version: version, category, name) }
    }
}
