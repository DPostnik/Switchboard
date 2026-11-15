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

    public static func refresh() { cache = nil; browserCache = nil; terminalCache = nil }

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

    private static var terminalCache: [(terminal: ExternalTerminal, app: URL)]?

    /// Terminals found on this Mac, looked up once per launch.
    public static var installedTerminals: [(terminal: ExternalTerminal, app: URL)] {
        if let terminalCache { return terminalCache }
        let found = ExternalEditors.installedTerminals { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        terminalCache = found
        return found
    }

    /// The terminal chosen last time, otherwise the first installed one.
    public static var preferredTerminal: (terminal: ExternalTerminal, app: URL)? {
        ExternalEditors.preferredTerminal(UserDefaults.standard.string(forKey: ExternalEditors.terminalPreferenceKey),
                                          among: installedTerminals)
    }

    /// Opens a new terminal window in `folder` and remembers an explicitly chosen terminal.
    /// Launch Services starts the terminal, so it never inherits the app's agent environment.
    public static func openTerminal(_ folder: String, terminal: (terminal: ExternalTerminal, app: URL)? = nil) {
        if let terminal { UserDefaults.standard.set(terminal.terminal.id, forKey: ExternalEditors.terminalPreferenceKey) }
        var directory: ObjCBool = false
        guard let chosen = terminal ?? preferredTerminal,
              FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue else {
            log.error("Terminal not opened: no terminal or the folder is missing")
            NSSound.beep(); return
        }
        let id = chosen.terminal.id
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: chosen.app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            let log = Logger(subsystem: "local.daniil.switchboard", category: "editor")
            if let error { log.error("Terminal \(id, privacy: .public) did not open: \(error.localizedDescription, privacy: .public)") }
            else { log.info("Opened a folder in terminal \(id, privacy: .public)") }
        }
    }

    public enum CommandLaunch: Equatable { case prefilled, copied, failed }

    /// Opens a Terminal window in `folder` with `command` typed at the zsh prompt but not run.
    /// Other terminals and shells cannot be prefilled: the folder opens there and the command goes to the pasteboard.
    public static func openTerminal(_ folder: String?, command: String, pasteboard: NSPasteboard = .general) -> CommandLaunch {
        var directory: ObjCBool = false
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = folder.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &directory) && directory.boolValue ? $0 : nil } ?? home
        guard let chosen = preferredTerminal else {
            log.error("Terminal not opened: no terminal is installed")
            NSSound.beep(); return .failed
        }
        let shell = loginShell
        if chosen.terminal.bundleID == "com.apple.Terminal", TerminalPrefill.supports(shell: shell),
           let launcher = writePrefill(command: command, folder: folder, shell: shell) {
            NSWorkspace.shared.open([launcher], withApplicationAt: chosen.app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let log = Logger(subsystem: "local.daniil.switchboard", category: "editor")
                if let error {
                    log.error("Terminal did not open a command: \(error.localizedDescription, privacy: .public)")
                    try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent())
                } else { log.info("Opened Terminal with a prefilled command") }
            }
            return .prefilled
        }
        pasteboard.clearContents()
        guard pasteboard.setString(command, forType: .string) else { return .failed }
        openTerminal(folder)
        return .copied
    }

    /// The user's login shell from the account database; `SHELL` of the app may be stale.
    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Writes the launcher folder; folders left by launches that never started are removed after an hour.
    private static func writePrefill(command: String, folder: String, shell: String) -> URL? {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        if let old = try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.creationDateKey]) {
            for url in old where url.lastPathComponent.hasPrefix(TerminalPrefill.folderPrefix) {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if created < Date().addingTimeInterval(-3600) { try? manager.removeItem(at: url) }
            }
        }
        let directory = temporary.appendingPathComponent(TerminalPrefill.folderPrefix + UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory.appendingPathComponent("zdot"), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            for file in TerminalPrefill.files(command: command, folder: folder, shell: shell, directory: directory.path) {
                try Data(file.contents.utf8).write(to: URL(fileURLWithPath: file.path))
                try manager.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: file.path)
            }
            return directory.appendingPathComponent(TerminalPrefill.launcherName)
        } catch {
            log.error("Terminal command not prepared: \(error.localizedDescription, privacy: .public)")
            try? manager.removeItem(at: directory)
            return nil
        }
    }

    public static func openTitle(_ app: String) -> String { L10n.text("Открыть в \(app)", "Open in \(app)") }

    public static var preferred: ExternalEditors.Installed? {
        ExternalEditors.preferred(UserDefaults.standard.string(forKey: ExternalEditors.preferenceKey), among: installed)
    }

    /// "Open in VS Code", or "Open in Default App" without an editor.
    public static var openTitle: String { openTitle(preferred) }

    /// Tooltip for an open button whose file was moved or deleted after the change.
    public static let missingFileHelp = L10n.text("Файла больше нет на диске: его переместили или удалили после этого изменения",
                                                  "The file is no longer on disk: it was moved or deleted after this change")

    public static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public static func openTitle(_ editor: ExternalEditors.Installed?) -> String {
        guard let editor else { return L10n.text("Открыть в программе по умолчанию", "Open in Default App") }
        return openTitle(editor.title)
    }

    /// Opens a file at `line` (and `column`), or a folder as a workspace.
    public static func open(_ path: String, line: Int? = nil, column: Int? = nil, target: Target = .preferred) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else {
            // Neither an editor nor the default app reacts to a missing path, so the click must not pass silently.
            log.error("Not opened: the file is no longer on disk")
            NSSound.beep(); return
        }
        let editor: ExternalEditors.Installed?
        switch target {
        case .preferred: editor = preferred
        case .editor(let chosen): editor = chosen
        case .defaultApp: editor = nil
        }
        guard let editor else {
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
