import Foundation

/// Wire format of the Fringe ↔ Switchboard channel: one JSON object per line over a
/// Unix socket. Every message carries `version`; a peer that sees another version or an unknown
/// message type closes the connection instead of guessing.
public enum FringeProtocol {
    public static let version = 1
    /// Bundle id of the only client Switchboard accepts.
    public static let clientBundleID = "local.daniil.fringe"
    /// Bundle id of Switchboard.
    public static let serverBundleID = "local.daniil.switchboard"
    /// Bundle id of Switchboard builds from before the rename (Context Desk); still accepted as the server.
    public static let legacyServerBundleID = "local.daniil.contextdesk"
    public static let serverBundleIDs = [serverBundleID, legacyServerBundleID]
    /// One line may not exceed this; a longer line is a protocol error.
    public static let maxLineBytes = 1 << 20

    /// `~/Library/Application Support/Switchboard/fringe.sock`. The pre-rename folder `Context Desk` is a link to
    /// this one, so clients that still use the old path reach the same socket.
    public static func socketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Switchboard/fringe.sock")
    }
}

/// Capabilities announced in `hello`; a side uses a feature only when both announce it.
public enum FringeCapability: String, Codable, Sendable, CaseIterable {
    /// Answering approval requests from the panel (stage 2).
    case answer
}

public struct FringeHello: Codable, Equatable, Sendable {
    public var app: String
    public var appVersion: String
    public var capabilities: [FringeCapability]
    public init(app: String, appVersion: String, capabilities: [FringeCapability]) {
        self.app = app; self.appVersion = appVersion; self.capabilities = capabilities
    }
    private enum CodingKeys: String, CodingKey { case app, appVersion, capabilities }
    /// Capabilities from a newer peer that this build does not know are ignored, not fatal:
    /// they are optional by definition.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(String.self, forKey: .app)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        capabilities = try container.decode([String].self, forKey: .capabilities).compactMap(FringeCapability.init(rawValue:))
    }
}

/// One chat as the Agents tab shows it.
public struct FringeChat: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Comparable, Sendable {
        case waiting, working, finished
        private var rank: Int { self == .waiting ? 0 : self == .working ? 1 : 2 }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }
    public var id: String
    public var title: String
    public var project: String
    public var phase: Phase
    public var activity: String?
    public var since: Date?
    public var updated: Date
    public init(id: String, title: String, project: String, phase: Phase, activity: String? = nil, since: Date? = nil, updated: Date) {
        self.id = id; self.title = title; self.project = project; self.phase = phase
        self.activity = activity; self.since = since; self.updated = updated
    }
}

/// A pending agent request. Only approvals can be answered from the panel; everything else opens the chat.
public struct FringeRequest: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case approval, question, other }
    public var id: String
    public var chatID: String
    public var kind: Kind
    public var title: String
    public var reason: String?
    public var details: String
    /// False when the agent offers no "allow" for this approval.
    public var canAllow: Bool
    public init(id: String, chatID: String, kind: Kind, title: String, reason: String? = nil, details: String = "", canAllow: Bool = false) {
        self.id = id; self.chatID = chatID; self.kind = kind; self.title = title
        self.reason = reason; self.details = details; self.canAllow = canAllow
    }
}

/// A sub-agent one of the listed chats delegated work to. Not a chat of its own: opening it opens `chatID`.
/// All text is engine output (data). Peers from before this field never send or show it.
public struct FringeSubagent: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case running, completed, failed, stopped }
    public var id: String
    /// The chat whose agent started it.
    public var chatID: String
    public var title: String
    /// Engine agent type, e.g. `general-purpose`.
    public var type: String?
    /// Runs without blocking its chat's agent, which resumes on its own when it finishes.
    public var background: Bool
    public var status: Status
    /// Latest one-line progress.
    public var activity: String?
    public var since: Date
    public var ended: Date?
    public init(id: String, chatID: String, title: String, type: String? = nil, background: Bool = false, status: Status,
                activity: String? = nil, since: Date, ended: Date? = nil) {
        self.id = id; self.chatID = chatID; self.title = title; self.type = type; self.background = background
        self.status = status; self.activity = activity; self.since = since; self.ended = ended
    }
}

public struct FringeSnapshot: Codable, Equatable, Sendable {
    /// At most 8, most urgent first.
    public var chats: [FringeChat]
    public var requests: [FringeRequest]
    /// Sub-agents of the listed chats, running ones first; absent from older peers.
    public var subagents: [FringeSubagent]
    public init(chats: [FringeChat], requests: [FringeRequest], subagents: [FringeSubagent] = []) {
        self.chats = chats; self.requests = requests; self.subagents = subagents
    }
    private enum CodingKeys: String, CodingKey { case chats, requests, subagents }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chats = try container.decode([FringeChat].self, forKey: .chats)
        requests = try container.decode([FringeRequest].self, forKey: .requests)
        subagents = try container.decodeIfPresent([FringeSubagent].self, forKey: .subagents) ?? []
    }
}

public struct FringeAnnouncement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, done }
    public var kind: Kind
    public var chatID: String
    public var requestID: String?
    public var chatTitle: String
    public init(kind: Kind, chatID: String, requestID: String? = nil, chatTitle: String) {
        self.kind = kind; self.chatID = chatID; self.requestID = requestID; self.chatTitle = chatTitle
    }
}

public enum FringeAnswer: String, Codable, Sendable { case allowOnce, deny }

public struct FringeAnswerResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Delivered to the agent.
        case sent
        /// Not delivered; `message` says why. The panel never retries.
        case failed
    }
    public var requestID: String
    public var outcome: Outcome
    public var message: String?
    public init(requestID: String, outcome: Outcome, message: String? = nil) {
        self.requestID = requestID; self.outcome = outcome; self.message = message
    }
}

/// Every message on the channel. Switchboard sends hello, snapshot, announce, answerResult;
/// Fringe sends hello, openChat, answer.
public enum FringeMessage: Equatable, Sendable {
    case hello(FringeHello)
    case snapshot(FringeSnapshot)
    case announce(FringeAnnouncement)
    case answerResult(FringeAnswerResult)
    case openChat(chatID: String)
    case answer(requestID: String, response: FringeAnswer)

    public var type: String {
        switch self {
        case .hello: "hello"
        case .snapshot: "snapshot"
        case .announce: "announce"
        case .answerResult: "answerResult"
        case .openChat: "openChat"
        case .answer: "answer"
        }
    }
}

public enum FringeProtocolError: Error, Equatable, Sendable {
    case versionMismatch(Int)
    case unknownType(String)
    case malformed(String)
    case lineTooLong
}

/// Encodes and decodes single lines. Dates are ISO 8601 with fractional seconds.
public enum FringeCodec {
    private struct Envelope<Payload: Codable>: Codable {
        var version: Int
        var type: String
        var payload: Payload
    }
    private struct Header: Decodable {
        var version: Int
        var type: String
    }
    private struct OpenChat: Codable { var chatID: String }
    private struct Answer: Codable { var requestID: String; var response: FringeAnswer }

    /// The encoded line, terminated by `\n`.
    public static func encode(_ message: FringeMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func wrap<P: Codable>(_ payload: P) throws -> Data {
            try encoder.encode(Envelope(version: FringeProtocol.version, type: message.type, payload: payload))
        }
        var data: Data = switch message {
        case .hello(let value): try wrap(value)
        case .snapshot(let value): try wrap(value)
        case .announce(let value): try wrap(value)
        case .answerResult(let value): try wrap(value)
        case .openChat(let chatID): try wrap(OpenChat(chatID: chatID))
        case .answer(let requestID, let response): try wrap(Answer(requestID: requestID, response: response))
        }
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> FringeMessage {
        guard line.count <= FringeProtocol.maxLineBytes else { throw FringeProtocolError.lineTooLong }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
        }
        let header: Header
        do { header = try decoder.decode(Header.self, from: line) } catch { throw FringeProtocolError.malformed("header") }
        guard header.version == FringeProtocol.version else { throw FringeProtocolError.versionMismatch(header.version) }
        func payload<P: Codable>(_ type: P.Type) throws -> P {
            do { return try decoder.decode(Envelope<P>.self, from: line).payload } catch { throw FringeProtocolError.malformed(header.type) }
        }
        switch header.type {
        case "hello": return .hello(try payload(FringeHello.self))
        case "snapshot": return .snapshot(try payload(FringeSnapshot.self))
        case "announce": return .announce(try payload(FringeAnnouncement.self))
        case "answerResult": return .answerResult(try payload(FringeAnswerResult.self))
        case "openChat": return .openChat(chatID: try payload(OpenChat.self).chatID)
        case "answer":
            let answer = try payload(Answer.self)
            return .answer(requestID: answer.requestID, response: answer.response)
        default: throw FringeProtocolError.unknownType(header.type)
        }
    }
}

/// Splits a byte stream into lines. Bytes after the last newline wait for more data.
public struct FringeLineBuffer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            guard line.count <= FringeProtocol.maxLineBytes else { throw FringeProtocolError.lineTooLong }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        guard buffer.count <= FringeProtocol.maxLineBytes else { throw FringeProtocolError.lineTooLong }
        return lines
    }
}
