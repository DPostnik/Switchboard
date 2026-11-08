import Foundation
import AgentContract

/// Engine builds checked against the adapter contract, and the connection policy for others
/// (`AgentVersionPolicy`, user decision 2026-11-02): an exact verified build connects normally; a build on the
/// same major.minor branch (for example 0.160.x) connects as unverified, with a warning in the app and drift
/// diagnostics; any other version is rejected before anything is dispatched.
enum CodexProtocolCompatibility {
    static let currentVersion = "0.160.0"
    static let supportedVersions = ["0.158.0-alpha.2.1", "0.159.0", "0.159.2", currentVersion]

    /// The engine version from `initialize`'s `userAgent`: the first product token's version.
    static func version(userAgent: String) -> String? {
        // initialize identifies the client first, then the engine version. Ignore later
        // platform/client metadata so it cannot accidentally satisfy the version gate.
        guard let product = userAgent.split(separator: " ").first,
              let separator = product.firstIndex(of: "/"), separator != product.startIndex else { return nil }
        let version = String(product[product.index(after: separator)...])
        return version.isEmpty ? nil : version
    }

    static func verdict(userAgent: String) -> AgentVersionPolicy.Verdict {
        version(userAgent: userAgent).map { AgentVersionPolicy.evaluate($0, verified: supportedVersions) } ?? .rejected
    }

    static func accepts(userAgent: String) -> Bool { verdict(userAgent: userAgent) != .rejected }

    /// The engine as the descriptor reports it; nil when the version is rejected.
    static func engine(userAgent: String, verifiedInstall: String? = nil) -> AgentEngineVersion? {
        guard let version = version(userAgent: userAgent) else { return nil }
        if version == verifiedInstall { return AgentEngineVersion(version: version, verified: true) }
        switch AgentVersionPolicy.evaluate(version, verified: supportedVersions) {
        case .verified: return AgentEngineVersion(version: version, verified: true)
        case .sameMinor(let nearest): return AgentEngineVersion(version: version, verified: false, nearestVerified: nearest)
        case .rejected: return nil
        }
    }
}
