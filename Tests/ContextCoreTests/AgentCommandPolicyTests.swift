import Foundation
import Testing
import AgentContract
import ContextCore
import CodexAdapter
import ClaudeAdapter

private func commandPolicyProfile() -> AgentPermissionProfile {
    var profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile
    profile.commandSandbox = .init(read: ["/toolchain/read"], write: ["/toolchain/cache"],
                                   unsandboxed: ["gh", "zsh scripts/test.sh", "sysctl -n"])
    return profile
}

@Test func commandPolicyCompilesLiteralPrefixesWithStableIDs() throws {
    var profile = commandPolicyProfile()
    profile.commandSandbox?.unsandboxed += [" gh ", "gh; sh", "env TOKEN=x gh", "zsh -c 'anything'", "echo $HOME", "gh\nsh", "gh *"]
    let policy = AgentCommandPolicy(profile)
    #expect(policy.trustedPrefixes.map(\.command) == ["gh", "zsh scripts/test.sh", "sysctl -n"])
    #expect(policy.rejectedPrefixes.count == 6)
    let gh = try #require(policy.trustedPrefixes.first)
    #expect(gh.ruleID == AgentCommandPolicy.Prefix("  gh  ")?.ruleID)
    #expect(gh.matches(["gh", "pr", "list"]) && !gh.matches(["ghx", "pr", "list"]))
    #expect(!gh.ruleID.contains("gh"))
    #expect(policy.containsTrustedCommand("'gh' pr list"))
    #expect(!policy.containsTrustedCommand("ghx pr list"))
}

@Test func commandPolicyReportsProviderGapWithoutApprovingMandatoryPrompts() {
    let policy = AgentCommandPolicy(commandPolicyProfile())
    let claude = policy.assess(command: "gh pr list", support: .claudeRestrictedFiles)
    #expect(claude.decision == .granted && claude.reason == .projectCommand && claude.ruleIDs.count == 1)
    let codex = policy.assess(command: "gh pr list", support: .codexProjectPolicy)
    #expect(codex.decision == .unsupportedGrant && codex.reason == .nativeRulesUnavailable)
    #expect(codex.ruleIDs == claude.ruleIDs)
    let mandatory = policy.assess(command: "gh pr list", support: .claudeRestrictedFiles, providerRequiresApproval: true)
    #expect(mandatory.decision == .providerApprovalRequired && mandatory.reason == .mandatoryProviderApproval)
    #expect(mandatory.ruleIDs == claude.ruleIDs)
    #expect(policy.assess(command: "cat /outside", support: .codexProjectPolicy).decision == .notGranted)
    #expect(policy.assess(command: "gh pr list && cat /outside", support: .claudeRestrictedFiles).decision == .notGranted)
}

@Test func commandPolicyPreservesSandboxAndInspectionSeparation() {
    let profile = commandPolicyProfile()
    #expect(AgentPermissionSupport.claudeRestrictedFiles.unenforcedRules(profile).isEmpty)
    let gaps = AgentPermissionSupport.codexProjectPolicy.unenforcedRules(profile)
    #expect(gaps.contains(.commandSandboxPaths) && gaps.contains(.trustedCommands))
    #expect(AgentPermissionSupport.codexProjectPolicy.approximations(profile).contains(.filesystem))
    // Shell-only toolchain grants must not silently widen Codex file tools.
    let policy = profile.codexTurnParameters(projectPath: "/project")["sandboxPolicy"]
    #expect(policy?["writableRoots"].array == [.string("/project")])
    var audit = profile; audit.audit = true
    #expect(!AgentCommandPolicy(audit).trusts("gh pr list"))
    #expect(!AgentPermissionSupport.codexProjectPolicy.unenforcedRules(audit).contains(.trustedCommands))
}

@Test func commandPolicyNeverTreatsFilterOptionsAsBlanketGrants() {
    let policy = AgentCommandPolicy(commandPolicyProfile())
    for command in ["gh pr list | tail -15", "gh pr list | grep -E 'open|closed' | grep -v closed",
                    "zsh scripts/test.sh > \"$TMPDIR/test.log\" 2>&1; code=$?; tail -15 \"$TMPDIR/test.log\"; exit $code"] {
        #expect(policy.trusts(command), "\(command)")
    }
    for command in ["gh pr list | sort --output=/outside", "gh pr list | grep -f/outside", "gh pr list | grep --file=/outside",
                    "gh pr list | sort --compress-program=sh", "gh pr list | wc --files0-from=/outside",
                    "gh pr list; stat /outside", "gh api \"$(gh api x)\"", "gh api `gh api x`", "gh pr list | sh",
                    "cd /another-project && zsh scripts/test.sh", "PATH=/tmp; sysctl -n vm.loadavg", "./payload=name; gh pr list",
                    "gh pr list | head 123", "gh pr list | tail -n", "gh pr list | grep -e", "gh2>&1",
                    "sysctl -n hw.ncpu >\"/outside/path\"", "gh pr list >>'/outside/path'"] {
        #expect(!policy.trusts(command), "\(command)")
    }
}

@Test func commandPolicyRejectsTemporaryOutputLinksOutsideTemporaryStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("output")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
    let policy = AgentCommandPolicy(commandPolicyProfile())
    #expect(!policy.trusts("gh pr list > \(link.path)"))
    #expect(!policy.trusts("gh pr list >\"\(link.path)\""))
    #expect(policy.trusts("gh pr list > \(root.appendingPathComponent("new-output").path)"))
}

@Test func commandInvocationObservationRecognizesOnlyLiteralNativeShellWrappers() throws {
    let policy = AgentCommandPolicy(commandPolicyProfile())
    let direct = policy.assess(command: "zsh scripts/test.sh", support: .codexProjectPolicy)
    #expect(policy.assessInvocation(command: "zsh scripts/test.sh", support: .codexProjectPolicy) == direct)
    #expect(policy.assessInvocation(command: "zsh scripts/test.sh", support: .claudeRestrictedFiles)?.decision == .providerApprovalRequired)
    #expect(policy.assessInvocation(command: "cat /outside", support: .codexProjectPolicy) == nil)
    for shell in ["/bin/zsh", "/bin/bash"] {
        for option in ["-c", "-lc"] {
            let command = "\(shell) \(option) 'zsh scripts/test.sh --filter QueueTests'"
            let codex = try #require(policy.assessInvocation(command: command, support: .codexProjectPolicy))
            #expect(codex.decision == .unsupportedGrant && codex.reason == .nativeRulesUnavailable)
            #expect(codex.ruleIDs == direct.ruleIDs)
            let claude = try #require(policy.assessInvocation(command: command, support: .claudeRestrictedFiles))
            #expect(claude.decision == .providerApprovalRequired && claude.reason == .mandatoryProviderApproval)
            #expect(claude.ruleIDs == direct.ruleIDs)
            #expect(!policy.trusts(command))
        }
    }
    for command in ["/bin/zsh -lc 'zsh scripts/test.sh' extra", "/bin/zsh -lc 'zsh scripts/test.sh'; gh pr list",
                    "/bin/zsh -lc 'zsh scripts/test.sh' && gh pr list", "/bin/bash -lc \"zsh scripts/test.sh\"",
                    "/bin/zsh -lc 'zsh scripts/test.sh'\"\"", "/bin/zsh -lc 'zsh scripts/test.sh'\\''gh'",
                    "/bin/zsh -lc 'zsh scripts/test.sh $(gh pr list)'", "/bin/zsh -lc 'zsh scripts/test.sh `gh pr list`'",
                    "/bin/zsh -lc 'zsh scripts/test.sh $HOME'", "/bin/zsh -lc 'zsh scripts/test.sh\\ argument'",
                    "/bin/zsh -lc '/bin/bash -lc gh'", "/bin/zsh -lc 'zsh scripts/test.sh && cat /outside'",
                    "/bin/zsh -lc 'zsh scripts/test.sh\ngh pr list'", "/bin/zsh -lc 'zsh scripts/test.sh"] {
        #expect(policy.assessInvocation(command: command, support: .codexProjectPolicy) == nil, "\(command)")
        #expect(!policy.trusts(command), "\(command)")
    }
}
