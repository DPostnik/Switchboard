import Foundation
import CryptoKit

/// Read-only admission evidence for scheduled work. Never enables paid overage or predicts refreshed quota.
public enum ScheduledLimitPolicy {
    public enum Provider: Sendable { case codex, claude }
    public enum Decision: Equatable, Sendable {
        case allowed
        case wait(until: Date?)
        case unknown
    }

    public static func evaluate(_ limits: AccountLimits?, provider: Provider, model: String?, now: Date,
                                maximumAge: TimeInterval = 300) -> Decision {
        guard let limits, maximumAge.isFinite, maximumAge >= 0,
              limits.fetchedAt <= now, now.timeIntervalSince(limits.fetchedAt) <= maximumAge else { return .unknown }
        let selected = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let windows = limits.buckets.filter { bucket in
            let id = bucket.id.lowercased()
            switch provider {
            case .codex:
                return id == "codex" || (!selected.isEmpty && id == selected)
            case .claude:
                if id == "all" { return true }
                if id == "sonnet" || id == "opus" { return selected.contains(id) }
                // Provider display names are not a reliable mapping to model IDs. Exact matches are safe;
                // unknown scopes must not block every other model on the account.
                return id.hasPrefix("model:") && !selected.isEmpty && bucket.name.lowercased() == selected
            }
        }.flatMap(\.windows)
        let exhausted = windows.filter { ($0.remainingPercent ?? 1) <= 0 }
        if !exhausted.isEmpty {
            let resets = exhausted.compactMap(\.resetsAt)
            guard resets.allSatisfy({ $0 > now }) else { return .unknown }
            return .wait(until: resets.count == exhausted.count ? resets.max() : nil)
        }
        // A denied ordinary allowance can never be overridden by a positive window or paid credits.
        if case .codex = provider, limits.ordinaryUsageAllowed == false { return .wait(until: nil) }
        // An unresolved provider default might select a family with a separate quota.
        if case .claude = provider, selected.isEmpty,
           limits.buckets.contains(where: { $0.id == "sonnet" || $0.id == "opus" || $0.id.hasPrefix("model:") }) {
            return .unknown
        }
        guard windows.allSatisfy({ window in
            guard let remaining = window.remainingPercent, (1...100).contains(remaining) else { return false }
            return window.resetsAt.map { $0 > now } ?? true
        }) else { return .unknown }
        if !windows.isEmpty { return .allowed }
        if case .codex = provider, limits.ordinaryUsageAllowed == true { return .allowed }
        return .unknown
    }
}

public enum ScheduledAccountIdentity {
    /// Hash only supported account metadata, never tokens, API keys or credential files.
    public static func fingerprint(provider: String, accountType: String, accountID: String?, organizationID: String? = nil) -> String? {
        let fields = [provider, accountType, accountID ?? "", organizationID ?? ""].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard fields.prefix(3).allSatisfy({ !$0.isEmpty }), let data = try? JSONEncoder().encode(fields) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
