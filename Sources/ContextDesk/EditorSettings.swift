import ContextCore
import ContextTranscript
import SwiftUI

/// Settings: which editor files open in.
struct EditorPreferenceSettings: View {
    @AppStorage(ExternalEditors.preferenceKey) private var saved = ""
    var body: some View {
        Section(L10n.text("Редактор кода", "Code editor")) {
            Picker(L10n.text("Открывать файлы в", "Open files in"), selection: Binding(
                get: { EditorLauncher.preferred?.id ?? ExternalEditors.systemID },
                set: { saved = $0 })) {
                ForEach(EditorLauncher.installed) { editor in Text(editor.title).tag(editor.id) }
                Text(L10n.text("Программа по умолчанию", "Default app")).tag(ExternalEditors.systemID)
            }
            .pointingHandCursor()
            Text(L10n.text("Файлы из ответов, предпросмотра, дерева файлов и изменений хода открываются в этом редакторе сразу на нужной строке. ⌘-клик по файлу в чате тоже открывает его здесь.",
                           "Files from answers, the preview, the file tree and turn changes open in this editor at the right line. ⌘-click on a file in a chat opens it here too."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
        .onAppear { EditorLauncher.refresh() }
        .id(saved)
    }
}
