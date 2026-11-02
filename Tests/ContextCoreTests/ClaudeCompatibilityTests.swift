@testable import ClaudeAdapter
import ContextCore
import Foundation
import Testing

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
