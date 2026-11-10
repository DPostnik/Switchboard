import Foundation
import AgentContract
import ContextCore


extension ActivityDetail {
    /// Outcome fields of a Claude tool result, in the neutral form the transcript reads. Only shell calls get them: an
    /// error result is its leading exit code, or a failure without one (tool error, denied or interrupted); a clean
    /// result is exit 0. A backgrounded command has not finished when its result arrives, so it only records an error.
    public static func claudeOutcome(call: TranscriptItem?, result text: String, isError: Bool) -> (exitCode: Int?, failed: Bool?) {
        guard let call, isShellCall(call) else { return (nil, nil) }
        let background = ActivityRetention.parsedCall(call.text)?.input["run_in_background"] as? Bool == true
        if background { return (nil, isError ? true : nil) }
        if let code = leadingExitCode(text) { return (code, nil) }
        return isError ? (nil, true) : (0, nil)
    }
}
