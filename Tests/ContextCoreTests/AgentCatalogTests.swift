import Foundation
import Testing
@testable import ContextCore

let catalogFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/catalog/registry-2026-11-02.json")

@Test func agentCatalogParsesTheRealRegistryShape() throws {
    let catalog = try AgentCatalogParser.parse(Data(contentsOf: catalogFixture))
    #expect(catalog.formatVersion == "1.0.0")
    #expect(catalog.skippedEntries == 0)
    #expect(catalog.unknownFields.isEmpty)
    let gemini = try #require(catalog.entry("gemini"))
    #expect(gemini.name == "Gemini CLI")
    #expect(gemini.version == "0.66.0")
    #expect(gemini.distribution.npx == AgentCatalogPackage(package: "@google/gemini-cli", version: "0.66.0", args: ["--acp"]))
    #expect(gemini.icon?.hasPrefix("https://cdn.agentclientprotocol.com/") == true)
    let goose = try #require(catalog.entry("goose"))
    let target = try #require(goose.distribution.binary["darwin-aarch64"])
    #expect(target.cmd == "./goose")
    #expect(target.args == ["acp"])
    #expect(target.sha256?.count == 64)
    #expect(target.archive.absoluteString.hasSuffix(".tar.bz2"))
    // Binary and npx: a binary for this Mac wins, so no Node is needed.
    let kilo = try #require(catalog.entry("kilo"))
    guard case .binary = kilo.installable else { Issue.record("expected binary"); return }
    // uvx is listed but not installable.
    let fast = try #require(catalog.entry("fast-agent"))
    #expect(fast.distribution.unsupported == ["uvx"])
    #expect(fast.installable == nil)
}

@Test func agentCatalogSkipsMalformedEntriesAndCountsUnknownFields() throws {
    let json = """
    {"version": "1.0.0", "future": true, "agents": [
      {"id": "good", "name": "Good", "version": "1.2.3", "badge": "new",
       "distribution": {"npx": {"package": "good-acp@1.2.3", "args": ["--acp", 7], "flags": 1}, "cargo": {"crate": "x"}}},
      {"id": "../escape", "name": "Bad", "version": "1.0.0", "distribution": {"npx": {"package": "x"}}},
      {"id": "badversion", "name": "Bad", "version": "../../1", "distribution": {"npx": {"package": "x"}}},
      {"id": "noname", "version": "1.0.0", "distribution": {"npx": {"package": "x"}}},
      {"id": "optionpackage", "name": "Bad", "version": "1.0.0", "distribution": {"npx": {"package": "--global"}}},
      {"id": "nodist", "name": "Bad", "version": "1.0.0"},
      {"id": "mixed", "name": "Mixed", "version": "2.0.0", "distribution": {"binary": {
         "darwin-aarch64": {"archive": "https://example.com/a.tar.gz", "cmd": "./bin/a"},
         "darwin-x86_64": {"archive": "http://example.com/a.tar.gz", "cmd": "./a"},
         "linux-x86_64": {"archive": "https://example.com/a.tar.gz", "cmd": "../a"},
         "windows-x86_64": {"archive": "https://example.com/a.zip", "cmd": "a.exe", "sha256": "nothex"}}}},
      {"id": "good", "name": "Duplicate", "version": "9.9.9", "distribution": {"npx": {"package": "dup"}}},
      "not an object"
    ]}
    """
    let catalog = try AgentCatalogParser.parse(Data(json.utf8))
    #expect(catalog.entries.map(\.id) == ["good", "mixed"])
    #expect(catalog.skippedEntries == 7)
    let good = try #require(catalog.entry("good"))
    #expect(good.distribution.npx?.args == ["--acp"])
    #expect(good.distribution.unsupported == ["cargo"])
    #expect(catalog.unknownFields["document.future"] == 1)
    #expect(catalog.unknownFields["agent.badge"] == 1)
    #expect(catalog.unknownFields["npx.flags"] == 1)
    #expect(catalog.unknownFields["distribution.cargo"] == 1)
    #expect(catalog.unknownFields["binary.invalid"] == 3)
    let mixed = try #require(catalog.entry("mixed"))
    #expect(Array(mixed.distribution.binary.keys) == ["darwin-aarch64"])
    #expect(mixed.distribution.binary["darwin-aarch64"]?.sha256 == nil)
}

@Test func agentCatalogRejectsDocumentsThatAreNotCatalogs() {
    #expect(throws: AgentCatalogParser.Failure.notACatalog) { try AgentCatalogParser.parse(Data("[]".utf8)) }
    #expect(throws: AgentCatalogParser.Failure.notACatalog) { try AgentCatalogParser.parse(Data("<html>".utf8)) }
}

@Test func agentCatalogPackageSpecsAndVersionsAreSafe() {
    #expect(AgentCatalogPackage.split("@google/gemini-cli@0.66.0")! == ("@google/gemini-cli", "0.66.0"))
    #expect(AgentCatalogPackage.split("cline")! == ("cline", nil))
    #expect(AgentCatalogPackage.split("-g") == nil)
    #expect(AgentCatalogPackage.split("file:../x") == nil)
    #expect(AgentCatalogPackage.split("https://evil/x.tgz") == nil)
    #expect(AgentCatalogPackage.split("x@latest") == nil)
    #expect(AgentCatalogVersion.isNewer("0.67.0", than: "0.66.0"))
    #expect(AgentCatalogVersion.isNewer("0.66.0", than: "0.66.0-preview.1"))
    #expect(!AgentCatalogVersion.isNewer("0.66.0", than: "0.66.0"))
    #expect(!AgentCatalogVersion.isNewer("0.9.0", than: "0.66.0"))
    #expect(AgentCatalogVersion.isNewer("2026.10.22", than: "2026.9.30"))
}
