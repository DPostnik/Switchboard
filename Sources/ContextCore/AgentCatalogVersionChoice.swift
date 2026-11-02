import Foundation
import AgentContract

/// Which version of a catalog agent to install when its adapter is verified on exact builds (`AgentVersionPolicy`).
public struct AgentCatalogVersionChoice: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The adapter has no version list; the catalog's version as is.
        case unconstrained
        case verified
        /// Same major.minor as the verified `nearest`: connects with a warning.
        case unverified(nearest: String)
        /// The catalog's version would be rejected; the newest verified one is installed instead (npm only).
        case catalogRejected(catalog: String)
    }
    public let version: String
    public let reason: Reason

    public init(version: String, reason: Reason) { self.version = version; self.reason = reason }

    /// Nil when the catalog's version is rejected and the distribution cannot install another one (a binary).
    public static func choose(for entry: AgentCatalogEntry, verified: [String]) -> AgentCatalogVersionChoice? {
        guard !verified.isEmpty else { return .init(version: entry.version, reason: .unconstrained) }
        switch AgentVersionPolicy.evaluate(entry.version, verified: verified) {
        case .verified: return .init(version: entry.version, reason: .verified)
        case .sameMinor(let nearest): return .init(version: entry.version, reason: .unverified(nearest: nearest))
        case .rejected:
            guard case .npx = entry.installable,
                  let newest = verified.filter(AgentCatalogParser.isSafeVersion).max(by: { AgentCatalogVersion.isNewer($1, than: $0) }) else { return nil }
            return .init(version: newest, reason: .catalogRejected(catalog: entry.version))
        }
    }

    /// Whether `version` may be offered as an update for an adapter verified on `verified`.
    public static func isAcceptable(_ version: String, verified: [String]) -> Bool {
        verified.isEmpty || AgentVersionPolicy.evaluate(version, verified: verified) != .rejected
    }

    /// One line for the UI; nil for a plain verified or unconstrained install.
    public var note: String? {
        switch reason {
        case .unconstrained, .verified: nil
        case .unverified(let nearest):
            L10n.text("Версия \(version) из каталога ещё не проверена (проверена \(nearest)): подключится с предупреждением.",
                      "Catalog version \(version) is not verified yet (verified: \(nearest)): it connects with a warning.")
        case .catalogRejected(let catalog):
            L10n.text("В каталоге версия \(catalog), но она вне проверенной ветки; установлена проверенная \(version).",
                      "The catalog lists \(catalog), which is outside the verified branch; installed the verified \(version) instead.")
        }
    }
}
