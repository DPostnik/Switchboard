import Foundation

/// Code editors a file can be opened in at a line, found by bundle identifier and launched through their own CLI.
/// Arguments go straight to `Process`, never through a shell.
public struct ExternalEditor: Identifiable, Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// VS Code family: `cli [folder] --goto file:line:column`; the folder brings up the project's window.
        case vscode
        /// Zed: `cli [folder] file:line:column`.
        case zed
        /// Xcode: `xed --line N file`.
        case xcode
        /// JetBrains IDEs: `binary --line N --column M file` (columns count from 0).
        case jetbrains
        /// Sublime Text: `subl file:line:column`.
        case sublime
    }

    public let id: String
    public let title: String
    /// Bundle identifiers, preferred first.
    public let bundleIDs: [String]
    /// Path inside the application bundle; absolute paths (`/usr/bin/xed`) are used as they are.
    public let executable: String
    public let style: Style
    /// Leading arguments, such as Cursor's `--classic` that targets the editor rather than its agents window.
    public let baseArguments: [String]

    public init(id: String, title: String, bundleIDs: [String], executable: String, style: Style, baseArguments: [String] = []) {
        self.id = id; self.title = title; self.bundleIDs = bundleIDs; self.executable = executable
        self.style = style; self.baseArguments = baseArguments
    }
}

/// A browser that previews HTML files; opened through Launch Services with the file's URL.
public struct ExternalBrowser: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let bundleID: String
    public init(id: String, title: String, bundleID: String) { self.id = id; self.title = title; self.bundleID = bundleID }
}

public enum ExternalEditors {
    /// Preference key holding the chosen editor's ID; `system` opens files in their default app.
    public static let preferenceKey = "preferredEditor"
    public static let systemID = "system"

    /// In the order an unset preference picks the first installed one.
    public static let known: [ExternalEditor] = [
        ExternalEditor(id: "vscode", title: "VS Code", bundleIDs: ["com.microsoft.VSCode"],
                       executable: "Contents/Resources/app/bin/code", style: .vscode),
        ExternalEditor(id: "cursor", title: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
                       executable: "Contents/Resources/app/bin/cursor", style: .vscode, baseArguments: ["--classic"]),
        ExternalEditor(id: "zed", title: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
                       executable: "Contents/MacOS/cli", style: .zed),
        ExternalEditor(id: "windsurf", title: "Windsurf", bundleIDs: ["com.exafunction.windsurf"],
                       executable: "Contents/Resources/app/bin/windsurf", style: .vscode),
        ExternalEditor(id: "vscodium", title: "VSCodium", bundleIDs: ["com.vscodium", "com.visualstudio.code.oss"],
                       executable: "Contents/Resources/app/bin/codium", style: .vscode),
        ExternalEditor(id: "vscode-insiders", title: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"],
                       executable: "Contents/Resources/app/bin/code-insiders", style: .vscode),
        ExternalEditor(id: "xcode", title: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], executable: "/usr/bin/xed", style: .xcode),
        ExternalEditor(id: "sublime", title: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"],
                       executable: "Contents/SharedSupport/bin/subl", style: .sublime),
        ExternalEditor(id: "idea", title: "IntelliJ IDEA", bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
                       executable: "Contents/MacOS/idea", style: .jetbrains),
        ExternalEditor(id: "webstorm", title: "WebStorm", bundleIDs: ["com.jetbrains.WebStorm"],
                       executable: "Contents/MacOS/webstorm", style: .jetbrains),
        ExternalEditor(id: "pycharm", title: "PyCharm", bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"],
                       executable: "Contents/MacOS/pycharm", style: .jetbrains),
        ExternalEditor(id: "goland", title: "GoLand", bundleIDs: ["com.jetbrains.goland"],
                       executable: "Contents/MacOS/goland", style: .jetbrains),
    ]

    /// An editor found on this Mac with the executable that launches it.
    public struct Installed: Identifiable, Hashable, Sendable {
        public let editor: ExternalEditor
        public let executable: URL
        public var id: String { editor.id }
        public var title: String { editor.title }
        public init(editor: ExternalEditor, executable: URL) { self.editor = editor; self.executable = executable }
    }

    /// Known editors whose application is found (`locate` maps a bundle ID to its app) and whose CLI is executable.
    public static func installed(locate: (String) -> URL?,
                                 isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [Installed] {
        known.compactMap { editor in
            guard let app = editor.bundleIDs.lazy.compactMap(locate).first else { return nil }
            let executable = editor.executable.hasPrefix("/") ? URL(fileURLWithPath: editor.executable)
                                                              : app.appendingPathComponent(editor.executable)
            return isExecutable(executable.path) ? Installed(editor: editor, executable: executable) : nil
        }
    }

    /// The saved choice when it is installed, otherwise the first installed editor; nil means the default app.
    public static func preferred(_ saved: String?, among installed: [Installed]) -> Installed? {
        if saved == systemID { return nil }
        return installed.first { $0.id == saved } ?? installed.first
    }

    /// Arguments that open `file` (at `line`/`column`, counted from 1) or, without a file, `folder` alone.
    /// `folder` is the project the file belongs to; editors that open workspaces use it to pick the right window.
    public static func arguments(for editor: ExternalEditor, file: String?, line: Int? = nil, column: Int? = nil,
                                 folder: String? = nil) -> [String] {
        let line = line.map { max(1, $0) }
        let column = line == nil ? nil : column.map { max(1, $0) }
        var position: String? {
            guard let file else { return nil }
            guard let line else { return file }
            return file + ":\(line)" + (column.map { ":\($0)" } ?? "")
        }
        let base = editor.baseArguments
        guard let file else { return folder.map { base + [$0] } ?? base }
        switch editor.style {
        case .vscode:
            return base + (folder.map { [$0] } ?? []) + (line == nil ? [file] : ["--goto", position ?? file])
        case .zed:
            return base + (folder.map { [$0] } ?? []) + [position ?? file]
        case .xcode:
            return base + (line.map { ["--line", String($0)] } ?? []) + [file]
        case .jetbrains:
            return base + (line.map { ["--line", String($0)] } ?? []) + (column.map { ["--column", String($0 - 1)] } ?? []) + [file]
        case .sublime:
            return base + [position ?? file]
        }
    }

    /// The deepest of `folders` that contains `path`, so a worktree wins over the project that holds it.
    public static func folder(containing path: String, in folders: [String]) -> String? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return folders.map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { folder in
                let parts = folder.pathComponents
                return parts.count > 1 && target.count > parts.count && Array(target.prefix(parts.count)) == parts
            }
            .max { $0.pathComponents.count < $1.pathComponents.count }?.path
    }

    /// Browsers offered for web pages, in menu order.
    public static let browsers: [ExternalBrowser] = [
        ExternalBrowser(id: "chrome", title: "Google Chrome", bundleID: "com.google.Chrome"),
        ExternalBrowser(id: "safari", title: "Safari", bundleID: "com.apple.Safari"),
    ]

    public static let webPageExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// HTML files get "Open in <browser>" entries next to the editor.
    public static func isWebPage(_ path: String) -> Bool {
        webPageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Known browsers whose application is found, with its location.
    public static func installedBrowsers(locate: (String) -> URL?) -> [(browser: ExternalBrowser, app: URL)] {
        browsers.compactMap { browser in locate(browser.bundleID).map { (browser, $0) } }
    }

    /// The editor inherits this environment when it is not running yet. The app's agent homes and chat labels
    /// stay out, so the editor's own Claude or Codex extensions never pick up the app's dedicated profiles.
    public static func environment(_ base: [String: String]) -> [String: String] {
        base.filter { key, _ in
            !key.hasPrefix("SWITCHBOARD_") && !key.hasPrefix("CLAUDE") && !key.hasPrefix("CODEX_")
                && !key.hasPrefix("ELECTRON_") && key != "OPENAI_API_KEY" && key != "ANTHROPIC_API_KEY"
        }
    }
}
