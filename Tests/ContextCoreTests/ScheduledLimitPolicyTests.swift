import Foundation
import Testing
@testable import ContextCore
@testable import CodexAdapter

private let scheduledLimitNow = Date(timeIntervalSince1970: 1_800_000_000)

private func scheduledBucket(_ id: String, remaining: Int?, reset: TimeInterval? = 60) -> LimitBucket {
    .init(id: id, name: id, windows: [.init(id: "primary", remainingPercent: remaining, durationMinutes: 300,
                                         resetsAt: reset.map { scheduledLimitNow.addingTimeInterval($0) })])
}

private func scheduledDecision(_ buckets: [LimitBucket], provider: ScheduledLimitPolicy.Provider = .claude,
                               model: String? = "claude-sonnet-4-6", allowed: Bool? = nil,
                               age: TimeInterval = 0) -> ScheduledLimitPolicy.Decision {
    ScheduledLimitPolicy.evaluate(.init(buckets: buckets, ordinaryUsageAllowed: allowed,
                                       fetchedAt: scheduledLimitNow.addingTimeInterval(-age)),
                                  provider: provider, model: model, now: scheduledLimitNow)
}

@Test func scheduledLimitsRequireFreshEvidence() {
    #expect(ScheduledLimitPolicy.evaluate(nil, provider: .codex, model: nil, now: scheduledLimitNow) == .unknown)
    #expect(scheduledDecision([scheduledBucket("all", remaining: 90)], age: 301) == .unknown)
    #expect(scheduledDecision([scheduledBucket("all", remaining: 90)], age: -1) == .unknown)
    #expect(scheduledDecision([scheduledBucket("all", remaining: 90)], age: 300) == .allowed)
    #expect(scheduledDecision([]) == .unknown)
    #expect(scheduledDecision([scheduledBucket("all", remaining: nil)]) == .unknown)
}

@Test func scheduledClaudeLimitsApplyOnlyToSelectedModel() {
    let buckets = [scheduledBucket("all", remaining: 50), scheduledBucket("sonnet", remaining: 0),
                   scheduledBucket("opus", remaining: 80)]
    #expect(scheduledDecision(buckets) == .wait(until: scheduledLimitNow.addingTimeInterval(60)))
    #expect(scheduledDecision(buckets, model: "claude-opus-4-6") == .allowed)
    #expect(scheduledDecision(buckets, model: "claude-haiku-4-5") == .allowed)
    #expect(scheduledDecision(buckets, model: nil) == .unknown)
    #expect(scheduledDecision(buckets, model: "") == .unknown)
    #expect(scheduledDecision([scheduledBucket("all", remaining: 0), scheduledBucket("sonnet", remaining: 0)], model: nil) ==
            .wait(until: scheduledLimitNow.addingTimeInterval(60)))
    #expect(scheduledDecision([scheduledBucket("all", remaining: 0)], model: "claude-opus-4-6") ==
            .wait(until: scheduledLimitNow.addingTimeInterval(60)))
}

@Test func scheduledLimitsWaitForAllApplicableResets() {
    #expect(scheduledDecision([scheduledBucket("all", remaining: 0, reset: 120),
                               scheduledBucket("sonnet", remaining: 0, reset: 300)]) ==
            .wait(until: scheduledLimitNow.addingTimeInterval(300)))
    #expect(scheduledDecision([scheduledBucket("all", remaining: 0, reset: nil)]) == .wait(until: nil))
    #expect(scheduledDecision([scheduledBucket("all", remaining: 0, reset: -1)]) == .unknown)
    #expect(scheduledDecision([scheduledBucket("all", remaining: 20, reset: 0)]) == .unknown)
}

@Test func scheduledUnknownScopesDoNotBlockUnrelatedModels() {
    let unrelated = scheduledBucket("model:0:Future Model", remaining: 0)
    #expect(scheduledDecision([scheduledBucket("all", remaining: 30), unrelated,
                               scheduledBucket("oauth_apps", remaining: 0)]) == .allowed)
    let exact = LimitBucket(id: "model:0:future", name: "future", windows: unrelated.windows)
    #expect(scheduledDecision([exact], model: "future") == .wait(until: scheduledLimitNow.addingTimeInterval(60)))
    #expect(scheduledDecision([unrelated]) == .unknown)
}

@Test func scheduledCodexNeverOverridesDeniedOrdinaryUsage() {
    #expect(scheduledDecision([scheduledBucket("codex", remaining: 80)], provider: .codex, allowed: false) == .wait(until: nil))
    #expect(scheduledDecision([], provider: .codex, allowed: true) == .allowed)
    #expect(scheduledDecision([], provider: .codex, allowed: false) == .wait(until: nil))
    #expect(scheduledDecision([scheduledBucket("codex", remaining: 0)], provider: .codex, allowed: true) ==
            .wait(until: scheduledLimitNow.addingTimeInterval(60)))
    #expect(scheduledDecision([scheduledBucket("codex", remaining: 70), scheduledBucket("other-model", remaining: 0)],
                              provider: .codex) == .allowed)
}

@Test func scheduledIdentityFingerprintIsStableAndScoped() throws {
    let base = ScheduledAccountIdentity.fingerprint(provider: "claude-code:firstParty", accountType: "oauth_token",
                                            accountID: "person@example.com", organizationID: "org-a")
    #expect(base?.count == 64)
    #expect(base == ScheduledAccountIdentity.fingerprint(provider: "claude-code:firstParty", accountType: "oauth_token",
                                                 accountID: "person@example.com", organizationID: "org-a"))
    #expect(base != ScheduledAccountIdentity.fingerprint(provider: "claude-code:firstParty", accountType: "oauth_token",
                                                 accountID: "person@example.com", organizationID: "org-b"))
    #expect(base != ScheduledAccountIdentity.fingerprint(provider: "codex", accountType: "oauth_token",
                                                 accountID: "person@example.com", organizationID: "org-a"))
    #expect(ScheduledAccountIdentity.fingerprint(provider: "codex", accountType: "chatgpt", accountID: nil) == nil)
    #expect(ScheduledAccountIdentity.fingerprint(provider: "codex", accountType: "chatgpt", accountID: " \n ") == nil)
    #expect(ScheduledAccountIdentity.fingerprint(provider: "codex", accountType: "", accountID: "person@example.com") == nil)
    #expect(AgentAccountInfo(authenticated: true, plan: nil).identityFingerprint == nil)
}

@Test func scheduledCodexAccountDecodeUsesOnlySupportedIdentity() throws {
    func decode(_ text: String) throws -> AgentAccountInfo {
        CodexClient.decodeAccount(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
    }
    let first = try decode(#"{"account":{"type":"chatgpt","email":"one@example.com","planType":"plus"}}"#)
    let upgraded = try decode(#"{"account":{"type":"chatgpt","email":"one@example.com","planType":"pro"}}"#)
    let other = try decode(#"{"account":{"type":"chatgpt","email":"two@example.com","planType":"plus"}}"#)
    #expect(first.authenticated)
    #expect(first.plan == "plus")
    #expect(first.identityFingerprint != nil)
    #expect(first.identityFingerprint == upgraded.identityFingerprint)
    #expect(first.identityFingerprint != other.identityFingerprint)
    #expect(try decode(#"{"account":{"type":"apiKey"}}"#).identityFingerprint == nil)
    #expect(try decode(#"{"account":null}"#).identityFingerprint == nil)
    #expect(try decode(#"{"account":{"type":"chatgpt","email":""}}"#).identityFingerprint == nil)
}
