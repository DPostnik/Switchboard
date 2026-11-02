import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test @MainActor func pluginSettingsExplainMissingIdleAndSelectedPluginsInBothLanguages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("example")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"schemaVersion":1,"id":"example","title":"Example","version":"1","executable":"run","arguments":[],"titleTranslations":{"ru":"Пример","en":"Example"},"descriptionTranslations":{"ru":"Обрабатывает контекст","en":"Processes context"}}"#.utf8).write(to: folder.appendingPathComponent("plugin.json"))
    let model = DeskModel(pluginDirectory: root)
    let route = RequestRoute(rawValue: "example")
    #expect(model.routeTitle(.direct, language: .english) == "No plugin")
    #expect(model.routeTitle(.direct, language: .russian) == "Без плагина")
    #expect(model.routeTitle(route, language: .english) == "Example")
    #expect(model.routeTitle(route, language: .russian) == "Пример")
    #expect(model.routeMessage(route, language: .english) == "Installed, but not in use.")
    model.state.defaultRoute = route
    #expect(model.routeMessage(route, language: .english).contains("Apply selection"))
    #expect(model.routeMessage(route, language: .russian).contains("Применить выбор"))
    model.agentStates[.originalCodex]?.connecting = true
    #expect(model.routeMessage(route, language: .english) == "Connecting…")
    model.agentStates[.originalCodex]?.connecting = false
    try FileManager.default.removeItem(at: folder)
    model.refreshPlugins()
    #expect(model.defaultRoute == route)
    #expect(model.routeTitle(route, language: .english).contains("not installed"))
    #expect(model.routeMessage(route, language: .english).contains("preserved"))
}
