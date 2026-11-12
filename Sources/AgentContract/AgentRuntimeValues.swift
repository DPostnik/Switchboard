import Foundation

public struct AgentAccountInfo: Sendable {
    public let authenticated: Bool
    public let plan: String?
    /// False when the agent offers no sign-out (an ACP agent that does not advertise `logout`); the app then hides it.
    public let canSignOut: Bool
    /// Stable across reconnects; nil when the supported account response has no nonsecret account identity.
    public let identityFingerprint: String?
    public init(authenticated: Bool, plan: String?, canSignOut: Bool = true, identityFingerprint: String? = nil) {
        self.authenticated = authenticated; self.plan = plan; self.canSignOut = canSignOut
        self.identityFingerprint = identityFingerprint
    }


}

public struct AgentModelInfo: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let defaultEffort: String
    public let efforts: [String]

    public init(id: String, displayName: String, isDefault: Bool = false, defaultEffort: String = "", efforts: [String] = []) {
        self.id = id; self.displayName = displayName; self.isDefault = isDefault
        self.defaultEffort = defaultEffort; self.efforts = efforts
    }

}

/// Sizes of an adapter's stored history before and after its tool bodies were reduced.
public struct AgentHistoryReduction: Equatable, Sendable {
    public let bytesBefore: Int
    public let bytesAfter: Int
    public init(bytesBefore: Int, bytesAfter: Int) { self.bytesBefore = bytesBefore; self.bytesAfter = bytesAfter }
}

public struct AgentHistoryTurn: Codable, Sendable {
    public let id: String?
    public let items: [TranscriptItem]
    public let isComplete: Bool
    private let startedAt: Date?
    private let completedAt: Date?
    private let duration: Double?

    public init(id: String?, items: [TranscriptItem], startedAt: Date?, completedAt: Date?, duration: Double?, isComplete: Bool = false) {
        self.id = id; self.items = items; self.startedAt = startedAt; self.completedAt = completedAt; self.duration = duration
        self.isComplete = isComplete
    }
    /// The same turn with other items; timing and completeness stay.
    public func replacingItems(_ items: [TranscriptItem]) -> Self {
        Self(id: id, items: items, startedAt: startedAt, completedAt: completedAt, duration: duration, isComplete: isComplete)
    }
    public func timing(fallback: ResponseTiming?) -> ResponseTiming? {
        guard let completedAt = completedAt ?? fallback?.completedAt else { return nil }
        return ResponseTiming(startedAt: startedAt ?? fallback?.startedAt, completedAt: completedAt,
                              durationSeconds: duration ?? fallback?.durationSeconds, tokens: fallback?.tokens,
                              changes: fallback?.changes)
    }
}
