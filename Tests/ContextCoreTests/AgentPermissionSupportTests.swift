import Foundation
import Testing
import AgentContract
import CodexAdapter
import ClaudeAdapter

// Stage B: permission support is described by enforced rules, not engine names. The Codex, Claude and external presets
// must answer exactly as the per-engine cases did; the reference below is the code they replaced.

private enum LegacySupport { case codexProjectPolicy, externalPolicyOnly, claudeRestrictedFiles }

private func legacyAccepts(_ support: LegacySupport, _ intent: AgentPermissionIntent) -> Bool {
    switch (support, intent) {
    case (.externalPolicyOnly, .externalPolicyDenyPrompts): return true
    case (.externalPolicyOnly, _), (_, .externalPolicyDenyPrompts): return false
    case (.codexProjectPolicy, .profile(let profile, _)), (.claudeRestrictedFiles, .profile(let profile, _)):
        return !(profile.filesystem == .unrestricted && profile.approvals != .never)
    }
}

private func legacyApproximations(_ support: LegacySupport, _ profile: AgentPermissionProfile) -> [AgentPermissionDimension] {
    let effective = profile.effective
    var result: [AgentPermissionDimension] = []
    switch support {
    case .externalPolicyOnly: return AgentPermissionDimension.allCases
    case .codexProjectPolicy:
        if effective.shell == .off { result.append(.shell) }
        if !effective.commandInspection.isEmpty { result.append(.commandInspection) }
        if effective.connectors != .off && effective.connectors != .all { result.append(.connectors) }
        if effective.scratch != nil, effective.filesystem == .readOnly { result.append(.scratch) }
        if effective.browser == .appAndUserChrome { result.append(.browser) }
    case .claudeRestrictedFiles:
        if effective.shell == .sandboxed { result.append(.shell) }
        if effective.shell == .on, !effective.network { result.append(.network) }
        if effective.filesystem == .unrestricted, effective.approvals != .never { result.append(.approvals) }
    }
    return result
}

/// Every combination of the dimensions the rules read, in and out of audit mode.
private var profiles: [AgentPermissionProfile] {
    var result: [AgentPermissionProfile] = []
    let filesystems: [AgentPermissionProfile.Filesystem] = [.readOnly, .project(extraRoots: []),
        .project(extraRoots: [.init(path: "/tmp/x", writable: true)]), .unrestricted]
    let inspections = [AgentPermissionProfile.CommandInspection(), .init(deny: ["rm"]), .init(ask: ["git push"])]
    for filesystem in filesystems {
        for shell in [AgentPermissionProfile.Shell.off, .sandboxed, .on] {
            for network in [false, true] {
                for browser in [AgentPermissionProfile.Browser.off, .app, .appAndUserChrome] {
                    for connectors in [AgentPermissionProfile.Connectors.off, .read, .askWrites, .all] {
                        for approvals in [AgentPermissionProfile.Approvals.blocked, .ask, .never] {
                            for inspection in inspections {
                                for scratch in [nil, "research"] as [String?] {
                                    for audit in [false, true] {
                                        result.append(.init(filesystem: filesystem, network: network, webSearch: network, shell: shell,
                                                            browser: browser, connectors: connectors, approvals: approvals,
                                                            commandInspection: inspection, scratch: scratch, audit: audit))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return result
}

@Test func permissionPresetsMatchThePerEngineBehavior() {
    let presets: [(AgentPermissionSupport, LegacySupport)] = [
        (.codexProjectPolicy, .codexProjectPolicy), (.claudeRestrictedFiles, .claudeRestrictedFiles), (.externalPolicyOnly, .externalPolicyOnly)
    ]
    let all = profiles
    #expect(all.count == 4 * 3 * 2 * 3 * 4 * 3 * 3 * 2 * 2)
    for (support, legacy) in presets {
        #expect(support.accepts(.externalPolicyDenyPrompts) == legacyAccepts(legacy, .externalPolicyDenyPrompts))
        for profile in all {
            #expect(support.approximations(profile) == legacyApproximations(legacy, profile), "\(legacy) \(profile)")
            let intent = AgentPermissionIntent.profile(profile, root: "/project")
            #expect(support.accepts(intent) == legacyAccepts(legacy, intent), "\(legacy) \(profile)")
        }
    }
}

@Test func permissionSupportIsDescribedByRules() {
    // A new engine declares what it enforces; nothing depends on its name.
    let everything = AgentPermissionSupport(roleProfiles: true, enforced: Set(AgentPermissionRule.allCases))
    let nothing = AgentPermissionSupport(roleProfiles: true)
    var reader = AgentPermissionProfile.workspace(); reader.shell = .off; reader.filesystem = .readOnly; reader.scratch = "research"
    #expect(everything.approximations(reader).isEmpty)
    #expect(nothing.approximations(reader) == [.shell, .scratch])
    #expect(!nothing.accepts(.externalPolicyDenyPrompts) && AgentPermissionSupport.externalPolicyOnly.accepts(.externalPolicyDenyPrompts))
    #expect(!AgentPermissionSupport.externalPolicyOnly.accepts(.profile(reader, root: "/p")))
}
