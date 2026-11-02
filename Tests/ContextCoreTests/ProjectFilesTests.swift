import Foundation
import Testing
import ContextCore

@Test func projectTreePutsFoldersFirstInFinderOrderAndExpandsOnRequest() {
    let tree = ProjectFiles.tree(["b.txt", "Sources/App/main.swift", "a10.txt", "a2.txt", "Sources/Core.swift", "README.md"])
    #expect(tree.map(\.name) == ["Sources", "a2.txt", "a10.txt", "b.txt", "README.md"])
    #expect(tree[0].children?.map(\.path) == ["Sources/App", "Sources/Core.swift"])
    #expect(tree[1].isFolder == false)

    #expect(ProjectFiles.rows(tree, expanded: []).count == 5)
    let open = ProjectFiles.rows(tree, expanded: ["Sources", "Sources/App"])
    #expect(open.map(\.id).prefix(4) == ["Sources", "Sources/App", "Sources/App/main.swift", "Sources/Core.swift"])
    #expect(open.map(\.depth).prefix(4) == [0, 1, 2, 1])
    // A collapsed parent hides an expanded child.
    #expect(ProjectFiles.rows(tree, expanded: ["Sources/App"]).count == 5)
    #expect(ProjectFiles.ancestors(of: "Sources/App/main.swift") == ["Sources", "Sources/App"])
    #expect(ProjectFiles.ancestors(of: "README.md") == [])
}

@Test func projectFileSearchMatchesEveryWordAndRanksFileNamesFirst() {
    let paths = ["Sources/DeskView.swift", "Sources/View/Desk.swift", "Docs/desk-notes.md", "Tests/DeskViewTests.swift", "other.txt"]
    #expect(ProjectFiles.search("deskview", in: paths) == ["Sources/DeskView.swift", "Tests/DeskViewTests.swift"])
    #expect(ProjectFiles.search("desk", in: paths).first == "Sources/View/Desk.swift")
    #expect(ProjectFiles.search("view desk", in: paths).count == 3)
    #expect(ProjectFiles.search("  ", in: paths).isEmpty)
    #expect(ProjectFiles.search("swift", in: paths, limit: 2).count == 2)
}

@Test func projectFilesListGitFilesWithoutIgnoredOrDeletedOnes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-files-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    for (name, text) in [(".gitignore", "build/\n"), ("src/a.swift", "a"), ("gone.txt", "g"), ("new.txt", "n")] {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
    try "x".write(to: root.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)
    let git = GitRunner(timeout: 15)
    for arguments in [["init", "-q"], ["add", ".gitignore", "src/a.swift", "gone.txt"],
                      ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
        #expect(try await git.run(arguments, in: root.path).succeeded)
    }
    try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))

    let listing = try await ProjectFiles.list(root: root.path, git: git)
    #expect(Set(listing.paths) == [".gitignore", "src/a.swift", "new.txt"])
    #expect(listing.truncated == false)
    let capped = try await ProjectFiles.list(root: root.path, git: git, limit: 2)
    #expect(capped.paths.count == 2 && capped.truncated)
}

@Test func projectFilesWalkAFolderOutsideGitSkippingHiddenAndBuildFolders() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-walk-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in ["docs", "node_modules/pkg", ".hidden"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    for name in ["docs/a.md", "node_modules/pkg/index.js", ".hidden/x", ".env", "top.txt"] {
        try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    // No git binary: the walk is the only source.
    let listing = try await ProjectFiles.list(root: root.path, git: GitRunner(executable: "/nonexistent/git"))
    #expect(Set(listing.paths) == ["docs/a.md", "top.txt"])
}

@Test func projectFilesRefuseTheHomeFolderAndTheDiskRoot() async {
    await #expect(throws: ProjectFiles.Failure.tooBroad) {
        try await ProjectFiles.list(root: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    await #expect(throws: ProjectFiles.Failure.tooBroad) { try await ProjectFiles.list(root: "/") }
}
