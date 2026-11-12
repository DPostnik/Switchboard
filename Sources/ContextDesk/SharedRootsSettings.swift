import AppKit
import SwiftUI
import AgentContract
import ContextCore
import ContextTranscript

/// Folder rows shared by a project's folders and the folders for every project: path, write toggle, remove, add.
struct FolderRootsEditor: View {
    @Binding var roots: [AgentPermissionProfile.Root]
    let emptyHint: String
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .ui(8)) {
            if roots.isEmpty {
                Text(emptyHint).font(.ui(.caption)).foregroundStyle(DeskPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(roots.indices, id: \.self) { index in
                HStack(spacing: .ui(10)) {
                    Image(systemName: "folder").foregroundStyle(DeskPalette.muted).accessibilityHidden(true)
                    Text(roots[index].path).font(.ui(.callout)).lineLimit(1).truncationMode(.middle).help(roots[index].path)
                    Spacer()
                    Toggle(L10n.text("Запись", "Write"), isOn: $roots[index].writable).toggleStyle(.checkbox)
                    Button { roots.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(PointerButtonStyle(base: .plain))
                        .accessibilityLabel(L10n.text("Убрать папку", "Remove folder"))
                        .help(L10n.text("Убрать папку", "Remove folder"))
                }
                .padding(.horizontal, .ui(10)).padding(.vertical, .ui(7))
                .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 8))
            }
            Button(L10n.text("Добавить папку…", "Add folder…")) { add() }
                .buttonStyle(DeskButtonStyle(kind: .text))
        }
    }

    /// The folder picker both editors use; returns the standardized path or nil when cancelled.
    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Добавить", "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }
}

/// Settings → Advanced → Folders for every project. Nothing is granted until the user adds a folder.
struct SharedRootsSettings: View {
    @ObservedObject var model: DeskModel
    @State private var refusal: String?

    var body: some View {
        Section(L10n.text("Папки для всех проектов", "Folders for every project")) {
            Text(L10n.text("Применяются как папка проекта к ролям, которые принимают дополнительные папки (Разработчик и операторы), и никогда — к Редактору и Читателю; задания по расписанию получают их в том виде, как они заданы здесь.",
                           "Applied like a project folder to roles that accept extra folders (Developer and operators), never to Editor or Reader; scheduled jobs get them as set here."))
                .font(.ui(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            FolderRootsEditor(roots: Binding(get: { model.state.sharedRoots ?? [] }, set: { refusal = model.updateSharedRoots($0) }),
                              emptyHint: L10n.text("Пока ни одной папки, доступ не выдан. Например: \(SharedRoots.suggestedPath), с записью.",
                                                   "No folders yet, nothing is granted. For example: \(SharedRoots.suggestedPath), writable."),
                              add: add)
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.ui(.callout)).foregroundStyle(DeskPalette.attentionInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add() {
        guard let path = FolderRootsEditor.chooseFolder() else { return }
        if let reason = SharedRoots.refusal(path) { refusal = reason.message(SharedRoots.canonical(path)); return }
        let current = model.state.sharedRoots ?? []
        guard !current.contains(where: { $0.path == SharedRoots.canonical(path) }) else { refusal = nil; return }
        refusal = model.updateSharedRoots(current + [.init(path: path, writable: false)])
    }
}
