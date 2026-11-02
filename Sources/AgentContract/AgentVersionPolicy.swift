import Foundation

/// Which agent CLI versions an adapter connects to (user decision 2026-11-02).
///
/// An exact verified version connects normally. A version on the same major.minor branch as a verified one
/// (for example Codex 0.160.x or Claude Code 2.1.x) connects as unverified: the app shows a warning and the
/// adapter's drift diagnostics stay on. Anything else, including malformed versions, is rejected.
/// Package dependencies are not covered by this policy and stay exactly pinned.
public enum AgentVersionPolicy {
    public enum Verdict: Equatable, Sendable {
        case verified
        /// Same major.minor as `nearest`, the newest verified version on that branch.
        case sameMinor(nearest: String)
        case rejected
    }

    public static func evaluate(_ version: String, verified: [String]) -> Verdict {
        if verified.contains(version) { return .verified }
        guard let own = branch(version) else { return .rejected }
        let candidates = verified.filter { branch($0)?.major == own.major && branch($0)?.minor == own.minor }
        guard let nearest = candidates.max(by: { (branch($0)?.patch ?? 0, $0) < (branch($1)?.patch ?? 0, $1) }) else { return .rejected }
        return .sameMinor(nearest: nearest)
    }

    /// `MAJOR.MINOR.PATCH` with an optional `-prerelease` suffix; numeric parts without leading zeros.
    static func branch(_ version: String) -> (major: Int, minor: Int, patch: Int)? {
        let core = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if core.count == 2 {
            let suffix = core[1]
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { return nil }
        }
        let parts = core[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), part == "0" || !part.hasPrefix("0"),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return (numbers[0], numbers[1], numbers[2])
    }
}

/// The engine build behind a connection, as the adapter identified it.
public struct AgentEngineVersion: Hashable, Sendable {
    public let version: String
    /// False for a same-branch version the adapter was not verified on.
    public let verified: Bool
    /// The verified version the app compares an unverified one with.
    public let nearestVerified: String?
    public init(version: String, verified: Bool, nearestVerified: String? = nil) {
        self.version = version; self.verified = verified; self.nearestVerified = nearestVerified
    }
}
