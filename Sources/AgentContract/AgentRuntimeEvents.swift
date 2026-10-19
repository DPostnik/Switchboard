import Foundation

/// Normalized runtime notifications. Original engine identifiers remain opaque data.
public struct AgentEvent: Sendable {
    public let session: AgentSessionReference?
    public let payload: Payload
    public init(session: AgentSessionReference?, payload: Payload) { self.session = session; self.payload = payload }
    public enum Payload: Sendable {
        case descriptor(AgentDescriptor)
        case accountChanged(error: String?)
        case limitsChanged, disconnected, interactionsReset
        case diagnostic(String)
        case interaction(AgentInteraction)
        case resolved(UUID)
        case usage(turn: String?, total: TokenCounters?, snapshot: UsageSnapshot)
        case started(turn: String)
        case completed(AgentTurnCompletion)
        case item(TranscriptItem)
        case delta(turn: String?, item: String, text: String)
        /// Transient one-line activity for a running turn, such as thinking or a tool name. Nil clears it.
        case status(turn: String?, text: String?)
        /// Background tasks an idle session's live engine still runs; the engine resumes the chat itself when they finish. Zero clears it.
        case background(tasks: Int)
        /// Full current list of the session's sub-agents (running ones and those finished since the last user message).
        case subagents([AgentSubagent])
        /// One capability use or permission decision for the ledger (plan Phase 0); never a prompt to the user.
        case capability(AgentCapabilityRecord)
    }
}

/// What an agent tried and what the role decided. `target` is a path, domain or command head, capped by the adapter.
public struct AgentCapabilityRecord: Codable, Hashable, Sendable {
    public enum Capability: String, Codable, Sendable {
        case read, writeInProject, writeOutside, shell, network, browser, connector, connectorWrite, subagent, question, other
    }
    public enum Decision: String, Codable, Sendable {
        /// The tool ran under the engine's own rules; the app only observed it.
        case used
        case allowed, asked, denied, wouldDeny, unsupportedTool, hookDenied, hookAsked
    }
    public var tool: String
    public var capability: Capability
    public var target: String?
    public var decision: Decision
    public var turn: String?
    public init(tool: String, capability: Capability, target: String? = nil, decision: Decision, turn: String? = nil) {
        self.tool = tool; self.capability = capability; self.target = target.map { String($0.prefix(200)) }; self.decision = decision; self.turn = turn
    }
}

public struct AgentTurnCompletion: Sendable {
    public let id: String
    public let status: AgentExecutionOutcome
    public let hasError: Bool
    public let error: String?
    private let history: AgentHistoryTurn
    public init(id: String, status: AgentExecutionOutcome, hasError: Bool, error: String?, history: AgentHistoryTurn) {
        self.id = id; self.status = status; self.hasError = hasError; self.error = error; self.history = history
    }
    public func timing(fallback: ResponseTiming) -> ResponseTiming { history.timing(fallback: fallback) ?? fallback }
}

public struct AgentInteraction: Identifiable, Sendable {
    public let id: UUID
    public let session: AgentSessionReference
    public let turn: String?
    public let kind: Kind
    public let reason: String?
    /// Literal diagnostic evidence for presentation, never a response template.
    public let details: String
    public init(id: UUID, session: AgentSessionReference, turn: String?, kind: Kind, reason: String?, details: String) {
        self.id = id; self.session = session; self.turn = turn; self.kind = kind; self.reason = reason; self.details = details
    }
    public enum Kind: Sendable {
        case approval(canAllow: Bool)
        case questions([Field])
        case form(message: String, fields: [Field])
        case link(message: String, url: URL)
        case unsupported(message: String)
    }
    public struct Field: Identifiable, Sendable {
        public let id: String
        public let text: String
        public let options: [String]
        public let secret: Bool
        public let required: Bool
        public init(id: String, text: String, options: [String], secret: Bool, required: Bool) {
            self.id = id; self.text = text; self.options = options; self.secret = secret; self.required = required
        }
    }
}

public enum AgentInteractionResponse: Sendable {
    case allowOnce, deny, answers([String: String]), completed
}

