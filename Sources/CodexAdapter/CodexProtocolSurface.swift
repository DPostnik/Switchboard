import Foundation
import ContextCore

/// The app-server protocol as this adapter knows it, in one place.
///
/// `notifications`, `serverRequests` and `itemTypes` list everything the verified 0.160.0 schema declares
/// (`codex app-server generate-json-schema --experimental`), handled or deliberately ignored. Anything else
/// is drift: it is still dropped as before, but counted in `CompatibilityDrift` by name only.
enum CodexProtocolSurface {
    static let notifications: Set<String> = [
        "account/gatewayOAuth/changed", "account/login/completed", "account/rateLimits/updated", "account/updated", "app/list/updated",
        "autoApprovalReview/strictReviewRequired", "command/exec/outputDelta", "configWarning", "deprecationNotice", "error",
        "externalAgentConfig/import/completed", "externalAgentConfig/import/progress", "fs/changed", "fuzzyFileSearch/sessionCompleted",
        "fuzzyFileSearch/sessionUpdated", "guardianWarning", "hook/completed", "hook/started", "item/agentMessage/delta",
        "item/autoApprovalReview/completed", "item/autoApprovalReview/started", "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction", "item/completed", "item/fileChange/outputDelta", "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress", "item/plan/delta", "item/reasoning/summaryPartAdded", "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta", "item/started", "mcpServer/event/stream/notification", "mcpServer/oauthLogin/completed",
        "mcpServer/startupStatus/updated", "model/rerouted", "model/safetyBuffering/updated", "model/verification",
        "modelProvider/authRecoveryCompleted", "modelProvider/authRecoveryStarted", "process/exited", "process/outputDelta",
        "project/changed", "remoteControl/status/changed", "serverRequest/resolved", "skills/changed", "thread/archived",
        "thread/attachment/updated", "thread/closed", "thread/compacted", "thread/deleted", "thread/environment/connected",
        "thread/environment/disconnected", "thread/goal/cleared", "thread/goal/updated", "thread/name/updated", "thread/project/updated",
        "thread/queue/changed", "thread/realtime/closed", "thread/realtime/error", "thread/realtime/item/completed",
        "thread/realtime/item/started", "thread/realtime/item/transcript/delta", "thread/realtime/itemAdded",
        "thread/realtime/outputAudio/delta", "thread/realtime/sdp", "thread/realtime/started", "thread/realtime/transcript/delta",
        "thread/realtime/transcript/done", "thread/reverted", "thread/settings/updated", "thread/started", "thread/status/changed",
        "thread/tokenUsage/updated", "thread/unarchived", "turn/completed", "turn/diff/updated", "turn/moderationMetadata",
        "turn/plan/updated", "turn/started", "warning", "windows/worldWritableWarning", "windowsSandbox/setupCompleted"
    ]
    /// Emitted by `CodexConnection` itself, never by the engine.
    static let syntheticNotifications: Set<String> = ["client/disconnected", "client/error"]
    static let serverRequests: Set<String> = [
        "account/chatgptAuthTokens/refresh", "applyPatchApproval", "attestation/generate", "currentTime/read", "execCommandApproval",
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/call",
        "item/tool/requestUserInput", "mcpServer/elicitation/request"
    ]
    static let itemTypes: Set<String> = [
        "agentMessage", "collabAgentToolCall", "commandExecution", "contextCompaction", "dynamicToolCall", "enteredReviewMode",
        "exitedReviewMode", "fileChange", "functionCallOutput", "hookPrompt", "imageGeneration", "imageView", "mcpToolCall", "plan",
        "reasoning", "sleep", "subAgentActivity", "userMessage", "webSearch"
    ]
    /// Notifications `CodexEventDecoder.notification` drops without a non-empty `threadId`.
    static let sessionBoundNotifications: Set<String> = [
        "thread/tokenUsage/updated", "turn/started", "turn/completed", "item/started", "item/completed", "item/agentMessage/delta"
    ]

    // What the adapter actually uses. CompatibilitySnapshotTests checks it against Tests/Fixtures/compat/codex-<version>.json
    // (scripts/compat-snapshot.py) for every supported version that has a snapshot; keep both lists in step with the code.

    /// Supported versions verified before snapshots existed; no binary is installed to generate them. New versions need one.
    static let versionsWithoutSnapshot: Set<String> = ["0.158.0-alpha.2.1", "0.159.0", "0.159.2"]
    /// Client requests the adapter sends (`CodexClient`, `CodexConnection`, `ArchiveSummaryRunner`).
    static let requests: Set<String> = [
        "initialize", "account/read", "account/login/start", "account/logout", "model/list", "account/rateLimits/read",
        "skills/extraRoots/set", "thread/start", "thread/resume", "turn/start", "turn/interrupt", "thread/name/set",
        "thread/archive", "thread/unarchive", "thread/delete", "thread/read", "config/read", "mcpServerStatus/list"
    ]
    /// Root -> field paths the decoders read. Roots: `response:<request>`, `notification:<method>`,
    /// `serverRequest:<method>` (params) and `item:<thread item type>`; `*` steps into a map value or array element.
    /// Not listed: `item/fileChange/requestApproval` `changes`, which 0.160.0 no longer sends (`grantRoot` is read first).
    static let reads: [String: [String]] = [
        "response:initialize": ["userAgent"],
        "response:account/read": ["account", "account.planType"],
        "response:account/login/start": ["authUrl"],
        "response:model/list": ["data.*.model", "data.*.displayName", "data.*.isDefault", "data.*.defaultReasoningEffort",
                                "data.*.supportedReasoningEfforts.*.reasoningEffort"],
        "response:account/rateLimits/read": ["rateLimitsByLimitId.*.limitName", "rateLimits.limitId", "rateLimits.limitName",
                                             "rateLimits.primary.usedPercent", "rateLimits.primary.windowDurationMins",
                                             "rateLimits.primary.resetsAt", "rateLimits.secondary", "ordinaryUsageAllowed"],
        "response:thread/start": ["thread.id", "thread.ephemeral", "thread.environments", "sandbox.type", "modelProvider", "model"],
        "response:turn/start": ["turn.id"],
        "response:thread/read": ["thread.id", "thread.turns.*.id", "thread.turns.*.status", "thread.turns.*.items",
                                 "thread.turns.*.startedAt", "thread.turns.*.completedAt", "thread.turns.*.durationMs"],
        "response:config/read": ["config", "config.mcp_servers"],
        "response:mcpServerStatus/list": ["data", "nextCursor"],
        "notification:account/login/completed": ["success", "error"],
        "notification:error": ["error.message"],
        "notification:thread/tokenUsage/updated": ["threadId", "turnId", "tokenUsage.total.inputTokens", "tokenUsage.total.cachedInputTokens",
                                                   "tokenUsage.total.outputTokens", "tokenUsage.last.totalTokens", "tokenUsage.modelContextWindow"],
        "notification:turn/started": ["threadId", "turn.id"],
        "notification:turn/completed": ["threadId", "turn.id", "turn.status", "turn.error.message", "turn.error.codexErrorInfo",
                                        "turn.startedAt", "turn.completedAt", "turn.durationMs", "turn.items"],
        "notification:item/started": ["threadId", "turnId", "item"],
        "notification:item/completed": ["threadId", "turnId", "item"],
        "notification:item/agentMessage/delta": ["threadId", "turnId", "itemId", "delta"],
        "notification:item/reasoning/summaryTextDelta": ["threadId", "turnId", "itemId", "delta", "summaryIndex"],
        "notification:item/reasoning/textDelta": ["threadId", "turnId", "itemId", "delta", "contentIndex"],
        "notification:serverRequest/resolved": ["threadId", "requestId"],
        "notification:account/updated": [], "notification:account/rateLimits/updated": [],
        "serverRequest:item/commandExecution/requestApproval": ["threadId", "turnId", "kind", "availableDecisions", "command", "reason"],
        "serverRequest:item/fileChange/requestApproval": ["threadId", "turnId", "grantRoot", "reason"],
        "serverRequest:item/permissions/requestApproval": ["threadId", "turnId", "reason", "permissions.network.enabled",
                                                           "permissions.fileSystem.read", "permissions.fileSystem.write"],
        "serverRequest:item/tool/requestUserInput": ["threadId", "turnId", "questions.*.id", "questions.*.question", "questions.*.isSecret",
                                                     "questions.*.options.*.label", "questions.*.options.*.description"],
        "serverRequest:mcpServer/elicitation/request": ["threadId", "turnId", "message", "mode", "url", "requestedSchema"],
        "item:userMessage": ["id", "content.*.type", "content.*.text"],
        "item:agentMessage": ["id", "text", "phase"],
        "item:contextCompaction": ["id"],
        "item:commandExecution": ["id", "command", "status", "aggregatedOutput", "exitCode", "durationMs"],
        "item:reasoning": ["id", "summary", "content"],
        "item:fileChange": ["id", "status", "changes.*.path"],
        "item:mcpToolCall": ["id", "server", "tool"],
        "item:webSearch": ["id", "query"]
    ]

    /// Drift in one inbound message, as (category, name). Missing-field names are `method:path`.
    /// Only fields the decoders depend on are checked; the list is short on purpose.
    static func drift(_ raw: JSONValue) -> [(CompatibilityDrift.Category, String)] {
        let method = raw["method"].string ?? "", p = raw["params"]
        if raw["id"] != .null { return serverRequests.contains(method) ? [] : [(.serverRequest, method)] }
        if syntheticNotifications.contains(method) { return [] }
        guard notifications.contains(method) else { return [(.notification, method)] }
        var found: [(CompatibilityDrift.Category, String)] = []
        func require(_ present: Bool, _ path: String) { if !present { found.append((.missingField, method + ":" + path)) } }
        if sessionBoundNotifications.contains(method) { require(!(p["threadId"].string ?? "").isEmpty, "threadId") }
        switch method {
        case "thread/tokenUsage/updated":
            for key in ["inputTokens", "cachedInputTokens", "outputTokens"] { require(p["tokenUsage"]["total"][key].int != nil, "tokenUsage.total." + key) }
        case "turn/started":
            require(p["turn"]["id"].string != nil, "turn.id")
        case "turn/completed":
            require(p["turn"]["id"].string != nil, "turn.id")
            require(p["turn"]["status"].string != nil, "turn.status")
        case "item/started", "item/completed":
            require(p["item"]["id"].string != nil, "item.id")
            if let type = p["item"]["type"].string {
                if !itemTypes.contains(type) { found.append((.itemType, type)) }
            } else { require(false, "item.type") }
        case "item/agentMessage/delta":
            require(p["itemId"].string != nil, "itemId")
        default: break
        }
        return found
    }

    /// Counts drift of one inbound message against the engine version from `initialize`.
    static func record(_ raw: JSONValue, userAgent: String?, into drift: CompatibilityDrift = .shared) {
        let found = Self.drift(raw)
        guard !found.isEmpty else { return }
        let version = userAgent.flatMap(CodexProtocolCompatibility.version(userAgent:))
        for (category, name) in found { drift.record(.codex, version: version, category, name) }
    }
}
