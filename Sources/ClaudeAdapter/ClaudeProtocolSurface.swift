import Foundation
import ContextCore

/// The stream-json protocol of the pinned Claude Code as this adapter knows it, in one place.
///
/// Frame types, system subtypes and control subtypes come from `@anthropic-ai/claude-agent-sdk@0.3.292`
/// (`claudeCodeVersion` 2.1.292), `sdk.d.ts` `StdoutMessage`; stream events are the Messages API
/// `BetaRawMessageStreamEvent` types. `undocumented` lists frames the CLI sends that the SDK types omit.
/// Anything else is drift: it is still ignored (or, for control requests, still closes the process) as
/// before, but counted in `CompatibilityDrift` by name only.
enum ClaudeProtocolSurface {
    static let frameTypes: Set<String> = [
        "active_goal", "assistant", "auth_status", "control_cancel_request", "control_request", "control_response",
        "conversation_reset", "keep_alive", "prompt_suggestion", "rate_limit_event", "result", "stream_event", "system",
        "tool_progress", "tool_use_summary", "user"
    ]
    static let systemSubtypes: Set<String> = [
        "api_retry", "background_tasks_changed", "commands_changed", "compact_boundary", "control_request_progress",
        "elicitation_complete", "files_persisted", "hook_progress", "hook_response", "hook_started", "informational", "init",
        "local_command_output", "memory_recall", "mirror_error", "model_refusal_fallback", "model_refusal_no_fallback",
        "notification", "permission_denied", "plugin_install", "session_state_changed", "status", "task_notification",
        "task_progress", "task_started", "task_updated", "thinking_tokens", "worker_shutting_down"
    ]
    static let streamEvents: Set<String> = [
        "content_block_delta", "content_block_start", "content_block_stop", "message_delta", "message_start", "message_stop"
    ]
    /// Sent by 2.1.292 but absent from the SDK types: `command_lifecycle` (seen in real sessions, read for queued
    /// turns) and `system/ui_invalidate` (sent right after `initialize`, verified 2026-11-02).
    static let undocumentedFrameTypes: Set<String> = ["command_lifecycle"]
    static let undocumentedSystemSubtypes: Set<String> = ["ui_invalidate"]
    /// Emitted by `ClaudeWire` itself when the stream ends.
    static let syntheticFrameTypes: Set<String> = ["transport_closed"]
    /// CLI-to-app control requests that obtain an answer; every other subtype closes the process.
    static let answeredControlRequests: Set<String> = ["can_use_tool", "hook_callback"]

    /// Drift in one frame, as (category, name). Missing-field names are `frame:path`.
    /// Only fields the decoders depend on are checked; the list is short on purpose.
    static func drift(_ frame: JSONValue) -> [(CompatibilityDrift.Category, String)] {
        let type = frame["type"].string ?? ""
        if syntheticFrameTypes.contains(type) || undocumentedFrameTypes.contains(type) { return [] }
        guard frameTypes.contains(type) else { return [(.frameType, type)] }
        var found: [(CompatibilityDrift.Category, String)] = []
        func require(_ present: Bool, _ path: String) { if !present { found.append((.missingField, path)) } }
        let main = frame["parent_tool_use_id"].string == nil
        switch type {
        case "system":
            let subtype = frame["subtype"].string ?? ""
            if !systemSubtypes.contains(subtype) && !undocumentedSystemSubtypes.contains(subtype) { found.append((.systemSubtype, subtype)) }
            if subtype == "compact_boundary" { require(frame["compact_metadata"]["pre_tokens"].int != nil, "compact_boundary:compact_metadata.pre_tokens") }
        case "stream_event":
            let event = frame["event"], name = event["type"].string ?? ""
            if !streamEvents.contains(name) { found.append((.streamEvent, name)) }
            if name == "message_start", main {
                require(event["message"]["id"].string != nil, "message_start:message.id")
                require(event["message"]["usage"]["input_tokens"].int != nil, "message_start:message.usage.input_tokens")
            }
        case "assistant":
            if main { require(frame["message"]["id"].string != nil, "assistant:message.id") }
        case "result":
            require(frame["is_error"].bool != nil, "result:is_error")
            require(frame["usage"]["input_tokens"].int != nil, "result:usage.input_tokens")
        case "control_request":
            let subtype = frame["request"]["subtype"].string ?? ""
            if !answeredControlRequests.contains(subtype) { found.append((.controlRequest, subtype)) }
        default: break
        }
        return found
    }

    /// The version printed by `claude --version` ("2.1.292 (Claude Code)"), or nil for any other shape.
    static func version(fromVersionOutput output: String) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(" (Claude Code)") else { return nil }
        let version = String(text.dropLast(" (Claude Code)".count))
        return version.isEmpty || version.contains(" ") ? nil : version
    }

    static func record(_ frame: JSONValue, version: String?, into drift: CompatibilityDrift = .shared) {
        for (category, name) in Self.drift(frame) { drift.record(.claudeCode, version: version, category, name) }
    }
}
