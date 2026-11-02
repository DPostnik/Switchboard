import Foundation
import AgentContract
import ContextCore

/// Codex 0.160.0 `ThreadItem` calls as `AgentToolCall` (stage C, 2026-11-02). Every field read here is declared in
/// `CodexProtocolSurface.reads` and resolves in `Tests/Fixtures/compat/codex-0.160.0.json`. Values (schema enums):
/// `CommandExecutionStatus` and `PatchApplyStatus` inProgress, completed, failed, declined; `McpToolCallStatus` and
/// `DynamicToolCallStatus` inProgress, completed, failed; `CommandAction.type` read, listFiles, search, unknown;
/// `PatchChangeKind.type` add, delete, update (with `move_path`); `WebSearchAction.type` search, openPage, findInPage, other.
enum CodexToolCalls {
    static func status(_ raw: String?) -> AgentToolCall.Status {
        switch raw {
        case "completed": .completed
        case "failed": .failed
        case "declined": .rejected
        default: .inProgress
        }
    }

    static func toolCall(_ raw: JSONValue) -> AgentToolCall? {
        guard let id = raw["id"].string else { return nil }
        switch raw["type"].string {
        case "commandExecution": return command(raw, id: id)
        case "fileChange": return fileChange(raw, id: id)
        case "mcpToolCall":
            let tool = raw["tool"].string ?? "", server = raw["server"].string ?? ""
            var content: [AgentToolCall.Content] = []
            if let message = raw["error"]["message"].string, !message.isEmpty { content.append(.text(message)) }
            let output = raw["result"]["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
            if !output.isEmpty { content.append(.text(output)) }
            return AgentToolCall(id: id, kind: .other, status: status(raw["status"].string),
                                 title: server.isEmpty ? tool : server + " · " + tool, content: content,
                                 inputSummary: ToolCallText.inputSummary(raw["arguments"]))
        case "webSearch":
            let action = raw["action"]
            let query = raw["query"].string ?? action["query"].string ?? action["queries"].array.compactMap(\.string).first ?? ""
            let title: String
            switch action["type"].string {
            case "openPage", "findInPage": title = ToolCallText.fetch(action["url"].string ?? query)
            default: title = ToolCallText.webSearch(query)
            }
            return AgentToolCall(id: id, kind: .fetch, status: .completed, title: title,
                                 inputSummary: action["pattern"].string.map { L10n.text("на странице: \($0)", "in page: \($0)") })
        case "dynamicToolCall":
            let tool = raw["tool"].string ?? "", namespace = raw["namespace"].string
            var call = AgentToolCall(id: id, kind: .other, status: status(raw["status"].string),
                                     title: namespace.map { $0 + " · " + tool } ?? tool, inputSummary: ToolCallText.inputSummary(raw["arguments"]))
            if raw["success"].bool == false, call.status == .completed { call.status = .failed }
            return call
        case "imageView":
            let path = raw["path"].string ?? ""
            return AgentToolCall(id: id, kind: .read, status: .completed, title: ToolCallText.read(path),
                                 locations: path.isEmpty ? [] : [.init(path: path)])
        default: return nil
        }
    }

    /// A command reads or searches when Codex parsed all of its parts as such (`commandActions`); otherwise it executes.
    private static func command(_ raw: JSONValue, id: String) -> AgentToolCall {
        let command = raw["command"].string ?? ""
        let actions = raw["commandActions"].array
        let types = actions.compactMap { $0["type"].string }
        let kind: AgentToolCall.Kind
        if !types.isEmpty, types.allSatisfy({ $0 == "read" }) { kind = .read }
        else if !types.isEmpty, types.allSatisfy({ $0 == "search" || $0 == "listFiles" }) { kind = .search }
        else { kind = .execute }
        var locations: [AgentToolCall.Location] = []
        if kind != .execute {
            for path in actions.compactMap({ $0["path"].string }) where !path.isEmpty && !locations.contains(where: { $0.path == path }) {
                locations.append(.init(path: absolute(path, cwd: raw["cwd"].string)))
            }
        }
        let query = kind == .search ? actions.compactMap({ $0["query"].string }).first : nil
        return AgentToolCall(id: id, kind: kind, status: status(raw["status"].string), title: command, locations: locations,
                             content: [.terminal(.init(command: command, exitCode: raw["exitCode"].int))], inputSummary: query)
    }

    private static func absolute(_ path: String, cwd: String?) -> String {
        guard !path.hasPrefix("/"), let cwd, cwd.hasPrefix("/") else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    /// One entry per change: an added file is all new text, a deleted one all old text, an update its hunks.
    private static func fileChange(_ raw: JSONValue, id: String) -> AgentToolCall {
        var content: [AgentToolCall.Content] = [], locations: [AgentToolCall.Location] = [], titles: [String] = []
        var kinds = Set<AgentToolCall.Kind>()
        for change in raw["changes"].array {
            guard let path = change["path"].string else { continue }
            let diff = change["diff"].string ?? ""
            switch change["kind"]["type"].string {
            case "add":
                kinds.insert(.edit); titles.append(ToolCallText.create(path))
                // An added file's `diff` is its content; a unified diff of it is read as hunks too.
                let entries = AgentToolCall.Diff.hunks(unifiedDiff: diff, path: path) ?? [.init(path: path, oldText: nil, newText: diff, line: 1)]
                content += entries.map { .diff(.init(path: path, oldText: nil, newText: $0.newText, line: $0.line)) }
                locations.append(.init(path: path))
            case "delete":
                kinds.insert(.delete); titles.append(ToolCallText.delete(path))
                let entries = AgentToolCall.Diff.hunks(unifiedDiff: diff, path: path) ?? [.init(path: path, oldText: diff, newText: "")]
                content += entries.map { .diff(.init(path: path, oldText: $0.oldText, newText: "")) }
                locations.append(.init(path: path))
            default:
                let target = change["kind"]["move_path"].string
                if let target, target != path { kinds.insert(.move); titles.append(ToolCallText.move(path, to: target)) }
                else { kinds.insert(.edit); titles.append(ToolCallText.edit(path)) }
                let hunks = AgentToolCall.Diff.hunks(unifiedDiff: diff, path: target ?? path) ?? []
                content += hunks.map { .diff($0) }
                locations.append(.init(path: target ?? path, line: hunks.first?.line))
            }
        }
        let kind: AgentToolCall.Kind = kinds.count == 1 ? kinds.first! : .edit
        let title = titles.count == 1 ? titles[0] : ToolCallText.files(titles.count)
        return AgentToolCall(id: id, kind: kind, status: status(raw["status"].string), title: title, locations: locations, content: content)
    }

    /// `turn/plan/updated`: the whole plan; `TurnPlanStepStatus` is pending, inProgress or completed.
    static func plan(_ params: JSONValue) -> AgentPlan {
        let entries = params["plan"].array.compactMap { step -> AgentPlan.Entry? in
            guard let text = step["step"].string else { return nil }
            let status: AgentPlan.Entry.Status = switch step["status"].string {
            case "completed": .completed
            case "inProgress": .inProgress
            default: .pending
            }
            return AgentPlan.Entry(content: text, status: status)
        }
        let explanation = params["explanation"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentPlan(entries: entries, explanation: explanation?.isEmpty == false ? explanation : nil)
    }
}
