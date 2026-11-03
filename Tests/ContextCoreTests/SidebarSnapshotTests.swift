import AgentContract
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

/// The sidebar list renders only from `SidebarSnapshot` (`SidebarRowsList`), so every model value a row shows must be in
/// it, and publications that change none of them must leave it equal.
@MainActor @Test func sidebarSnapshotCarriesEveryRowValueAndIgnoresUnrelatedChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(pluginDirectory: root)
    let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b")
    var pinned = Chat(id: "pinned", projectID: b.id, title: "Pinned", model: ""); pinned.pinned = true
    var unread = Chat(id: "unread", projectID: b.id, title: "Unread", model: ""); unread.unreadCompletionID = "turn:unread:t"
    model.state.projects = [a, b]
    model.state.chats = [Chat(id: "one", projectID: a.id, title: "One", model: ""), Chat(id: "two", projectID: a.id, title: "Two", model: ""),
                         pinned, unread]
    let listing = SidebarListing(expanded: [a.id, b.id])
    func snapshot() -> SidebarSnapshot { model.sidebarSnapshot(listing) }
    func row(_ id: String) -> SidebarChatRow? { snapshot().projects.flatMap(\.rows).first { $0.chat.id == id } }
    func project(_ id: UUID) -> SidebarProjectRow? { snapshot().projects.first { $0.id == id } }

    #expect(snapshot().hasFavorites && snapshot().favorites.map(\.id) == ["pinned"])
    #expect(snapshot().favorites.first?.projectName == b.name && snapshot().favorites.first?.projectPath == b.path)
    #expect(row("one")?.workingDirectory == a.path && row("one")?.busy == false)
    #expect(project(b.id)?.unread == true && project(a.id)?.unread == false && project(a.id)?.hasChats == true)

    // Unrelated publications: the snapshot stays equal, so the list is not rendered again.
    let before = snapshot()
    model.error = "Something failed"; model.loadingChat = true; model.usage["one"] = UsageSnapshot(last: 3, measuredAt: Date())
    model.draftEffort = "high"; model.composer.text = "typing"
    #expect(snapshot() == before)

    // Each row value follows its source.
    let session = try #require(model.state.chats[0].nativeSession)
    await model.receive(.init(session: session, payload: .started(turn: "t")))
    #expect(row("one")?.busy == true && snapshot() != before)
    model.pending.append(PendingAction(interaction: AgentInteraction(id: UUID(), session: session, turn: "t", kind: .approval(canAllow: true),
                                                                     reason: "Run", details: "ls", canAllowTurn: false), threadID: "one"))
    #expect(row("one")?.pending == true && project(a.id)?.waiting == true)
    model.pending.removeAll()
    model.restartWaitingChatIDs = ["two"]
    #expect(row("two")?.restartWaiting == true && project(a.id)?.waiting == true)
    model.runningBrowserChats = ["two": 42]
    #expect(row("two")?.browserOpen == true)
    model.configuringBrowserChats = ["two"]
    #expect(row("two")?.changing == true)
    model.state.chats[1].title = "Renamed"
    #expect(row("two")?.chat.title == "Renamed")
    model.chatID = "two"; model.projectID = a.id
    #expect(snapshot().chatID == "two" && snapshot().projectID == a.id && !snapshot().pageOpen)
    model.showingJobs = true
    #expect(snapshot().pageOpen)
    // The listing decides expansion and the rows under each project.
    let collapsed = model.sidebarSnapshot(SidebarListing(expanded: [b.id], pageSize: 1))
    #expect(collapsed.projects.first { $0.id == a.id }?.expanded == false)
    #expect(collapsed.projects.first { $0.id == a.id }.map { ($0.limit, $0.total, $0.rows.count) } ?? (0, 0, 0) == (1, 2, 1))
}
