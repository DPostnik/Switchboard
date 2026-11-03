import AppKit
import ContextCore
import ContextTranscript
import SwiftUI
import Testing
@testable import ContextDesk

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_PROJECT_RENDER_DIR"] != nil))
@MainActor func projectVisibilityRenderProbe() throws {
    let language = ProcessInfo.processInfo.environment["SWITCHBOARD_PROJECT_RENDER_LANGUAGE"] ?? "ru"
    UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: language], forName: UserDefaults.argumentDomain)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let hidden = model.state.addProject(path: "/tmp/HiddenProject")
    let visible = model.state.addProject(path: "/tmp/ExampleProject")
    var chat = Chat(id: "hidden-chat", projectID: hidden, title: "Hidden favorite", model: "")
    chat.pinned = true
    model.state.chats = [chat]
    model.state.hideProject(hidden)
    model.selectProject(visible)
    let host = NSHostingView(rootView: DeskView(model: model).environment(\.locale, L10n.locale).preferredColorScheme(.light))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.orderOut(nil) }
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    func headers(_ view: NSView) -> [ProjectHeaderView] {
        (view as? ProjectHeaderView).map { [$0] } ?? view.subviews.flatMap { headers($0) }
    }
    #expect(headers(host).map(\.projectID) == [visible])
    #expect(L10n.language.rawValue == language)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHBOARD_PROJECT_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("projects-\(language).png"))
    try projectContextMenuRemovesThroughItsCallback()
}

@Test func hiddenProjectsRestoreIdentityPermissionsAndChatsAfterReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("keep.txt")
    try Data("project files".utf8).write(to: marker)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    var state = SavedState()
    let id = state.addProject(path: root.path)
    state.projects[0].accessMode = .fullAccess
    state.chats = [Chat(id: "saved-chat", projectID: id, title: "Keep", model: "model")]
    state.chats[0].pinned = true
    state.queuedMessages = [.init(id: "queued", threadID: "saved-chat", projectID: id, text: "Keep", model: "model", effort: "high")]
    let chats = state.chats, queue = state.queuedMessages
    let legacy = try JSONEncoder().encode(state)
    #expect(!String(decoding: legacy, as: UTF8.self).contains("hidden"))
    #expect(try JSONDecoder().decode(SavedState.self, from: legacy).visibleProjects.count == 1)
    let hidden = state.hideProject(id)
    let repeated = state.hideProject(id)
    let unknown = state.hideProject(UUID())
    #expect(hidden && !repeated && !unknown)
    let file = root.appendingPathComponent("metadata.sqlite")
    try await AppStore(file: file).save(state)
    var restored = try await AppStore(file: file).load()
    #expect(restored.visibleProjects.isEmpty)
    #expect(restored.visiblePinnedChats.isEmpty)
    #expect(restored.chats == chats)
    #expect(restored.queuedMessages == queue)
    #expect(restored.projects[0].accessMode == .fullAccess)
    let fromAlias = restored.addProject(path: alias.path)
    let fromPath = restored.addProject(path: root.path)
    #expect(fromAlias == id && fromPath == id)
    #expect(restored.projects.count == 1)
    #expect(restored.visibleProjects.map(\.id) == [id])
    #expect(restored.visiblePinnedChats == chats)
    try await AppStore(file: file).save(restored)
    #expect(try await AppStore(file: file).load().visibleProjects.map(\.id) == [id])
    #expect(try String(contentsOf: marker, encoding: .utf8) == "project files")
}

@Test @MainActor func removingSelectedProjectSelectsVisibleFallbackAndKeepsDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("metadata.sqlite"))
    let model = DeskModel(store: store, pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let a = model.state.addProject(path: root.appendingPathComponent("a").path)
    let b = model.state.addProject(path: root.appendingPathComponent("b").path)
    let c = model.state.addProject(path: root.appendingPathComponent("c").path)
    model.selectProject(a)
    model.draft = "Keep project draft"
    await model.hideProject(b)
    #expect(model.projectID == a && model.draft == "Keep project draft")
    model.state.chats = [Chat(id: "chat", projectID: a, title: "Chat", model: "")]
    model.chatID = "chat"
    model.draft = "Keep chat draft"
    model.loadingChat = true
    await model.hideProject(a)
    #expect(model.projectID == c)
    #expect(model.chatID == nil && !model.loadingChat && model.items.isEmpty)
    #expect(model.state.chats.count == 1)
    #expect(try await store.load().visibleProjects.map(\.id) == [c])
    await model.hideProject(c)
    #expect(model.projectID == nil && model.selectedProject == nil)
    #expect(try await store.load().visibleProjects.isEmpty)
    let restored = model.state.addProject(path: root.appendingPathComponent("a").path)
    #expect(restored == a)
    model.selectProject(a)
    #expect(model.draft == "Keep project draft")
}

@MainActor private func projectMenuActions(rename: @escaping () -> Void = {}, remove: @escaping () -> Void = {}) -> [SidebarMenuAction] {
    ProjectMenu.actions(path: "/tmp/ExampleProject", hasChats: false, settings: {}, newChat: {}, rename: rename,
                        selectAllChats: {}, remove: remove)
}

@Test @MainActor func projectContextMenuRemovesThroughItsCallback() throws {
    let view = ProjectHeaderView()
    var removed = false
    view.actions = { projectMenuActions(remove: { removed = true }) }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    let index = menu.items.count - 1
    let item = menu.items[index]
    #expect(item.title == L10n.text("Убрать проект из списка", "Remove project from list"))
    #expect(item.isEnabled)
    #expect(item.toolTip == L10n.text("Файлы и чаты сохранятся. Вернуть проект можно через «Добавить проект».", "Files and chats are kept. Restore it with Add project."))
    menu.performActionForItem(at: index)
    #expect(removed)
}

/// The "…" button and the right-click menu render the same list; reordering is by drag, not by menu items.
@Test @MainActor func projectMenuListsSettingsFirstAndRemoveLast() throws {
    let view = ProjectHeaderView()
    view.actions = { projectMenuActions() }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
        L10n.text("Настройки проекта…", "Project settings…"), L10n.text("Новый чат", "New chat"),
        L10n.text("Открыть в Finder", "Open in Finder"), EditorLauncher.openTitle, L10n.text("Скопировать путь", "Copy path"),
        L10n.text("Переименовать…", "Rename…"), L10n.text("Выделить все чаты", "Select all chats"),
        L10n.text("Убрать проект из списка", "Remove project from list"),
    ])
    #expect(menu.items.first { $0.title == L10n.text("Выделить все чаты", "Select all chats") }?.isEnabled == false)
    #expect(!menu.items.contains { $0.title == L10n.text("Переместить выше", "Move up") })
}

@Test @MainActor func chatRowMenuNestsAgentToolsInASubmenu() throws {
    let view = ChatRowView()
    var copied = 0
    view.actions = {[
        SidebarMenuAction(title: "Pin") {}, .separator,
        .submenu(L10n.text("Для агентов", "For agents"), [SidebarMenuAction(title: "Copy chat ID") { copied += 1 }]),
    ]}
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    #expect(menu.items.map(\.isSeparatorItem) == [false, true, false])
    let submenu = try #require(menu.items.last?.submenu)
    #expect(menu.items.last?.title == L10n.text("Для агентов", "For agents"))
    submenu.performActionForItem(at: 0)
    #expect(copied == 1)
}

@Test func renamingAProjectChangesOnlyItsDisplayName() {
    var state = SavedState()
    let id = state.addProject(path: "/tmp/ExampleProject")
    let path = state.projects.first?.path
    var changed = state.renameProject(id, to: "  Client work \n")
    #expect(changed)
    #expect(state.projects.first?.name == "Client work")
    #expect(state.projects.first?.path == path)
    changed = state.renameProject(id, to: "Client work")
    #expect(!changed)
    changed = state.renameProject(UUID(), to: "Other")
    #expect(!changed)
    changed = state.renameProject(id, to: "   ")
    #expect(changed)
    #expect(state.projects.first?.name == "ExampleProject")
    state.hideProject(id)
    state.renameProject(id, to: "Kept")
    let restored = state.addProject(path: "/tmp/ExampleProject")
    #expect(restored == id)
    #expect(state.projects.first?.name == "Kept") // Re-adding restores the custom name.
}

@Test @MainActor func projectHeaderMenuOffersRename() throws {
    let view = ProjectHeaderView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
    var renamed = 0
    view.actions = { projectMenuActions(rename: { renamed += 1 }) }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    let item = try #require(menu.items.first { $0.title == L10n.text("Переименовать…", "Rename…") })
    #expect(item.isEnabled)
    _ = (item.target as? NSObject)?.perform(item.action)
    #expect(renamed == 1)
}
