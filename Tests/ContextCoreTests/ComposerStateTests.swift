@_spi(NativeProtocol) import CodexAdapter
import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import ContextCore
@testable import ContextTranscript
@testable import ContextDesk

@MainActor private func composerModel(_ root: URL) -> DeskModel {
    DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"),
              summaryResources: nil, jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
}

@Test @MainActor func typingInTheComposerDoesNotPublishTheModel() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = composerModel(root)
    let project = Project(path: "/tmp/composer-project")
    model.state.projects = [project]; model.projectID = project.id
    var modelChanges = 0, composerChanges = 0, menuChanges = 0
    let observers = [model.objectWillChange.sink { modelChanges += 1 },
                     model.composer.objectWillChange.sink { composerChanges += 1 },
                     model.menu.objectWillChange.sink { menuChanges += 1 }]
    defer { observers.forEach { $0.cancel() } }
    // The first character flips `hasText` and `hasMessage`; the rest of the word publishes nothing at all.
    model.composer.editorChanged("П")
    #expect(modelChanges == 0 && composerChanges == 2 && menuChanges == 0)
    #expect(model.composer.hasText && model.composer.hasMessage && model.composer.revision == 0)
    for text in ["Пр", "При", "Прив", "Приве", "Привет"] { model.composer.editorChanged(text) }
    #expect(modelChanges == 0 && composerChanges == 2)
    #expect(model.draft == "Привет" && model.composer.text == "Привет")
    // Whitespace only: text is present but nothing can be sent.
    model.composer.editorChanged("  \n")
    #expect(modelChanges == 0 && composerChanges == 3)
    #expect(model.composer.hasText && !model.composer.hasMessage)
    model.composer.editorChanged("")
    #expect(modelChanges == 0 && composerChanges == 4)
    #expect(!model.composer.hasText && !model.composer.hasMessage && model.composer.revision == 0)
    // A write from the model (prompt button, quote, restore) bumps the revision so the editor replaces its text.
    model.draft = "Объясни проект"
    #expect(modelChanges == 0 && composerChanges == 7 && model.composer.revision == 1)
    model.composer.text = "Объясни проект"
    #expect(composerChanges == 7 && model.composer.revision == 1)
}

@Test @MainActor func draftsFollowTheSelectedChatThroughTheComposer() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = composerModel(root)
    let project = Project(path: "/tmp/composer-switch-project")
    let first = Chat(id: "first", projectID: project.id, title: "First", model: "")
    let second = Chat(id: "second", projectID: project.id, title: "Second", model: "")
    model.state.projects = [project]; model.state.chats = [first, second]
    model.selectProject(project.id)
    model.composer.editorChanged("New chat draft")
    await model.openChat(first)
    #expect(model.composer.text.isEmpty && !model.composer.hasText)
    let revision = model.composer.revision
    model.composer.editorChanged("First chat draft")
    await model.openChat(second)
    #expect(model.composer.text.isEmpty)
    model.composer.editorChanged("Second chat draft")
    await model.openChat(first)
    #expect(model.draft == "First chat draft" && model.composer.hasMessage)
    // Each switch wrote the editor's text from the model, so the editor has a new revision to apply.
    #expect(model.composer.revision > revision)
    model.newChat()
    #expect(model.composer.text == "New chat draft")
    await model.openChat(second)
    #expect(model.composer.text == "Second chat draft")
    // A chat's draft cleared in the editor stays cleared.
    model.composer.editorChanged("")
    await model.openChat(first)
    await model.openChat(second)
    #expect(model.composer.text.isEmpty)
}

@Test @MainActor func canSendAndSendReadTheComposerText() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json
    turns = 0
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if m['method'] == 'turn/start':
            turns += 1
            result = {'turn': {'id': 'v' + str(turns)}}
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    let fixtureClient = CodexClient(transport: connection)
    try await fixtureClient.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: CodexIntegration(client: fixtureClient), store: store,
                          pluginDirectory: folder.appendingPathComponent("plugins"), summaryResources: nil,
                          summaryExecutable: executable, summaryHome: folder,
                          jobStore: JobStore(file: folder.appendingPathComponent("jobs.json")))
    model.state.defaultRoute = .direct
    let project = Project(path: folder.path)
    model.state.projects = [project]; model.projectID = project.id; model.chatID = "t"
    model.state.chats = [Chat(id: "t", projectID: project.id, title: "Fixture", model: "")]
    model.connected = true; model.authenticated = true
    #expect(!model.canSend)
    model.composer.editorChanged("   ")
    #expect(!model.canSend)
    await model.send()
    #expect(model.items.isEmpty && model.composer.text == "   ")
    model.composer.editorChanged("Typed message")
    #expect(model.canSend)
    await model.send()
    #expect(model.items.map(\.text) == ["Typed message"])
    // Sending clears the editor through the composer, so the editor sees a new revision.
    #expect(model.composer.text.isEmpty && !model.composer.hasText && model.composer.revision == 1)
    #expect(!model.canSend)
    await connection.stop()
}

@Test @MainActor func appMenuStatePublishesOnlyWhenItsItemsFlip() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = composerModel(root)
    var changes = 0
    let observer = model.menu.objectWillChange.sink { changes += 1 }
    defer { observer.cancel() }
    #expect(!model.menu.ready && !model.menu.hasProject)
    let project = Project(path: "/tmp/menu-project")
    model.state.projects = [project]
    model.state.chats = [Chat(id: "a", projectID: project.id, title: "A", model: "")]
    #expect(changes == 0)
    model.projectID = project.id
    #expect(changes == 1 && model.menu.hasProject)
    model.chatID = "a"
    model.state.chats[0].title = "Renamed"
    model.composer.editorChanged("typing")
    #expect(changes == 1)
    // The selected project disappearing from the state disables New Chat.
    model.state.projects = []
    #expect(changes == 2 && !model.menu.hasProject)
    model.state.projects = [project]
    #expect(changes == 3 && model.menu.hasProject)
}

@Test @MainActor func hostedComposerFollowsModelWritesAndReportsTyping() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = composerModel(root)
    let project = Project(path: "/tmp/hosted-composer-project")
    model.state.projects = [project]; model.projectID = project.id
    model.authenticated = true
    let host = NSHostingView(rootView: ChatView(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    host.layoutSubtreeIfNeeded()
    func editors(in view: NSView) -> [ComposerTextView] {
        (view as? ComposerTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
    }
    let editor = try #require(editors(in: host).first)
    // A prompt button or a quote writes through the model; the editor shows it after the next layout.
    model.composer.text = "Объясни проект"
    host.layoutSubtreeIfNeeded()
    #expect(editor.string == "Объясни проект")
    // Typing reaches the model without publishing it.
    var modelChanges = 0
    let observer = model.objectWillChange.sink { modelChanges += 1 }
    defer { observer.cancel() }
    editor.string = "Объясни проект подробно"
    editor.didChangeText()
    #expect(model.composer.text == "Объясни проект подробно" && model.draft == "Объясни проект подробно")
    #expect(modelChanges == 0)
}
