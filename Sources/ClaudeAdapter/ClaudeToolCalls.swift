import Foundation
import AgentContract
import ContextCore

/// Claude Code tool calls, plans, commands, settings and stop reasons in the ACP-shaped model (stage C, 2026-11-02).
/// Tool inputs follow `@anthropic-ai/claude-agent-sdk@0.3.292` `sdk-tools.d.ts` (claudeCodeVersion 2.1.292): Bash
/// `command`/`description`, Read `file_path`/`offset`, Edit `file_path`/`old_string`/`new_string`/`replace_all`, Write
/// `file_path`/`content`, NotebookEdit `notebook_path`/`new_source`, Glob and Grep `pattern`/`path`, WebFetch `url`/`prompt`,
/// WebSearch `query`, Agent `description`/`subagent_type`, TodoWrite `todos[].content`/`status`/`activeForm`. MultiEdit
/// (`edits[].old_string`/`new_string`) is gone from 2.1.292 but still read from older records. Fields of frames are listed
/// in `ClaudeProtocolSurface.readFields`.
enum ClaudeToolCalls {
    static func toolCall(id: String, name: String, input: JSONValue) -> AgentToolCall {
        func string(_ key: String) -> String? { input[key].string.flatMap { $0.isEmpty ? nil : $0 } }
        let path = string("file_path") ?? string("notebook_path") ?? string("path")
        let file = path.map { [AgentToolCall.Location(path: $0)] } ?? []
        switch name {
        case "Bash", "PowerShell":
            let command = string("command") ?? ""
            return .init(id: id, kind: .execute, status: .inProgress, title: command,
                         content: [.terminal(.init(command: command))], inputSummary: string("description"))
        case "Read", "NotebookRead":
            let line = input["offset"].int.flatMap { $0 > 0 ? $0 : nil }
            return .init(id: id, kind: .read, status: .inProgress, title: ToolCallText.read(path ?? ""),
                         locations: path.map { [.init(path: $0, line: line)] } ?? [])
        case "Edit":
            guard let path else { break }
            let diff = AgentToolCall.Diff(path: path, oldText: input["old_string"].string ?? "", newText: input["new_string"].string ?? "")
            return .init(id: id, kind: .edit, status: .inProgress, title: ToolCallText.edit(path), locations: file, content: [.diff(diff)],
                         inputSummary: input["replace_all"].bool == true ? L10n.text("все вхождения", "all occurrences") : nil)
        case "MultiEdit":
            guard let path else { break }
            let diffs = input["edits"].array.map {
                AgentToolCall.Content.diff(.init(path: path, oldText: $0["old_string"].string ?? "", newText: $0["new_string"].string ?? ""))
            }
            return .init(id: id, kind: .edit, status: .inProgress, title: ToolCallText.edit(path), locations: file, content: diffs)
        case "Write", "NotebookEdit":
            guard let path else { break }
            let text = input["content"].string ?? input["new_source"].string ?? ""
            return .init(id: id, kind: .edit, status: .inProgress, title: ToolCallText.write(path), locations: file,
                         content: [.diff(.init(path: path, oldText: nil, newText: text))])
        case "Grep", "Glob":
            let summary = [string("glob"), string("type")].compactMap { $0 }.joined(separator: " ")
            return .init(id: id, kind: .search, status: .inProgress, title: ToolCallText.search(string("pattern") ?? ""), locations: file,
                         inputSummary: summary.isEmpty ? nil : summary)
        case "LS":
            return .init(id: id, kind: .search, status: .inProgress, title: ToolCallText.read(path ?? ""), locations: file)
        case "WebFetch":
            return .init(id: id, kind: .fetch, status: .inProgress, title: ToolCallText.fetch(string("url") ?? ""),
                         inputSummary: string("prompt").map { ActivityDetail.oneLine($0, limit: 200) })
        case "WebSearch":
            return .init(id: id, kind: .fetch, status: .inProgress, title: ToolCallText.webSearch(string("query") ?? ""))
        case "Agent", "Task":
            return .init(id: id, kind: .think, status: .inProgress, title: string("description") ?? name, inputSummary: string("subagent_type"))
        case "Skill":
            // `skill` is "<plugin>:<name>" for the user's skills (`ClaudeSkills`); `args` is what the skill was asked to do.
            return .init(id: id, kind: .read, status: .inProgress, title: ToolCallText.skill(ClaudeSkills.displayName(string("skill") ?? name)),
                         inputSummary: string("args").map { ActivityDetail.oneLine($0, limit: 200) })
        case "TodoWrite":
            return .init(id: id, kind: .think, status: .inProgress, title: ToolCallText.plan)
        case "EnterPlanMode", "ExitPlanMode":
            return .init(id: id, kind: .switchMode, status: .inProgress,
                         title: name == "EnterPlanMode" ? L10n.text("Режим плана", "Plan mode") : L10n.text("Выход из режима плана", "Leave plan mode"))
        default: break
        }
        // MCP tools are "mcp__<server>__<tool>".
        let parts = name.components(separatedBy: "__")
        let title = parts.count >= 3 && parts[0] == "mcp" ? parts[1] + " · " + parts[2...].joined(separator: "__") : name
        return .init(id: id, kind: .other, status: .inProgress, title: title, locations: file, inputSummary: ToolCallText.inputSummary(input))
    }

    /// TodoWrite's list as the turn's plan; nil when the input carries no list.
    static func plan(input: JSONValue) -> AgentPlan? {
        guard case .array(let todos) = input["todos"] else { return nil }
        return AgentPlan(entries: todos.compactMap { todo in
            guard let content = todo["content"].string, !content.isEmpty else { return nil }
            let status: AgentPlan.Entry.Status = switch todo["status"].string {
            case "completed": .completed
            case "in_progress": .inProgress
            default: .pending
            }
            return .init(content: content, status: status)
        })
    }

    /// `system/commands_changed` `commands[]` (`SlashCommand`: name, description, argumentHint).
    static func commands(changed frame: JSONValue) -> [AgentCommand] {
        frame["commands"].array.compactMap { command in
            guard let name = command["name"].string, !name.isEmpty else { return nil }
            return AgentCommand(name: name, description: command["description"].string ?? "", inputHint: command["argumentHint"].string)
        }
    }

    /// `system/init` `slash_commands` (names only), with the details a `commands_changed` gave for the same names.
    static func commands(initFrame frame: JSONValue, known: [String: AgentCommand]) -> [AgentCommand]? {
        guard case .array(let names) = frame["slash_commands"] else { return nil }
        return names.compactMap(\.string).filter { !$0.isEmpty }.map { known[$0] ?? AgentCommand(name: $0) }
    }

    /// Model, effort and advisor as config options; the values are the app's Claude catalog.
    static func configOptions(model: String, effort: String?, advisor: String?) -> [AgentConfigOption] {
        var models = ClaudeModel.catalog.filter { $0.isSupported() }.map { AgentConfigOption.Value(id: $0.id, name: $0.name, description: $0.reasoning.title) }
        if !model.isEmpty, !models.contains(where: { $0.id == model }) { models.insert(.init(id: model, name: ClaudeModel.title(for: model)), at: 0) }
        return [
            AgentConfigOption(id: "model", name: L10n.text("Модель", "Model"), category: .model, kind: .select(models), current: model),
            AgentConfigOption(id: "effort", name: L10n.text("Усилие", "Effort"), category: .thoughtLevel,
                              kind: .select(ClaudeEffort.allCases.map { .init(id: $0.rawValue, name: $0.title) }), current: ClaudeEffort.resolved(effort)),
            AgentConfigOption(id: "advisor", name: L10n.text("Советник", "Advisor"), category: .modelConfig,
                              kind: .select(ClaudeAdvisor.options.map { .init(id: $0.id, name: $0.name) }), current: advisor ?? "")
        ]
    }

    /// Why a `result` ended the turn: an interrupt, a usage limit, the turn limit (`error_max_turns`), the model's own
    /// `stop_reason` ("max_tokens", "refusal"), an error, else the end of the turn.
    static func stopReason(result frame: JSONValue, interrupted: Bool, usageLimit: Bool) -> AgentStopReason {
        if interrupted { return .cancelled }
        if usageLimit { return .usageLimit }
        if frame["subtype"].string == "error_max_turns" { return .maxTurnRequests }
        switch frame["stop_reason"].string {
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        default: return frame["is_error"].bool == true ? .failed : .endTurn
        }
    }
}
