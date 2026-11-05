import Foundation

/// A sub-agent the chat's agent delegated work to, as reported by its engine. All text is engine/tool output (data).
public struct AgentSubagent: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable { case running, completed, failed, stopped }
    public struct Step: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable { case text, tool, result }
        public let id: String
        public let kind: Kind
        public var text: String
        public var isError: Bool
        public init(id: String, kind: Kind, text: String, isError: Bool = false) {
            self.id = id; self.kind = kind; self.text = text; self.isError = isError
        }
    }
    /// A tool call the sub-agent made that has no result yet.
    public struct PendingTool: Sendable, Equatable {
        public let id: String
        public let name: String
        /// The call's own time limit, when its input declares one.
        public let timeout: TimeInterval?
        public init(id: String, name: String, timeout: TimeInterval? = nil) { self.id = id; self.name = name; self.timeout = timeout }
    }
    public let id: String
    public var title: String
    /// Engine agent type, e.g. `general-purpose`.
    public var type: String?
    public var prompt: String
    /// Runs without blocking the parent agent, which resumes as each such sub-agent finishes.
    public var background: Bool
    public var depth: Int
    public var status: Status
    /// Latest one-line progress, e.g. "Reading Features.tsx".
    public var activity: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var toolUses: Int?
    public var tokens: Int?
    /// The sub-agent's final report once it finished.
    public var report: String?
    /// Most recent messages, tool calls and results, oldest first; earlier ones are dropped (`droppedSteps`).
    public var steps: [Step]
    public var droppedSteps: Int
    /// When the engine last reported anything from this sub-agent; engines may coarsen it to limit updates.
    public var lastActivityAt: Date
    /// Tool calls still waiting for their result, oldest first.
    public var pendingTools: [PendingTool]
    public init(id: String, title: String, type: String?, prompt: String, background: Bool, depth: Int, status: Status = .running,
                activity: String? = nil, startedAt: Date, endedAt: Date? = nil, toolUses: Int? = nil, tokens: Int? = nil,
                report: String? = nil, steps: [Step] = [], droppedSteps: Int = 0, lastActivityAt: Date? = nil, pendingTools: [PendingTool] = []) {
        self.id = id; self.title = title; self.type = type; self.prompt = prompt; self.background = background; self.depth = depth
        self.status = status; self.activity = activity; self.startedAt = startedAt; self.endedAt = endedAt
        self.toolUses = toolUses; self.tokens = tokens; self.report = report; self.steps = steps; self.droppedSteps = droppedSteps
        self.lastActivityAt = lastActivityAt ?? startedAt; self.pendingTools = pendingTools
    }
}

/// A command, watcher or workflow the chat's agent (or one of its sub-agents) left running in the background, such as a
/// dev server or a test run. All text is engine/tool output (data).
public struct AgentBackgroundTask: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case shell, monitor, workflow, mcp, other }
    public let id: String
    public var kind: Kind
    public var title: String
    /// The command line of a shell task.
    public var command: String?
    public var status: AgentSubagent.Status
    /// The sub-agent that started it; nil for the chat's own agent.
    public var parentID: String?
    /// Latest one-line status the engine reported.
    public var activity: String?
    /// The engine's closing summary, e.g. the exit code.
    public var report: String?
    public var startedAt: Date
    public var endedAt: Date?
    public init(id: String, kind: Kind, title: String, command: String? = nil, status: AgentSubagent.Status = .running, parentID: String? = nil,
                activity: String? = nil, report: String? = nil, startedAt: Date, endedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.command = command; self.status = status; self.parentID = parentID
        self.activity = activity; self.report = report; self.startedAt = startedAt; self.endedAt = endedAt
    }
    /// Shell commands and watchers have an output the engine can return (`AgentIntegration.taskOutput`).
    public var hasOutput: Bool { kind == .shell || kind == .monitor }
}

/// The end of a background task's output as plain text.
public struct AgentTaskOutput: Sendable, Equatable {
    public var text: String
    /// Size of the whole output in bytes.
    public var totalBytes: Int
    /// `text` holds only the end of a longer output.
    public var truncated: Bool
    public init(text: String, totalBytes: Int, truncated: Bool) { self.text = text; self.totalBytes = totalBytes; self.truncated = truncated }
}
