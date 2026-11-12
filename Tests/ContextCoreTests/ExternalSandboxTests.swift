import Foundation
import Testing
import AgentContract
import ContextCore
@_spi(NativeProtocol) import CodexAdapter

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
