import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDesk

@Test @MainActor func sidebarChatHeightSurvivesTitleAndStatusUpdates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = Project(path: "/tmp/sidebar-layout-fixture")
    model.state.projects = [project]
    model.projectID = project.id
    model.state.chats = [Chat(id: "short", projectID: project.id, title: "Chat", model: ""),
                         Chat(id: "long", projectID: project.id, title: "Title", model: ""),
                         Chat(id: "worktree", projectID: project.id, title: "Worktree chat", model: "")]
    // A chat in its own worktree shows its branch on the same secondary line.
    model.state.chats[2].worktree = ChatWorktree(path: "/tmp/wt/sidebar/chat-abcdef", branch: "switchboard/" + String(repeating: "long-title-slug-", count: 3))
    // The short chat last worked on another branch: its branch line must not change the row height.
    model.state.chats[0].turnBranch = "feature/" + String(repeating: "long-branch-name-", count: 4)
    model.gitStatus.setStatus(GitStatus(branch: "main", commit: "abcdef1234", changedFiles: 2), for: project.path)
    #expect(model.gitStatus.branchChange(for: model.state.chats[0], projectPath: project.path) != nil)
    let host = NSHostingView(rootView: DeskView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.orderOut(nil) }
    func rows(_ view: NSView) -> [ChatRowView] {
        (view as? ChatRowView).map { [$0] } ?? view.subviews.flatMap { rows($0) }
    }
    func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    for title in [String(repeating: "Длинное название чата ", count: 8),
                  String(repeating: "Long conversation title ", count: 8)] {
        model.state.chats[1].title = title
        settle()
        let short = try #require(rows(host).first { $0.chatID == "short" })
        let long = try #require(rows(host).first { $0.chatID == "long" })
        let worktree = try #require(rows(host).first { $0.chatID == "worktree" })
        let height = long.frame.height
        #expect(abs(height - 40) < 1)
        #expect(abs(short.frame.height - height) < 1)
        #expect(abs(worktree.frame.height - height) < 1)
        #expect(worktree.toolTip?.contains("/tmp/wt/sidebar/chat-abcdef") == true)
        for index in 0..<6 {
            model.state.chats[1].unreadCompletionID = index.isMultiple(of: 2) ? "response" : nil
            model.showingJobs = index.isMultiple(of: 2)
            window.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 900 : 1100, height: 700))
            settle()
            #expect(abs(long.frame.height - height) < 1)
            #expect(abs(short.frame.height - height) < 1)
            #expect(long.accessibilityLabel() == title)
            #expect(long.hitTest(NSPoint(x: long.frame.midX, y: long.frame.midY)) === long)
        }
    }
}
