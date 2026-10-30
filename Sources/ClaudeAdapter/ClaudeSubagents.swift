import Foundation
import ContextCore
import AgentContract

/// Follows one CLI session's sub-agents from its stream-json frames: `system/task_*` lifecycle events
/// and the sub-agents' own messages (`parent_tool_use_id` = the Agent tool call that started them).
struct ClaudeSubagentTracker {
    static let stepLimit = 150, textLimit = 2000, resultLimit = 800, agentLimit = 24
    private(set) var agents: [AgentSubagent] = []
    /// Agent tool call ID -> task ID.
    private var calls: [String: String] = [:]

    /// Returns true when the list changed.
    mutating func observe(_ value: JSONValue, now: Date = Date()) -> Bool {
        switch value["type"].string {
        case "system": return system(value, now: now)
        case "assistant":
            guard let index = index(call: value["parent_tool_use_id"].string) else { return false }
            var changed = false
            for part in value["message"]["content"].array {
                switch part["type"].string {
                case "text":
                    guard let text = part["text"].string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    append(.init(id: (value["message"]["id"].string ?? UUID().uuidString) + ":text", kind: .text, text: Self.clip(text, Self.textLimit)), to: index)
                    changed = true
                case "tool_use":
                    let name = part["name"].string ?? ""
                    append(.init(id: part["id"].string ?? UUID().uuidString, kind: .tool, text: Self.toolLine(name, input: part["input"])), to: index)
                    changed = true
                default: break
                }
            }
            return changed
        case "user":
            guard let index = index(call: value["parent_tool_use_id"].string) else { return false }
            var changed = false
            for part in value["message"]["content"].array where part["type"].string == "tool_result" {
                let text = ClaudeIntegration.toolResultText(part["content"])
                append(.init(id: (part["tool_use_id"].string ?? UUID().uuidString) + ":result", kind: .result,
                             text: Self.clip(text, Self.resultLimit), isError: part["is_error"].bool == true), to: index)
                changed = true
            }
            return changed
        default: return false
        }
    }
    var runningIDs: [String] { agents.filter { $0.status == .running }.map(\.id) }
    /// The CLI is gone: sub-agents still running will not report anymore.
    mutating func stopRunning(now: Date = Date()) -> Bool {
        var changed = false
        for index in agents.indices where agents[index].status == .running {
            agents[index].status = .stopped; agents[index].endedAt = now; agents[index].activity = nil; changed = true
        }
        return changed
    }
    /// The CLI confirmed a user stop of this sub-agent. Returns true when the list changed.
    mutating func stop(_ id: String, now: Date = Date()) -> Bool {
        guard let index = agents.firstIndex(where: { $0.id == id && $0.status == .running }) else { return false }
        finish(index, status: .stopped, now: now)
        return true
    }
    /// A new user message starts a fresh delegation round; running sub-agents stay visible.
    mutating func clearFinished() -> Bool {
        let before = agents.count
        agents.removeAll { $0.status != .running }
        calls = calls.filter { call in agents.contains { $0.id == call.value } }
        return agents.count != before
    }

    private mutating func system(_ value: JSONValue, now: Date) -> Bool {
        guard let task = value["task_id"].string else { return false }
        switch value["subtype"].string {
        case "task_started":
            guard value["task_type"].string == "local_agent" || value["subagent_type"].string != nil else { return false }
            if let call = value["tool_use_id"].string { calls[call] = task }
            if let index = agents.firstIndex(where: { $0.id == task }) {
                // A background sub-agent resumes when its own background work finishes.
                agents[index].status = .running; agents[index].endedAt = nil; agents[index].activity = nil
                return true
            }
            agents.append(.init(id: task, title: Self.clip(Self.line(value["description"].string ?? ""), 200), type: value["subagent_type"].string,
                                prompt: Self.clip(value["prompt"].string ?? "", Self.textLimit * 4), background: value["is_backgrounded"].bool == true,
                                depth: max(1, value["spawn_depth"].int ?? 1), startedAt: now))
            if agents.count > Self.agentLimit, let oldest = agents.firstIndex(where: { $0.status != .running }) { agents.remove(at: oldest) }
            return true
        case "task_progress":
            guard let index = agents.firstIndex(where: { $0.id == task }) else { return false }
            if let text = value["description"].string.map(Self.line), !text.isEmpty { agents[index].activity = Self.clip(text, 200) }
            usage(value["usage"], index: index)
            return true
        case "task_updated":
            guard let index = agents.firstIndex(where: { $0.id == task }), let status = Self.status(value["patch"]["status"].string) else { return false }
            finish(index, status: status, now: now)
            return true
        case "task_notification":
            guard let index = agents.firstIndex(where: { $0.id == task }) else { return false }
            finish(index, status: Self.status(value["status"].string) ?? .completed, now: now)
            if let summary = value["summary"].string, !summary.isEmpty { agents[index].report = Self.clip(summary, Self.textLimit * 4) }
            usage(value["usage"], index: index)
            return true
        default: return false
        }
    }
    private mutating func finish(_ index: Int, status: AgentSubagent.Status, now: Date) {
        agents[index].status = status; agents[index].activity = nil
        if agents[index].endedAt == nil { agents[index].endedAt = now }
    }
    private mutating func usage(_ usage: JSONValue, index: Int) {
        if let tools = usage["tool_uses"].int { agents[index].toolUses = tools }
        if let tokens = usage["total_tokens"].int { agents[index].tokens = tokens }
    }
    private mutating func append(_ step: AgentSubagent.Step, to index: Int) {
        if let existing = agents[index].steps.firstIndex(where: { $0.id == step.id }) { agents[index].steps[existing] = step; return }
        agents[index].steps.append(step)
        let overflow = agents[index].steps.count - Self.stepLimit
        if overflow > 0 { agents[index].steps.removeFirst(overflow); agents[index].droppedSteps += overflow }
    }
    private func index(call: String?) -> Int? {
        guard let call, let task = calls[call] else { return nil }
        return agents.firstIndex { $0.id == task }
    }
    static func status(_ raw: String?) -> AgentSubagent.Status? {
        switch raw {
        case "completed": .completed
        case "failed", "error": .failed
        case "killed", "stopped", "cancelled", "canceled", "aborted": .stopped
        default: nil
        }
    }
    /// One line for a tool call: its name and the most telling input field.
    static func toolLine(_ name: String, input: JSONValue) -> String {
        for key in ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "expression"] {
            if let text = input[key].string.map(line), !text.isEmpty { return name + ": " + clip(text, 300) }
        }
        let rest = input.object.isEmpty ? "" : clip(line(input.display), 300)
        return rest.isEmpty ? name : name + ": " + rest
    }
    static func line(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func clip(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit - 1)) + "…" : text }
}
