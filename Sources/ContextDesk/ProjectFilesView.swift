import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ContextCore
import ContextTranscript

/// The chat folder's files for the side panel. Expansion and selection survive opening a file and coming back.
@MainActor final class ProjectFilesModel: ObservableObject {
    @Published private(set) var root: String?
    @Published private(set) var listing: ProjectFiles.Listing?
    @Published private(set) var tree: [ProjectFiles.Node] = []
    @Published private(set) var issue: String?
    @Published private(set) var loading = false
    @Published var expanded: Set<String> = []
    @Published var selection: String?
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    /// Filter results and the query they answer; filled off the main thread shortly after typing pauses.
    @Published private(set) var result = ProjectFiles.SearchResult.empty
    private var generation = UUID()
    private var searchIndex = ProjectFiles.SearchIndex([])
    private var searchTask: Task<Void, Never>?

    var rows: [ProjectFiles.Row] { ProjectFiles.rows(tree, expanded: expanded) }
    var matches: [String] { result.paths }
    /// The results answer the current text; until then the previous ones stay on screen.
    var matchesCurrent: Bool { result.query == query }

    /// The best match for the current text, computed now when the background search has not caught up (Return).
    func firstMatch() -> String? {
        matchesCurrent ? matches.first : ProjectFiles.search(query, in: searchIndex, limit: 1).paths.first
    }

    /// Filters in a detached task 80 ms after the last keystroke; a newer keystroke cancels it. When the text
    /// extends the previous query, only the previous matches are checked.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { result = .empty; return }
        let index = searchIndex, previous = result.query.isEmpty ? nil : result
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let found = await Task.detached(priority: .userInitiated) { ProjectFiles.search(query, in: index, narrowing: previous) }.value
            guard !Task.isCancelled, let self, self.query == query else { return }
            self.result = found
        }
    }

    /// Lists `folder` once; a new folder starts with a collapsed tree. Read errors are shown, never retried.
    func load(_ folder: String?, force: Bool = false) async {
        guard force || folder != root || listing == nil && issue == nil else { return }
        if folder != root { expanded = []; selection = nil; query = "" }
        root = folder
        guard let folder else { listing = nil; tree = []; issue = nil; replaceSearchIndex(.init([])); return }
        let token = UUID(); generation = token
        loading = true
        defer { if generation == token { loading = false } }
        do {
            let listed = try await ProjectFiles.list(root: folder)
            let built = await Task.detached(priority: .userInitiated) { (ProjectFiles.tree(listed.paths), ProjectFiles.SearchIndex(listed.paths)) }.value
            guard generation == token else { return }
            listing = listed; tree = built.0; issue = nil
            replaceSearchIndex(built.1)
        } catch {
            guard generation == token else { return }
            listing = nil; tree = []; replaceSearchIndex(.init([]))
            switch error {
            case .tooBroad:
                issue = L10n.text("Папка слишком широкая для дерева файлов (домашняя папка или корень диска).",
                                  "This folder is too broad for a file tree (the home folder or the disk root).")
            case .unreadable(let path):
                issue = L10n.text("Не удалось прочитать папку: ", "Could not read the folder: ") + path
            }
        }
    }

    /// A new listing: earlier matches index the old one, so they cannot be narrowed further.
    private func replaceSearchIndex(_ index: ProjectFiles.SearchIndex) {
        searchIndex = index
        result = .empty
        scheduleSearch()
    }

    func url(_ path: String) -> URL? { root.map { URL(fileURLWithPath: $0).appendingPathComponent(path) } }

    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// Expands the folders above `path` and selects it.
    func reveal(_ path: String) {
        expanded.formUnion(ProjectFiles.ancestors(of: path))
        selection = path
    }
}

struct ProjectFilesView: View {
    @ObservedObject var files: ProjectFilesModel
    let open: (URL) -> Void
    let addToMessage: (URL) -> Void
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(DeskPalette.muted)
                Text(files.root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.text("Файлы", "Files"))
                    .font(.ui(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .help(files.root ?? "")
                Spacer(minLength: 8)
                if files.loading { ProgressView().controlSize(.small) }
                Button { Task { await files.load(files.root, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.text("Обновить список файлов", "Refresh the file list"))
                    .disabled(files.loading)
                if let root = files.root {
                    Button { EditorLauncher.open(root) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help(L10n.text("Открыть папку: ", "Open the folder: ") + EditorLauncher.openTitle)
                        .disabled(EditorLauncher.preferred == nil)
                }
                Button(action: close) { Image(systemName: "xmark") }
                    .help(L10n.text("Скрыть файлы", "Hide files"))
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            TextField(L10n.text("Найти файл", "Find a file"), text: $files.query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { if let first = files.firstMatch() { activate(first) } }
                .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if files.listing?.truncated == true {
                Text(L10n.text("Показаны первые \(ProjectFiles.limit) файлов.", "Showing the first \(ProjectFiles.limit) files."))
                    .font(.ui(.caption)).foregroundStyle(DeskPalette.attentionInk).padding(8)
            }
        }
        .accessibilityLabel(L10n.text("Файлы проекта", "Project files"))
    }

    @ViewBuilder private var content: some View {
        if let issue = files.issue {
            Text(issue).font(.ui(.callout)).foregroundStyle(.secondary).padding(20)
        } else if files.listing == nil {
            ProgressView()
        } else if !files.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = files.matches
            if matches.isEmpty {
                if files.matchesCurrent {
                    Text(L10n.text("Ничего не найдено", "No matches")).font(.ui(.callout)).foregroundStyle(.secondary)
                } else {
                    // The first results are a moment away; a spinner would only flash.
                    Color.clear
                }
            } else {
                List(matches, id: \.self, selection: selectionBinding) { path in
                    FileRow(name: URL(fileURLWithPath: path).lastPathComponent, detail: (path as NSString).deletingLastPathComponent,
                            folder: false, expanded: false, depth: 0)
                        .tag(path)
                        .modifier(FileActions(files: files, path: path, open: open, addToMessage: addToMessage))
                }
                .listStyle(.sidebar)
                .onKeyPress(.return) { keyActivate() }
            }
        } else if files.tree.isEmpty {
            Text(L10n.text("В папке нет файлов", "The folder has no files")).font(.ui(.callout)).foregroundStyle(.secondary)
        } else {
            ScrollViewReader { proxy in
                List(files.rows, selection: selectionBinding) { row in
                    FileRow(name: row.node.name, detail: nil, folder: row.node.isFolder,
                            expanded: files.expanded.contains(row.node.path), depth: row.depth) { files.toggle(row.node.path) }
                        .tag(row.node.path)
                        .modifier(FileActions(files: files, path: row.node.path, folder: row.node.isFolder,
                                              open: open, addToMessage: addToMessage))
                }
                .listStyle(.sidebar)
                .onKeyPress(.return) { keyActivate() }
                .onKeyPress(.space) { keyActivate() }
                .onAppear { if let selected = files.selection { proxy.scrollTo(selected, anchor: .center) } }
            }
        }
    }

    /// A click on a file previews it and a click on a folder opens or closes it; arrow keys only move the selection,
    /// Return or Space acts on it.
    private var selectionBinding: Binding<String?> {
        Binding(get: { files.selection }, set: { path in
            files.selection = path
            let type = NSApp.currentEvent?.type
            guard let path, type == .leftMouseDown || type == .leftMouseUp else { return }
            activate(path)
        })
    }

    private func activate(_ path: String) {
        guard let url = files.url(path) else { return }
        if files.query.trimmingCharacters(in: .whitespaces).isEmpty,
           files.rows.first(where: { $0.node.path == path })?.node.isFolder == true {
            files.toggle(path); return
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return }
        if !files.query.trimmingCharacters(in: .whitespaces).isEmpty { files.reveal(path) }
        open(url)
    }

    private func keyActivate() -> KeyPress.Result {
        guard let selected = files.selection else { return .ignored }
        activate(selected)
        return .handled
    }
}

private struct FileRow: View {
    let name: String
    let detail: String?
    let folder: Bool
    let expanded: Bool
    let depth: Int
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            if folder {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(DeskPalette.muted).frame(width: 10)
                    .contentShape(Rectangle()).onTapGesture(perform: toggle)
            } else {
                Color.clear.frame(width: 10)
            }
            Image(nsImage: folder ? FileIcons.folder : FileIcons.icon(for: name)).resizable().frame(width: 15, height: 15)
            Text(name).font(.ui(size: 12.5)).lineLimit(1).truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail).font(.ui(size: 11)).foregroundStyle(DeskPalette.muted).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
    }
}

/// Context menu and drag for a file row; folders get the Finder and path actions only.
private struct FileActions: ViewModifier {
    let files: ProjectFilesModel
    let path: String
    var folder = false
    let open: (URL) -> Void
    let addToMessage: (URL) -> Void

    func body(content: Content) -> some View {
        if let url = files.url(path) {
            content
                .onDrag { NSItemProvider(object: url as NSURL) }
                .contextMenu {
                    if !folder {
                        Button(L10n.text("Предпросмотр", "Preview")) { open(url) }
                        OpenInEditorMenu(path: url.path)
                        Button(L10n.text("Добавить в сообщение", "Add to Message")) { addToMessage(url) }
                        Divider()
                    } else if EditorLauncher.preferred != nil {
                        Button(EditorLauncher.openTitle) { EditorLauncher.open(url.path) }
                    }
                    Button(L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button(L10n.text("Скопировать относительный путь", "Copy Relative Path")) { copy(path) }
                    Button(L10n.text("Скопировать абсолютный путь", "Copy Absolute Path")) { copy(url.path) }
                }
        } else {
            content
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

/// File-type icons, cached per extension: a lookup costs milliseconds and a tree shows hundreds.
@MainActor private enum FileIcons {
    static let folder: NSImage = NSWorkspace.shared.icon(for: .folder)
    private static var cache: [String: NSImage] = [:]

    static func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let icon = cache[ext] { return icon }
        let icon = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(for: .data)
        cache[ext] = icon
        return icon
    }
}
