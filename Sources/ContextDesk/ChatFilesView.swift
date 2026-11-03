import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// The open chat's files: what its turns changed (from the turn checkpoints) and every file the agent or the user
/// cited, edited or read. Feeds the chat's right column and the chat changes window.
@MainActor final class ChatFilesModel: ObservableObject {
    enum PatchState: Equatable {
        case loading, binary, tooLarge
        case loaded([DiffLine], truncated: Bool)
        case failed(String)
    }

    @Published private(set) var files: [ChatFile] = []
    @Published private(set) var turns: [ChatTurnChanges] = []
    @Published private(set) var changed: [ChatChangedFile] = []
    @Published private(set) var loadingChanges = false
    /// Turns whose checkpoints could not be read (removed refs, a moved repository).
    @Published private(set) var unavailableTurns = 0
    /// The changed file whose diffs are shown (`ChatChangedFile.id`), in the chat changes window.
    @Published var openChange: String? { didSet { if openChange != oldValue { patches = [:]; loadPatches() } } }
    @Published private(set) var patches: [String: PatchState] = [:]
    private(set) var projectPath: String?
    private(set) var chatID: String?
    private let index = ChatFilesIndex()
    private var turnFiles: [String: [GitCheckpoints.FileChange]] = [:]
    private var failedTurns: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var patchTask: Task<Void, Never>?
    /// Next mention to jump to per file, counting back from the latest.
    private var jumpCursor: [String: Int] = [:]
    private(set) var engine: GitCheckpoints?
    private var latest: (items: [TranscriptItem], projectPath: String?)?

    var isEmpty: Bool { files.isEmpty && turns.isEmpty }

    /// Rebuilds the lists from the transcript at most a few times a second; streaming changes it far more often, and
    /// only the changed message is parsed again (`ChatFilesIndex`).
    func update(chatID: String?, items: [TranscriptItem], projectPath: String?, engine: GitCheckpoints, immediately: Bool = false) {
        self.engine = engine
        if chatID != self.chatID {
            self.chatID = chatID
            files = []; turns = []; changed = []; openChange = nil
            jumpCursor = [:]; unavailableTurns = 0
        }
        latest = (items, projectPath)
        if immediately { refreshTask?.cancel(); refreshTask = nil }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            guard let (items, projectPath) = self.latest else { return }
            let base = projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let index = self.index, chat = self.chatID
            // Parsing and file checks run off the main thread; only the results come back.
            let (collected, turns) = await Task.detached(priority: .utility) {
                (index.collect(items, baseDirectory: base), ChatFiles.turnChanges(items))
            }.value
            guard !Task.isCancelled, chat == self.chatID else { return }
            self.projectPath = projectPath
            if collected != self.files { self.files = collected }
            if turns != self.turns {
                self.turns = turns
                self.loadChanges()
            }
        }
    }

    /// Each turn's files come from its stored list; git is read only for turns recorded without a complete one.
    /// Checkpoints do not change after the turn, so every turn is read once.
    private func loadChanges() {
        for turn in turns where turnFiles[key(turn.changes)] == nil {
            if let stored = ChatFiles.storedFiles(turn.changes) { turnFiles[key(turn.changes)] = stored }
        }
        let missing = turns.filter { turnFiles[key($0.changes)] == nil && !failedTurns.contains(key($0.changes)) }
        guard let engine, !missing.isEmpty else { merge(); return }
        changesTask?.cancel()
        loadingChanges = true
        changesTask = Task { [weak self] in
            for turn in missing {
                let changes = turn.changes
                let result: [GitCheckpoints.FileChange]?
                do { result = try await engine.changes(root: changes.repository, from: changes.start, to: changes.end) }
                catch { result = nil }
                guard !Task.isCancelled, let self else { return }
                if let result { self.turnFiles[self.key(changes)] = result } else { self.failedTurns.insert(self.key(changes)) }
            }
            guard !Task.isCancelled, let self else { return }
            self.loadingChanges = false
            self.merge()
        }
    }

    private func merge() {
        let merged = ChatFiles.mergeChanges(turns.compactMap { turn in turnFiles[key(turn.changes)].map { (turn, $0) } })
        unavailableTurns = turns.filter { failedTurns.contains(key($0.changes)) }.count
        if merged != changed { changed = merged }
        if openChange != nil { loadPatches() }
    }

    private func key(_ changes: TurnChanges) -> String { changes.start + ":" + changes.end }

    func displayPath(_ path: String) -> String {
        TranscriptScrollView.relativePath(path, project: projectPath) ?? (path as NSString).abbreviatingWithTildeInPath
    }

    var openFile: ChatChangedFile? { changed.first { $0.id == openChange } }

    private func loadPatches() {
        patchTask?.cancel()
        // Keyed by turn for the open file only; opening another file starts from an empty set.
        guard let engine, let file = openFile else { return }
        for entry in file.turns where entry.change.isBinary { patches[entry.turn.itemID] = .binary }
        let pending = file.turns.filter { !$0.change.isBinary && (patches[$0.turn.itemID] == nil || patches[$0.turn.itemID] == .loading) }
        for entry in pending { patches[entry.turn.itemID] = .loading }
        patchTask = Task { [weak self] in
            for entry in pending {
                let changes = entry.turn.changes
                let state: PatchState
                do {
                    let result = try await engine.patch(root: changes.repository, from: changes.start, to: changes.end, file: entry.change)
                    if result.tooLarge { state = .tooLarge }
                    else {
                        let lines = await Task.detached(priority: .userInitiated) { DiffLine.parse(result.text) }.value
                        state = .loaded(lines, truncated: result.truncated)
                    }
                } catch { state = .failed(error.localizedDescription) }
                guard !Task.isCancelled, let self, self.openChange == file.id else { return }
                self.patches[entry.turn.itemID] = state
            }
        }
    }

    /// The mention to show for a click on the jump button: the latest first, then earlier ones in turn.
    func nextMention(_ file: ChatFile) -> ChatFile.Mention? {
        guard !file.mentions.isEmpty else { return nil }
        let step = jumpCursor[file.path, default: 0] % file.mentions.count
        jumpCursor[file.path] = step + 1
        return file.mentions[file.mentions.count - 1 - step]
    }

    /// A copy for the changes window, so switching chats in the main window does not empty it.
    func snapshot() -> ChatFilesModel {
        let copy = ChatFilesModel()
        copy.chatID = chatID; copy.projectPath = projectPath; copy.engine = engine
        copy.files = files; copy.turns = turns; copy.changed = changed; copy.unavailableTurns = unavailableTurns
        copy.turnFiles = turnFiles; copy.failedTurns = failedTurns
        return copy
    }
}

/// The chat's files at its top right: a small summary tile while hidden ("3 changed +120 −8 · 12 mentioned") that
/// grows into the files panel and shrinks back. It floats over the chat's right margin instead of narrowing the chat,
/// so opening it never reflows the transcript. Observes the files model so the chat view itself does not.
struct ChatFilesOverlay: View {
    @ObservedObject var files: ChatFilesModel
    let model: DeskModel
    let open: (URL, Int?) -> Void
    let addToMessage: (URL) -> Void
    @AppStorage("chatFilesPanelOpen") private var panelOpen = false
    /// Hides the tile and the panel in every chat; View → Show Chat Files brings them back.
    @AppStorage(ChatFilesVisibility.hiddenKey) private var hidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
        ZStack(alignment: .topTrailing) {
            if model.selectedChat != nil, !files.isEmpty, !hidden {
                if panelOpen {
                    ChatFilesSidebar(files: files, model: model, open: open, addToMessage: addToMessage,
                                     maxHeight: max(160, proxy.size.height - 130)) { toggle(false) }
                        .background(shape.fill(DeskPalette.canvas))
                        .overlay(shape.stroke(DeskPalette.border, lineWidth: 1))
                        .clipShape(shape)
                        .shadow(color: DeskPalette.shadow, radius: 16, y: 6)
                        .contextMenu { hideButton }
                        .transition(panelTransition)
                } else {
                    ChatFilesTile(files: files) { toggle(true) }
                        .background(shape.fill(DeskPalette.canvas))
                        .overlay(shape.stroke(DeskPalette.border, lineWidth: 1))
                        .clipShape(shape)
                        .shadow(color: DeskPalette.shadow, radius: 8, y: 3)
                        .contextMenu { hideButton }
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.12)), removal: .opacity.animation(.easeIn(duration: 0.08))))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(.top, 10).padding(.trailing, 12)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86), value: panelOpen)
        .animation(.easeOut(duration: 0.15), value: hidden)
    }

    private var hideButton: some View {
        Button(L10n.text("Не показывать файлы чата", "Don't Show Chat Files")) { hidden = true }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    /// The panel grows out of the tile's corner (top right) and shrinks back into it; only a fade with Reduce Motion.
    private var panelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .scale(scale: 0.3, anchor: .topTrailing).combined(with: .opacity),
                           removal: .scale(scale: 0.3, anchor: .topTrailing).combined(with: .opacity.animation(.easeIn(duration: 0.16))))
    }

    private func toggle(_ open: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86)) { panelOpen = open }
    }
}

/// Whether the chat files tile and panel are shown at all, shared by the overlay and the View menu.
enum ChatFilesVisibility {
    static let hiddenKey = "chatFilesHidden"
}

/// View menu toggle for the chat files tile and panel.
struct ChatFilesMenuItem: View {
    @AppStorage(ChatFilesVisibility.hiddenKey) private var hidden = false

    var body: some View {
        Toggle(L10n.text("Показывать файлы чата", "Show Chat Files"), isOn: Binding(get: { !hidden }, set: { hidden = !$0 }))
    }
}

/// The summary tile shown while the panel is closed.
private struct ChatFilesTile: View {
    @ObservedObject var files: ChatFilesModel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(DeskPalette.accentDeep)
                if !files.changed.isEmpty {
                    let added = files.changed.compactMap(\.added).reduce(0, +), removed = files.changed.compactMap(\.removed).reduce(0, +)
                    HStack(spacing: 4) {
                        Text(L10n.text("изменено \(files.changed.count)", "\(files.changed.count) changed")).foregroundStyle(DeskPalette.ink)
                        Text("+\(added)").foregroundStyle(DeskPalette.accent).monospacedDigit()
                        Text("−\(removed)").foregroundStyle(DeskPalette.problem).monospacedDigit()
                    }
                }
                if !files.changed.isEmpty, !files.files.isEmpty { Text("·").foregroundStyle(DeskPalette.muted) }
                if !files.files.isEmpty {
                    Text(L10n.text("упомянуто \(files.files.count)", "\(files.files.count) mentioned")).foregroundStyle(DeskPalette.inkSoft)
                }
                Image(systemName: "chevron.left").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(DeskPalette.muted)
                    .offset(x: hovering ? -2 : 0)
            }
            .font(.ui(size: 11.5))
            .padding(.horizontal, 11).padding(.vertical, 7)
            // One colour fading in and out: animating from .clear (transparent black) passes through a darker shade.
            .background(DeskPalette.rowHover.opacity(hovering ? 0.6 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovering = value } }
        .pointingHandCursor()
        .help(L10n.text("Показать файлы чата. Убрать плашку совсем: правый клик или Вид → Показывать файлы чата",
                        "Show chat files. To remove the tile, right-click it or use View → Show Chat Files"))
        .accessibilityLabel(L10n.text("Файлы чата", "Chat files"))
    }
}

/// The files panel: sections stacked at a fixed width, no tabs. Changed files open the chat changes window; cited
/// files open in the preview, and a button jumps to the message.
struct ChatFilesSidebar: View {
    @ObservedObject var files: ChatFilesModel
    let model: DeskModel
    let open: (URL, Int?) -> Void
    let addToMessage: (URL) -> Void
    /// Room above the composer; the panel is as tall as its sections up to this and scrolls beyond.
    let maxHeight: CGFloat
    let close: () -> Void
    static let width: CGFloat = 280
    @State private var contentHeight: CGFloat = 0
    @AppStorage("chatFilesChangesCollapsed") private var changesCollapsed = false
    @AppStorage("chatFilesMentionedCollapsed") private var mentionedCollapsed = false
    @State private var showAllChanges = false
    @State private var showAllFiles = false
    /// Filters both sections by name or folder; shown once the lists are long.
    @State private var query = ""
    private let rowLimit = 8
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private func matches(_ path: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || path.localizedCaseInsensitiveContains(query)
    }
    private static let motion = Animation.spring(response: 0.3, dampingFraction: 0.9)

    var body: some View {
        VStack(spacing: 0) {
            // The whole header row hides the panel, not only its arrow.
            HStack(spacing: 8) {
                Text(L10n.text("Файлы чата", "Chat files")).font(.ui(size: 13, weight: .semibold)).foregroundStyle(DeskPalette.ink)
                if files.loadingChanges { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DeskPalette.muted)
                    .frame(width: 22, height: 22)
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .pointingHandCursor()
            .help(L10n.text("Скрыть файлы чата", "Hide chat files"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: L10n.text("Скрыть файлы чата", "Hide chat files"), close)
            Divider().overlay(DeskPalette.border)
            if files.changed.count + files.files.count > rowLimit * 2 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                    TextField(L10n.text("Найти файл", "Find a file"), text: $query).textFieldStyle(.plain).font(.ui(size: 12))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DeskPalette.muted) }
                            .buttonStyle(.plain).pointingHandCursor()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(DeskPalette.subtle))
                .padding(.horizontal, 12).padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !files.turns.isEmpty {
                        section(L10n.text("Изменения", "Changes"), count: files.changed.count, collapsed: $changesCollapsed) { changes }
                        Divider().overlay(DeskPalette.border).padding(.horizontal, 16)
                    }
                    section(L10n.text("Файлы в чате", "Files in this chat"), count: files.files.count, collapsed: $mentionedCollapsed) { mentioned }
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if contentHeight == 0 { contentHeight = height } else { withAnimation(Self.motion) { contentHeight = height } }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 40), maxHeight - 40))
        }
        .frame(width: Self.width)
        .accessibilityLabel(L10n.text("Файлы чата", "Chat files"))
    }

    private func section<Content: View>(_ title: String, count: Int, collapsed: Binding<Bool>,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The whole row, padding included, opens and closes the section.
            HStack(spacing: 6) {
                Text(title).font(.ui(size: 12.5, weight: .medium)).foregroundStyle(DeskPalette.inkSoft)
                if count > 0 { Text("\(count)").font(.ui(size: 11.5)).foregroundStyle(DeskPalette.muted).monospacedDigit() }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(DeskPalette.muted)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Self.motion) { collapsed.wrappedValue.toggle() } }
            .pointingHandCursor()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(Self.motion) { collapsed.wrappedValue.toggle() } }
            if !collapsed.wrappedValue {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    // MARK: Changes

    @ViewBuilder private var changes: some View {
        let all = files.changed.filter { matches(files.displayPath($0.absolutePath)) }
        let shown = showAllChanges || searching ? all : Array(all.prefix(rowLimit))
        if all.isEmpty {
            note(files.loadingChanges ? L10n.text("Загрузка изменений…", "Loading changes…")
                 : searching ? L10n.text("Ничего не найдено", "No matches") : L10n.text("Нет изменённых файлов", "No changed files"))
        }
        ForEach(shown) { file in
            SidebarRow(icon: icon(for: file), name: URL(fileURLWithPath: file.path).lastPathComponent,
                       detail: (files.displayPath(file.absolutePath) as NSString).deletingLastPathComponent,
                       struck: file.status == .deleted, help: files.displayPath(file.absolutePath)) {
                if let added = file.added, let removed = file.removed {
                    HStack(spacing: 4) {
                        if file.status != .deleted { Text("+\(added)").foregroundStyle(DeskPalette.accent) }
                        if file.status != .added { Text("−\(removed)").foregroundStyle(DeskPalette.problem) }
                    }
                    .font(.system(size: 11).monospacedDigit())
                } else {
                    Text(L10n.text("двоичный", "binary")).font(.ui(size: 10.5)).foregroundStyle(DeskPalette.muted)
                }
            } hover: { EmptyView() } action: {
                ChatChangesWindow.show(files.snapshot(), file: file.id, model: model)
            }
            .contextMenu { changeMenu(file) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if all.count > rowLimit, !searching { moreButton(all.count - rowLimit, expanded: $showAllChanges) }
        if files.unavailableTurns > 0 {
            note(L10n.text("Снимки ходов недоступны: \(files.unavailableTurns).",
                           "Checkpoints unavailable for \(files.unavailableTurns) \(files.unavailableTurns == 1 ? "turn" : "turns")."))
        }
    }

    private func icon(for file: ChatChangedFile) -> SidebarRowIcon {
        file.status == .added || file.status == .copied ? .badge(URL(fileURLWithPath: file.path).pathExtension) : .file(file.path)
    }

    @ViewBuilder private func changeMenu(_ file: ChatChangedFile) -> some View {
        Button(L10n.text("Показать изменения", "Show changes")) { ChatChangesWindow.show(files.snapshot(), file: file.id, model: model) }
        if file.status != .deleted {
            Button(L10n.text("Предпросмотр", "Preview")) { open(URL(fileURLWithPath: file.absolutePath), nil) }
            OpenInEditorMenu(path: file.absolutePath)
            Button(L10n.text("Добавить в сообщение", "Add to Message")) { addToMessage(URL(fileURLWithPath: file.absolutePath)) }
            Button(L10n.text("Показать в Finder", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.absolutePath)])
            }
        }
        if let last = file.turns.last {
            Button(L10n.text("Перейти к последнему изменившему ходу", "Go to the last turn that changed it")) { reveal(last.turn.itemID, file: nil) }
        }
        Divider()
        Button(L10n.text("Скопировать относительный путь", "Copy Relative Path")) { copy(file.path) }
        Button(L10n.text("Скопировать абсолютный путь", "Copy Absolute Path")) { copy(file.absolutePath) }
    }

    // MARK: Mentioned

    @ViewBuilder private var mentioned: some View {
        let all = files.files.filter { matches(files.displayPath($0.path)) }
        let shown = showAllFiles || searching ? all : Array(all.prefix(rowLimit))
        if all.isEmpty {
            note(searching ? L10n.text("Ничего не найдено", "No matches") : L10n.text("В чате пока нет ссылок на файлы.", "No files are mentioned in this chat yet."))
        }
        ForEach(shown) { file in
            SidebarRow(icon: .file(file.path), name: URL(fileURLWithPath: file.path).lastPathComponent,
                       detail: (files.displayPath(file.path) as NSString).deletingLastPathComponent,
                       struck: file.deleted, help: files.displayPath(file.path) + " · " + Self.title(file.use)) {
                Image(systemName: Self.symbol(file.use)).font(.system(size: 10))
                    .foregroundStyle(file.use == .edited ? DeskPalette.accentDeep : DeskPalette.muted)
            } hover: {
                Button { jump(file) } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "text.bubble")
                        if file.mentions.count > 1 { Text("\(file.mentions.count)").monospacedDigit() }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(DeskPalette.accentDeep)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Перейти к упоминанию в чате; повторное нажатие — к более раннему",
                                "Go to the mention in the chat; click again for an earlier one"))
            } action: {
                activate(file)
            }
            .contextMenu { mentionMenu(file) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if all.count > rowLimit, !searching { moreButton(all.count - rowLimit, expanded: $showAllFiles) }
    }

    @ViewBuilder private func mentionMenu(_ file: ChatFile) -> some View {
        let url = URL(fileURLWithPath: file.path)
        if !file.deleted {
            Button(L10n.text("Предпросмотр", "Preview")) { open(url, file.line) }
            OpenInEditorMenu(path: file.path, line: file.line)
        }
        if let latest = file.mentions.last {
            Button(L10n.text("Перейти к последнему упоминанию", "Go to the latest mention")) { reveal(latest.itemID, file: file.path) }
        }
        if file.mentions.count > 1, let first = file.mentions.first {
            Button(L10n.text("Перейти к первому упоминанию", "Go to the first mention")) { reveal(first.itemID, file: file.path) }
        }
        if let change = files.changed.first(where: { $0.absolutePath == file.path }) {
            Button(L10n.text("Показать изменения", "Show changes")) { ChatChangesWindow.show(files.snapshot(), file: change.id, model: model) }
        }
        if !file.deleted {
            Button(L10n.text("Добавить в сообщение", "Add to Message")) { addToMessage(url) }
            Button(L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button(L10n.text("Скопировать относительный путь", "Copy Relative Path")) { copy(files.displayPath(file.path)) }
        Button(L10n.text("Скопировать абсолютный путь", "Copy Absolute Path")) { copy(file.path) }
    }

    /// A click previews the file; a file that no longer exists jumps to where it was mentioned instead.
    private func activate(_ file: ChatFile) {
        if ChatFiles.cachedIsFile(file.path) { open(URL(fileURLWithPath: file.path), file.line) } else { jump(file) }
    }

    private func jump(_ file: ChatFile) {
        guard let mention = files.nextMention(file) else { return }
        reveal(mention.itemID, file: file.path)
    }

    private func reveal(_ itemID: String, file: String?) {
        TranscriptScrollView.chatTranscript?.reveal(itemID: itemID, file: file)
    }

    private func moreButton(_ hidden: Int, expanded: Binding<Bool>) -> some View {
        Button(expanded.wrappedValue ? L10n.text("Свернуть", "Show less") : L10n.text("Ещё \(hidden)", "\(hidden) more")) {
            withAnimation(Self.motion) { expanded.wrappedValue.toggle() }
        }
        .buttonStyle(.plain).font(.ui(size: 11.5)).foregroundStyle(DeskPalette.accentDeep)
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.ui(size: 11.5)).foregroundStyle(DeskPalette.muted).padding(.horizontal, 16).padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    static func symbol(_ use: ChatFile.Use) -> String {
        switch use {
        case .edited: "pencil"
        case .read: "eye"
        case .mentioned: "quote.bubble"
        }
    }

    static func title(_ use: ChatFile.Use) -> String {
        switch use {
        case .edited: L10n.text("агент изменял файл", "the agent edited it")
        case .read: L10n.text("агент читал файл", "the agent read it")
        case .mentioned: L10n.text("упомянут в сообщениях", "mentioned in messages")
        }
    }
}

/// One compact row: icon, name with its folder underneath, a trailing mark; `hover` replaces the mark under the pointer.
enum SidebarRowIcon { case file(String), badge(String) }

struct SidebarRow<Trailing: View, Hover: View>: View {
    let icon: SidebarRowIcon
    let name: String
    let detail: String
    var struck = false
    let help: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let hover: () -> Hover
    let action: () -> Void
    @State private var hovering = false

    private var title: some View {
        Text(name).font(.ui(size: 12.5)).foregroundStyle(struck ? DeskPalette.muted : DeskPalette.ink)
            .strikethrough(struck, color: DeskPalette.muted).lineLimit(1).truncationMode(.middle)
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch icon {
                case .file(let path):
                    Image(nsImage: TranscriptLinks.fileIcon(URL(fileURLWithPath: path))).resizable().frame(width: 15, height: 15)
                case .badge(let ext):
                    FileTypeBadge(pathExtension: ext)
                }
            }
            .frame(width: 30)
            // One line per file: the name, then its folder in what room is left, so long lists stay dense.
            // The folder shows only when it fits whole; a cut-off fragment told nothing.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    title.fixedSize()
                    if !detail.isEmpty {
                        Text(detail).font(.ui(size: 10.5)).foregroundStyle(DeskPalette.muted).lineLimit(1).fixedSize()
                    }
                }
                title
            }
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                trailing().opacity(hovering && ObjectIdentifier(Hover.self) != ObjectIdentifier(EmptyView.self) ? 0 : 1)
                if hovering { hover() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? DeskPalette.rowHover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .pointingHandCursor()
        .help(help)
    }
}

/// A created file's type as a small rounded badge ("MD"), as attachments show it.
struct FileTypeBadge: View {
    let pathExtension: String
    var body: some View {
        Text(String((pathExtension.isEmpty ? "FILE" : pathExtension.uppercased()).prefix(4)))
            .font(.system(size: 7.5, weight: .semibold)).foregroundStyle(DeskPalette.inkSoft)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 4).frame(minWidth: 22, minHeight: 15)
            .fixedSize()
            .background(Capsule().fill(DeskPalette.canvas))
            .overlay(Capsule().stroke(DeskPalette.border, lineWidth: 1))
    }
}

/// The chat's changed files in their own window: the list on the left, the selected file's diff turn by turn on the
/// right, each turn with a jump to its answer and its own turn window (comments, restoring files).
@MainActor final class ChatChangesWindow: NSObject, NSWindowDelegate {
    private static var open: [ChatChangesWindow] = []
    private let files: ChatFilesModel
    private var window: NSWindow?

    static func show(_ files: ChatFilesModel, file: String?, model: DeskModel) {
        if let existing = open.first(where: { $0.files.chatID == files.chatID && files.chatID != nil }) {
            existing.files.openChange = file ?? existing.files.openChange
            existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ChatChangesWindow(files: files)
        open.append(controller)
        files.openChange = file ?? files.changed.first?.id
        let title = files.chatID.flatMap { id in model.state.chats.first { $0.id == id }?.title }
        controller.present(ChatChangesView(files: files, model: model), title: title)
    }

    private init(files: ChatFilesModel) { self.files = files }

    private func present(_ view: ChatChangesView, title: String?) {
        let content = view
            .buttonStyle(PointerButtonStyle(base: .automatic))
            .tint(DeskPalette.accent)
            .preferredColorScheme(.light)
            .environment(\.locale, L10n.locale)
        let window = EscapeClosingWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let base = L10n.text("Изменения чата", "Chat changes")
        window.title = title.map { base + " · " + $0 } ?? base
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - 520, y: parent.frame.midY - 340))
        } else { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}

private struct ChatChangesView: View {
    @ObservedObject var files: ChatFilesModel
    let model: DeskModel

    var body: some View {
        HSplitView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(files.changed) { file in
                            ChatChangesRow(file: file, selected: files.openChange == file.id) { files.openChange = file.id }
                                .id(file.id)
                        }
                    }
                    .padding(8)
                }
                .background(DeskPalette.sidebar)
                .focusable()
                .focusEffectDisabled()
                // Arrow keys move through the files, as in a list.
                .onKeyPress(.downArrow) { step(1, proxy) }
                .onKeyPress(.upArrow) { step(-1, proxy) }
            }
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 460)
            Group {
                if let file = files.openFile { ChatChangeDiffView(files: files, file: file, model: model) }
                else {
                    Text(files.changed.isEmpty ? L10n.text("Нет изменённых файлов", "No changed files") : L10n.text("Выберите файл", "Choose a file"))
                        .foregroundStyle(DeskPalette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)
        }
        .background(DeskPalette.canvas)
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !files.changed.isEmpty else { return .ignored }
        let current = files.changed.firstIndex { $0.id == files.openChange } ?? -1
        let next = files.changed[min(max(current + delta, 0), files.changed.count - 1)].id
        files.openChange = next
        proxy.scrollTo(next)
        return .handled
    }
}

/// A file in the chat changes window: the selection is a palette tint, so names and counts stay readable on it.
private struct ChatChangesRow: View {
    let file: ChatChangedFile
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(TurnChangesView.badge(file.status))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(TurnChangesView.tint(file.status)).frame(width: 14)
                .help(TurnChangesView.statusTitle(file.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(DeskPalette.ink).lineLimit(1)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.system(size: 11)).foregroundStyle(DeskPalette.muted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.turns.count > 1 {
                Text(L10n.text("ходов: \(file.turns.count)", "\(file.turns.count) turns")).font(.system(size: 10.5)).foregroundStyle(DeskPalette.muted)
            }
            if let added = file.added, let removed = file.removed {
                Text("+\(added)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DeskPalette.accentDeep)
                Text("−\(removed)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DeskPalette.problem)
            } else {
                Text(L10n.text("двоичный", "binary")).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? DeskPalette.selection : hovering ? DeskPalette.rowHover : .clear))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 1.5).fill(DeskPalette.accent).frame(width: 3).padding(.vertical, 6) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .pointingHandCursor()
    }
}

/// One changed file's diff, turn by turn.
private struct ChatChangeDiffView: View {
    @ObservedObject var files: ChatFilesModel
    let file: ChatChangedFile
    let model: DeskModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(files.displayPath(file.absolutePath)).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        .lineLimit(1).truncationMode(.head)
                }
                .help(file.absolutePath)
                Spacer(minLength: 8)
                if file.status != .deleted {
                    Button(EditorLauncher.openTitle) { EditorLauncher.open(file.absolutePath) }
                        .disabled(EditorLauncher.preferred == nil)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.turns) { entry in
                        turnHeader(entry.turn, change: entry.change)
                        patch(files.patches[entry.turn.itemID] ?? .loading, change: entry.change)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func turnHeader(_ turn: ChatTurnChanges, change: GitCheckpoints.FileChange) -> some View {
        HStack(spacing: 8) {
            Text(Self.turnTitle(turn)).font(.system(size: 12, weight: .semibold))
            Text(TurnChangesView.statusTitle(change.status)).font(.system(size: 11)).foregroundStyle(TurnChangesView.tint(change.status))
            if let old = change.oldPath, change.status == .renamed {
                Text(L10n.text("из ", "from ") + old).font(.system(size: 11)).foregroundStyle(DeskPalette.muted).lineLimit(1).truncationMode(.middle)
            }
            if !change.isBinary {
                Text("+\(change.added ?? 0)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DeskPalette.accentDeep)
                Text("−\(change.removed ?? 0)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DeskPalette.problem)
            }
            Spacer(minLength: 4)
            Button(L10n.text("К ответу", "Go to answer")) {
                TurnChangesWindow.showMainWindow?()
                TranscriptScrollView.chatTranscript?.reveal(itemID: turn.itemID)
            }
            .disabled(files.chatID != model.chatID)
            .help(files.chatID != model.chatID ? L10n.text("Откройте этот чат в главном окне", "Open this chat in the main window")
                                               : L10n.text("Перейти к ответу этого хода", "Go to this turn's answer"))
            Button(L10n.text("Окно хода", "Turn window")) {
                TurnChangesWindow.show(turn.changes, chatID: files.chatID, model: model, file: change.path)
            }
            .help(L10n.text("Изменения этого хода: комментарии для агента и возврат файлов",
                            "This turn's changes: comments for the agent and restoring files"))
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskPalette.subtle)
    }

    @ViewBuilder private func patch(_ state: ChatFilesModel.PatchState, change: GitCheckpoints.FileChange) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).padding(12).frame(maxWidth: .infinity)
        case .binary:
            notice(L10n.text("Двоичный файл: построчное сравнение не показывается.", "Binary file: no line-by-line diff."))
        case .tooLarge:
            notice(L10n.text("Изменение слишком большое для просмотра.", "This change is too large to show."))
        case .failed(let message):
            notice(L10n.text("Не удалось показать изменения: ", "Could not show the changes: ") + message)
        case .loaded(let lines, let truncated):
            if lines.isEmpty {
                notice(L10n.text("Содержимое не изменилось (только режим или имя).", "No content change (mode or name only)."))
            }
            ForEach(lines) { line in
                DiffLineRow(line: line, allowsComments: false)
                    .contextMenu {
                        DiffLineCopyItems(line: line, lines: lines)
                        if change.status != .deleted, let number = DiffComment.editorLine(line.id, in: lines) {
                            Button(EditorLauncher.openTitle + L10n.text(" на строке \(number)", " at line \(number)")) {
                                EditorLauncher.open(file.absolutePath, line: number)
                            }
                        }
                    }
            }
            if truncated {
                notice(L10n.text("Изменение слишком большое: показано начало.", "This change is too large: only the beginning is shown."))
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(DeskPalette.muted).padding(12)
    }

    static func turnTitle(_ turn: ChatTurnChanges) -> String {
        var title = L10n.text("Ход \(turn.number)", "Turn \(turn.number)")
        if let date = turn.completedAt {
            title += " · " + (Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                                                    : date.formatted(date: .abbreviated, time: .shortened))
        }
        return title
    }
}
