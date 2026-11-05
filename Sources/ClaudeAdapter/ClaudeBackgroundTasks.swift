import Foundation
import ContextCore
import AgentContract

/// Follows one CLI session's background commands, watchers and workflows (every task that is not a sub-agent):
/// `system/task_*` events, the `background_tasks_changed` level, and the tool calls that started them for the command line.
struct ClaudeBackgroundTaskTracker {
    static let taskLimit = 24, callLimit = 200, foregroundLimit = 50
    private(set) var tasks: [AgentBackgroundTask] = []
    /// Foreground commands; one appears in `tasks` once it moves to the background.
    private var foreground: [String: AgentBackgroundTask] = [:]
    /// Tool call ID -> its command line or one-line input, newest last.
    private var calls: [(id: String, line: String)] = []
    /// Tasks seen in a `background_tasks_changed` level; leaving it ends them.
    private var leveled: Set<String> = []

    /// Returns true when the list changed.
    mutating func observe(_ value: JSONValue, now: Date = Date()) -> Bool {
        switch value["type"].string {
        case "assistant":
            for part in value["message"]["content"].array where part["type"].string == "tool_use" {
                guard let id = part["id"].string else { continue }
                let input = part["input"]
                let line = input["command"].string.map(ClaudeSubagentTracker.line)
                    ?? ClaudeSubagentTracker.toolLine(part["name"].string ?? "", input: input)
                calls.append((id, ClaudeSubagentTracker.clip(line, 1000)))
            }
            if calls.count > Self.callLimit { calls.removeFirst(calls.count - Self.callLimit) }
            return false
        case "system": return system(value, now: now)
        default: return false
        }
    }
    var runningIDs: [String] { tasks.filter { $0.status == .running }.map(\.id) }
    /// Sub-agents that still wait for a background task they started.
    var waitingParents: Set<String> { Set(tasks.filter { $0.status == .running }.compactMap(\.parentID)) }
    /// The CLI is gone: tasks still running ended with it.
    mutating func stopRunning(now: Date = Date()) -> Bool {
        foreground.removeAll(); leveled.removeAll()
        var changed = false
        for index in tasks.indices where tasks[index].status == .running { finish(index, status: .stopped, now: now); changed = true }
        return changed
    }
    /// The CLI confirmed a user stop of this task. Returns true when the list changed.
    mutating func stop(_ id: String, now: Date = Date()) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.status == .running }) else { return false }
        finish(index, status: .stopped, now: now)
        return true
    }
    /// A new user message starts a fresh round; running tasks stay visible.
    mutating func clearFinished() -> Bool {
        let before = tasks.count
        tasks.removeAll { $0.status != .running }
        return tasks.count != before
    }
    func task(_ id: String) -> AgentBackgroundTask? { tasks.first { $0.id == id } }

    private mutating func system(_ value: JSONValue, now: Date) -> Bool {
        if value["subtype"].string == "background_tasks_changed" { return level(value["tasks"].array, now: now) }
        guard let id = value["task_id"].string else { return false }
        switch value["subtype"].string {
        case "task_started":
            // Sub-agents have their own panel (`ClaudeSubagentTracker`).
            guard let kind = Self.kind(value["task_type"].string), value["subagent_type"].string == nil else { return false }
            let command = value["tool_use_id"].string.flatMap { call in calls.last { $0.id == call }?.line }
            let title = ClaudeSubagentTracker.clip(ClaudeSubagentTracker.line(value["workflow_name"].string ?? value["description"].string ?? ""), 200)
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                // Usually known from the level, which comes first and has no command line; or a resumed run.
                tasks[index].status = .running; tasks[index].endedAt = nil; tasks[index].report = nil; tasks[index].kind = kind
                if tasks[index].command == nil { tasks[index].command = command }
                if tasks[index].parentID == nil { tasks[index].parentID = value["parent_task_id"].string }
                if !title.isEmpty { tasks[index].title = title }
                return true
            }
            let task = AgentBackgroundTask(id: id, kind: kind, title: title.isEmpty ? (command ?? id) : title, command: command,
                                           parentID: value["parent_task_id"].string, startedAt: now)
            guard value["is_backgrounded"].bool != false else {
                foreground[id] = task
                if foreground.count > Self.foregroundLimit, let oldest = foreground.values.min(by: { $0.startedAt < $1.startedAt }) {
                    foreground[oldest.id] = nil
                }
                return false
            }
            append(task)
            return true
        case "task_updated":
            let patch = value["patch"]
            if patch["is_backgrounded"].bool == true, var task = foreground.removeValue(forKey: id) {
                if let status = Self.status(patch["status"].string) { task.status = status; task.endedAt = now }
                append(task)
                return true
            }
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                if Self.status(patch["status"].string) != nil { foreground[id] = nil }
                return false
            }
            var changed = false
            if let text = patch["description"].string.map(ClaudeSubagentTracker.line), !text.isEmpty, text != tasks[index].title {
                tasks[index].title = ClaudeSubagentTracker.clip(text, 200); changed = true
            }
            if let status = Self.status(patch["status"].string) { finish(index, status: status, now: now); changed = true }
            if let error = patch["error"].string, !error.isEmpty { tasks[index].report = ClaudeSubagentTracker.clip(error, 2000); changed = true }
            return changed
        case "task_progress":
            guard let index = tasks.firstIndex(where: { $0.id == id }),
                  let text = (value["summary"].string ?? value["description"].string).map(ClaudeSubagentTracker.line), !text.isEmpty,
                  text != tasks[index].activity, text != tasks[index].title else { return false }
            tasks[index].activity = ClaudeSubagentTracker.clip(text, 200)
            return true
        case "task_notification":
            foreground[id] = nil
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
            finish(index, status: Self.status(value["status"].string) ?? .completed, now: now)
            if let summary = value["summary"].string, !summary.isEmpty { tasks[index].report = ClaudeSubagentTracker.clip(summary, 2000) }
            return true
        default: return false
        }
    }
    /// Replaces the live set: unknown tasks join (the level may come before their `task_started`); tasks that left it ended.
    private mutating func level(_ entries: [JSONValue], now: Date) -> Bool {
        var changed = false, live: Set<String> = []
        for entry in entries {
            guard let id = entry["task_id"].string, let kind = Self.kind(entry["task_type"].string) else { continue }
            live.insert(id)
            if var task = foreground.removeValue(forKey: id) {
                task.status = .running; append(task); changed = true
            } else if !tasks.contains(where: { $0.id == id }) {
                let title = ClaudeSubagentTracker.clip(ClaudeSubagentTracker.line(entry["description"].string ?? ""), 200)
                append(.init(id: id, kind: kind, title: title.isEmpty ? id : title, parentID: entry["parent_task_id"].string, startedAt: now))
                changed = true
            }
        }
        // The CLI drops a finished task from the level after its notification; without one its outcome is unknown, so it reads as done.
        for index in tasks.indices where tasks[index].status == .running && leveled.contains(tasks[index].id) && !live.contains(tasks[index].id) {
            finish(index, status: .completed, now: now); changed = true
        }
        leveled = live
        return changed
    }
    private mutating func append(_ task: AgentBackgroundTask) {
        tasks.append(task)
        if tasks.count > Self.taskLimit, let oldest = tasks.firstIndex(where: { $0.status != .running }) { tasks.remove(at: oldest) }
    }
    private mutating func finish(_ index: Int, status: AgentSubagent.Status, now: Date) {
        tasks[index].status = status; tasks[index].activity = nil
        if tasks[index].endedAt == nil { tasks[index].endedAt = now }
    }
    /// Nil for sub-agents, which `ClaudeSubagentTracker` follows.
    static func kind(_ type: String?) -> AgentBackgroundTask.Kind? {
        switch type {
        case "local_agent": nil
        case "local_bash": .shell
        case let type? where type.hasPrefix("monitor"): .monitor
        case "local_workflow": .workflow
        case "mcp_task": .mcp
        default: .other
        }
    }
    static func status(_ raw: String?) -> AgentSubagent.Status? {
        raw == "running" || raw == "pending" ? nil : ClaudeSubagentTracker.status(raw)
    }

    /// A `get_task_output` answer as plain text: escape sequences dropped, and a line redrawn with carriage returns
    /// (progress bars) reduced to what the terminal would show last.
    static func output(_ response: JSONValue) -> AgentTaskOutput? {
        guard let raw = response["output"].string else { return nil }
        return .init(text: plain(raw), totalBytes: response["total_bytes"].int ?? raw.utf8.count, truncated: response["truncated"].bool == true)
    }
    static func plain(_ raw: String) -> String {
        // CSI sequences (colors, cursor moves), OSC sequences (titles, links) and other two-byte escapes.
        let stripped = raw.replacingOccurrences(of: #"\u001B(\[[0-?]*[ -/]*[@-~]|\][^\u0007\u001B]*(\u0007|\u001B\\)|[@-Z\\-_])"#,
                                                with: "", options: .regularExpression)
        return stripped.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "\r").last.map(String.init) ?? "" }.joined(separator: "\n")
    }
}
