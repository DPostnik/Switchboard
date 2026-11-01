import Foundation
import Testing
@testable import ContextCore

@Test func gitRunnerReportsOutputStatusAndInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitRunner()
    #expect(try await git.run(["init", "-q", "-b", "main"], in: root.path).succeeded)
    let branch = try await git.run(["symbolic-ref", "--short", "HEAD"], in: root.path)
    #expect(branch.succeeded && branch.text == "main\n")
    // stdin reaches git; a large output drains without stalling.
    let blob = Data(String(repeating: "x", count: 300_000).utf8)
    let hash = try await git.run(["hash-object", "-w", "--stdin"], in: root.path, input: blob)
    #expect(hash.succeeded && hash.text.count == 41)
    let back = try await git.run(["cat-file", "-p", hash.text.trimmingCharacters(in: .whitespacesAndNewlines)], in: root.path)
    #expect(back.output == blob)
    let failed = try await git.run(["rev-parse", "--verify", "missing-ref"], in: root.path)
    #expect(!failed.succeeded && !failed.errors.isEmpty)
    await #expect(throws: GitRunner.Failure.self) {
        try await GitRunner(executable: "/nonexistent/git").run(["status"], in: root.path)
    }
}

@Test func gitHubRunnerUsesTheFolderAsWorkingDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GitRunner.gitHub(searchPaths: ["/nonexistent/gh"]) == nil)
    // A stand-in tool: /bin/pwd shows the working directory and receives no "-C" flag.
    let tool = try #require(GitRunner.gitHub(searchPaths: ["/bin/pwd"]))
    let result = try await tool.run([], in: root.path)
    #expect(result.succeeded && result.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(root.lastPathComponent))
}
