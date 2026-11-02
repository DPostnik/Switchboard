import Foundation
import Testing
import ContextCore

private func editor(_ id: String) -> ExternalEditor { ExternalEditors.known.first { $0.id == id }! }

@Test func editorArgumentsOpenTheFileAtItsLineInTheProjectWindow() {
    #expect(ExternalEditors.arguments(for: editor("vscode"), file: "/p/a.swift", line: 12, column: 3, folder: "/p")
        == ["/p", "--goto", "/p/a.swift:12:3"])
    #expect(ExternalEditors.arguments(for: editor("vscode"), file: "/p/a.swift") == ["/p/a.swift"])
    #expect(ExternalEditors.arguments(for: editor("cursor"), file: "/p/a.swift", line: 4)
        == ["--classic", "--goto", "/p/a.swift:4"])
    #expect(ExternalEditors.arguments(for: editor("zed"), file: "/p/a.swift", line: 4, folder: "/p") == ["/p", "/p/a.swift:4"])
    #expect(ExternalEditors.arguments(for: editor("xcode"), file: "/p/a.swift", line: 4, column: 2) == ["--line", "4", "/p/a.swift"])
    // JetBrains columns count from 0.
    #expect(ExternalEditors.arguments(for: editor("idea"), file: "/p/A.kt", line: 4, column: 2)
        == ["--line", "4", "--column", "1", "/p/A.kt"])
    #expect(ExternalEditors.arguments(for: editor("sublime"), file: "/p/a.py", line: 9) == ["/p/a.py:9"])
    // A column without a line is meaningless; lines below 1 are clamped.
    #expect(ExternalEditors.arguments(for: editor("vscode"), file: "/p/a.swift", line: nil, column: 5) == ["/p/a.swift"])
    #expect(ExternalEditors.arguments(for: editor("vscode"), file: "/p/a.swift", line: 0) == ["--goto", "/p/a.swift:1"])
    // A folder alone opens as a workspace.
    #expect(ExternalEditors.arguments(for: editor("vscode"), file: nil, folder: "/p") == ["/p"])
    #expect(ExternalEditors.arguments(for: editor("cursor"), file: nil, folder: "/p") == ["--classic", "/p"])
}

@Test func installedEditorsFollowTheKnownOrderAndNeedAnExecutable() {
    let apps = ["com.microsoft.VSCode": "/Applications/Code.app", "com.todesktop.230313mzl4w4u92": "/Applications/Cursor.app",
                "dev.zed.Zed-Preview": "/Applications/Zed Preview.app"]
    let found = ExternalEditors.installed(locate: { apps[$0].map { URL(fileURLWithPath: $0) } },
                                          isExecutable: { !$0.contains("Cursor") })
    #expect(found.map(\.id) == ["vscode", "zed"])
    #expect(found[0].executable.path == "/Applications/Code.app/Contents/Resources/app/bin/code")
    #expect(found[1].executable.path == "/Applications/Zed Preview.app/Contents/MacOS/cli")

    #expect(ExternalEditors.preferred(nil, among: found)?.id == "vscode")
    #expect(ExternalEditors.preferred("zed", among: found)?.id == "zed")
    // An uninstalled choice falls back to the first editor; "system" means the default app.
    #expect(ExternalEditors.preferred("sublime", among: found)?.id == "vscode")
    #expect(ExternalEditors.preferred(ExternalEditors.systemID, among: found) == nil)
    #expect(ExternalEditors.preferred(nil, among: []) == nil)
}

@Test func editorFolderIsTheDeepestProjectHoldingTheFile() {
    let folders = ["/work/app", "/work/app/.worktrees/feature", "/work/other", "/"]
    #expect(ExternalEditors.folder(containing: "/work/app/Sources/a.swift", in: folders) == "/work/app")
    #expect(ExternalEditors.folder(containing: "/work/app/.worktrees/feature/a.swift", in: folders) == "/work/app/.worktrees/feature")
    #expect(ExternalEditors.folder(containing: "/work/application/a.swift", in: folders) == nil)
    #expect(ExternalEditors.folder(containing: "/work/app", in: folders) == nil)
}

@Test func editorEnvironmentLeavesTheAppsAgentProfilesOut() {
    let environment = ExternalEditors.environment(["PATH": "/usr/bin", "HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/app/claude",
                                                   "CODEX_HOME": "/app/codex", "SWITCHBOARD_CHAT_ID": "C-1", "CLAUDECODE": "1",
                                                   "ANTHROPIC_API_KEY": "k", "ELECTRON_RUN_AS_NODE": "1"])
    #expect(environment == ["PATH": "/usr/bin", "HOME": "/Users/me"])
}
