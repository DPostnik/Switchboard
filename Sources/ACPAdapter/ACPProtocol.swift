import Foundation
import AgentContract
import ContextCore

// The ACP v1 subset this adapter reads and writes, written against the pinned schema release
// (`ACPProtocolSurface.schemaVersion`, agent-client-protocol schema/v1 1.29.1, wire `protocolVersion` 1).
// Decoding is lenient where the schema says `x-deserialize-default-on-error`: a malformed optional field reads as absent.
// Enumerations stay strings because the schema keeps them open; unknown values are data, never a decoding failure.

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
}

enum ACPCodec {
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

/// An object whose presence is the information (capability markers such as `sessionCapabilities.resume: {}`).
struct ACPMarker: Codable, Equatable, Sendable {
    init() {}
    init(from decoder: any Decoder) throws {
        guard case .object = try JSONValue(from: decoder) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "capability marker is not an object"))
        }
    }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode([String: String]()) }
}

struct ACPImplementation: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var version: String
}

// MARK: initialize

struct ACPClientCapabilities: Codable, Equatable, Sendable {
    struct FileSystem: Codable, Equatable, Sendable { var readTextFile = false; var writeTextFile = false }
    struct Auth: Codable, Equatable, Sendable { var terminal = false }
    var fs = FileSystem()
    var terminal = false
    var auth = Auth()
    /// What this client implements: no client file system, no terminals, no terminal sign-in, no elicitation and
    /// no boolean config options (all absent or false), so agents never route those to it.
    static let honest = Self()
}

struct ACPInitializeRequest: Codable, Sendable {
    var protocolVersion: Int
    var clientCapabilities: ACPClientCapabilities
    var clientInfo: ACPImplementation
}

struct ACPAgentCapabilities: Decodable, Equatable, Sendable {
    struct Session: Decodable, Equatable, Sendable {
        var list: ACPMarker?, resume: ACPMarker?, close: ACPMarker?, delete: ACPMarker?, additionalDirectories: ACPMarker?
        enum CodingKeys: String, CodingKey { case list, resume, close, delete, additionalDirectories }
        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            list = c.lenient(ACPMarker.self, .list); resume = c.lenient(ACPMarker.self, .resume)
            close = c.lenient(ACPMarker.self, .close); delete = c.lenient(ACPMarker.self, .delete)
            additionalDirectories = c.lenient(ACPMarker.self, .additionalDirectories)
        }
    }
    struct Prompt: Decodable, Equatable, Sendable {
        var image = false, audio = false, embeddedContext = false
        enum CodingKeys: String, CodingKey { case image, audio, embeddedContext }
        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            image = c.lenient(Bool.self, .image) ?? false; audio = c.lenient(Bool.self, .audio) ?? false
            embeddedContext = c.lenient(Bool.self, .embeddedContext) ?? false
        }
    }
    struct Auth: Decodable, Equatable, Sendable {
        var logout: ACPMarker?
        enum CodingKeys: String, CodingKey { case logout }
        init() {}
        init(from decoder: any Decoder) throws { logout = try decoder.container(keyedBy: CodingKeys.self).lenient(ACPMarker.self, .logout) }
    }
    var loadSession = false
    var promptCapabilities = Prompt()
    var sessionCapabilities = Session()
    var auth = Auth()
    enum CodingKeys: String, CodingKey { case loadSession, promptCapabilities, sessionCapabilities, auth }
    init() {}
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loadSession = c.lenient(Bool.self, .loadSession) ?? false
        promptCapabilities = c.lenient(Prompt.self, .promptCapabilities) ?? Prompt()
        sessionCapabilities = c.lenient(Session.self, .sessionCapabilities) ?? Session()
        auth = c.lenient(Auth.self, .auth) ?? Auth()
    }
}

struct ACPAuthMethod: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String?
    /// Absent or "agent": the agent runs the flow inside `authenticate`. "terminal": the client must run the agent in a terminal.
    var type: String?
    var isAgentFlow: Bool { type == nil || type == "agent" }
}

struct ACPInitializeResponse: Decodable, Sendable {
    var protocolVersion: Int
    var agentCapabilities: ACPAgentCapabilities
    var authMethods: [ACPAuthMethod]
    var agentInfo: ACPImplementation?
    enum CodingKeys: String, CodingKey { case protocolVersion, agentCapabilities, authMethods, agentInfo }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        agentCapabilities = c.lenient(ACPAgentCapabilities.self, .agentCapabilities) ?? ACPAgentCapabilities()
        // Invalid entries are skipped, as the schema says (`x-deserialize-skip-invalid-items`).
        authMethods = (c.lenient([JSONValue].self, .authMethods) ?? []).compactMap { try? ACPCodec.decode(ACPAuthMethod.self, from: $0) }
        agentInfo = c.lenient(ACPImplementation.self, .agentInfo)
    }
}

// MARK: sessions

struct ACPSessionRequest: Encodable, Sendable {
    /// Present for session/load and session/resume, absent for session/new.
    var sessionId: String?
    var cwd: String
    /// The app attaches no MCP servers through ACP yet.
    var mcpServers: [JSONValue] = []
}

struct ACPConfigOption: Codable, Equatable, Sendable {
    struct Choice: Codable, Equatable, Sendable { var value: String; var name: String; var description: String? }
    var id: String
    var name: String
    var category: String?
    /// "select" or "boolean"; other values are kept but never set by this client.
    var type: String
    var currentValue: JSONValue
    /// Select choices, flattened from groups.
    var options: [Choice]
    /// Set by this client for the model list of the pre-config-option session API (`models` in the session response,
    /// changed through `session/set_model`), which Gemini CLI 0.66.0 still uses instead of a model config option.
    /// Never read from the wire: only the app's own session records carry it.
    var setModel: Bool?
    enum CodingKeys: String, CodingKey { case id, name, category, type, currentValue, options, setModel = "switchboardSetModel" }
    init(id: String, name: String, category: String?, type: String, currentValue: JSONValue, options: [Choice], setModel: Bool? = nil) {
        self.id = id; self.name = name; self.category = category; self.type = type; self.currentValue = currentValue; self.options = options
        self.setModel = setModel
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = c.lenient(String.self, .category)
        type = try c.decode(String.self, forKey: .type)
        currentValue = c.lenient(JSONValue.self, .currentValue) ?? .null
        options = (c.lenient([JSONValue].self, .options) ?? []).flatMap { entry -> [Choice] in
            if entry["group"] != .null { return entry["options"].array.compactMap { try? ACPCodec.decode(Choice.self, from: $0) } }
            return (try? ACPCodec.decode(Choice.self, from: entry)).map { [$0] } ?? []
        }
        setModel = c.lenient(Bool.self, .setModel)
    }
    static func list(_ value: JSONValue) -> [Self]? {
        guard case .array(let entries) = value else { return nil }
        return entries.compactMap { try? ACPCodec.decode(Self.self, from: $0) }
    }
    /// A session's settings from a `session/new`, `session/load` or `session/resume` response: its config options, or,
    /// from an agent that reports only the older `models` list, that list as one model select option.
    static func session(_ response: JSONValue) -> [Self]? {
        if let options = list(response["configOptions"]) { return options }
        let models = response["models"]
        guard case .array(let available) = models["availableModels"] else { return nil }
        let choices = available.compactMap { entry -> Choice? in
            guard let id = entry["modelId"].string else { return nil }
            return Choice(value: id, name: entry["name"].string ?? id, description: entry["description"].string)
        }
        guard !choices.isEmpty else { return nil }
        return [Self(id: "model", name: L10n.text("Модель", "Model"), category: "model", type: "select",
                     currentValue: models["currentModelId"].string.map { JSONValue.string($0) } ?? .null, options: choices, setModel: true)]
    }

    /// The contract's form: categories and select choices as named values, a boolean's value as "true" or "false".
    var contract: AgentConfigOption? {
        let kind: AgentConfigOption.Kind
        switch type {
        case "select": kind = .select(options.map { .init(id: $0.value, name: $0.name, description: $0.description) })
        case "boolean": kind = .boolean
        default: return nil
        }
        let category: AgentConfigOption.Category = switch self.category {
        case "mode": .mode
        case "model": .model
        case "model_config": .modelConfig
        case "thought_level": .thoughtLevel
        default: .other
        }
        let current: String = switch currentValue {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        default: ""
        }
        return AgentConfigOption(id: id, name: name, category: category, kind: kind, current: current)
    }
}

/// One `available_commands_update` entry, typed as "/name" in the composer.
struct ACPCommand: Decodable, Equatable, Sendable {
    var name: String
    var description: String?
    var hint: String?
    enum CodingKeys: String, CodingKey { case name, description, input }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = c.lenient(String.self, .description)
        hint = c.lenient(JSONValue.self, .input)?["hint"].string
    }
    static func list(_ value: JSONValue) -> [AgentCommand] {
        value.array.compactMap { try? ACPCodec.decode(Self.self, from: $0) }.filter { !$0.name.isEmpty }
            .map { AgentCommand(name: $0.name, description: $0.description ?? "", inputHint: $0.hint) }
    }
}

struct ACPNewSessionResponse: Decodable, Sendable {
    var sessionId: String
}

struct ACPContentBlock: Codable, Equatable, Sendable {
    var type: String
    var text: String?
    var uri: String?
    var name: String?
    static func text(_ text: String) -> Self { .init(type: "text", text: text) }
    /// Readable form of a block; non-text blocks are named, never fetched.
    var display: String {
        switch type {
        case "text": return text ?? ""
        case "resource_link": return "[" + (name ?? uri ?? "resource") + "]"
        case "resource": return text ?? "[resource]"
        default: return "[" + type + "]"
        }
    }
}

struct ACPPromptRequest: Encodable, Sendable {
    var sessionId: String
    var prompt: [ACPContentBlock]
}

enum ACPStopReason {
    static let endTurn = "end_turn", maxTokens = "max_tokens", maxTurnRequests = "max_turn_requests"
    static let refusal = "refusal", cancelled = "cancelled"
    static let all: Set<String> = [endTurn, maxTokens, maxTurnRequests, refusal, cancelled]
    /// The contract's stop reason; nil for a value the schema does not declare.
    static func contract(_ raw: String) -> AgentStopReason? {
        switch raw {
        case endTurn: .endTurn
        case maxTokens: .maxTokens
        case maxTurnRequests: .maxTurnRequests
        case refusal: .refusal
        case cancelled: .cancelled
        default: nil
        }
    }
}

// MARK: session/update

struct ACPToolCallLocation: Codable, Equatable, Sendable { var path: String; var line: Int? }

struct ACPToolCallContent: Decodable, Equatable, Sendable {
    var type: String
    var content: ACPContentBlock?
    var path: String?
    var oldText: String?
    var newText: String?
    var terminalId: String?
    var display: String {
        switch type {
        case "content": return content?.display ?? ""
        case "diff":
            let path = self.path ?? ""
            let kind = oldText == nil ? L10n.text("новый файл", "new file") : L10n.text("изменён", "modified")
            return "\(path) (\(kind))"
        case "terminal": return "[terminal \(terminalId ?? "")]"
        default: return "[" + type + "]"
        }
    }
}

/// A `tool_call`, a `tool_call_update` or the `toolCall` of a permission request: everything but the ID is optional on update.
struct ACPToolCall: Decodable, Sendable {
    var toolCallId: String
    var title: String?
    var kind: String?
    var status: String?
    var content: [ACPToolCallContent]?
    var locations: [ACPToolCallLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    enum CodingKeys: String, CodingKey { case toolCallId, title, kind, status, content, locations, rawInput, rawOutput }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try c.decode(String.self, forKey: .toolCallId)
        title = c.lenient(String.self, .title); kind = c.lenient(String.self, .kind); status = c.lenient(String.self, .status)
        content = c.lenient([JSONValue].self, .content).map { $0.compactMap { try? ACPCodec.decode(ACPToolCallContent.self, from: $0) } }
        locations = c.lenient([JSONValue].self, .locations).map { $0.compactMap { try? ACPCodec.decode(ACPToolCallLocation.self, from: $0) } }
        rawInput = c.lenient(JSONValue.self, .rawInput); rawOutput = c.lenient(JSONValue.self, .rawOutput)
    }
}

struct ACPPlanEntry: Decodable, Equatable, Sendable { var content: String; var priority: String?; var status: String? }

struct ACPPermissionOption: Decodable, Equatable, Sendable {
    var optionId: String
    var name: String
    /// allow_once, allow_always, reject_once or reject_always.
    var kind: String
}

struct ACPPermissionRequest: Decodable, Sendable {
    var sessionId: String
    var toolCall: ACPToolCall
    var options: [ACPPermissionOption]
}

enum ACPPermissionOutcome {
    static func selected(_ option: String) -> JSONValue {
        .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])])
    }
    static let cancelled: JSONValue = .object(["outcome": .object(["outcome": .string("cancelled")])])
}
