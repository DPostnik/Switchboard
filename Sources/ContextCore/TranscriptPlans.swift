import Foundation
import AgentContract

/// Plan checklists in stored transcripts (ACP-shaped model, stage C, 2026-11-02). Engines do not return plans with
/// their history (Codex `thread/read` has no plan updates, Claude's session record keeps only items it emitted), so the
/// app keeps each turn's latest plan in its own stored transcript and puts it back when the history is read again.
extension AgentPlan {
    /// Copies plan items of `stored` into the turns that lack them. A plan goes right after the item it followed in
    /// `stored` (same turn), else after the turn's first item; plans of turns no longer in the history are dropped.
    public static func carry(from stored: [TranscriptItem], into turns: [AgentHistoryTurn]) -> [AgentHistoryTurn] {
        let plans = stored.filter { $0.kind == itemKind && $0.plan != nil && $0.turnID != nil }
        guard !plans.isEmpty else { return turns }
        let byTurn = Dictionary(grouping: stored.filter { $0.turnID != nil }, by: { $0.turnID! })
        return turns.map { turn in
            guard let id = turn.id, let mine = byTurn[id], mine.contains(where: { $0.kind == itemKind && $0.plan != nil }) else { return turn }
            var items = turn.items
            guard insert(plansOf: mine, into: &items) else { return turn }
            return turn.replacingItems(items)
        }
    }

    /// The same for a flat item list whose items carry their turn ids.
    @discardableResult
    public static func carry(from stored: [TranscriptItem], into items: inout [TranscriptItem]) -> Bool {
        let turnsWithPlans = Set(stored.compactMap { $0.kind == itemKind && $0.plan != nil ? $0.turnID : nil })
        guard !turnsWithPlans.isEmpty else { return false }
        var changed = false
        for turn in turnsWithPlans {
            let indices = items.indices.filter { items[$0].turnID == turn }
            guard let first = indices.first, let last = indices.last else { continue }
            var slice = Array(items[first...last])
            if insert(plansOf: stored.filter { $0.turnID == turn }, into: &slice) {
                items.replaceSubrange(first...last, with: slice); changed = true
            }
        }
        return changed
    }

    /// Inserts the plan items of one turn's stored items into that turn's current items. Returns whether it did.
    private static func insert(plansOf stored: [TranscriptItem], into items: inout [TranscriptItem]) -> Bool {
        guard !items.isEmpty else { return false }
        var changed = false
        for (index, plan) in stored.enumerated() where plan.kind == itemKind && plan.plan != nil {
            guard !items.contains(where: { $0.id == plan.id }) else { continue }
            var position = 1
            for earlier in stored[..<index].reversed() {
                if let found = items.firstIndex(where: { $0.id == earlier.id }) { position = found + 1; break }
            }
            items.insert(plan, at: min(position, items.count)); changed = true
        }
        return changed
    }

    /// Done and total entries, for the checklist header.
    public var progress: (done: Int, total: Int) { (entries.filter { $0.status == .completed }.count, entries.count) }
}
