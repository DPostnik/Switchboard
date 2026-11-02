import Foundation
import AgentContract

/// Finds running sub-agents the engine has not heard from for too long. A sub-agent that hangs inside a tool call
/// otherwise leaves its parent waiting for a completion notice that never comes; the app checks every
/// `checkInterval` and tells the parent agent once per stall.
public enum SubagentWatch {
    /// How often the app looks at running sub-agents.
    public static let checkInterval: TimeInterval = 180
    /// Silence allowed while the model works or a tool without its own time limit runs.
    public static let quietLimit: TimeInterval = 300
    /// Added to a pending tool call's own time limit (for example a Bash `timeout`).
    public static let toolMargin: TimeInterval = 180
    /// Delegation calls: the sub-agent they start is watched on its own.
    static let delegationTools: Set<String> = ["Agent", "Task"]

    public struct Silence: Sendable, Equatable {
        public let agentID: String
        public let title: String
        public let quietSince: Date
        /// Names of the tool calls still waiting for their result.
        public let pendingTools: [String]
        /// One stall: new activity and a later silence make a new key.
        public var key: String { agentID + "@" + String(quietSince.timeIntervalSinceReferenceDate) }
    }

    /// How long the sub-agent may stay silent; nil while it waits for a sub-agent it started.
    public static func allowance(_ agent: AgentSubagent) -> TimeInterval? {
        var limit = quietLimit
        for tool in agent.pendingTools {
            if delegationTools.contains(tool.name) { return nil }
            if let timeout = tool.timeout { limit = max(limit, timeout + toolMargin) }
        }
        return limit
    }

    /// Running sub-agents silent beyond their allowance. `awakeSince` is when the Mac last woke: sleep stops
    /// the agents too, so silence is counted from then at the earliest.
    public static func silences(_ agents: [AgentSubagent], now: Date, awakeSince: Date? = nil) -> [Silence] {
        agents.compactMap { agent in
            guard agent.status == .running, let allowance = allowance(agent) else { return nil }
            let since = max(agent.lastActivityAt, awakeSince ?? .distantPast)
            guard now.timeIntervalSince(since) >= allowance else { return nil }
            return Silence(agentID: agent.id, title: agent.title, quietSince: agent.lastActivityAt, pendingTools: agent.pendingTools.map(\.name))
        }
    }

    /// The message the parent agent gets. Titles and tool names are the agent's own data, quoted as such.
    public static func message(_ silences: [Silence], now: Date, language: AppLanguage = L10n.language) -> String {
        let lines = silences.map { silence in
            let minutes = max(1, Int(now.timeIntervalSince(silence.quietSince) / 60))
            let title = silence.title.count > 120 ? String(silence.title.prefix(119)) + "…" : silence.title
            let tools = silence.pendingTools.joined(separator: ", ")
            return tools.isEmpty
                ? L10n.text("- «\(title)» (ID \(silence.agentID)): нет активности \(minutes) мин.",
                            "- \"\(title)\" (ID \(silence.agentID)): no activity for \(minutes) min.", language: language)
                : L10n.text("- «\(title)» (ID \(silence.agentID)): нет активности \(minutes) мин; ждёт результата: \(tools).",
                            "- \"\(title)\" (ID \(silence.agentID)): no activity for \(minutes) min; waiting for: \(tools).", language: language)
        }.joined(separator: "\n")
        return L10n.text(
            """
            Проверка Switchboard: эти подагенты давно ничего не сообщают и могли зависнуть.
            \(lines)
            Проверь их состояние, например по их выводу или журналу. Если подагент завис, останови его и выполни его работу заново. Если он ещё работает, продолжай ждать. Switchboard ничего не останавливал и не повторял.
            """,
            """
            Switchboard check: these sub-agents have reported nothing for a while and may be stuck.
            \(lines)
            Check their state, for example in their output or journal. If one is stuck, stop it and redo its work. If it is still working, keep waiting. Switchboard stopped and retried nothing.
            """, language: language)
    }
}
