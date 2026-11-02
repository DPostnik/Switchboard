import AppKit
import ContextCore
import ClaudeAdapter
import SwiftUI
import Testing
@testable import ContextDesk

/// Opt-in visual probe: renders the composer with the Claude selector in the requested language.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_CLAUDE_MODEL_RENDER_DIR"] != nil))
@MainActor func claudeModelSelectorRenderProbe() throws {
    let language = ProcessInfo.processInfo.environment["SWITCHBOARD_CLAUDE_MODEL_RENDER_LANGUAGE"] ?? "ru"
    UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: language], forName: UserDefaults.argumentDomain)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = model.state.addProject(path: "/tmp/ExampleProject")
    model.state.defaultConnection = .appClaude
    // Mirrors the real saved state: a legacy blank model and no effort chosen yet.
    model.state.claudeModel = ""
    model.state.claudeEffort = nil
    model.selectProject(project)
    #expect(model.currentAgent == .appClaude)
    #expect(ClaudeModel.title(for: model.currentModel) == "Opus 5.5")
    #expect(ClaudeModel.requirementNote(for: model.currentModel) == nil)
    #expect(model.claudeEffort == "medium")
    let host = NSHostingView(rootView: DeskView(model: model).environment(\.locale, L10n.locale).preferredColorScheme(.light))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.orderOut(nil) }
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    #expect(L10n.language.rawValue == language)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHBOARD_CLAUDE_MODEL_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: folder.appendingPathComponent("claude-model-\(language).png"))
}

/// Selecting a catalog model writes the identifier the adapter passes to the CLI, and a value
/// outside the catalog is preserved exactly as configured.
@Test @MainActor func claudeModelSelectionPersistsTheConfiguredIdentifier() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = model.state.addProject(path: "/tmp/ExampleProject")
    model.state.defaultConnection = .appClaude
    model.selectProject(project)
    #expect(model.currentModel == "claude-opus-5-5")

    model.selectCurrentModel("claude-sonnet-5-5")
    #expect(model.state.claudeModel == "claude-sonnet-5-5")
    #expect(ClaudeModel.title(for: model.currentModel) == "Sonnet 5.5")
    #expect(model.state.model.isEmpty || model.state.model != "claude-sonnet-5-5")

    model.selectCurrentModel("claude-future-9")
    #expect(model.currentModel == "claude-future-9")
    #expect(ClaudeModel.title(for: model.currentModel) == "claude-future-9")

    // A blank value (the legacy empty field) means the app default, not the CLI's own choice.
    model.selectCurrentModel("")
    #expect(model.state.claudeModel == "")
    #expect(model.currentModel == "claude-opus-5-5")
}

/// Claude keeps its own effort: selecting one must not disturb the Codex default, and only a
/// documented level is stored.
@Test @MainActor func claudeEffortPersistsSeparatelyFromCodex() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = model.state.addProject(path: "/tmp/ExampleProject")
    model.state.defaultConnection = .appClaude
    model.selectProject(project)
    #expect(model.claudeEffort == "medium")
    #expect(model.effort == "medium")

    model.selectClaudeEffort("low")
    #expect(model.claudeEffort == "low")
    #expect(model.state.claudeEffort == "low")
    #expect(model.effort == "medium")

    model.selectClaudeEffort("ultra")
    #expect(model.claudeEffort == "low")

    model.selectClaudeEffort("")
    #expect(model.claudeEffort == "medium")
}

/// The user's real state before this change: a legacy blank model and no effort. Both must
/// resolve to Opus 5.5 at medium, and a new chat must store them explicitly.
@Test @MainActor func claudeDefaultsApplyToLegacyBlankState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = model.state.addProject(path: "/tmp/ExampleProject")
    model.state.defaultConnection = .appClaude
    model.state.claudeModel = ""
    model.state.claudeEffort = nil
    model.selectProject(project)
    #expect(model.currentModel == ClaudeModel.defaultID)
    #expect(model.claudeEffort == ClaudeEffort.defaultLevel.rawValue)
    #expect(model.effort == "medium")

    // An explicit choice still wins over the default.
    model.selectCurrentModel("claude-haiku-4-5")
    model.selectClaudeEffort("low")
    #expect(model.currentModel == "claude-haiku-4-5")
    #expect(model.claudeEffort == "low")
}
