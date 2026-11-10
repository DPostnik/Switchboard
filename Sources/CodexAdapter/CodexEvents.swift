import Foundation
import AgentContract
import ContextCore

public typealias CodexEvent = AgentEvent
public typealias CodexInteraction = AgentInteraction
public typealias CodexInteractionResponse = AgentInteractionResponse
public typealias CodexTurnCompletion = AgentTurnCompletion

extension AgentTurnCompletion {
    init(_ raw: JSONValue, id: String) {
        let status: AgentExecutionOutcome
        switch raw["status"].string {
        case "completed": status = raw["error"] == .null ? .completed : .failed
        case "interrupted": status = .cancelled
        case "failed": status = .failed
        default: status = .uncertain
        }
        let usageLimit = CodexDecoding.usageLimitStop(turn: raw)
        self.init(id: id, status: status, hasError: raw["error"] != .null,
                  error: raw["error"]["message"].string, history: CodexHistoryTurn(raw),
                  usageLimit: usageLimit, stopReason: CodexDecoding.stopReason(turn: raw, status: status, usageLimit: usageLimit != nil))
    }
}

// Kept solely in the adapter. UUIDs are single-use handles, never native request IDs.
struct CodexPendingInteraction: Sendable {
    let interaction: CodexInteraction
    let rpcID: JSONValue
    let method: String
    let params: JSONValue

    /// Keep lifecycle evidence separate from schema, message, URL and answer content.
    func capability(stage: AgentCapabilityRecord.Stage, response: CodexInteractionResponse? = nil,
                    outcome: AgentCapabilityRecord.Outcome? = nil) -> AgentCapabilityRecord? {
        guard var record = CodexEventDecoder.capability(request: method, params: params) else { return nil }
        record.requestID = interaction.id.uuidString
        record.source = method; record.stage = stage; record.outcome = outcome
        if let response {
            switch response {
            case .allowOnce, .allowTurn, .allowChat: record.decision = .allowed
            case .deny: record.decision = .denied
            case .answers, .completed: record.decision = .answered
            }
        }
        return record
    }

    static func parse(_ raw: JSONValue) -> Self? {
        let p = raw["params"], method = raw["method"].string ?? ""
        guard let native = p["threadId"].string, !native.isEmpty,
              validRequestID(raw["id"]) else { return nil }
        let kind: CodexInteraction.Kind
        var canAllowChat = false
        switch method {
        case "item/commandExecution/requestApproval":
            guard p["turnId"].string != nil, p["kind"] == .null || ["command", "writeStdin"].contains(p["kind"].string ?? "") else { return nil }
            let decisions = p["availableDecisions"]
            guard decisions == .null || decisions.array.contains(.string("decline")) || decisions.array.contains(.string("cancel")) else { return nil }
            kind = .approval(canAllow: decisions == .null || decisions.array.contains(.string("accept")))
        case "item/fileChange/requestApproval":
            guard p["turnId"].string != nil else { return nil }
            // grantRoot can grant writes for the session, not just once.
            kind = .approval(canAllow: p["grantRoot"] == .null)
        case "item/permissions/requestApproval":
            guard p["turnId"].string != nil, case .object = p["permissions"] else { return nil }
            kind = .approval(canAllow: supportedPermissions(p["permissions"]))
        case "item/tool/requestUserInput":
            guard p["turnId"].string != nil, case .array(let questions) = p["questions"], !questions.isEmpty else { return nil }
            var fields: [CodexInteraction.Field] = []
            for q in questions {
                guard let id = q["id"].string, !id.isEmpty, let text = q["question"].string,
                      !fields.contains(where: { $0.id == id }),
                      q["isSecret"] == .null || q["isSecret"].bool != nil,
                      q["options"] == .null || { if case .array(let options) = q["options"] { return options.allSatisfy { $0["label"].string != nil } }; return false }() else { return nil }
                let options = q["options"].array.compactMap { option -> AgentInteraction.Field.Option? in
                    option["label"].string.map { .init(label: $0, description: option["description"].string) }
                }
                fields.append(.init(id: id, text: text, options: options, secret: q["isSecret"].bool == true, required: true, header: q["header"].string))
            }
            kind = .questions(fields)
        case "mcpServer/elicitation/request":
            let message = p["message"].string ?? L10n.text("Инструменту нужен ответ", "The tool needs your input")
            if let server = toolApprovalServer(p) {
                kind = .approval(canAllow: true)
                canAllowChat = chatGrantServers.contains(server)
            } else if p["mode"].string == "url", let rawURL = p["url"].string, let url = URL(string: rawURL), url.scheme == "https", url.host != nil {
                kind = .link(message: message, url: url)
            } else if p["mode"].string == "form", let fields = formFields(p["requestedSchema"]) {
                kind = .form(message: message, fields: fields)
            } else {
                kind = .unsupported(message: message)
            }
        default: return nil
        }
        let interaction = CodexInteraction(id: UUID(), session: .init(connection: .originalCodex, nativeID: native),
                                           turn: p["turnId"].string, kind: kind, reason: p["reason"].string, details: p.display, auditSource: method,
                                           command: method == "item/commandExecution/requestApproval" ? p["command"].string : nil,
                                           workingDirectory: method == "item/commandExecution/requestApproval" ? p["cwd"].string : nil,
                                           origin: method == "mcpServer/elicitation/request" ? .tool : (method == "item/tool/requestUserInput" ? .agent : .provider),
                                           canAllowChat: canAllowChat)
        return Self(interaction: interaction, rpcID: raw["id"], method: method, params: p)
    }

    /// App-owned browser servers whose tool calls the user may allow for the rest of a chat.
    static let chatGrantServers: Set<String> = ["switchboard_browser", UserChromeConfiguration.server]
    static let toolApprovalKindKey = "codex/approvals/mcp_tool_call/kind"
    static let toolApprovalPersistKey = "codex/approvals/mcp_tool_call/persist"

    /// The server of the engine's own MCP tool-call approval: a form with no fields and the approval kind marker.
    /// Message and tool parameters stay untrusted data; only the server name keys a chat grant.
    static func toolApprovalServer(_ p: JSONValue) -> String? {
        guard p["mode"].string == "form", p["_meta"][toolApprovalKindKey].string == "mcp_tool_call",
              let server = p["serverName"].string, !server.isEmpty,
              p["requestedSchema"]["type"].string == "object", case .object(let properties) = p["requestedSchema"]["properties"],
              properties.isEmpty, p["requestedSchema"]["required"].array.isEmpty else { return nil }
        return server
    }
    var toolApprovalServer: String? { method == "mcpServer/elicitation/request" ? Self.toolApprovalServer(params) : nil }

    private static func validRequestID(_ value: JSONValue) -> Bool {
        switch value {
        case .string: return true
        case .number(let number): return number.isFinite && number.rounded() == number
        default: return false
        }
    }

    func encode(_ response: CodexInteractionResponse) throws -> JSONValue {
        if toolApprovalServer != nil {
            switch response {
            case .allowOnce: return .object(["action": .string("accept"), "content": .object([:])])
            case .allowChat where interaction.canAllowChat:
                // Also let the engine skip asking again for this tool; the client grant covers the server's other tools.
                let offered = params["_meta"][Self.toolApprovalPersistKey]
                let session = offered.string == "session" || offered.array.contains(.string("session"))
                return .object(["action": .string("accept"), "content": .object([:]),
                                "_meta": .object(session ? [Self.toolApprovalPersistKey: .string("session")] : [:])])
            case .deny: return .object(["action": .string("decline")])
            default: throw Self.invalidResponse
            }
        }
        switch (interaction.kind, response) {
        case (.approval(let canAllow), .allowOnce) where canAllow:
            if method == "item/permissions/requestApproval" {
                return .object(["permissions": params["permissions"], "scope": .string("turn")])
            }
            return .object(["decision": .string("accept")])
        case (.approval, .deny):
            if method == "item/permissions/requestApproval" { return .object(["permissions": .object([:]), "scope": .string("turn")]) }
            let decisions = params["availableDecisions"]
            return .object(["decision": .string(decisions != .null && !decisions.array.contains(.string("decline")) ? "cancel" : "decline")])
        case (.questions(let fields), .answers(let answers)):
            try validate(answers, fields: fields)
            return .object(["answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })])
        case (.form(_, let fields), .answers(let answers)):
            try validate(answers, fields: fields)
            return .object(["action": .string("accept"), "content": .object(answers.mapValues(JSONValue.string))])
        case (.link, .completed): return .object(["action": .string("accept")])
        case (.form, .deny), (.link, .deny), (.unsupported, .deny): return .object(["action": .string("decline")])
        default: throw Self.invalidResponse
        }
    }
    private func validate(_ answers: [String: String], fields: [CodexInteraction.Field]) throws {
        guard Set(answers.keys).isSubset(of: Set(fields.map(\.id))),
              fields.allSatisfy({ !$0.required || !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Self.invalidResponse }
    }
    static var invalidResponse: ClientFailure {
        ClientFailure(L10n.text("Запрос устарел или ответ недопустим. Ничего не отправлено.", "The request is stale or the response is invalid. Nothing was sent."))
    }
    private static func formFields(_ schema: JSONValue) -> [CodexInteraction.Field]? {
        guard schema["type"].string == "object", case .object(let properties) = schema["properties"],
              Set(schema.object.keys).isSubset(of: ["type", "properties", "required", "$schema"]),
              schema["required"] == .null || { if case .array = schema["required"] { return schema["required"].array.allSatisfy { $0.string != nil } }; return false }() else { return nil }
        let required = Set(schema["required"].array.compactMap(\.string))
        guard required.isSubset(of: Set(properties.keys)) else { return nil }
        var fields: [CodexInteraction.Field] = []
        for id in properties.keys.sorted() {
            let value = properties[id]!
            // Never discard enum, format, length, pattern or other restrictions.
            guard value["type"].string == "string", Set(value.object.keys).isSubset(of: ["type", "title", "description"]) else { return nil }
            fields.append(.init(id: id, text: value["title"].string ?? id, options: [], secret: false, required: required.contains(id)))
        }
        return fields
    }
    private static func supportedPermissions(_ value: JSONValue) -> Bool {
        guard Set(value.object.keys).isSubset(of: ["network", "fileSystem"]) else { return false }
        let network = value["network"], files = value["fileSystem"]
        if network != .null {
            guard case .object = network, Set(network.object.keys).isSubset(of: ["enabled"]), network["enabled"] == .null || network["enabled"].bool != nil else { return false }
        }
        if files != .null {
            // Rich entry/glob policies require a dedicated presentation before acceptance.
            guard case .object = files, Set(files.object.keys).isSubset(of: ["read", "write"]) else { return false }
            for key in ["read", "write"] where files[key] != .null {
                guard case .array(let paths) = files[key], paths.allSatisfy({ $0.string?.hasPrefix("/") == true }) else { return false }
            }
        }
        return true
    }
}

/// Pure notification decoding; request IDs and answer encoding stay in the client.
enum CodexEventDecoder {
    /// Observing an item start does not establish successful execution.
    static func capability(_ item: JSONValue, turn: String?, completed: Bool = false) -> AgentCapabilityRecord? {
        var record: AgentCapabilityRecord
        switch item["type"].string {
        case "commandExecution": record = .init(tool: "commandExecution", capability: .shell, target: item["command"].string, decision: .used, turn: turn)
        case "fileChange": record = .init(tool: "fileChange", capability: .writeInProject, target: item["changes"].array.first?["path"].string, decision: .used, turn: turn)
        case "mcpToolCall":
            let server = item["server"].string ?? ""
            record = .init(tool: String((server + "." + (item["tool"].string ?? "")).prefix(200)), capability: ["switchboard_browser", "switchboard_user_chrome"].contains(server) ? .browser : .other, decision: .used, turn: turn)
        case "webSearch": record = .init(tool: "webSearch", capability: .network, target: item["query"].string, decision: .used, turn: turn)
        default: return nil
        }
        // Native item IDs are scoped by session and turn by the ledger consumer.
        record.requestID = item["id"].string.map { "item:" + String($0.prefix(195)) }
        record.source = completed ? "item/completed" : "item/started"
        record.stage = completed ? .completed : .started
        if completed {
            switch item["status"].string {
            case "failed": record.outcome = .failed
            case "declined", "cancelled": record.outcome = .cancelled
            case "completed":
                if item["type"].string == "commandExecution" {
                    record.outcome = item["exitCode"].int.map { $0 == 0 ? .succeeded : .failed } ?? .unknown
                } else if item["type"].string == "mcpToolCall" {
                    record.outcome = item["error"] != .null ? .failed : (item["result"] != .null ? .succeeded : .unknown)
                } else { record.outcome = .succeeded }
            default: record.outcome = .unknown
            }
        }
        return record
    }
    /// An approval request as a ledger record.
    static func capability(request method: String, params p: JSONValue) -> AgentCapabilityRecord? {
        switch method {
        case "item/commandExecution/requestApproval": return .init(tool: "commandExecution", capability: .shell, target: p["command"].string, decision: .asked, turn: p["turnId"].string)
        case "item/fileChange/requestApproval": return .init(tool: "fileChange", capability: .writeOutside, target: p["grantRoot"].string ?? p["changes"].array.first?["path"].string, decision: .asked, turn: p["turnId"].string)
        case "item/permissions/requestApproval": return .init(tool: "permissions", capability: .other, decision: .asked, turn: p["turnId"].string)
        case "item/tool/requestUserInput": return .init(tool: "requestUserInput", capability: .question, decision: .asked, turn: p["turnId"].string)
        case "mcpServer/elicitation/request":
            // Elicitation may ask for permission or data. Its message is untrusted and proves neither authority nor capability.
            if let server = CodexPendingInteraction.toolApprovalServer(p) {
                return .init(tool: "mcpElicitation", capability: CodexPendingInteraction.chatGrantServers.contains(server) ? .browser : .other,
                             target: server, decision: .asked, turn: p["turnId"].string)
            }
            return .init(tool: "mcpElicitation", capability: .other, decision: .asked, turn: p["turnId"].string)
        default: return nil
        }
    }
    static func notification(_ raw: JSONValue) -> CodexEvent? {
        let p = raw["params"], method = raw["method"].string ?? ""
        let session = p["threadId"].string.map { AgentSessionReference(connection: .originalCodex, nativeID: $0) }
        if CodexProtocolSurface.sessionBoundNotifications.contains(method) {
            guard let session, !session.nativeID.isEmpty else { return nil }
        }
        let payload: CodexEvent.Payload
        switch method {
        case "account/login/completed", "account/updated": payload = .accountChanged(error: p["success"].bool == false ? (p["error"].string ?? L10n.text("Вход не выполнен", "Not signed in")) : nil)
        case "account/rateLimits/updated": payload = .limitsChanged
        case "client/disconnected": payload = .disconnected
        case "client/error": payload = .diagnostic(p["message"].string ?? L10n.text("Ошибка Codex", "Codex error"))
        case "thread/tokenUsage/updated": payload = .usage(turn: p["turnId"].string, total: CodexDecoding.tokenCounters(p["tokenUsage"]["total"]), snapshot: CodexDecoding.usageSnapshot(event: p))
        case "turn/started":
            guard let id = p["turn"]["id"].string else { return nil }; payload = .started(turn: id)
        case "turn/completed":
            guard let id = p["turn"]["id"].string else { return nil }; payload = .completed(.init(p["turn"], id: id))
        case "item/started", "item/completed":
            guard var item = CodexDecoding.transcriptItem(p["item"]) else { return nil }
            if item.kind == "compaction", method == "item/started" {
                item.phase = "inProgress"
                item.text = L10n.text("Сжатие контекста…", "Compacting conversation…")
            }
            item.turnID = p["turnId"].string
            payload = .item(item)
        case "item/agentMessage/delta":
            guard let id = p["itemId"].string else { return nil }; payload = .delta(turn: p["turnId"].string, item: id, text: p["delta"].string ?? "")
        case "turn/plan/updated":
            guard let turn = p["turnId"].string, !turn.isEmpty else { return nil }
            payload = .plan(turn: turn, CodexToolCalls.plan(p))
        case "error": payload = .diagnostic(p["error"]["message"].string ?? p["message"].string ?? L10n.text("Ошибка Codex", "Codex error"))
        default: return nil
        }
        return CodexEvent(session: session, payload: payload)
    }
    /// The result item of a command `item/completed` reports finished; sent after `notification`'s call item.
    static func commandResult(_ raw: JSONValue) -> CodexEvent? {
        let p = raw["params"]
        guard raw["method"].string == "item/completed", let native = p["threadId"].string, !native.isEmpty,
              var item = CodexDecoding.commandResult(p["item"]) else { return nil }
        item.turnID = p["turnId"].string
        return CodexEvent(session: .init(connection: .originalCodex, nativeID: native), payload: .item(item))
    }
}
