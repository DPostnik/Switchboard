import Foundation
import AgentContract
import ContextCore

/// Context size around a Codex compaction. In Codex 0.160.0 the `contextCompaction` item carries only its id
/// (`{ "type": "contextCompaction", id }`) and the deprecated `thread/compacted` notification only thread and turn, so the
/// size before is the thread's last reported context (`tokenUsage.last.totalTokens`, as `UsageSnapshot.last`) and the size
/// after is the first smaller report once the compaction started. Codex does not say what triggered it.
struct CodexCompactionMeter {
    /// Last reported context size per thread.
    private var context: [String: Int] = [:]
    /// Latest compaction item per thread; its started and completed events (and any repeat) share the sizes.
    private var latest: [String: TranscriptItem] = [:]

    /// The event with the compaction sizes attached, plus the completed compaction item again once a usage report
    /// supplies its size after.
    mutating func observe(_ event: AgentEvent) -> [AgentEvent] {
        guard let thread = event.session?.nativeID else { return [event] }
        switch event.payload {
        case .usage(_, _, let snapshot):
            guard let size = snapshot.last else { return [event] }
            context[thread] = size
            // Without a size before, a report could not be told apart from the context before compaction.
            guard var item = latest[thread], item.compaction?.after == nil, let before = item.compaction?.before,
                  size < before else { return [event] }
            item.compaction?.after = size
            latest[thread] = item
            return item.phase == "completed" ? [event, AgentEvent(session: event.session, payload: .item(item))] : [event]
        case .item(var item) where item.kind == "compaction":
            if let known = latest[thread], known.id == item.id { item.compaction = known.compaction }
            else { item.compaction = context[thread].map { ContextCompaction(before: $0) } }
            latest[thread] = item
            return [AgentEvent(session: event.session, payload: .item(item))]
        default:
            return [event]
        }
    }
}
