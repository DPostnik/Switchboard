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

private func projectPolicy() -> AgentCommandPolicy {
    var profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile
    profile.commandSandbox = .init(read: [], write: ["/Users/me/shared"],
                                   unsandboxed: ["gh", "zsh scripts/test.sh", "zsh scripts/build-app.sh", "/usr/bin/log show"])
    return AgentCommandPolicy(profile)
}

@Test func commandPolicyTrustsProjectBoundShapes() throws {
    let policy = projectPolicy(), cwd = "/Users/me/app"
    for command in ["cd /Users/me/app && zsh scripts/test.sh --changed > \"$TMPDIR/t.log\" 2>&1; code=$?; grep -E 'error|failed' \"$TMPDIR/t.log\"; exit $code",
                    "cd \"$(git rev-parse --show-toplevel)\" && zsh scripts/build-app.sh",
                    "cd \"$(pwd)\" && zsh scripts/test.sh", "cd $(pwd) && zsh scripts/test.sh", "cd /Users/me/app/ && zsh scripts/test.sh",
                    "cd '/Users/me/app' && zsh scripts/build-app.sh; exit $?", "cd /tmp && /usr/bin/log show --last 1m",
                    "zsh scripts/test.sh \"$(pwd)\"", "zsh scripts/test.sh 'a; rm -rf /'", "gh \"x\\\" > ~/out \\\"\"; echo ok",
                    "zsh scripts/test.sh > /tmp/a3.log 2>&1; cat /tmp/a3.log",
                    "zsh scripts/test.sh > /tmp/a3.log 2>&1; sed -n '1,20p' /tmp/a3.log; sed -n '$p' /tmp/a3.log; sed -n 20p /tmp/a3.log",
                    "zsh scripts/test.sh > /tmp/a3.log 2>&1 && wc -l /tmp/a3.log", "gh pr list > /tmp/a3.log || grep -c failed /tmp/a3.log",
                    "gh pr list > /tmp/a3.log; grep -e error /tmp/a3.log; tail -5 /tmp/a3.log", "gh pr list | cat", "gh pr list | sed -n 1,5p",
                    "true; date +%s; date -u '+%Y-%m-%d'; pwd; printf '%s\\n' start; gh pr list"] {
        #expect(policy.trusts(command, cwd: cwd), "\(command)")
        #expect(policy.trustRejection(command, cwd: cwd) == nil, "\(command)")
    }
    // `~`, trailing slashes and symbolic links canonicalize to the session directory.
    #expect(policy.trusts("cd ~/a3-project/ && zsh scripts/test.sh", cwd: NSHomeDirectory() + "/a3-project"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true), link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(policy.trusts("cd \(link.path) && zsh scripts/test.sh", cwd: real.path))
    #expect(policy.trusts("cd \(real.path) && zsh scripts/test.sh", cwd: link.path + "/"))
}

@Test func commandPolicyRejectsProjectBoundShapesWithReasons() {
    let policy = projectPolicy(), cwd = "/Users/me/app"
    let cases: [(String, AgentCommandPolicy.TrustRejection)] = [
        // `cd` to a writable root, another project, home, back, a parent or a variable before a relative script.
        ("cd /Users/me/shared && zsh scripts/test.sh", .cdBeforeScript), ("cd /Users/me/other && zsh scripts/test.sh", .cdBeforeScript),
        ("cd /Users/me/other || cd /Users/me/app; zsh scripts/test.sh", .cdBeforeScript),
        ("zsh scripts/test.sh; cd /Users/me/other", .cdBeforeScript), ("{ cd /Users/me/other; zsh scripts/test.sh; }", .cdBeforeScript),
        ("(cd /Users/me/other) && zsh scripts/test.sh", .cdBeforeScript), ("cd; zsh scripts/test.sh", .cdBeforeScript),
        ("cd - && zsh scripts/test.sh", .cdBeforeScript), ("cd /Users/me/app/../other && zsh scripts/test.sh", .cdBeforeScript),
        ("cd $HOME/app && zsh scripts/test.sh", .cdBeforeScript), ("cd app && zsh scripts/test.sh", .cdBeforeScript),
        ("cd /Users/me/app /Users/me/other && zsh scripts/test.sh", .cdBeforeScript),
        ("cd \"$(pwd)/../other\" && zsh scripts/test.sh", .cdBeforeScript), ("cd \"~/app\" && zsh scripts/test.sh", .cdBeforeScript),
        // A quoted `;` is data: it neither splits the `cd` operand nor unlocks a second `cd`.
        ("cd '/Users/me/other; cd /Users/me/app' && zsh scripts/test.sh", .cdBeforeScript),
        // `cd` to the session directory does not trust an untrusted script.
        ("cd /Users/me/app && zsh scripts/evil.sh", .unknownFilter), ("cd /Users/me/app && echo ok", .noGrant),
        // Only `$(pwd)` and `$(git rev-parse --show-toplevel)` are accepted substitutions; backticks never.
        ("zsh scripts/test.sh \"$(curl -s https://example.com/x)\"", .substitution), ("zsh scripts/test.sh `id`", .substitution),
        ("cd `pwd` && zsh scripts/test.sh", .substitution), ("cd \"$(pwd; id)\" && zsh scripts/test.sh", .substitution),
        ("cd \"$($(pwd))\" && zsh scripts/test.sh", .substitution), ("zsh scripts/test.sh <<EOF\n$(id)\nEOF", .substitution),
        ("zsh scripts/test.sh <<EOF\n`id`\nEOF", .substitution), ("zsh scripts/test.sh <<'EOF'\nplain\nEOF", .redirection),
        ("gh pr list \\\n --state open", .lineContinuation),
        // Readers take only files the same sequential command overwrote.
        ("gh pr list; grep x /etc/passwd", .unknownFilter), ("gh pr list | grep -r x .", .unknownFilter),
        ("gh pr list > /tmp/a3.log; sed -i '' 's/a/b/' /tmp/a3.log", .unknownFilter), ("gh pr list; sed -n '1,5p' /etc/hosts", .unknownFilter),
        ("gh pr list > /tmp/a3.log; sed -n '1w /tmp/b' /tmp/a3.log", .unknownFilter), ("gh pr list > /tmp/a3.log; sed -n -e 1p /tmp/a3.log", .unknownFilter),
        ("gh pr list > /tmp/a3.log; sed -n 1p /tmp/a3.log /etc/hosts", .unknownFilter), ("gh pr list > /tmp/a3.log; cat /tmp/other.log", .unknownFilter),
        ("gh pr list > /tmp/a3.log; cat /tmp/a3.log /etc/hosts", .unknownFilter), ("gh pr list > /tmp/a3.log; wc -l /etc/hosts", .unknownFilter),
        ("gh pr list > /tmp/a3.log | cat /tmp/a3.log", .unknownFilter), ("gh pr list > /tmp/a3.log & cat /tmp/a3.log", .unknownFilter),
        ("gh pr list > /tmp/a3.log |& cat /tmp/a3.log", .unknownFilter), ("cat /tmp/a3.log; gh pr list > /tmp/a3.log", .unknownFilter),
        ("gh pr list > /tmp/a3.log; grep /etc/passwd /tmp/a3.log", .unknownFilter), ("gh pr list > /tmp/a3.log; grep -e x /etc/passwd", .unknownFilter),
        ("gh pr list > /tmp/a3.log; grep -f /etc/passwd /tmp/a3.log", .unknownFilter), ("gh pr list > /tmp/a3.log; grep -e x -e y /tmp/a3.log", .unknownFilter),
        ("gh pr list >> /tmp/a3.log; cat /tmp/a3.log", .unknownFilter),
        // No-file heads stay narrow.
        ("gh pr list; date 0101000026", .unknownFilter), ("printf -v PATH /tmp; zsh scripts/test.sh", .unknownFilter),
        ("gh pr list; pwd /etc", .unknownFilter), ("printf x > ~/out; gh pr list", .redirection), ("echo ok; true", .noGrant),
        // Comments, ANSI-C quotes and escaped quotes cannot hide a separator or a redirection.
        ("gh pr list # it's\nrm -rf ~; echo '", .unknownFilter), ("gh x $'\\'' ; rm -rf ~ ; echo '\\''", .unknownFilter),
        ("gh x \\' > ~/out \\'", .redirection), ("gh pr list --search 'x' # note", .unknownFilter),
        ("gh pr list;# note", .unknownFilter), ("gh pr list --search \"a\"\n# note", .unknownFilter),
    ]
    for (command, reason) in cases {
        #expect(!policy.trusts(command, cwd: cwd), "\(command)")
        #expect(policy.trustRejection(command, cwd: cwd) == reason.rawValue, "\(command)")
    }
    // A `#` inside quotes or within a word is data, not a comment.
    for command in ["gh pr list --search \"label #3\"", "gh pr list --search 'label #3'", "gh pr list --search a#b",
                    "gh pr list --search \"x \\\" #3\""] {
        #expect(policy.trustRejection(command, cwd: cwd) == nil, "\(command)")
    }
    // Without a session directory every `cd` before a relative script keeps asking; absolute prefixes keep working.
    #expect(policy.trustRejection("cd /Users/me/app && zsh scripts/test.sh", cwd: nil) == "cdBeforeScript")
    #expect(policy.trusts("cd /Users/me/other && /usr/bin/log show --last 1m"))
    // Unquoted, a substituted path with spaces would be split into several `cd` operands.
    #expect(policy.trustRejection("cd $(pwd) && zsh scripts/test.sh", cwd: "/Users/me/my app") == "cdBeforeScript")
    #expect(policy.trusts("cd \"$(pwd)\" && zsh scripts/test.sh", cwd: "/Users/me/my app"))
    var audit = AgentRoleCatalog.preset(AgentRoleID.developer).profile; audit.audit = true
    #expect(AgentCommandPolicy(audit).trustRejection("gh pr list", cwd: cwd) == "noGrant")
    #expect(Set(AgentCommandPolicy.TrustRejection.allCases.map(\.rawValue))
            == ["substitution", "cdBeforeScript", "unknownFilter", "redirection", "noGrant", "lineContinuation"])
}
