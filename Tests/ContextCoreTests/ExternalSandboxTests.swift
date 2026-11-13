import Foundation
import Testing
import AgentContract
import ContextCore
@_spi(NativeProtocol) @testable import CodexAdapter

private func fixtureProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project/.git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("resources/SandboxRuntime"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("resources/SandboxRuntime/mcp_relay.py"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("home/Library/Developer"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("home/.gitconfig"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("codex-home"), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("codex"))
    return root
}

private func helperFixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Minimal 64-bit Mach-O header: little-endian magic then CPU_TYPE_ARM64.
    var binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]); binary.append(Data(repeating: 0, count: 24))
    let executable = directory.appendingPathComponent("nono")
    try binary.write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let lock: [String: String] = ["version": "0.81.0", "platform": "aarch64-apple-darwin", "binary_sha256": sha256(binary),
                                  "identifier": "ai.nolabs.nono", "team_identifier": "54DFBSV5GX"]
    try JSONSerialization.data(withJSONObject: lock).write(to: directory.appendingPathComponent("runtime.lock.json"))
    return directory
}

private func helperFromFixture() throws -> ExternalSandboxHelper {
    let directory = try helperFixture()
    return try ExternalSandboxHelper.verified(executable: directory.appendingPathComponent("nono"), lock: directory.appendingPathComponent("runtime.lock.json"), checkSignature: false)
}

private func sha256(_ data: Data) -> String {
    let process = Process(), output = Pipe(), input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); process.arguments = ["-a", "256"]
    process.standardInput = input; process.standardOutput = output
    try! process.run()
    input.fileHandleForWriting.write(data); try! input.fileHandleForWriting.close()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return String(text.split(separator: " ")[0])
}

@Test func helperVerificationRejectsChecksumAndArchitectureMismatches() throws {
    let directory = try helperFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = try ExternalSandboxHelper.verified(executable: directory.appendingPathComponent("nono"), lock: directory.appendingPathComponent("runtime.lock.json"), checkSignature: false)
    #expect(helper.version == "0.81.0" && helper.executable.lastPathComponent == "nono")
    // The real signature check runs against the fixture bytes and must fail: unsigned data is never a verified helper.
    #expect(throws: ExternalSandboxHelper.Failure.self) { try ExternalSandboxHelper.verified(executable: directory.appendingPathComponent("nono"), lock: directory.appendingPathComponent("runtime.lock.json")) }
    try Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 24)).write(to: directory.appendingPathComponent("nono"))
    #expect(throws: ExternalSandboxHelper.Failure.checksum) { try ExternalSandboxHelper.verified(executable: directory.appendingPathComponent("nono"), lock: directory.appendingPathComponent("runtime.lock.json"), checkSignature: false) }
    var lock = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("runtime.lock.json"))) as! [String: String]
    lock["binary_sha256"] = sha256(try Data(contentsOf: directory.appendingPathComponent("nono")))
    try JSONSerialization.data(withJSONObject: lock).write(to: directory.appendingPathComponent("runtime.lock.json"))
    #expect(throws: ExternalSandboxHelper.Failure.architecture) { try ExternalSandboxHelper.verified(executable: directory.appendingPathComponent("nono"), lock: directory.appendingPathComponent("runtime.lock.json"), checkSignature: false) }
    #expect(throws: ExternalSandboxHelper.Failure.self) { try ExternalSandboxHelper.verified(executable: directory.appendingPathComponent("missing/nono"), lock: directory.appendingPathComponent("runtime.lock.json"), checkSignature: false) }
}

@Test func plannerCompilesRoleAndProjectIntoCanonicalGrantsWithoutCwd() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = ["swift", "apple-signing", "github"]
    var profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)
    profile.filesystem = .project(extraRoots: [.init(path: root.appendingPathComponent("home/Library/Developer").path, writable: false)])
    let input = ExternalSandboxPlanner.Input(project: project.path + "/", profile: profile, providerHome: root.appendingPathComponent("codex-home"),
                                             providerExecutable: root.appendingPathComponent("codex"), resources: root.appendingPathComponent("resources"),
                                             workerID: "abcd1234", home: root.appendingPathComponent("home"))
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    let canonicalProject = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
    #expect(plan.project == canonicalProject && !plan.readOnlyProject)
    let arguments = plan.arguments(helper: helper)
    #expect(arguments.prefix(2) == [helper.executable.path, "run"])
    #expect(!arguments.contains("--allow-cwd"))
    #expect(arguments.contains("--allow") && arguments[arguments.firstIndex(of: "--allow")! + 1] == canonicalProject)
    // Preset folders that exist become session grants; missing ones are skipped; the project is never granted twice.
    let developerFolder = root.appendingPathComponent("home/Library/Developer").resolvingSymlinksInPath().path
    #expect(plan.grants.contains(.init(.allow, developerFolder)))
    #expect(plan.grants.filter { $0.path == canonicalProject }.count == 1)
    #expect(!plan.grants.contains { $0.path.hasSuffix("/.bun") })
    // The policy file lives in the worker folder, outside every grant; only its tmp subfolder and socket are granted.
    #expect(!plan.grants.contains { plan.policyFile.path.hasPrefix($0.path + "/") })
    #expect(plan.grants.contains(.init(.allow, plan.temporary.path)) && plan.grants.contains(.init(.unixSocket, plan.socket.path)))
    #expect(plan.grants.contains(.init(.readFile, root.appendingPathComponent("home/.gitconfig").resolvingSymlinksInPath().path)))
    #expect(plan.grants.contains(.init(.allow, root.appendingPathComponent("home/Library/Caches/Switchboard").resolvingSymlinksInPath().path)))
    // Mediated commands follow the ticked presets: signing and GitHub get the Keychain, git keeps its helper trees; git's own
    // sandbox has neither Keychain nor network, only its network route does (`narrowedGitSplitsKeychainFromLocalWork`).
    let names = plan.commands.map(\.name).sorted()
    #expect(names.contains("codesign") && names.contains("security") && names.contains("git"))
    let git = plan.commands.first { $0.name == "git" }!
    #expect(!git.keychain && !git.network && git.executableTrees.contains("/bin"))
    #expect(git.routes.contains { $0.sandbox.keychain && $0.sandbox.network && $0.sandbox.executableTrees.contains("/bin") })
    let document = plan.policyDocument()
    let policies = (document["command_policies"] as! [String: Any])["commands"] as! [String: Any]
    #expect((policies["codesign"] as! [String: Any])["allow_direct_exec_bypass"] as? [String] == ["/usr/bin/codesign"])
    #expect((policies["security"] as! [String: Any])["allow_direct_exec_bypass"] == nil)
    #expect((policies["git"] as! [String: Any])["allow_direct_exec_bypass"] == nil)
    // `security` carries an argument allow-list, so its sandbox moves into the session edge with nono's invocation policy:
    // signing alone lists identities only, never a secret.
    let securityPolicy = policies["security"] as! [String: Any]
    #expect(securityPolicy["sandbox"] == nil && securityPolicy["executable"] as? String == "/usr/bin/security")
    let edge = (securityPolicy["from"] as! [String: Any])["session"] as! [String: Any]
    let security = edge["sandbox"] as! [String: Any]
    #expect(security["keychain_access"] as? String == "read" && (security["fs_write"] as! [String]).contains(canonicalProject))
    #expect((security["fs_read_file"] as! [String]).contains { $0.hasSuffix("/.gitconfig") })
    #expect((security["network"] as! [String: Bool])["allow_all"] == false)
    let invocation = edge["invocation_policy"] as! [String: Any]
    #expect(invocation["default"] as? String == "deny" && invocation["deny"] == nil && invocation["approve"] == nil)
    let allow = invocation["allow"] as! [[String: [String: [String]]]]
    #expect(allow == [["argv": ["prefix": ["find-identity"]]]])
    // Commands without an allow-list keep the shorthand and filter no arguments.
    #expect((policies["codesign"] as! [String: Any])["sandbox"] != nil && (policies["codesign"] as! [String: Any])["from"] == nil)
    #expect((policies["git"] as! [String: Any])["sandbox"] == nil && (policies["git"] as! [String: Any])["from"] != nil)
    #expect(plan.commands.first { $0.name == "security" }?.arguments == [.prefix(["find-identity"])])
    #expect(plan.commands.filter { !["security", "gh"].contains($0.name) }.allSatisfy { $0.arguments == nil })
    #expect(plan.authority.contains { $0.hasPrefix("command security ") && $0.hasSuffix("argv=prefix \"find-identity\"") })
    #expect((document["workdir"] as! [String: String])["access"] == "none")
    #expect(plan.environment["TMPDIR"] == plan.temporary.path && plan.environment["SWITCHBOARD_EXTERNAL_SANDBOX"] == "1")
    #expect(plan.environment["SSL_CERT_FILE"] == "/etc/ssl/cert.pem")
}

@Test func plannerKeepsReadersReadOnlyAndRefusesUnsupportedRoles() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let project = Project(path: root.appendingPathComponent("project").path)
    func input(_ profile: AgentPermissionProfile) -> ExternalSandboxPlanner.Input {
        .init(project: project.path, profile: profile, providerHome: root.appendingPathComponent("codex-home"), providerExecutable: root.appendingPathComponent("codex"),
              resources: root.appendingPathComponent("resources"), workerID: "r", home: root.appendingPathComponent("home"))
    }
    let reader = try ExternalSandboxPlanner.plan(input(AgentRoleCatalog.preset(AgentRoleID.reader).profile(for: project)), helper: .success(helper)).get()
    let canonicalProject = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
    #expect(reader.readOnlyProject && reader.grants.contains(.init(.read, canonicalProject)))
    #expect(reader.grants.contains(.init(.allow, canonicalProject + "/research")) && reader.commands.isEmpty)
    #expect(ExternalSandboxPlanner.plan(input(.unrestricted), helper: .success(helper)) == .failure(.unrestricted))
    #expect(ExternalSandboxPlanner.plan(input(AgentRoleCatalog.preset(AgentRoleID.editor).profile(for: project)), helper: .success(helper)) == .failure(.networkOff))
    var off = project; off.commandSandbox = false
    #expect(ExternalSandboxPlanner.plan(input(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: off)), helper: .success(helper)) == .failure(.commandSandboxOff))
    #expect(ExternalSandboxPlanner.plan(input(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)), helper: .failure(.checksum)) == .failure(.helper(.checksum)))
    var noRelay = input(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)); noRelay.resources = root
    #expect(ExternalSandboxPlanner.plan(noRelay, helper: .success(helper)) == .failure(.resourcesMissing))
}

@Test func launchWrapsTheProviderInOneProcessGroupAndRewritesAppServersToTheRelay() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let project = Project(path: root.appendingPathComponent("project").path)
    let input = ExternalSandboxPlanner.Input(project: project.path, profile: AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project),
                                             providerHome: root.appendingPathComponent("codex-home"), providerExecutable: root.appendingPathComponent("codex"),
                                             resources: root.appendingPathComponent("resources"), workerID: "w1", home: root.appendingPathComponent("home"))
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    let launch = ExternalSandboxLaunch(plan: plan, helper: helper)
    let command = launch.command(provider: root.appendingPathComponent("codex"), arguments: ["app-server", "--listen", "stdio://"])
    #expect(command.executable.path == "/usr/bin/python3" && command.arguments.contains { $0.contains("os.setsid()") })
    let separator = command.arguments.lastIndex(of: "--")!
    #expect(Array(command.arguments[(separator + 1)...]) == [root.appendingPathComponent("codex").path, "app-server", "--listen", "stdio://"])
    #expect(command.arguments[separator - 2 ..< separator].first.map { ["--allow", "--read", "--read-file", "--allow-unix-socket"].contains($0) } == true)
    let relay = plan.relayCommand(for: "switchboard_browser")
    #expect(relay.command == "/usr/bin/python3" && relay.arguments == ["-I", plan.relay.path, plan.socket.path, "switchboard_browser"])
    #expect(plan.socket.path.utf8.count <= 104)
    // Thread and turn parameters under the boundary: nothing is asked; the engine reports the external sandbox.
    let profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)
    #expect(profile.codexThreadParameters(external: true)["approvalPolicy"] == .string("never"))
    #expect(profile.codexThreadParameters(external: false)["approvalPolicy"] == .string("on-request"))
    let turn = profile.codexTurnParameters(projectPath: project.path, external: true)
    #expect(turn["approvalPolicy"] == .string("never") && turn["sandboxPolicy"]?["type"] == .string("externalSandbox"))
    #expect(turn["sandboxPolicy"]?["networkAccess"] == .string("enabled"))
    #expect(profile.codexTurnParameters(projectPath: project.path)["sandboxPolicy"]?["type"] == .string("workspaceWrite"))
}

@Test func relayRewriteKeepsProjectServersInsideAndWritesTheHostSpec() async throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let project = Project(path: root.appendingPathComponent("project").path)
    let input = ExternalSandboxPlanner.Input(project: project.path, profile: AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project),
                                             providerHome: root.appendingPathComponent("codex-home"), providerExecutable: root.appendingPathComponent("codex"),
                                             resources: root.appendingPathComponent("resources"), workerID: "w2", home: root.appendingPathComponent("home"))
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    try plan.materialize()
    defer { plan.removeWorkerFolder() }
    #expect(FileManager.default.fileExists(atPath: plan.policyFile.path))
    let config: JSONValue = .object([
        "mcp_servers.switchboard_browser": .object(["command": .string("/usr/bin/python3"), "args": .array([.string("-I"), .string("/app/server.py")]),
                                                    "enabled": .bool(true), "required": .bool(true), "env": .object(["LANG": .string("ru")])]),
        "mcp_servers.switchboard_user_chrome": .object(["command": .string("/usr/bin/false"), "args": .array([]), "enabled": .bool(false), "required": .bool(false)]),
        "mcp_servers.project_tool": .object(["command": .string("/usr/bin/python3"), "args": .array([]), "enabled": .bool(true)]),
        "web_search": .string("disabled")
    ])
    let client = CodexClient(transport: CodexConnection())
    let rewritten = try await client.relayedForTesting(config, boundary: ExternalSandboxLaunch(plan: plan, helper: helper))
    let browser = rewritten["mcp_servers.switchboard_browser"]
    #expect(browser["command"] == .string("/usr/bin/python3") && browser["args"].array.map(\.string) == ["-I", plan.relay.path, plan.socket.path, "switchboard_browser"])
    #expect(browser["env"] == .null && browser["required"] == .bool(true))
    #expect(rewritten["mcp_servers.switchboard_user_chrome"]["command"] == .string("/usr/bin/false"))
    #expect(rewritten["mcp_servers.project_tool"]["args"] == .array([]) && rewritten["web_search"] == .string("disabled"))
    let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: plan.serversFile)) as! [String: Any]
    let servers = spec["servers"] as! [String: Any]
    #expect(servers.count == 1)
    let entry = servers["switchboard_browser"] as! [String: Any]
    #expect(entry["command"] as? String == "/usr/bin/python3" && entry["args"] as? [String] == ["-I", "/app/server.py"])
    #expect((entry["env"] as? [String: String])?["LANG"] == "ru")
    #expect(entry["cwd"] as? String == plan.project)
}

@Test func plannerGrantsTheFoldersForEveryProjectToCodex() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let shared = root.appendingPathComponent("self-projects"), notes = root.appendingPathComponent("notes")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let project = Project(path: root.appendingPathComponent("project").path)
    let profile = AgentRoleCatalog.preset(AgentRoleID.developer)
        .profile(for: project, sharedRoots: [.init(path: shared.path, writable: true), .init(path: notes.path, writable: false)])
    let input = ExternalSandboxPlanner.Input(project: project.path, profile: profile, providerHome: root.appendingPathComponent("codex-home"),
                                             providerExecutable: root.appendingPathComponent("codex"), resources: root.appendingPathComponent("resources"),
                                             workerID: "share123", home: root.appendingPathComponent("home"))
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    #expect(plan.grants.contains(.init(.allow, shared.resolvingSymlinksInPath().path)))
    #expect(plan.grants.contains(.init(.read, notes.resolvingSymlinksInPath().path)))
    // The Codex turn's own writable roots carry the writable shared folder too.
    let policy = try #require(profile.codexTurnParameters(projectPath: project.path)["sandboxPolicy"])
    #expect(policy["writableRoots"].array.contains(.string(shared.path)) && !policy["writableRoots"].array.contains(.string(notes.path)))
}

private extension CodexIntegration {
    static func boundaryInput(project: String, profile: AgentPermissionProfile, root: URL, inbox: URL) -> ExternalSandboxPlanner.Input {
        boundaryInput(project: project, permissions: profile, home: root.appendingPathComponent("codex-home"), executable: root.appendingPathComponent("codex"),
                      resources: root.appendingPathComponent("resources"), workflowDirectories: [], inbox: inbox)
    }
}

private func claudeInput(_ root: URL, project: Project, workerID: String) -> ExternalSandboxPlanner.Input {
    var input = ExternalSandboxPlanner.Input(project: project.path, profile: AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project),
                                             providerHome: root.appendingPathComponent("codex-home"), providerExecutable: root.appendingPathComponent("codex"),
                                             resources: root.appendingPathComponent("resources"), workerID: workerID, home: root.appendingPathComponent("home"))
    input.settingsFile = true; input.mediateProcessList = true; input.commandInventory = true
    return input
}

@Test func plannerOmitsCommandPoliciesWithoutMediatedCommands() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let project = Project(path: root.appendingPathComponent("project").path)
    let input = ExternalSandboxPlanner.Input(project: project.path, profile: AgentRoleCatalog.preset(AgentRoleID.reader).profile(for: project),
                                             providerHome: root.appendingPathComponent("codex-home"), providerExecutable: root.appendingPathComponent("codex"),
                                             resources: root.appendingPathComponent("resources"), workerID: "noexec", home: root.appendingPathComponent("home"))
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    // nono 0.81.0 refuses `executable_dirs` without a mediated command (B1 probe): the whole section is left out.
    #expect(plan.commands.isEmpty && plan.policyDocument()["command_policies"] == nil)
    // A plan with a mediated command keeps it.
    var developer = input; developer.profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project); developer.mediateProcessList = true
    let mediated = try ExternalSandboxPlanner.plan(developer, helper: .success(helper)).get()
    #expect(mediated.policyDocument()["command_policies"] != nil)
}

@Test func claudePlanGrantsSettingsFileInboxAndMediatesPgrepWithStableAuthority() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let project = Project(path: root.appendingPathComponent("project").path)
    let inbox = root.appendingPathComponent("inbox"), attachments = root.appendingPathComponent("dropped")
    for folder in [inbox, attachments] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    var input = claudeInput(root, project: project, workerID: "c1")
    input.extraWrites = [inbox.path]; input.extraReads = [attachments.path, root.appendingPathComponent("missing").path]
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    #expect(plan.grants.contains(.init(.readFile, plan.settingsFile.path)))
    #expect(plan.grants.contains(.init(.allow, inbox.resolvingSymlinksInPath().path)))
    #expect(plan.grants.contains(.init(.read, attachments.resolvingSymlinksInPath().path)))
    #expect(!plan.grants.contains { $0.path.hasSuffix("/missing") })
    #expect(plan.grants.contains(.init(.allow, root.appendingPathComponent("codex-home").resolvingSymlinksInPath().path)))
    let pgrep = try #require(plan.commands.first { $0.name == "pgrep" })
    #expect(pgrep.executable == "/usr/bin/pgrep" && !pgrep.keychain && !pgrep.network)
    // The settings file is outside every writable grant.
    #expect(!plan.grants.contains { $0.mode == .allow && plan.settingsFile.path.hasPrefix($0.path + "/") })
    // Equal rights give equal authority whatever the worker; a changed setting changes it.
    var same = claudeInput(root, project: project, workerID: "c2"); same.extraWrites = [inbox.path]; same.extraReads = [attachments.path]
    let other = try ExternalSandboxPlanner.plan(same, helper: .success(helper)).get()
    #expect(other.authority == plan.authority && other.worker != plan.worker)
    #expect(!plan.authority.contains { $0.contains(plan.worker.path) })
    var narrower = claudeInput(root, project: project, workerID: "c3"); narrower.extraReads = [attachments.path]
    #expect(try ExternalSandboxPlanner.plan(narrower, helper: .success(helper)).get().authority != plan.authority)
    // A bare input adds neither: pgrep and the settings file are planner inputs, not defaults.
    let codex = try ExternalSandboxPlanner.plan(.init(project: project.path, profile: input.profile, providerHome: input.providerHome,
                                                      providerExecutable: input.providerExecutable, resources: input.resources, workerID: "x1", home: input.home),
                                                helper: .success(helper)).get()
    #expect(!codex.commands.contains { $0.name == "pgrep" } && !codex.grants.contains { $0.path == codex.settingsFile.path })
}

/// The Switchboard project's own trusted commands once `/usr/bin/log show` and `zsh scripts/request-app-restart.sh` are
/// replaced by the app-owned `app_log` and `request_app_restart`: the Claude inventory accepts the rest. Only
/// `log show` makes the project ineligible; the restart script still plans but cannot reach the app from inside.
@Test func switchboardProjectPassesTheInventoryWithoutLogShowAndTheRestartScript() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let remaining = ["ps", "sysctl -n", "gh", "git push", "git pull", "git fetch", "git clone", "git ls-remote", "git worktree",
                     "swift build", "swift test", "swift run", "swift package", "xcodebuild", "codesign",
                     "zsh scripts/build-app.sh", "zsh scripts/test.sh"]
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = ["github", "swift", "apple-signing"]
    project.sandboxCommands = remaining
    let trusted = try #require(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project).commandSandbox?.unsandboxed)
    #expect(Set(remaining).isSubset(of: Set(trusted)))
    let plan = try ExternalSandboxPlanner.plan(claudeInput(root, project: project, workerID: "sb1"), helper: .success(helper)).get()
    #expect(plan.commands.contains { $0.name == "codesign" } && plan.commands.contains { $0.name == "pgrep" })
    // Also without any mediated command (gh or git not installed): none of them is an unrunnable head or names a path.
    #expect(ExternalSandboxPlanner.unrunnableTrustedCommand(trusted, mediated: [], grants: plan.grants, home: root.appendingPathComponent("home")) == nil)
    for removed in ["/usr/bin/log show", "zsh scripts/request-app-restart.sh"] {
        project.sandboxCommands = remaining + [removed]
        let result = ExternalSandboxPlanner.plan(claudeInput(root, project: project, workerID: "sb2"), helper: .success(helper))
        if removed.hasPrefix("/usr/bin/log") { #expect(result == .failure(.trustedCommandOutside(removed))) }
        else { #expect((try? result.get()) != nil, "a project script runs inside the boundary; only the restart it requests needs the app") }
    }
}

@Test func codexBoundaryGrantsAndExportsTheSettingsProposalInbox() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let project = Project(path: root.appendingPathComponent("project").path)
    let shared = root.appendingPathComponent("inbox", isDirectory: true)
    let inbox = try #require(SettingsProposalInbox.chatFolder("codex-worker-a", directory: shared, create: true))
    let sibling = try #require(SettingsProposalInbox.chatFolder("codex-worker-b", directory: shared, create: true))
    var input = CodexIntegration.boundaryInput(project: project.path, profile: AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project),
                                               root: root, inbox: inbox)
    input.workerID = "cx1"; input.home = root.appendingPathComponent("home")
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    #expect(plan.grants.contains(.init(.allow, inbox.resolvingSymlinksInPath().path)))
    // Only the worker's own folder: neither the whole inbox nor another chat's folder is granted.
    #expect(!plan.grants.contains { $0.path == shared.resolvingSymlinksInPath().path || $0.path == sibling.resolvingSymlinksInPath().path })
    // Codex has the inbox and mediated pgrep, as Claude; no settings file (Claude-only launch settings).
    #expect(plan.commands.contains { $0.name == "pgrep" } && !plan.grants.contains { $0.path == plan.settingsFile.path })
    let environment = CodexConnection.boundaryEnvironment(ExternalSandboxLaunch(plan: plan, helper: helper, settingsInbox: inbox))
    #expect(environment[SettingsProposalInbox.environmentKey] == inbox.path)
    #expect(environment["TMPDIR"] == plan.temporary.path && environment["SWITCHBOARD_EXTERNAL_SANDBOX"] == "1")
    // Negative: a launch without a folder exports no variable.
    #expect(CodexConnection.boundaryEnvironment(ExternalSandboxLaunch(plan: plan, helper: helper))[SettingsProposalInbox.environmentKey] == nil)
    // PATH: Claude's base list first, then the other inherited entries once each, order kept; relative entries dropped.
    let path = CodexConnection.boundaryEnvironment(ExternalSandboxLaunch(plan: plan, helper: helper),
                                                   inheritedPath: "/usr/bin:/Users/x/.local/bin:/bin:relative:/opt/homebrew/bin:/Users/x/.local/bin::/opt/tools")["PATH"]
    #expect(path == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Users/x/.local/bin:/opt/tools")
    #expect(CodexConnection.boundaryEnvironment(ExternalSandboxLaunch(plan: plan, helper: helper), inheritedPath: nil)["PATH"]
            == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    // Commands under the boundary run in a non-login shell, so path_helper cannot move nono's shims behind /usr/bin.
    let arguments = CodexConnection.boundaryArguments(ExternalSandboxLaunch(plan: plan, helper: helper))
    #expect(arguments == ["-c", "allow_login_shell=false"])
    // Negative: the native launch gets no extra argument.
    #expect(CodexConnection.boundaryArguments(nil).isEmpty)
    // Negative: without the inbox input no grant appears for it.
    var bare = input; bare.extraWrites = []; bare.workerID = "cx2"
    let barePlan = try ExternalSandboxPlanner.plan(bare, helper: .success(helper)).get()
    #expect(!barePlan.grants.contains { $0.path.hasPrefix(shared.resolvingSymlinksInPath().path) })
}

@Test func commandInventoryRefusesTrustedCommandsTheBoundaryCannotRun() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    let home = root.appendingPathComponent("home")
    let projectPath = root.appendingPathComponent("project").resolvingSymlinksInPath().path
    let grants: [ExternalSandboxPlan.Grant] = [.init(.allow, projectPath), .init(.unixSocket, "/private/tmp/x.sock")]
    func check(_ trusted: [String], mediated: Set<String> = []) -> String? {
        ExternalSandboxPlanner.unrunnableTrustedCommand(trusted, mediated: mediated, grants: grants, home: home)
    }
    // The app's base entries never make a project ineligible, although `ps` cannot run under nono.
    #expect(check(AccessPresetCatalog.baseUnsandboxed) == nil)
    #expect(check(["zsh scripts/test.sh", "zsh scripts/build-app.sh", "swift build", "xcodebuild"]) == nil)
    #expect(check(["gh", "git push"], mediated: ["gh", "git"]) == nil)
    #expect(check(["python3 \(projectPath)/tools/x.py", "cat /dev/null", "/usr/bin/env true"]) == nil)
    // Negative: unrunnable heads (also by absolute path), unmediated Keychain tools, paths outside every grant.
    #expect(check(["/usr/bin/log show --last 1m"]) == "/usr/bin/log show --last 1m")
    #expect(check(["launchctl load x.plist"]) == "launchctl load x.plist")
    #expect(check(["security find-identity"]) == "security find-identity")
    #expect(check(["security find-identity"], mediated: ["security"]) == nil)
    #expect(check(["cp job.plist ~/Library/LaunchAgents/"]) == "cp job.plist ~/Library/LaunchAgents/")
    #expect(check(["cat '/private/var/root/x'"]) == "cat '/private/var/root/x'")
    #expect(check(["tee /private/tmp/x.sock"]) == "tee /private/tmp/x.sock")
    #expect(check(["osascript -e x"]) == "osascript -e x" && check(["pkill -f x"]) == "pkill -f x" && check(["sudo true"]) == "sudo true")
    // In the planner: Claude refuses the boundary with the command named; an input without the inventory still plans.
    var project = Project(path: root.appendingPathComponent("project").path)
    project.sandboxCommands = ["zsh scripts/test.sh", "/usr/bin/log show"]
    let input = claudeInput(root, project: project, workerID: "inv1")
    #expect(ExternalSandboxPlanner.plan(input, helper: .success(helper)) == .failure(.trustedCommandOutside("/usr/bin/log show")))
    var bare = input; bare.commandInventory = false
    #expect((try? ExternalSandboxPlanner.plan(bare, helper: .success(helper)).get()) != nil)
    let reason = ExternalSandboxPlanner.Ineligible.trustedCommandOutside("/usr/bin/log show")
    #expect(reason.description(language: .english).contains("`/usr/bin/log show`") && reason.description(language: .russian).contains("`/usr/bin/log show`"))
}

/// Codex goes through the same planner path as Claude: the inventory refuses an unrunnable trusted command, the base
/// entries stay exempt, `pgrep` is mediated, and role-defined reasons win over the helper check.
@Test func codexAppliesTheCommandInventoryThroughTheSamePlannerPath() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    func decision(_ commands: [String], role: String = AgentRoleID.developer,
                  helper result: Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>? = nil) -> Result<ExternalSandboxLaunch, ExternalSandboxPlanner.Ineligible> {
        project.sandboxCommands = commands
        var input = CodexIntegration.boundaryInput(project: project.path, profile: AgentRoleCatalog.preset(role).profile(for: project),
                                                   root: root, inbox: root.appendingPathComponent("inbox"))
        input.workerID = "cxi"; input.home = root.appendingPathComponent("home")
        return CodexIntegration.boundaryDecision(input, helper: { result ?? .success(helper) })
    }
    // An unrunnable trusted command: native sandbox, the command named.
    guard case .failure(.trustedCommandOutside("/usr/bin/log show")) = decision(["zsh scripts/test.sh", "/usr/bin/log show"]) else {
        Issue.record("Codex must refuse the boundary for an unrunnable trusted command"); return
    }
    // Without it: under the boundary, with mediated pgrep.
    let plan = try decision(["zsh scripts/test.sh"]).get().plan
    #expect(plan.commands.contains { $0.name == "pgrep" && $0.executable == "/usr/bin/pgrep" && !$0.keychain && !$0.network })
    // The base entries `ps` and `sysctl -n` are exempt although `ps` cannot run under nono.
    let trusted = try #require(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project).commandSandbox?.unsandboxed)
    #expect(Set(AccessPresetCatalog.baseUnsandboxed).isSubset(of: Set(trusted)) && AccessPresetCatalog.baseUnsandboxed.contains("ps"))
    #expect((try? decision(["ps", "sysctl -n"]).get()) != nil)
    // Negative: `ps` with an argument is not the base entry; other unrunnable heads are refused too.
    guard case .failure(.trustedCommandOutside("ps aux")) = decision(["ps aux"]),
          case .failure(.trustedCommandOutside("launchctl list")) = decision(["launchctl list"]) else {
        Issue.record("Only the exact base entries are exempt"); return
    }
    // A role-defined reason comes before the helper: an Operator chat is never reported as a missing helper.
    guard case .failure(.unrestricted) = decision(["/usr/bin/log show"], role: AgentRoleID.fullOperator, helper: .failure(.missing("/x/nono"))) else {
        Issue.record("Operator falls back as unrestricted"); return
    }
    guard case .failure(.helper(.missing("/x/nono"))) = decision([], helper: .failure(.missing("/x/nono"))) else {
        Issue.record("A Developer chat without a verified helper falls back with the helper reason"); return
    }
}

/// The Codex fallback notice: once per chat and reason, RU/EN with the route, nothing for role-defined reasons.
@Test func codexFallbackNoticeIsShownOncePerSessionAndReason() {
    var notices = CodexBoundaryNotices()
    let chat = AgentSessionReference(connection: .originalCodex, nativeID: "a"), other = AgentSessionReference(connection: .originalCodex, nativeID: "b")
    let outside = ExternalSandboxPlanner.Ineligible.trustedCommandOutside("/usr/bin/log show")
    let first = notices.note(outside, session: chat)
    #expect(first == CodexBoundaryNotices.text(outside))
    #expect(notices.note(outside, session: chat) == nil)
    // Another chat gets its own notice; another reason in the same chat is shown.
    #expect(notices.note(outside, session: other) != nil)
    #expect(notices.note(.helper(.checksum), session: chat) != nil)
    // A worker under the boundary resets the chat, so a later fallback is shown again.
    #expect(notices.note(nil, session: chat) == nil && notices.note(outside, session: chat) != nil)
    // Role-defined reasons are only logged.
    for reason in [ExternalSandboxPlanner.Ineligible.unrestricted, .networkOff, .commandSandboxOff] {
        #expect(notices.note(reason, session: AgentSessionReference(connection: .originalCodex, nativeID: "r")) == nil)
    }
    // The text names the command, the route and the sandbox, in both languages, from the same source as Claude's notice.
    let english = CodexBoundaryNotices.text(outside, language: .english), russian = CodexBoundaryNotices.text(outside, language: .russian)
    #expect(english.hasPrefix("External boundary unavailable:") && english.contains("`/usr/bin/log show`")
            && english.contains("remove it from the project settings") && english.contains("the Codex sandbox and approval prompts"))
    #expect(russian.hasPrefix("Внешняя граница недоступна:") && russian.contains("`/usr/bin/log show`")
            && russian.contains("убери её из настроек проекта") && russian.contains("песочницей Codex"))
}

/// The name a mediated command matches, shared by the inventory and the settings proposal review.
@Test func commandHeadIsTheExecutableNameOfATrustedCommand() {
    #expect(ExternalSandboxPlanner.commandHead("/usr/bin/security find-identity") == "security")
    #expect(ExternalSandboxPlanner.commandHead("  'codesign' --sign X") == "codesign")
    #expect(ExternalSandboxPlanner.commandHead("scripts/transcribe-audio") == "transcribe-audio")
    // Negative: nothing to run has no head.
    #expect(ExternalSandboxPlanner.commandHead(" \t ") == nil && ExternalSandboxPlanner.commandHead("") == nil)
}

/// Apple's `/usr/bin/git` is an `xcrun` shim that cannot start inside a mediated sandbox; the planner mediates the real binary.
@Test func mediatedGitIsTheRealBinaryNotTheXcrunShim() throws {
    let real = "/bin/sh"
    #expect(ExternalSandboxPlanner.resolveGit(found: "/usr/bin/git", homebrew: nil, locate: { _ in real }) == real)
    // Negative: another git stays as found; a missing or non-executable answer keeps the shim rather than inventing a path.
    #expect(ExternalSandboxPlanner.resolveGit(found: "/opt/homebrew/bin/git", locate: { _ in real }) == "/opt/homebrew/bin/git")
    #expect(ExternalSandboxPlanner.resolveGit(found: "/usr/bin/git", homebrew: nil, locate: { _ in nil }) == "/usr/bin/git")
    #expect(ExternalSandboxPlanner.resolveGit(found: "/usr/bin/git", homebrew: nil, locate: { _ in "/nonexistent/git" }) == "/usr/bin/git")
    #expect(ExternalSandboxPlanner.resolveGit(found: nil, locate: { _ in real }) == nil)
    #expect(ExternalSandboxPlanner.resolveGit(found: "/usr/bin/git", homebrew: real, locate: { _ in nil }) == real)
}

// MARK: - Named Keychain items (user decision 2026-11-12)

@Test func keychainItemRuleAcceptsExactNamesOnlyAndBuildsTheExactReadForms() throws {
    typealias Item = AgentPermissionProfile.KeychainItem
    #expect(try KeychainItemRule.checked(.init(service: "  my api ", account: " ")).get() == Item(service: "my api"))
    #expect(try KeychainItemRule.checked(.init(service: "svc.v2_x-y@host:443/p+q=", account: "me@example.com")).get().account == "me@example.com")
    #expect(try KeychainItemRule.checked(.init(service: "Ключ")).get().service == "Ключ")
    // Negative: empty, too long, wildcards, quotes, backslash, control characters, a leading dash, reserved services.
    #expect(KeychainItemRule.checked(.init(service: "   ")) == .failure(.empty))
    #expect(KeychainItemRule.checked(.init(service: String(repeating: "a", count: 129))) == .failure(.tooLong))
    #expect(KeychainItemRule.checked(.init(service: "ok", account: String(repeating: "a", count: 129))) == .failure(.tooLong))
    for bad in ["api*", "a?b", "a\"b", "a'b", "a\\b", "a\tb", "a\nb", "a\u{0}b", "-w", "-s", "a;b", "a|b", "$(x)", "a`b`"] {
        #expect(KeychainItemRule.checked(.init(service: bad)) == .failure(.characters), "\(bad.debugDescription)")
        #expect(KeychainItemRule.checked(.init(service: "ok", account: bad)) == .failure(.characters), "\(bad.debugDescription)")
    }
    for reserved in ["Claude Code-credentials", "claude code-credentials-1a2b3c4d", "Chrome Safe Storage", "CHROMIUM SAFE STORAGE", "Claude Safe Storage"] {
        #expect(KeychainItemRule.checked(.init(service: reserved)) == .failure(.reserved))
    }
    // Exact forms only: both orders without an account, every order of the three groups with one.
    let plain = KeychainItemRule.argumentForms(.init(service: "my api"))
    #expect(plain == [["find-generic-password", "-s", "my api", "-w"], ["find-generic-password", "-w", "-s", "my api"]])
    let withAccount = KeychainItemRule.argumentForms(.init(service: "svc", account: "me"))
    #expect(withAccount.count == 6 && Set(withAccount).count == 6)
    #expect(withAccount.allSatisfy { $0.first == "find-generic-password" && $0.count == 6 && !$0.contains("-g") })
    #expect(withAccount.contains(["find-generic-password", "-a", "me", "-s", "svc", "-w"]) && withAccount.contains(["find-generic-password", "-w", "-s", "svc", "-a", "me"]))
    // Usable: invalid dropped, duplicates merged, capped.
    let many = (1...20).map { Item(service: "s\($0)") } + [.init(service: "s1"), .init(service: "bad*")]
    #expect(KeychainItemRule.usable(many).count == KeychainItemRule.maximumPerProject)
    #expect(KeychainItemRule.usable([.init(service: " a "), .init(service: "a"), .init(service: "Chrome Safe Storage")]) == [.init(service: "a")])
}

@Test func plannerMediatesSecurityWithExactItemReadsAndChangesAuthorityWithTheList() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = []
    func plan(_ project: Project, role: String = AgentRoleID.developer, worker: String = "k") throws -> ExternalSandboxPlan {
        var input = claudeInput(root, project: project, workerID: worker)
        input.profile = AgentRoleCatalog.preset(role).profile(for: project)
        return try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    }
    // No signing, no items: no `security` at all.
    #expect(try plan(project).commands.contains { $0.name == "security" } == false)
    // Items alone: `security` is mediated with only their exact reads; no identity listing.
    project.keychainItems = [.init(service: "openai-api"), .init(service: "deepgram", account: "me"), .init(service: "bad*")]
    let items = try plan(project)
    let security = try #require(items.commands.first { $0.name == "security" })
    #expect(security.executable == "/usr/bin/security" && security.keychain && !security.network)
    let rules = try #require(security.arguments)
    #expect(rules.count == 8 && !rules.contains(.prefix(["find-identity"])))
    #expect(rules.contains(.exact(["find-generic-password", "-s", "openai-api", "-w"])))
    #expect(!rules.contains { if case .exact(let argv) = $0 { return argv.contains("bad*") }; return true })
    let commands = (items.policyDocument()["command_policies"] as! [String: Any])["commands"] as! [String: Any]
    let edge = ((commands["security"] as! [String: Any])["from"] as! [String: Any])["session"] as! [String: Any]
    let invocation = edge["invocation_policy"] as! [String: Any]
    #expect(invocation["default"] as? String == "deny")
    #expect((invocation["allow"] as! [[String: [String: [String]]]]).first == ["argv": ["exact": ["find-generic-password", "-s", "openai-api", "-w"]]])
    // Signing and items: one command, rules unioned.
    project.accessPresets = ["apple-signing"]
    let both = try #require(try plan(project).commands.first { $0.name == "security" }?.arguments)
    #expect(both.first == .prefix(["find-identity"]) && both.count == 9)
    // Launch identity: the same list keeps the authority, another list replaces it.
    let same = try plan(project, worker: "k2")
    #expect(try plan(project, worker: "k3").authority == same.authority)
    var fewer = project; fewer.keychainItems = [.init(service: "openai-api")]
    #expect(try plan(fewer).authority != same.authority)
    #expect(same.authority.contains { $0.contains("\"openai-api\"") })
    // Reader and Editor never get items: no shell sandbox, so no `security`.
    project.accessPresets = []
    for role in [AgentRoleID.reader, AgentRoleID.editor] {
        #expect(AgentRoleCatalog.preset(role).profile(for: project).commandSandbox?.keychainItems == nil)
    }
    #expect(try plan(project, role: AgentRoleID.reader).commands.contains { $0.name == "security" } == false)
    // The command sandbox switch off removes them too.
    var off = project; off.commandSandbox = false
    #expect(AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: off).commandSandbox == nil)
}

// MARK: - Narrowed mediated git and gh (user decision 2026-11-13)

/// Which sandbox nono gives an argv, with nono 0.81.0's matcher semantics (whole tokens; `prefix` from the first argument;
/// `contains` a contiguous run; deny before allow before default; the first matching intercept wins). The semantics were
/// checked with `nono why` (`narrowedGitPolicyIsAcceptedByThePinnedHelper` repeats that when the helper is present).
private enum Selection: Equatable { case refused(String), denied, route(Int), own }
private func matches(_ rule: ExternalSandboxCommand.ArgumentRule, _ argv: [String]) -> Bool {
    switch rule {
    case .exact(let tokens): return argv == tokens
    case .prefix(let tokens): return argv.starts(with: tokens)
    case .contains(let tokens):
        guard !tokens.isEmpty, tokens.count <= argv.count else { return false }
        return (0...(argv.count - tokens.count)).contains { Array(argv[$0..<$0 + tokens.count]) == tokens }
    }
}
private func select(_ command: ExternalSandboxCommand, _ argv: [String]) -> Selection {
    if let refusal = command.refusals.first(where: { matches($0.rule, argv) }) { return .refused(refusal.reason) }
    if let allowed = command.arguments, !allowed.contains(where: { matches($0, argv) }) { return .denied }
    if let index = command.routes.firstIndex(where: { $0.rules.contains { matches($0, argv) } }) { return .route(index) }
    return .own
}

private let gitFixture = ExternalSandboxPlanner.gitCommand("/opt/homebrew/bin/git", trees: ["/bin", "/opt/homebrew/libexec/git-core"],
                                                           home: "/Users/u", roots: ["/x", "/shared"])

@Test func narrowedGitSplitsKeychainFromLocalWork() throws {
    let git = gitFixture
    // Its own sandbox: no Keychain, no network, local protocols only, the identity and index variables a commit needs.
    #expect(!git.keychain && !git.network && git.arguments == nil)
    #expect(git.sandbox.environment == ExternalSandboxPlanner.gitLocalEnvironment)
    #expect(git.sandbox.setEnvironment == ["GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": "file", "HOME": "/Users/u"])
    #expect(git.sandbox.executableFiles == ["/usr/bin/false", "/usr/bin/true"] && git.sandbox.prependArguments.isEmpty)
    for name in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_EMAIL", "GIT_AUTHOR_DATE", "GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR"] {
        #expect(git.sandbox.environment!.contains(name))
    }
    let keychain = git.routes[0].sandbox, clone = git.routes[1].sandbox
    #expect(keychain.keychain && keychain.network && keychain.executableTrees == git.executableTrees && keychain.executableFiles.isEmpty)
    #expect(keychain.environment == ExternalSandboxPlanner.plainEnvironment)
    #expect(keychain.setEnvironment == ["GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": "https", "HOME": "/Users/u", "GIT_EDITOR": ":", "GIT_SEQUENCE_EDITOR": ":"])
    #expect(keychain.prependArguments == ExternalSandboxPlanner.gitKeychainPrepend)
    let prepend = keychain.prependArguments
    #expect(prepend.first == "--no-pager" && prepend.contains("core.hooksPath=/dev/null") && prepend.contains("core.fsmonitor=false") && prepend.contains("core.askPass="))
    #expect(prepend.firstIndex(of: "credential.helper=")! < prepend.firstIndex(of: "credential.helper=osxkeychain")!)
    #expect(!clone.keychain && clone.network && clone.setEnvironment["GIT_ALLOW_PROTOCOL"] == "https:file" && clone.prependArguments.isEmpty)
    // Never passed from the caller, in any git sandbox: config injection, replaced config files, programs git would run.
    let forbidden = ["GIT_*", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0",
                     "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS",
                     "GIT_PROXY_COMMAND", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR", "XDG_CONFIG_HOME"]
    for sandbox in [git.sandbox, keychain, clone] {
        #expect(Set(sandbox.environment ?? ["GIT_*"]).isDisjoint(with: forbidden))
        // The user's global config stays the one git reads: neither replaced nor switched off.
        #expect(sandbox.setEnvironment["GIT_CONFIG_GLOBAL"] == nil && sandbox.setEnvironment["GIT_CONFIG_NOSYSTEM"] == nil && sandbox.setEnvironment["HOME"] == "/Users/u")
    }
}

@Test func narrowedGitGivesTheKeychainOnlyToTheAcceptedShapes() {
    let git = gitFixture
    let keychain: [[String]] = [
        ["push"], ["push", "--dry-run", "origin", "HEAD"], ["fetch"], ["fetch", "origin"], ["ls-remote", "--refs", "origin", "x"],
        ["ls-remote", "--exit-code", "origin", "HEAD"],
        // The verification queue's own calls (`verification_snapshot.publish_plan`, `reconcile_publication`).
        ["-C", "/x", "push", "--force-with-lease=refs/heads/main:abc", "origin", "h:refs/heads/main"],
        ["-C", "/x", "ls-remote", "--refs", "origin", "refs/heads/main"], ["-C", "/shared", "fetch"]]
    for argv in keychain { #expect(select(git, argv) == .route(0), "\(argv)") }
    // Negative: local work, aliases, injected config and every other global option stay in the sandbox without Keychain.
    let local: [[String]] = [
        ["status"], ["commit", "-m", "x"], ["commit", "-m", "push"], ["rebase", "--continue"], ["-c", "alias.x=!sh", "x"],
        ["-c", "alias.x=!sh", "x", "push"], ["x", "push"], ["-c", "credential.helper=osxkeychain", "push"], ["-C", "/x", "-c", "a=b", "push"],
        ["--config-env=a=B", "push"], ["--git-dir=/y/.git", "push"], ["--work-tree", "/y", "push"], ["--exec-path=/tmp", "push"],
        ["-C", "/other", "push"], ["-C", "/x/", "push"], ["-C", "/x", "-C", "y", "push"], ["--no-pager", "push"], ["-P", "fetch"],
        ["credential-osxkeychain", "get"], ["-C", "/other", "credential", "fill"], ["worktree", "add", "--detach", "/x/w", "HEAD"],
        ["commit-tree", "t", "-p", "b"], ["update-ref", "refs/x", "h"], ["remote", "update"], ["submodule", "update"], ["Push"]]
    for argv in local { #expect(select(git, argv) == .own, "\(argv)") }
    #expect(select(git, ["clone", "https://example.invalid/r"]) == .route(1))
    #expect(select(git, ["-C", "/x", "clone", "u"]) == .route(1))
    #expect(select(git, ["-c", "a=b", "clone", "u"]) == .own)
    for argv in [["pull"], ["pull", "--rebase"], ["-C", "/x", "pull"], ["-C", "/shared", "pull", "origin"]] {
        #expect(select(git, argv) == .refused(ExternalSandboxPlanner.gitPullRefusal), "\(argv)")
    }
    for argv in [["credential", "fill"], ["credential", "approve"], ["-C", "/x", "credential", "fill"]] {
        #expect(select(git, argv) == .refused(ExternalSandboxPlanner.gitCredentialRefusal), "\(argv)")
    }
}

@Test func narrowedGitCompilesToABaseEdgeAndKeychainIntercepts() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = ["github"]
    let input = claudeInput(root, project: project, workerID: "g1")
    let plan = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    guard let git = plan.commands.first(where: { $0.name == "git" }) else { return }   // no git on this Mac: nothing to compile
    // The project root is the accepted `-C` path, canonical.
    #expect(git.routes[0].rules.contains(.prefix(["-C", plan.project, "push"])))
    #expect(git.routes[0].sandbox.setEnvironment["HOME"] == root.appendingPathComponent("home").resolvingSymlinksInPath().path)
    let policy = ((plan.policyDocument()["command_policies"] as! [String: Any])["commands"] as! [String: Any])["git"] as! [String: Any]
    #expect(policy["sandbox"] == nil)
    let edge = (policy["from"] as! [String: Any])["session"] as! [String: Any]
    let base = edge["sandbox"] as! [String: Any]
    #expect(base["keychain_access"] == nil && (base["network"] as! [String: Bool])["allow_all"] == false && base["argv_prepend"] == nil)
    let environment = base["environment"] as! [String: Any]
    #expect(!(environment["allow_vars"] as! [String]).contains("GIT_*"))
    #expect((environment["set_vars"] as! [String: String])["GIT_ALLOW_PROTOCOL"] == "file")
    #expect((base["unsafe_macos_seatbelt_rules"] as! [String]).contains("(allow process-exec* (literal \"/usr/bin/true\"))"))
    let invocation = edge["invocation_policy"] as! [String: Any]
    #expect(invocation["default"] as? String == "allow" && invocation["allow"] == nil)
    #expect((invocation["deny"] as! [[String: Any]]).contains { ($0["argv"] as? [String: [String]]) == ["prefix": ["pull"]] && $0["reason"] as? String == ExternalSandboxPlanner.gitPullRefusal })
    let intercept = policy["intercept"] as! [[String: Any]]
    #expect(intercept.count == git.routes.map(\.rules.count).reduce(0, +))
    let first = intercept[0]
    #expect((first["match"] as! [String: Any])["argv"] as? [String: [String]] == ["prefix": ["push"]])
    #expect(first["action"] as? [String: String] == ["type": "passthrough"])
    let sandbox = first["sandbox"] as! [String: Any]
    #expect(sandbox["keychain_access"] as? String == "read" && (sandbox["network"] as! [String: Bool])["allow_all"] == true)
    #expect(sandbox["argv_prepend"] as? [String] == ExternalSandboxPlanner.gitKeychainPrepend)
    #expect((sandbox["fs_write"] as! [String]) == (base["fs_write"] as! [String]))
    #expect(((sandbox["environment"] as! [String: Any])["set_vars"] as! [String: String])["GIT_ALLOW_PROTOCOL"] == "https")
    let clone = intercept.first { ($0["match"] as! [String: Any])["argv"] as? [String: [String]] == ["prefix": ["clone"]] }!["sandbox"] as! [String: Any]
    #expect(clone["keychain_access"] == nil && (clone["network"] as! [String: Bool])["allow_all"] == true)
}

@Test func narrowedGhRefusesTokensExtensionsAndAliases() {
    let gh = ExternalSandboxPlanner.ghCommand("/opt/homebrew/bin/gh", home: "/Users/u")
    #expect(gh.keychain && gh.network && gh.routes.isEmpty)
    #expect(gh.sandbox.environment == ExternalSandboxPlanner.plainEnvironment)
    #expect(gh.sandbox.setEnvironment == ["HOME": "/Users/u", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0"])
    for name in ["GH_HOST", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_*", "GIT_*", "PAGER", "EDITOR", "BROWSER"] {
        #expect(!gh.sandbox.environment!.contains(name))
    }
    for argv in [["pr", "list"], ["pr", "view", "1", "--json", "title"], ["api", "repos/a/b"], ["run", "list"], ["repo", "view"],
                 ["issue", "list"], ["release", "list"], ["auth", "status"], ["auth", "status", "--active"], ["--version"]] {
        #expect(select(gh, argv) == .own, "\(argv)")
    }
    for argv in [["auth", "token"], ["auth", "status", "--show-token"], ["auth", "git-credential", "get"], ["extension", "install", "x"],
                 ["ext", "list"], ["extensions"], ["alias", "set", "x", "!sh"], ["config", "set", "editor", "x"], ["pr", "list", "--show-token"]] {
        #expect(select(gh, argv) == .refused(ExternalSandboxPlanner.ghRefusal), "\(argv)")
    }
    // Default deny: other auth forms, config reads, extensions and aliases run by name, codespaces.
    for argv in [["auth", "status", "-t"], ["auth", "login"], ["auth", "setup-git"], ["auth", "refresh"], ["config", "get", "editor"],
                 ["my-extension"], ["x"], ["codespace", "ssh"], ["gist", "create", "f"], []] {
        #expect(select(gh, argv) == .denied, "\(argv)")
    }
}

@Test func gitNarrowingSwitchRestoresThePreviousPolicyAndKeysTheAuthority() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = ["github"]
    #expect(ExternalSandboxPlanner.gitNarrowingOffKey == "ExternalBoundaryGitNarrowingOff")
    func plan(_ worker: String, narrow: Bool = true, project: Project) throws -> ExternalSandboxPlan {
        var input = claudeInput(root, project: project, workerID: worker); input.narrowGit = narrow
        return try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    }
    let on = try plan("s1", project: project), off = try plan("s2", narrow: false, project: project)
    guard let legacy = off.commands.first(where: { $0.name == "git" }) else { return }
    // Off: one sandbox with Keychain and network, the caller's `GIT_*`, no argument policy (the policy before 2026-11-13).
    #expect(legacy.keychain && legacy.network && legacy.routes.isEmpty && legacy.refusals.isEmpty && legacy.arguments == nil && legacy.sandbox.environment == nil)
    let policy = ((off.policyDocument()["command_policies"] as! [String: Any])["commands"] as! [String: Any])["git"] as! [String: Any]
    #expect(policy["intercept"] == nil && policy["from"] == nil)
    #expect((((policy["sandbox"] as! [String: Any])["environment"] as! [String: Any])["allow_vars"] as! [String]).contains("GIT_*"))
    if let gh = off.commands.first(where: { $0.name == "gh" }) { #expect(gh.arguments == nil && gh.refusals.isEmpty) }
    // Launch identity: the switch, a route and its prepended config are part of it; equal settings keep it.
    #expect(on.authority != off.authority)
    #expect(try plan("s3", project: project).authority == on.authority)
    #expect(try plan("s4", narrow: false, project: project).authority == off.authority)
    let line = try #require(on.authority.first { $0.hasPrefix("command git ") })
    #expect(line.contains("keychain=false network=false") && line.contains("route[keychain=true network=true") && line.contains("core.hooksPath=/dev/null"))
    #expect(line.contains("deny=prefix \"pull\"") && !line.contains(ExternalSandboxPlanner.gitPullRefusal))
    #expect(!on.authority.contains { $0.contains(on.worker.path) })
    // Another folder adds its `-C` routes, so the authority changes with it.
    let shared = root.appendingPathComponent("shared")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    var wider = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)
    wider.filesystem = .project(extraRoots: [.init(path: shared.path, writable: true)])
    var input = claudeInput(root, project: project, workerID: "s5"); input.profile = wider
    let widened = try ExternalSandboxPlanner.plan(input, helper: .success(helper)).get()
    #expect(widened.authority != on.authority)
    #expect(widened.commands.first { $0.name == "git" }!.routes[0].rules.contains(.prefix(["-C", shared.resolvingSymlinksInPath().path, "fetch"])))
}

/// Codex plans git and gh through the same planner path as Claude (invariant 14).
@Test func codexGetsTheSameNarrowedGitAndGh() throws {
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = ["github"]
    let profile = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)
    var codex = CodexIntegration.boundaryInput(project: project.path, profile: profile, root: root, inbox: root.appendingPathComponent("inbox"))
    codex.home = root.appendingPathComponent("home")
    let codexPlan = try ExternalSandboxPlanner.plan(codex, helper: .success(helper)).get()
    let claudePlan = try ExternalSandboxPlanner.plan(claudeInput(root, project: project, workerID: "cx"), helper: .success(helper)).get()
    for name in ["git", "gh"] {
        #expect(codexPlan.commands.first { $0.name == name } == claudePlan.commands.first { $0.name == name })
    }
    #expect(codexPlan.commands.first { $0.name == "git" }.map { !$0.routes.isEmpty } ?? true)
}

/// The emitted document is accepted by the pinned helper and its argument rules behave as the tests above assume. Runs when
/// `.build/nono/nono` exists in this checkout or the main checkout (worktrees); the profile goes on stdin, no file is written.
@Test func narrowedGitPolicyIsAcceptedByThePinnedHelper() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [package, package.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        .map { $0.appendingPathComponent(".build/nono/nono").path }
    guard let nono = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    func run(_ arguments: [String], _ document: [String: Any]) throws -> (Int32, String) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: nono); process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: document)); try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
    let root = try fixtureProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try helperFromFixture()
    var project = Project(path: root.appendingPathComponent("project").path)
    project.accessPresets = ["github"]
    let plan = try ExternalSandboxPlanner.plan(claudeInput(root, project: project, workerID: "n1"), helper: .success(helper)).get()
    let document = plan.policyDocument()
    let (code, text) = try run(["profile", "validate", "/dev/stdin"], document)
    #expect(code == 0 && text.contains("Result: valid"), "\(text)")
    // The keychain grant is seen in the intercepts only, never on git's own edge.
    #expect(text.contains("from.intercept[0].sandbox is granted the login keychain") && !text.contains("'git' from.session is granted the login keychain"))
    func why(_ document: [String: Any], _ name: String, _ argv: [String]) throws -> String {
        let (_, out) = try run(["why", "--json", "--profile", "/dev/stdin", "--command", name, "--"] + argv, document)
        return ((try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any])?["status"] as? String ?? out
    }
    guard let git = plan.commands.first(where: { $0.name == "git" }) else { return }
    // Refusals through nono's own invocation policy.
    #expect(try why(document, "git", ["pull"]) == "denied" && why(document, "git", ["credential", "fill"]) == "denied")
    #expect(try why(document, "git", ["push"]) == "allowed" && why(document, "git", ["status"]) == "allowed")
    // Routing: nono's `why` does not report intercepts, so each route's matchers are replayed as an allow-list (the same
    // matcher shapes) and compared with the selection the other tests assume.
    let commands = (document["command_policies"] as! [String: Any])["commands"] as! [String: Any]
    var mirror = commands["git"] as! [String: Any]
    mirror["intercept"] = nil
    let samples: [[String]] = [["push"], ["-C", plan.project, "push", "--force-with-lease=a:b", "origin", "h:r"], ["ls-remote", "--refs", "origin", "x"],
                               ["status"], ["commit", "-m", "x"], ["rebase", "--continue"], ["-c", "alias.x=!sh", "x"], ["-c", "alias.x=!sh", "x", "push"],
                               ["credential", "fill"], ["-C", "/other", "push"], ["clone", "u"], ["commit", "-m", "push"]]
    for (index, route) in git.routes.enumerated() {
        var edge = (mirror["from"] as! [String: Any])["session"] as! [String: Any]
        edge["invocation_policy"] = ["default": "deny", "allow": route.rules.map { ["argv": $0.matcherForTests] }] as [String: Any]
        mirror["from"] = ["session": edge]
        var replay = document; replay["command_policies"] = ["executable_dirs": [String](), "commands": ["git": mirror]] as [String: Any]
        for argv in samples {
            let expected = select(git, argv)
            let matched = try why(replay, "git", argv) == "allowed"
            if case .refused = expected { continue }
            #expect(matched == (expected == .route(index)), "\(argv) route \(index)")
        }
    }
    if let gh = plan.commands.first(where: { $0.name == "gh" }) {
        for argv in [["auth", "token"], ["auth", "status", "-t"], ["extension", "list"], ["my-extension"], ["pr", "list"], ["auth", "status"]] {
            let expected = select(gh, argv)
            #expect(try why(document, "gh", argv) == (expected == .own ? "allowed" : "denied"), "\(argv)")
        }
    }
}
private extension ExternalSandboxCommand.ArgumentRule {
    var matcherForTests: [String: [String]] {
        switch self {
        case .exact(let argv): ["exact": argv]
        case .prefix(let argv): ["prefix": argv]
        case .contains(let argv): ["contains": argv]
        }
    }
}
