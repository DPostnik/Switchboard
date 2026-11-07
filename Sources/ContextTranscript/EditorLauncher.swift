import AppKit
import ContextCore
import SwiftUI
import os

/// Opens files in the user's code editor at a line: the editor chosen in Settings, or the first one installed.
/// Launch failures fall back to the default app and are logged; nothing is retried.
@MainActor public enum EditorLauncher {
    public enum Target: Equatable { case preferred, editor(ExternalEditors.Installed), defaultApp }

    /// Set by the app: project and worktree folders, so a file opens in its project's editor window.
    public static var projectFolders: () -> [String] = { [] }
    private static let log = Logger(subsystem: "local.daniil.switchboard", category: "editor")
    private static var cache: [ExternalEditors.Installed]?

    /// Editors found on this Mac, looked up once per launch until `refresh()`.
    public static var installed: [ExternalEditors.Installed] {
        if let cache { return cache }
        let found = ExternalEditors.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        cache = found
        return found
    }

    public static func refresh() { cache = nil; browserCache = nil }

    private static var browserCache: [(browser: ExternalBrowser, app: URL)]?

    /// Browsers offered for an HTML file at `path`; empty for other files.
    public static func browsers(for path: String) -> [(browser: ExternalBrowser, app: URL)] {
        ExternalEditors.isWebPage(path) ? installedBrowsers : []
    }

    public static var installedBrowsers: [(browser: ExternalBrowser, app: URL)] {
        if let browserCache { return browserCache }
        let found = ExternalEditors.installedBrowsers { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        browserCache = found
        return found
    }

    /// Opens the file as a page in `browser`; a failure is logged, not retried.
    public static func openInBrowser(_ path: String, browser: ExternalBrowser, app: URL) {
        openInBrowser(URL(fileURLWithPath: path), browser: browser, app: app)
    }

    /// Opens a file or web address in `browser`.
    public static func openInBrowser(_ url: URL, browser: ExternalBrowser, app: URL) {
        let id = browser.id
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            let log = Logger(subsystem: "local.daniil.switchboard", category: "editor")
            if let error { log.error("Browser \(id, privacy: .public) did not open a file: \(error.localizedDescription, privacy: .public)") }
            else { log.info("Opened a file in \(id, privacy: .public)") }
        }
    }

    /// "Open in Google Chrome", "Open in Safari" for AppKit menus.
    public static func browserItems(_ path: String) -> [NSMenuItem] {
        browsers(for: path).map { found in
            EditorMenuItem(title: openTitle(found.browser.title)) { openInBrowser(path, browser: found.browser, app: found.app) }
        }
    }

    public static func openTitle(_ app: String) -> String { L10n.text("Открыть в \(app)", "Open in \(app)") }

    public static var preferred: ExternalEditors.Installed? {
        ExternalEditors.preferred(UserDefaults.standard.string(forKey: ExternalEditors.preferenceKey), among: installed)
    }

    /// "Open in VS Code", or "Open in Default App" without an editor.
    public static var openTitle: String { openTitle(preferred) }

    public static func openTitle(_ editor: ExternalEditors.Installed?) -> String {
        guard let editor else { return L10n.text("Открыть в программе по умолчанию", "Open in Default App") }
        return openTitle(editor.title)
    }

    /// Opens a file at `line` (and `column`), or a folder as a workspace.
    public static func open(_ path: String, line: Int? = nil, column: Int? = nil, target: Target = .preferred) {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        let editor: ExternalEditors.Installed?
        switch target {
        case .preferred: editor = preferred
        case .editor(let chosen): editor = chosen
        case .defaultApp: editor = nil
        }
        guard exists, let editor else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path)); return
        }
        let arguments = directory.boolValue
            ? ExternalEditors.arguments(for: editor.editor, file: nil, folder: path)
            : ExternalEditors.arguments(for: editor.editor, file: path, line: line, column: column,
                                        folder: ExternalEditors.folder(containing: path, in: projectFolders()))
        launch(editor, arguments: arguments, fallback: path)
    }

    private static func launch(_ editor: ExternalEditors.Installed, arguments: [String], fallback: String) {
        let process = Process()
        process.executableURL = editor.executable
        process.arguments = arguments
        process.environment = ExternalEditors.environment(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = editor.id
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                Logger(subsystem: "local.daniil.switchboard", category: "editor")
                    .error("Editor \(id, privacy: .public) exited with \(finished.terminationStatus)")
            }
        }
        do {
            try process.run()
            log.info("Opened a file in \(id, privacy: .public)")
        } catch {
            log.error("Editor \(id, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            NSWorkspace.shared.open(URL(fileURLWithPath: fallback))
        }
    }

    /// "Open in" submenu for AppKit menus: every installed editor, then the default app.
    public static func submenu(_ path: String, line: Int? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.text("Открыть в", "Open In"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for editor in installed {
            menu.addItem(EditorMenuItem(title: editor.title) { open(path, line: line, target: .editor(editor)) })
        }
        if !installed.isEmpty { menu.addItem(.separator()) }
        menu.addItem(EditorMenuItem(title: L10n.text("Программа по умолчанию", "Default App")) { open(path, target: .defaultApp) })
        item.submenu = menu
        return item
    }
}

/// A menu item that runs a closure.
final class EditorMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func run() { perform() }
}

/// SwiftUI menu entries: the preferred editor first, then an "Open In" submenu with the others and the default app.
public struct OpenInEditorMenu: View {
    let path: String
    let line: Int?
    public init(path: String, line: Int? = nil) { self.path = path; self.line = line }

    public var body: some View {
        Button(EditorLauncher.openTitle) { EditorLauncher.open(path, line: line) }
        ForEach(EditorLauncher.browsers(for: path), id: \.browser.id) { found in
            Button(EditorLauncher.openTitle(found.browser.title)) {
                EditorLauncher.openInBrowser(path, browser: found.browser, app: found.app)
            }
        }
        Menu(L10n.text("Открыть в", "Open In")) {
            ForEach(EditorLauncher.installed) { editor in
                Button(editor.title) { EditorLauncher.open(path, line: line, target: .editor(editor)) }
            }
            if !EditorLauncher.installed.isEmpty { Divider() }
            Button(L10n.text("Программа по умолчанию", "Default App")) { EditorLauncher.open(path, target: .defaultApp) }
        }
    }
}
