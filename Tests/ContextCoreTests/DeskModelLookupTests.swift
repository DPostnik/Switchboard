import Combine
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@MainActor @Test func chatAndProjectLookupsFollowStateChanges() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(pluginDirectory: root)
    let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b")
    model.state.projects = [a, b]
    model.state.chats = [Chat(id: "one", projectID: a.id, title: "One", model: ""),
                         Chat(id: "two", projectID: b.id, title: "Two", model: "")]
    #expect(model.chat("two")?.title == "Two")
    #expect(model.project(b.id) == b)
    #expect(model.chat("missing") == nil && model.project(UUID()) == nil)

    model.projectID = a.id; model.chatID = "one"
    #expect(model.selectedChat?.id == "one" && model.selectedProject == a)

    // In-place edits, inserts, removals and reorders all go through `state`'s observer.
    model.state.chats[0].title = "Renamed"
    #expect(model.selectedChat?.title == "Renamed")
    model.state.chats.insert(Chat(id: "zero", projectID: a.id, title: "Zero", model: ""), at: 0)
    #expect(model.chat("zero")?.title == "Zero" && model.chat("two")?.title == "Two" && model.chat("one")?.title == "Renamed")
    model.state.chats.removeAll { $0.id == "one" }
    #expect(model.selectedChat == nil && !model.hasChat("one") && model.chat("two")?.projectID == b.id)
    model.state.chats.reverse()
    #expect(model.chat("zero")?.title == "Zero" && model.chat("two")?.title == "Two")
    model.state.projects.removeAll { $0.id == a.id }
    #expect(model.selectedProject == nil && model.project(b.id) == b)

    // A repeated ID resolves to the first chat, as a scan did.
    model.state.chats.append(Chat(id: "two", projectID: a.id, title: "Duplicate", model: ""))
    #expect(model.chat("two")?.title == "Two")
    #expect(model.workingDirectory(forChat: "two") == "/tmp/b" && model.workingDirectory(forChat: "zero") == nil)
}

@MainActor @Test func browsersMenuFollowsRunningBrowsersAndChatTitles() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(pluginDirectory: root)
    let project = Project(path: "/tmp/browsers")
    model.state.projects = [project]
    model.state.chats = [Chat(id: "one", projectID: project.id, title: "One", model: ""),
                         Chat(id: "two", projectID: project.id, title: "Two", model: "")]
    var publications = 0
    let watch = model.browsersMenu.objectWillChange.sink { publications += 1 }
    defer { watch.cancel() }
    model.state.chats[0].title = "Still one" // No browser runs: nothing to publish.
    #expect(model.browsersMenu.entries.isEmpty && publications == 0)
    model.runningBrowserChats = ["two": 42]
    #expect(model.browsersMenu.entries == [.init(id: "two", label: "Two · browsers")])
    model.state.chats[0].title = "Other" // Not a browser chat: the rows stay, the menu is not rebuilt.
    #expect(publications == 1)
    model.state.chats[1].title = "Renamed"
    #expect(model.browsersMenu.entries.map(\.label) == ["Renamed · browsers"] && publications == 2)
    model.runningBrowserChats = [:]
    #expect(model.browsersMenu.entries.isEmpty)
}
