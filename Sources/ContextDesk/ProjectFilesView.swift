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
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var searching: Bool { !files.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(DeskPalette.muted)
                Text(files.root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.text("Файлы", "Files"))
                    .font(.ui(size: 13, weight: .semibold)).foregroundStyle(DeskPalette.ink).lineLimit(1).truncationMode(.middle)
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
            .buttonStyle(.borderless).foregroundStyle(DeskPalette.muted).pointingHandCursor()
            .padding(.horizontal, 14).padding(.vertical, 10)
            searchField.padding(.horizontal, 12).padding(.bottom, 8)
            Divider().overlay(DeskPalette.border)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if files.listing?.truncated == true {
                Text(L10n.text("Показаны первые \(ProjectFiles.limit) файлов.", "Showing the first \(ProjectFiles.limit) files."))
                    .font(.ui(.caption)).foregroundStyle(DeskPalette.attentionInk).padding(8)
            }
        }
        .background(DeskPalette.canvas)
        .accessibilityLabel(L10n.text("Файлы проекта", "Project files"))
    }

    /// The same field as the chat files panel; Down Arrow moves into the list.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
            TextField(L10n.text("Найти файл", "Find a file"), text: $files.query)
                .textFieldStyle(.plain).font(.ui(size: 12)).focused($searchFocused)
                .onSubmit { if let first = files.firstMatch() { activate(first) } }
                .onKeyPress(.downArrow) {
                    guard let first = entries.first else { return .ignored }
                    files.selection = first.id; listFocused = true
                    return .handled
                }
            if !files.query.isEmpty {
                Button { files.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DeskPalette.muted) }
                    .buttonStyle(.plain).pointingHandCursor()
                    .help(L10n.text("Очистить поиск", "Clear the search"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(DeskPalette.subtle))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? DeskPalette.focusBorder : .clear, lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        if let issue = files.issue {
            Text(issue).font(.ui(.callout)).foregroundStyle(DeskPalette.muted).padding(20)
        } else if files.listing == nil {
            ProgressView()
        } else if searching && files.matches.isEmpty {
            if files.matchesCurrent {
                Text(L10n.text("Ничего не найдено", "No matches")).font(.ui(.callout)).foregroundStyle(DeskPalette.muted)
            } else {
                // The first results are a moment away; a spinner would only flash.
                Color.clear
            }
        } else if !searching && files.tree.isEmpty {
            Text(L10n.text("В папке нет файлов", "The folder has no files")).font(.ui(.callout)).foregroundStyle(DeskPalette.muted)
        } else {
            list(entries)
        }
    }

    /// The tree's visible rows, or the filter results with their folders.
    private var entries: [FileEntry] {
        if searching {
            return files.matches.map { FileEntry(id: $0, name: URL(fileURLWithPath: $0).lastPathComponent,
                                                 detail: ($0 as NSString).deletingLastPathComponent, folder: false, depth: 0) }
        }
        return files.rows.map { FileEntry(id: $0.node.path, name: $0.node.name, detail: nil, folder: $0.node.isFolder, depth: $0.depth) }
    }

    /// Rows drawn in the app's colors; opening a folder slides its contents in under it, as Finder does.
    private func list(_ entries: [FileEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(entries) { entry in
                        FileRow(entry: entry, expanded: files.expanded.contains(entry.id), selected: files.selection == entry.id,
                                toggle: { toggle(entry.id) }, click: { files.selection = entry.id; listFocused = true; activate(entry.id) })
                            .id(entry.id)
                            .modifier(FileDrag(files: files, path: entry.id))
                            .contextMenu { FileMenu(files: files, path: entry.id, folder: entry.folder, open: open, addToMessage: addToMessage) }
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space]) { press in
                key(press.key, entries, proxy)
            }
            .onAppear { if let selected = files.selection { proxy.scrollTo(selected, anchor: .center) } }
        }
    }

    private func toggle(_ path: String) {
        withAnimation(DeskMotion.standard(reduceMotion, response: 0.26)) { files.toggle(path) }
    }

    /// Up and Down move the selection, Right opens a folder or steps into it, Left closes it or steps out to its
    /// parent, Return or Space acts on the selected row.
    private func key(_ key: KeyEquivalent, _ entries: [FileEntry], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        let index = files.selection.flatMap { selected in entries.firstIndex { $0.id == selected } }
        let current = index.map { entries[$0] }
        var target: String?
        switch key {
        case .downArrow: target = entries[min((index ?? -1) + 1, entries.count - 1)].id
        case .upArrow: target = entries[max((index ?? entries.count) - 1, 0)].id
        case .rightArrow:
            guard let current, current.folder, let index else { return .ignored }
            if !files.expanded.contains(current.id) { toggle(current.id); return .handled }
            if index + 1 < entries.count, entries[index + 1].depth > current.depth { target = entries[index + 1].id }
        case .leftArrow:
            guard let current, !searching else { return .ignored }
            if current.folder, files.expanded.contains(current.id) { toggle(current.id); return .handled }
            let parent = (current.id as NSString).deletingLastPathComponent
            if !parent.isEmpty { target = parent }
        default:
            guard let current else { return .ignored }
            activate(current.id)
            return .handled
        }
        if let target {
            files.selection = target
            proxy.scrollTo(target)
        }
        return .handled
    }

    private func activate(_ path: String) {
        guard let url = files.url(path) else { return }
        if !searching, files.rows.first(where: { $0.node.path == path })?.node.isFolder == true {
            toggle(path); return
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return }
        if searching { files.reveal(path) }
        open(url)
    }
}

/// One row of the tree or of the filter results; the id is the path relative to the folder.
private struct FileEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String?
    let folder: Bool
    let depth: Int
}

/// The selection is a palette tint, as in the chat changes window, so the name stays readable on it.
private struct FileRow: View {
    let entry: FileEntry
    let expanded: Bool
    let selected: Bool
    let toggle: () -> Void
    let click: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if entry.folder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(DeskPalette.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle()).onTapGesture(perform: toggle)
            } else {
                Color.clear.frame(width: 12, height: 18)
            }
            Image(nsImage: entry.folder ? FileIcons.folder : FileIcons.icon(for: entry.name)).resizable().frame(width: 15, height: 15)
            Text(entry.name).font(.ui(size: 12.5)).foregroundStyle(DeskPalette.ink).lineLimit(1).truncationMode(.middle)
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail).font(.ui(size: 11)).foregroundStyle(DeskPalette.muted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4 + CGFloat(entry.depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? DeskPalette.selection : hovering ? DeskPalette.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: click)
        .pointingHandCursor()
    }
}

/// Drag for a file row; the URL is made when the drag starts.
private struct FileDrag: ViewModifier {
    let files: ProjectFilesModel
    let path: String

    func body(content: Content) -> some View {
        content.onDrag { files.url(path).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
    }
}

/// The context menu of one file or folder row; folders get the Finder and path actions only.
private struct FileMenu: View {
    let files: ProjectFilesModel
    let path: String
    let folder: Bool
    let open: (URL) -> Void
    let addToMessage: (URL) -> Void

    var body: some View {
        if let url = files.url(path) {
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
