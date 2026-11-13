import ContextCore
import ContextTranscript
import SwiftUI

/// Toolbar button that opens a terminal window in the chat's working folder (its worktree, if it has one).
/// A click uses the terminal chosen last time; with several terminals installed, the menu picks another one.
struct OpenTerminalButton: View {
    let folder: String

    var body: some View {
        let installed = EditorLauncher.installedTerminals
        let help = L10n.text("Открыть терминал в папке чата (⌃⌘T)", "Open a terminal in the chat’s folder (⌃⌘T)")
        let label = Label(L10n.text("Терминал", "Terminal"), systemImage: "apple.terminal")
        Group {
            if installed.count > 1 {
                Menu {
                    ForEach(installed, id: \.terminal.id) { found in
                        Button(EditorLauncher.openTitle(found.terminal.title)) {
                            EditorLauncher.openTerminal(folder, terminal: found)
                        }
                    }
                } label: { label } primaryAction: { EditorLauncher.openTerminal(folder) }
            } else {
                Button { EditorLauncher.openTerminal(folder) } label: { label }
            }
        }
        .pointingHandCursor()
        .help(help)
        .keyboardShortcut("t", modifiers: [.command, .control])
        .disabled(installed.isEmpty)
    }
}
