import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDesk

/// Row menus and VoiceOver moves are built when asked for, and still list the same items.
@Test @MainActor func sidebarRowMenusAndVoiceOverMovesAreBuiltOnDemand() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = Project(path: "/tmp/sidebar-menu-fixture")
    model.state.projects = [project]
    model.projectID = project.id
    model.state.chats = ["a", "b", "c"].map { Chat(id: $0, projectID: project.id, title: $0.uppercased(), model: "") }
    let host = NSHostingView(rootView: DeskView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.orderOut(nil) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    func views<V: NSView>(_ view: NSView, _ type: V.Type) -> [V] {
        (view as? V).map { [$0] } ?? view.subviews.flatMap { views($0, type) }
    }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1))
    let rows = views(host, ChatRowView.self)
    let order = model.state.orderedChats(projectID: project.id, archived: false).map(\.id)
    let middle = try #require(rows.first { $0.chatID == order[1] })
    let titles = try #require(middle.menu(for: event)).items.map(\.title)
    for title in [L10n.text("Закрепить в избранном", "Pin to favorites"), L10n.text("Переименовать…", "Rename…"),
                  L10n.text("Удалить чат…", "Delete chat…"), L10n.text("Для агентов", "For agents")] {
        #expect(titles.contains(title))
    }
    let up = L10n.text("Переместить выше", "Move up"), down = L10n.text("Переместить ниже", "Move down")
    #expect(middle.accessibilityCustomActions()?.map(\.name) == [up, down])
    let first = try #require(rows.first { $0.chatID == order[0] })
    #expect(first.accessibilityCustomActions()?.map(\.name) == [down])
    // The VoiceOver move runs the reorder it names.
    _ = first.accessibilityCustomActions()?.first?.handler?()
    #expect(model.state.orderedChats(projectID: project.id, archived: false).map(\.id) == [order[1], order[0], order[2]])

    let header = try #require(views(host, ProjectHeaderView.self).first)
    let projectTitles = try #require(header.menu(for: event)).items.map(\.title)
    #expect(projectTitles.contains(L10n.text("Настройки проекта…", "Project settings…")))
    #expect(projectTitles.contains(L10n.text("Убрать проект из списка", "Remove project from list")))
    #expect(header.accessibilityCustomActions()?.isEmpty == true) // One project: nowhere to move.
}
