@testable import CodexAdapter
import Foundation
import Testing
@testable import ContextCore

@Test(arguments: [
    "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "ChatGPT.app/Contents/Resources/codex",
    "Codex.app/Contents/Resources/codex"
]) func discoversDesktopCodexLayouts(relativePath: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    #expect(try Locations.codexExecutable(applicationDirectories: [folder.path], path: "") == executable)
}

@Test func discoverySkipsInvalidBundleCandidates() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let resources = folder.appendingPathComponent("ChatGPT.app/Contents/Resources")
    let nested = resources.appendingPathComponent("codex-cli/CodexCLI.app/Contents/MacOS/codex")
    // An executable directory is not a runnable CLI.
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let legacy = resources.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: legacy)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path)
    #expect(try Locations.codexExecutable(applicationDirectories: [folder.path], path: "") == legacy)
    let managed = folder.appendingPathComponent("managed-codex")
    try FileManager.default.copyItem(at: legacy, to: managed)
    #expect(try Locations.codexExecutable(applicationDirectories: [folder.path], path: "", managedExecutable: managed.path) == managed)
    try FileManager.default.removeItem(at: nested)
    try Data().write(to: nested)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nested.path)
    #expect(try Locations.codexExecutable(applicationDirectories: [folder.path], path: "") == legacy)
}

@Test func discoversAbsolutePATHAndRejectsRelativePATH() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let executable = folder.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    #expect(try Locations.codexExecutable(applicationDirectories: [], path: ":relative:\(folder.path)", cliDirectories: []) == executable)
    #expect(throws: ClientFailure.self) {
        try Locations.codexExecutable(applicationDirectories: [], path: ":relative", cliDirectories: [])
    }
}
