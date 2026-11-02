import Foundation
import Testing
import CryptoKit
@testable import ContextCore

private let sharedLauncher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fixture-launcher").path

/// A fake `npm` (Python): logs its arguments, then lays out `node_modules/<package>` with a `bin` like npm does. The
/// agent's command is a hard link to the shared, already-assessed fixture launcher (its script is `<path>.fixture`), so
/// no freshly written executable runs. FAKE_NPM_MODE: ok, fail, badcheck (the agent exits 1), nonode.
private let fakeNPM = """
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_NPM_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
mode = os.environ.get("FAKE_NPM_MODE", "ok")
if mode == "fail":
    print("npm ERR! code E404", file=sys.stderr); sys.exit(1)
if mode == "nonode":
    print("env: node: No such file or directory", file=sys.stderr); sys.exit(127)
prefix = args[args.index("--prefix") + 1]
name, version = args[-1].rsplit("@", 1)
binary = os.environ.get("FAKE_NPM_BIN", "agent")
package = os.path.join(prefix, "node_modules", *name.split("/"))
os.makedirs(package, exist_ok=True)
with open(os.path.join(package, "package.json"), "w") as f:
    json.dump({"name": name, "version": version, "bin": {binary: "cli.js"}}, f)
bins = os.path.join(prefix, "node_modules", ".bin")
os.makedirs(bins, exist_ok=True)
command = os.path.join(bins, binary)
os.link(os.environ["FAKE_LAUNCHER"], command)
with open(command + ".fixture", "w") as f:
    f.write("#!/bin/sh\\n" + ("exit 1\\n" if mode == "badcheck" else 'echo "' + version + '"\\n'))
"""

private struct NPMFixture {
    let root: URL, npm: URL, log: URL
    init() throws {
        root = try catalogTemporaryDirectory()
        npm = root.appendingPathComponent("npm")
        log = root.appendingPathComponent("npm.log")
        try ("#!" + fixturePython + "\n" + fakeNPM).write(to: npm, atomically: true, encoding: .utf8)
        try installFixtureExecutable(at: npm)
    }
    func environment(mode: String = "ok", bin: String = "agent") -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_NPM_LOG": log.path, "FAKE_NPM_MODE": mode, "FAKE_NPM_BIN": bin, "FAKE_LAUNCHER": sharedLauncher,
         "npm_config_global": "true"]
    }
    var calls: [[String]] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]
        }
    }
}

private func npxEntry(_ id: String = "sample", version: String = "1.2.3", package: String = "@scope/sample-cli") -> AgentCatalogEntry {
    AgentCatalogEntry(id: id, name: "Sample", version: version, distribution: .init(npx: .init(package: package, version: version, args: ["--acp"])))
}

private func installer(_ agents: URL, npm: NPMFixture, mode: String = "ok", bin: String = "agent",
                       limits: AgentCatalogInstaller.Limits = .init(), host: CatalogHost? = nil) -> AgentCatalogInstaller {
    AgentCatalogInstaller(directory: agents, configuration: host?.configuration ?? .ephemeral, npmCandidates: [npm.npm.path],
                          environment: npm.environment(mode: mode, bin: bin), limits: limits)
}

@Test func agentCatalogNPXInstallStagesChecksAndRecords() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory()
    let record = try await installer(agents, npm: npm).install(npxEntry())
    #expect(record.version == "1.2.3")
    #expect(record.distribution == .npx)
    #expect(record.source == "@scope/sample-cli@1.2.3")
    #expect(record.checksum == .notApplicable)
    #expect(record.versionConfirmed)
    #expect(record.args == ["--acp"])
    #expect(record.command == agents.appendingPathComponent("sample/1.2.3/node_modules/.bin/agent").path)
    let call = try #require(npm.calls.first)
    #expect(Array(call.prefix(4)) == ["install", "--ignore-scripts", "--no-audit", "--no-fund"])
    #expect(!call.contains("-g") && !call.contains("--global"))
    #expect(call.last == "@scope/sample-cli@1.2.3")
    let prefix = try #require(call.firstIndex(of: "--prefix"))
    #expect(call[prefix + 1].contains("/sample/.staging-"))
    #expect(AgentCatalogInstaller.installedCommand(id: "sample", directory: agents)?.path == record.command)
    #expect(AgentCatalogInstaller.record(id: "sample", directory: agents) == record)
    let left = try FileManager.default.contentsOfDirectory(atPath: agents.appendingPathComponent("sample").path).sorted()
    #expect(left == ["1.2.3", "installed.json"])
}

@Test func agentCatalogUpdateReplacesTheOldVersionOnlyAfterTheCheckAndRollsBack() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory()
    _ = try await installer(agents, npm: npm).install(npxEntry(version: "1.2.3"))
    let newer = AgentCatalog(entries: [npxEntry(version: "1.3.0")])
    #expect(await installer(agents, npm: npm).availableUpdates(catalog: newer) == [.init(id: "sample", installed: "1.2.3", available: "1.3.0")])
    #expect(await installer(agents, npm: npm).availableUpdates(catalog: AgentCatalog(entries: [npxEntry(version: "1.2.3")])).isEmpty)

    // The new version fails its --version check: the old one stays installed and recorded, nothing is retried.
    await #expect(throws: AgentInstallFailure.self) { try await installer(agents, npm: npm, mode: "badcheck").update("sample", catalog: newer) }
    #expect(npm.calls.count == 2)
    #expect(AgentCatalogInstaller.record(id: "sample", directory: agents)?.version == "1.2.3")
    #expect(AgentCatalogInstaller.installedCommand(id: "sample", directory: agents) != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: agents.appendingPathComponent("sample").path).sorted() == ["1.2.3", "installed.json"])

    // npm itself fails: same.
    await #expect(throws: AgentInstallFailure.self) { try await installer(agents, npm: npm, mode: "fail").update("sample", catalog: newer) }
    #expect(npm.calls.count == 3)
    #expect(AgentCatalogInstaller.record(id: "sample", directory: agents)?.version == "1.2.3")

    let updated = try await installer(agents, npm: npm).update("sample", catalog: newer)
    #expect(updated.version == "1.3.0")
    #expect(try FileManager.default.contentsOfDirectory(atPath: agents.appendingPathComponent("sample").path).sorted() == ["1.3.0", "installed.json"])

    try await installer(agents, npm: npm).remove("sample")
    #expect(!FileManager.default.fileExists(atPath: agents.appendingPathComponent("sample").path))
    #expect(AgentCatalogInstaller.installedCommand(id: "sample", directory: agents) == nil)
    await #expect(throws: AgentInstallFailure.notInstalled("sample")) { try await installer(agents, npm: npm).remove("sample") }
}

@Test func agentCatalogNPXInstallReportsMissingNode() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory()
    let missing = AgentCatalogInstaller(directory: agents, npmCandidates: [agents.appendingPathComponent("none/npm").path, "relative/npm"],
                                        environment: npm.environment())
    await #expect(throws: AgentInstallFailure.nodeNotFound) { try await missing.install(npxEntry()) }
    await #expect(throws: AgentInstallFailure.nodeNotFound) { try await installer(agents, npm: npm, mode: "nonode").install(npxEntry()) }
    #expect(AgentCatalogInstaller.record(id: "sample", directory: agents) == nil)
    #expect(npm.calls.count == 1)
}

@Test func agentCatalogNPXInstallsARequestedVersionOtherThanTheCatalogs() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory()
    let record = try await installer(agents, npm: npm).install(npxEntry(version: "0.70.0"), version: "0.66.0")
    #expect(record.version == "0.66.0")
    #expect(npm.calls.first?.last == "@scope/sample-cli@0.66.0")
}

// MARK: Binary archives

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments; process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

/// `<name>.tar.gz` (or `.zip`) of a folder holding `bin/agent`, a script printing `version`, plus `extra(folder)`.
private func archive(_ name: String, version: String = "2.0.0", extra: (URL) throws -> Void = { _ in }) throws -> Data {
    let root = try catalogTemporaryDirectory(), content = root.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: content.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let agent = content.appendingPathComponent("bin/agent")
    try "#!/bin/sh\necho \"agent \(version)\"\n".write(to: agent, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
    try extra(content)
    let output = root.appendingPathComponent(name)
    if name.hasSuffix(".zip") { try run("/usr/bin/ditto", ["-c", "-k", "content", output.path], in: root) }
    else { try run("/usr/bin/tar", ["-czf", output.path, "-C", content.path, "."], in: root) }
    return try Data(contentsOf: output)
}

/// A one-member ustar archive whose member name is taken as given (for traversal attempts).
private func ustar(member: String, body: Data = Data("x".utf8)) -> Data {
    var header = Data(count: 512)
    func put(_ text: String, at offset: Int) { for (i, byte) in text.utf8.enumerated() { header[offset + i] = byte } }
    put(member, at: 0); put("0000644\0", at: 100); put("0000000\0", at: 108); put("0000000\0", at: 116)
    put(String(format: "%011o\0", body.count), at: 124); put("00000000000\0", at: 136)
    put("        ", at: 148); put("0", at: 156); put("ustar\0", at: 257); put("00", at: 263)
    let sum = header.reduce(0) { $0 + Int($1) }
    put(String(format: "%06o\0 ", sum), at: 148)
    var data = header + body + Data(count: (512 - body.count % 512) % 512)
    data += Data(count: 1024)
    return data
}

private func binaryEntry(_ host: CatalogHost, file: String, sha: String?, cmd: String = "./bin/agent", version: String = "2.0.0") -> AgentCatalogEntry {
    let target = AgentCatalogBinary(archive: host.url("/" + file), sha256: sha, cmd: cmd, args: ["acp"])
    return AgentCatalogEntry(id: "binagent", name: "Bin Agent", version: version, distribution: .init(binary: [AgentCatalog.currentPlatform: target]))
}

@Test func agentCatalogBinaryInstallVerifiesTheChecksum() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), host = CatalogHost()
    let tgz = try archive("agent.tar.gz"), zip = try archive("agent.zip")
    host.serve("/agent.tar.gz", body: tgz); host.serve("/agent.zip", body: zip)
    let tool = installer(agents, npm: npm, host: host)

    await #expect(throws: AgentInstallFailure.checksumMismatch) {
        try await tool.install(binaryEntry(host, file: "agent.tar.gz", sha: String(repeating: "0", count: 64)))
    }
    #expect(AgentCatalogInstaller.record(id: "binagent", directory: agents) == nil)
    #expect(host.requests.count == 1)

    let verified = try await tool.install(binaryEntry(host, file: "agent.tar.gz", sha: sha256(tgz)))
    #expect(verified.checksum == .verified)
    #expect(verified.distribution == .binary)
    #expect(verified.versionConfirmed)
    #expect(verified.command == agents.appendingPathComponent("binagent/2.0.0/bin/agent").path)

    let unverified = try await tool.install(binaryEntry(host, file: "agent.zip", sha: nil))
    #expect(unverified.checksum == .unverified)
    #expect(AgentCatalogInstaller.installedCommand(id: "binagent", directory: agents) != nil)
    #expect(npm.calls.isEmpty)
    // A binary install cannot pick another version.
    await #expect(throws: AgentInstallFailure.versionUnavailable("1.0.0")) {
        try await tool.install(binaryEntry(host, file: "agent.zip", sha: nil), version: "1.0.0")
    }
}

@Test func agentCatalogBinaryInstallRefusesUnsafeArchives() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), host = CatalogHost()
    let traversal = ustar(member: "../escaped.txt"), absolute = ustar(member: "/tmp/escaped-\(UUID().uuidString).txt")
    let outsideLink = try archive("link.tar.gz") { content in
        try FileManager.default.createSymbolicLink(atPath: content.appendingPathComponent("bin/escape").path, withDestinationPath: "../../../outside")
    }
    let absoluteLink = try archive("abs.tar.gz") { content in
        try FileManager.default.createSymbolicLink(atPath: content.appendingPathComponent("etc").path, withDestinationPath: "/etc")
    }
    host.serve("/traversal.tar", body: traversal); host.serve("/absolute.tar", body: absolute)
    host.serve("/link.tar.gz", body: outsideLink); host.serve("/abs.tar.gz", body: absoluteLink)
    let tool = installer(agents, npm: npm, host: host)
    for file in ["traversal.tar", "absolute.tar", "link.tar.gz", "abs.tar.gz"] {
        do {
            try await tool.install(binaryEntry(host, file: file, sha: nil))
            Issue.record("installed \(file)")
        } catch AgentInstallFailure.unsafeArchive {
        } catch { Issue.record("\(file): \(error)") }
    }
    #expect(!FileManager.default.fileExists(atPath: agents.appendingPathComponent("binagent/escaped.txt").path))
    #expect(!FileManager.default.fileExists(atPath: agents.appendingPathComponent("escaped.txt").path))
    #expect(AgentCatalogInstaller.record(id: "binagent", directory: agents) == nil)
    // Staging and downloads are gone.
    let left = (try? FileManager.default.contentsOfDirectory(atPath: agents.appendingPathComponent("binagent").path)) ?? []
    #expect(left.isEmpty)
}

@Test func agentCatalogBinaryInstallEnforcesSizeCaps() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), host = CatalogHost()
    let big = try archive("big.tar.gz") { content in
        // Incompressible, so the archive itself is large too.
        var generator = SystemRandomNumberGenerator()
        try Data((0..<64 * 1024).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: content.appendingPathComponent("payload.bin"))
    }
    host.serve("/big.tar.gz", body: big)
    var small = AgentCatalogInstaller.Limits(); small.download = 1024
    await #expect(throws: AgentInstallFailure.tooLarge) {
        try await installer(agents, npm: npm, limits: small, host: host).install(binaryEntry(host, file: "big.tar.gz", sha: nil))
    }
    var unpacked = AgentCatalogInstaller.Limits(); unpacked.extracted = 16 * 1024
    await #expect(throws: AgentInstallFailure.self) {
        try await installer(agents, npm: npm, limits: unpacked, host: host).install(binaryEntry(host, file: "big.tar.gz", sha: nil))
    }
    #expect(AgentCatalogInstaller.record(id: "binagent", directory: agents) == nil)
}

@Test func agentCatalogRawBinaryInstallUsesTheCommandName() async throws {
    let npm = try NPMFixture(), agents = try catalogTemporaryDirectory(), host = CatalogHost()
    host.serve("/agent-darwin", body: Data("#!/bin/sh\necho 3.1.0\n".utf8))
    let entry = binaryEntry(host, file: "agent-darwin", sha: nil, cmd: "./agent-darwin", version: "3.1.0")
    let record = try await installer(agents, npm: npm, host: host).install(entry)
    #expect(record.command == agents.appendingPathComponent("binagent/3.1.0/agent-darwin").path)
    #expect(record.checksum == .unverified)
}
