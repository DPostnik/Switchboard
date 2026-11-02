import Foundation

/// Exact engine builds checked against the adapter contract; never accept a version range.
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

    static func accepts(userAgent: String) -> Bool {
        version(userAgent: userAgent).map(supportedVersions.contains) ?? false
    }
}
