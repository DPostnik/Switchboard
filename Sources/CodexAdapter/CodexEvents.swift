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
        self.init(id: id, status: status, hasError: raw["error"] != .null,
                  error: raw["error"]["message"].string, history: CodexHistoryTurn(raw))
    }
}

// Kept solely in the adapter. UUIDs are single-use handles, never native request IDs.
struct CodexPendingInteraction: Sendable {
    let interaction: CodexInteraction
    let rpcID: JSONValue
    let method: String
    let params: JSONValue

    static func parse(_ raw: JSONValue) -> Self? {
        let p = raw["params"], method = raw["method"].string ?? ""
        guard let native = p["threadId"].string, !native.isEmpty,
              validRequestID(raw["id"]) else { return nil }
        let kind: CodexInteraction.Kind
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
                fields.append(.init(id: id, text: text, options: q["options"].array.compactMap { $0["label"].string }, secret: q["isSecret"].bool == true, required: true))
            }
            kind = .questions(fields)
        case "mcpServer/elicitation/request":
            let message = p["message"].string ?? L10n.text("Инструменту нужен ответ", "The tool needs your input")
            if p["mode"].string == "url", let rawURL = p["url"].string, let url = URL(string: rawURL), url.scheme == "https", url.host != nil {
                kind = .link(message: message, url: url)
            } else if p["mode"].string == "form", let fields = formFields(p["requestedSchema"]) {
                kind = .form(message: message, fields: fields)
            } else {
                kind = .unsupported(message: message)
            }
        default: return nil
        }
        let interaction = CodexInteraction(id: UUID(), session: .init(connection: .originalCodex, nativeID: native),
                                           turn: p["turnId"].string, kind: kind, reason: p["reason"].string, details: p.display)
        return Self(interaction: interaction, rpcID: raw["id"], method: method, params: p)
    }

    private static func validRequestID(_ value: JSONValue) -> Bool {
        switch value {
        case .string: return true
        case .number(let number): return number.isFinite && number.rounded() == number
        default: return false
        }
    }

    func encode(_ response: CodexInteractionResponse) throws -> JSONValue {
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
    /// A started item as a ledger record: the sandbox decided, the app only observed it.
    static func capability(_ item: JSONValue, turn: String?) -> AgentCapabilityRecord? {
        switch item["type"].string {
        case "commandExecution": return .init(tool: "commandExecution", capability: .shell, target: item["command"].string, decision: .used, turn: turn)
        case "fileChange": return .init(tool: "fileChange", capability: .writeInProject, target: item["changes"].array.first?["path"].string, decision: .used, turn: turn)
        case "mcpToolCall":
            let server = item["server"].string ?? ""
            return .init(tool: server + "." + (item["tool"].string ?? ""), capability: server == "switchboard_browser" ? .browser : .other, decision: .used, turn: turn)
        case "webSearch": return .init(tool: "webSearch", capability: .network, target: item["query"].string, decision: .used, turn: turn)
        default: return nil
        }
    }
    /// An approval request as a ledger record.
    static func capability(request method: String, params p: JSONValue) -> AgentCapabilityRecord? {
        switch method {
        case "item/commandExecution/requestApproval": return .init(tool: "commandExecution", capability: .shell, target: p["command"].string, decision: .asked, turn: p["turnId"].string)
        case "item/fileChange/requestApproval": return .init(tool: "fileChange", capability: .writeOutside, target: p["grantRoot"].string ?? p["changes"].array.first?["path"].string, decision: .asked, turn: p["turnId"].string)
        case "item/permissions/requestApproval": return .init(tool: "permissions", capability: .other, target: p["reason"].string, decision: .asked, turn: p["turnId"].string)
        default: return nil
        }
    }
    static func notification(_ raw: JSONValue) -> CodexEvent? {
        let p = raw["params"], method = raw["method"].string ?? ""
        let session = p["threadId"].string.map { AgentSessionReference(connection: .originalCodex, nativeID: $0) }
        if ["thread/tokenUsage/updated", "turn/started", "turn/completed", "item/started", "item/completed", "item/agentMessage/delta"].contains(method) {
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
        case "error": payload = .diagnostic(p["error"]["message"].string ?? p["message"].string ?? L10n.text("Ошибка Codex", "Codex error"))
        default: return nil
        }
        return CodexEvent(session: session, payload: payload)
    }
}
