@testable import ClaudeAdapter
import ContextCore
import AgentContract
import Foundation
import Testing

/// Version policy at connect: the pinned build is verified, another 2.1.x connects as unverified, others are rejected.
@Test(arguments: [("2.1.292", true as Bool?), ("2.1.316", false), ("2.2.0", nil), ("0.0.0", nil)])
func claudeAdapterAppliesTheVersionPolicyAtConnect(version: String, verified: Bool?) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys,json
    if '--version' in sys.argv: print('VERSION (Claude Code)'); sys.exit(0)
    if sys.argv[1:3] == ['auth','status']: print(json.dumps({'loggedIn':False})); sys.exit(0)
    sys.exit(3)
    """#.replacingOccurrences(of: "VERSION", with: version).utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let integration = ClaudeIntegration(browserRoot: root.appendingPathComponent("browser"))
    let result = await integration.connect(.init(executable: executable, home: root.appendingPathComponent("home")))
    switch (result, verified) {
    case (.success(let descriptor), .some(let verified)):
        #expect(descriptor.engine?.version == version)
        #expect(descriptor.engine?.verified == verified)
        #expect(descriptor.engine?.nearestVerified == (verified ? nil : ClaudeRuntime.pinnedVersion))
    case (.rejected(.incompatibleContract), nil):
        if case .unavailable = await integration.descriptor() {} else { Issue.record("Rejected connection left usable") }
    default: Issue.record("Unexpected result for \(version)")
    }
    await integration.disconnect()
}

/// Explicit opt-in (`SWITCHBOARD_CLAUDE_COMPATIBILITY_LIVE=1`, run by scripts/compat-check.py for a newly installed
/// version): the installed CLI in a fresh, signed-out `CLAUDE_CONFIG_DIR` answers `--version` and a stream-json
/// `initialize`, the same handshake the usage probe uses. No user message is sent, so there is no model request;
/// no tools, settings, MCP servers or sessions are loaded or persisted. Verified 2026-11-02 on 2.1.292: about 0.3 s,
/// no sign-in or network needed.
@Test func installedClaudeHandshakeWithoutInference() async throws {
    guard ProcessInfo.processInfo.environment["SWITCHBOARD_CLAUDE_COMPATIBILITY_LIVE"] == "1" else { return }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-compat-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = try ClaudeJobRunner.executable()
    let (code, output) = try await ClaudeProfile.command(executable: executable, home: home, arguments: ["--version"])
    #expect(code == 0)
    let version = try #require(ClaudeProtocolSurface.version(fromVersionOutput: String(decoding: output, as: UTF8.self)))
    print("CLAUDE VERSION: \(version)")

    var environment = ClaudeProfile.environment(home: home)
    environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    let wire = ClaudeWire()
    try await wire.start(executable: executable, arguments: ClaudeLimits.arguments, environment: environment, cwd: home)
    let frames = Task {
        var seen: [JSONValue] = []
        for await frame in wire.frames { seen.append(frame) }
        return seen
    }
    do {
        let response = try await wire.control(.object(["subtype": .string("initialize"), "hooks": .null]))
        // Keys the app relies on after initialize stay present.
        #expect(response["commands"] != .null || response["models"] != .null)
    } catch {
        await wire.close(); throw error
    }
    await wire.close()
    let drift = (await frames.value).flatMap(ClaudeProtocolSurface.drift).map { "\($0.0.rawValue) \($0.1)" }
    #expect(drift == [], "Frames this adapter does not know at handshake")
}
