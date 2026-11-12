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
        /// Full current list of the session's background commands and watchers (running ones and those finished since the last user message).
        case backgroundTasks([AgentBackgroundTask])
        /// One capability use or permission decision for the ledger (plan Phase 0); never a prompt to the user.
        case capability(AgentCapabilityRecord)
        /// The whole current plan of a turn; it replaces the turn's previous plan.
        case plan(turn: String?, AgentPlan)
        /// The full list of commands the session offers now.
        case commands([AgentCommand])
        /// The full list of the session's settings and their current values.
        case configOptions([AgentConfigOption])
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
        case allowed, asked, denied, wouldDeny, unsupportedTool, hookDenied, hookAsked, answered
    }
    /// A record is a lifecycle event, not another interruption. Correlate events using `requestID`.
    public enum Stage: String, Codable, Sendable {
        case requested, presented
        /// A response was attempted; this does not establish receipt or execution.
        case responded
        case started, completed, resolved
    }
    /// Only explicit engine results establish success. A successful response write establishes no tool outcome.
    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled, unknown
    }
    public var tool: String
    public var capability: Capability
    public var target: String?
    public var decision: Decision
    public var turn: String?
    /// Opaque correlation identifier scoped by provider, chat and run. Never a form answer or tool payload.
    public var requestID: String?
    /// Protocol method or app-owned policy identifier, never inferred from human-readable prompt text.
    public var source: String?
    public var stage: Stage?
    public var outcome: Outcome?
    /// Stable app-owned rule identifier when a policy supplies one.
    public var ruleID: String?
    /// Why the app asked, allowed or denied: a plain ASCII identifier such as `backslash`, `denyList` or `trusted`.
    /// Diagnostic evidence only; never shown as product copy and never used to decide.
    public var reason: String?
    public init(tool: String, capability: Capability, target: String? = nil, decision: Decision, turn: String? = nil,
                requestID: String? = nil, source: String? = nil, stage: Stage? = nil, outcome: Outcome? = nil, ruleID: String? = nil,
                reason: String? = nil) {
        self.tool = tool; self.capability = capability; self.target = target.map { String($0.prefix(200)) }; self.decision = decision; self.turn = turn
        self.requestID = requestID.map { String($0.prefix(200)) }; self.source = source.map { String($0.prefix(200)) }
        self.stage = stage; self.outcome = outcome; self.ruleID = ruleID.map { String($0.prefix(200)) }
        self.reason = reason.map { String($0.prefix(64)) }
    }
}

public struct AgentTurnCompletion: Sendable {
    public let id: String
    public let status: AgentExecutionOutcome
    public let hasError: Bool
    public let error: String?
    /// Set when the turn stopped because the account's usage limit is exhausted.
    public let usageLimit: AgentUsageLimitStop?
    /// Why the turn ended; the outcome's implied reason when the adapter has nothing more specific.
    public let stopReason: AgentStopReason?
    private let history: AgentHistoryTurn
    public init(id: String, status: AgentExecutionOutcome, hasError: Bool, error: String?, history: AgentHistoryTurn,
                usageLimit: AgentUsageLimitStop? = nil, stopReason: AgentStopReason? = nil) {
        self.id = id; self.status = status; self.hasError = hasError; self.error = error; self.history = history
        self.usageLimit = usageLimit
        self.stopReason = stopReason ?? AgentStopReason.implied(by: status, usageLimit: usageLimit != nil)
    }
    public func timing(fallback: ResponseTiming) -> ResponseTiming { history.timing(fallback: fallback) ?? fallback }
}

/// A turn stopped on an exhausted usage limit. `resetsAt` is the engine's own reset time when it reported one.
public struct AgentUsageLimitStop: Equatable, Sendable {
    public let resetsAt: Date?
    public init(resetsAt: Date?) { self.resetsAt = resetsAt }
}

public struct AgentInteraction: Identifiable, Sendable {
    /// Presentation provenance only; it grants no authority and is independent of wire method names.
    public enum Origin: String, Sendable { case provider, tool, agent }
    public let id: UUID
    public let session: AgentSessionReference
    public let turn: String?
    public let kind: Kind
    public let reason: String?
    /// Literal diagnostic evidence for presentation, never a response template.
    public let details: String
    /// True when `.allowTurn` is accepted: the agent then allows repeats of the same tool for the rest of this turn.
    public let canAllowTurn: Bool
    /// True when `.allowChat` is accepted: browser grants cover the same app-owned server until reset;
    /// command approvals use the provider's explicitly offered session decision, enforced by that provider.
    public let canAllowChat: Bool
    public let origin: Origin
    /// Bounded protocol identifier for audit correlation. Presentation text and answers never belong in the audit.
    public let auditSource: String?
    /// The adapter's opaque audit correlation ID; falls back to this interaction's UUID when omitted.
    public let auditRequestID: String?
    /// Typed command approval inputs. These stay in memory; audit records use their own bounded target policy.
    public let command: String?
    public let workingDirectory: String?
    public init(id: UUID, session: AgentSessionReference, turn: String?, kind: Kind, reason: String?, details: String, canAllowTurn: Bool = false,
                auditSource: String? = nil, auditRequestID: String? = nil, command: String? = nil, workingDirectory: String? = nil,
                origin: Origin = .provider, canAllowChat: Bool = false) {
        self.id = id; self.session = session; self.turn = turn; self.kind = kind; self.reason = reason; self.details = details
        self.canAllowTurn = canAllowTurn; self.canAllowChat = canAllowChat
        self.origin = origin
        self.auditSource = auditSource.map { String($0.prefix(200)) }
        self.auditRequestID = auditRequestID.map { String($0.prefix(200)) }
        self.command = command; self.workingDirectory = workingDirectory
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
        public let options: [Option]
        public let secret: Bool
        public let required: Bool
        /// The agent's short label for the question (Claude and Codex "header"), as data; nil when none was sent.
        public let header: String?
        public init(id: String, text: String, options: [Option], secret: Bool, required: Bool, header: String? = nil) {
            self.id = id; self.text = text; self.options = options; self.secret = secret; self.required = required
            let trimmed = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.header = trimmed.isEmpty ? nil : trimmed
        }
        /// One selectable answer. `label` is the value sent back; `description` and `preview` are agent text shown beside it, as data.
        public struct Option: Hashable, Sendable {
            public let label: String
            public let description: String?
            public let preview: String?
            public init(label: String, description: String? = nil, preview: String? = nil) {
                func trimmed(_ text: String?) -> String? {
                    let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return value.isEmpty ? nil : value
                }
                self.label = label; self.description = trimmed(description); self.preview = trimmed(preview)
            }
        }
    }
}

public enum AgentInteractionResponse: Sendable {
    /// `allowTurn` allows this request and every later request of the same tool until the turn ends.
    /// `allowChat` accepts the offered session scope (see `canAllowChat`); it never creates a global rule.
    case allowOnce, allowTurn, allowChat, deny, answers([String: String]), completed
}

