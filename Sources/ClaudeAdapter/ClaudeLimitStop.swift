import Foundation
import ContextCore

/// Watches one turn's stream-json messages for a stop on an exhausted plan limit (Claude Code 2.1.292).
///
/// Evidence: the CLI schema declares `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"|"allowed_warning"|"rejected",
/// "resetsAt":<Unix seconds>,"rateLimitType":"five_hour"|...}}`, and a 429 on the plan limit ends with an API-error
/// assistant message carrying top-level `"error":"rate_limit"` ("You've hit your limit · resets …"). Either signal marks
/// the stop; only the event carries a machine-readable reset time.
struct ClaudeLimitStop {
    private(set) var rejected = false
    private(set) var resetsAt: Date?

    mutating func observe(_ value: JSONValue) {
        switch value["type"].string {
        case "rate_limit_event":
            let info = value["rate_limit_info"]
            // A later "allowed" (for example, extra usage taking over) clears the stop.
            guard info["status"].string == "rejected" else {
                if info["status"].string == "allowed" { rejected = false; resetsAt = nil }
                return
            }
            rejected = true
            if let seconds = info["resetsAt"].int, seconds > 0 { resetsAt = Date(timeIntervalSince1970: Double(seconds)) }
        case "assistant":
            if value["parent_tool_use_id"].string == nil, value["error"].string == "rate_limit" { rejected = true }
        default: break
        }
    }

    /// The stop for a turn that ended with this outcome; only a failed turn stopped on the limit.
    func stop(outcome: AgentExecutionOutcome) -> AgentUsageLimitStop? {
        guard rejected, outcome == .failed else { return nil }
        return AgentUsageLimitStop(resetsAt: resetsAt)
    }
}
