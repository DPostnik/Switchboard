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
    // Mediated commands follow the ticked presets: signing and GitHub get the Keychain, git keeps its helper trees.
    let names = plan.commands.map(\.name).sorted()
    #expect(names.contains("codesign") && names.contains("security") && names.contains("git"))
    let git = plan.commands.first { $0.name == "git" }!
    #expect(git.keychain && git.network && git.executableTrees.contains("/bin"))
    let document = plan.policyDocument()
    let policies = (document["command_policies"] as! [String: Any])["commands"] as! [String: Any]
    #expect((policies["codesign"] as! [String: Any])["allow_direct_exec_bypass"] as? [String] == ["/usr/bin/codesign"])
    #expect((policies["security"] as! [String: Any])["allow_direct_exec_bypass"] == nil)
    #expect((policies["git"] as! [String: Any])["allow_direct_exec_bypass"] == nil)
    let security = (policies["security"] as! [String: Any])["sandbox"] as! [String: Any]
    #expect(security["keychain_access"] as? String == "read" && (security["fs_write"] as! [String]).contains(canonicalProject))
    #expect((security["fs_read_file"] as! [String]).contains { $0.hasSuffix("/.gitconfig") })
    #expect((security["network"] as! [String: Bool])["allow_all"] == false)
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
