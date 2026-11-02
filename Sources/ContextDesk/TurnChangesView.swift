import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// A turn's changed files in their own window: the file list on the left, the unified diff of the selected file on
/// the right, and "Restore files to before this turn". Opened from the changes row under an answer.
@MainActor final class TurnChangesWindow: NSObject, NSWindowDelegate {
    private static var open: [TurnChangesWindow] = []
    /// Set by the app: brings the main window forward, for "Go to message".
    static var showMainWindow: (() -> Void)?
    private let changes: TurnChanges
    private var window: NSWindow?

    static func show(_ changes: TurnChanges, chatID: String?, model: DeskModel) {
        if let existing = open.first(where: { $0.changes.start == changes.start && $0.changes.end == changes.end }) {
            existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = TurnChangesWindow(changes: changes)
        open.append(controller)
        let title = chatID.flatMap { id in model.state.chats.first { $0.id == id }?.title }
        controller.present(TurnChangesView(viewer: TurnChangesViewer(changes: changes, chatID: chatID, engine: model.turnCheckpoints.engine),
                                           model: model), title: title)
    }

    private init(changes: TurnChanges) { self.changes = changes }

    private func present(_ view: TurnChangesView, title: String?) {
        let content = view
            .buttonStyle(PointerButtonStyle(base: .automatic))
            .tint(DeskPalette.accent)
            .preferredColorScheme(.light)
            .environment(\.locale, L10n.locale)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let base = L10n.text("Изменения хода", "Turn changes")
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

@MainActor final class TurnChangesViewer: ObservableObject {
    enum PatchState: Equatable {
        case loading, binary, tooLarge
        case loaded([DiffLine], truncated: Bool)
        case failed(String)
    }
    struct RestorePlan: Identifiable {
        let id = UUID()
        let files: [GitCheckpoints.FileChange]
        let edited: Set<String>
        let checkIssue: String?
    }

    /// A comment already written into the chat draft, shown under its lines while the window is open.
    struct LineComment: Identifiable {
        let id = UUID()
        let file: String
        let lines: ClosedRange<Int>
        let text: String
    }

    let changes: TurnChanges
    let chatID: String?
    let engine: GitCheckpoints
    @Published private(set) var files: [GitCheckpoints.FileChange] = []
    @Published private(set) var loadIssue: String?
    @Published private(set) var loading = true
    @Published var selection: String? {
        didSet { if selection != oldValue { lineSelection = nil; commentText = ""; loadPatch() } }
    }
    /// Diff line indices picked for a comment: a click on a line number, Shift-click extends from the first one.
    @Published private(set) var lineSelection: ClosedRange<Int>?
    private var selectionAnchor: Int?
    @Published var commentText = ""
    @Published private(set) var comments: [LineComment] = []
    @Published private(set) var patch: PatchState = .loading
    @Published private(set) var preparing = false
    @Published private(set) var restoring = false
    @Published var plan: RestorePlan?
    @Published private(set) var outcome: (text: String, failed: Bool)?
    private var patchTask: Task<Void, Never>?

    init(changes: TurnChanges, chatID: String?, engine: GitCheckpoints) {
        self.changes = changes; self.chatID = chatID; self.engine = engine
    }

    func load() async {
        defer { loading = false }
        do {
            files = try await engine.changes(root: changes.repository, from: changes.start, to: changes.end)
            selection = files.first?.path
        } catch {
            loadIssue = L10n.text("Снимки этого хода больше недоступны: ", "This turn's checkpoints are no longer available: ") + error.localizedDescription
        }
    }

    private func loadPatch() {
        patchTask?.cancel()
        guard let file = files.first(where: { $0.path == selection }) else { patch = .loading; return }
        if file.isBinary { patch = .binary; return }
        patch = .loading
        let changes = changes, engine = engine
        patchTask = Task { [weak self] in
            let state: PatchState
            do {
                let result = try await engine.patch(root: changes.repository, from: changes.start, to: changes.end, file: file)
                if result.tooLarge { state = .tooLarge }
                else {
                    // Parsing a capped patch is cheap, but off the main actor all the same.
                    let lines = await Task.detached(priority: .userInitiated) { DiffLine.parse(result.text) }.value
                    state = .loaded(lines, truncated: result.truncated)
                }
            } catch { state = .failed(error.localizedDescription) }
            guard !Task.isCancelled, let self, self.selection == file.path else { return }
            self.patch = state
        }
    }

    /// The file's absolute path in the repository the turn ran in.
    func absolutePath(_ file: String) -> String {
        URL(fileURLWithPath: changes.repository).appendingPathComponent(file).path
    }

    func selectLine(_ index: Int, extend: Bool) {
        if extend, let anchor = selectionAnchor {
            lineSelection = min(anchor, index)...max(anchor, index)
        } else if lineSelection == index...index {
            clearLineSelection()
        } else {
            selectionAnchor = index; lineSelection = index...index
        }
    }

    func clearLineSelection() { lineSelection = nil; selectionAnchor = nil; commentText = "" }

    /// Writes the selected lines and the comment into the chat draft; the comment stays visible under the lines.
    func addComment(lines: [DiffLine], model: DeskModel) {
        guard let file = selection, let range = lineSelection, lines.indices.contains(range.upperBound) else { return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = DiffComment.codeLines(lines[range])
        guard !text.isEmpty, !picked.isEmpty else { return }
        let absolute = absolutePath(file)
        let path = chatID.flatMap(model.workingDirectory(forChat:)).flatMap { TranscriptScrollView.relativePath(absolute, project: $0) } ?? absolute
        model.updateDraft(chatID: chatID) { DiffComment.draft(path: path, lines: picked, comment: text, appendingTo: $0) }
        comments.append(LineComment(file: file, lines: range, text: text))
        clearLineSelection()
    }

    /// Checks which files were edited after the turn, then asks for confirmation.
    func prepareRestore() async {
        guard !files.isEmpty, !preparing, !restoring else { return }
        preparing = true; outcome = nil
        defer { preparing = false }
        do {
            let edited = try await engine.editedSince(root: changes.repository, end: changes.end, files: files)
            plan = RestorePlan(files: files, edited: edited, checkIssue: nil)
        } catch {
            plan = RestorePlan(files: files, edited: [], checkIssue: error.localizedDescription)
        }
    }

    /// Runs once; errors are reported, never retried.
    func restore(_ plan: RestorePlan) async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let report = try await engine.restore(root: changes.repository, to: changes.start, files: plan.files)
            let done = report.restored.count + report.deleted.count
            if report.failures.isEmpty {
                outcome = (L10n.text("Файлы возвращены к началу хода: \(done).", "Restored \(done) \(done == 1 ? "file" : "files") to before this turn."), false)
            } else {
                outcome = (L10n.text("Возвращено файлов: \(done). Не удалось: ", "Restored \(done). Failed: ") + report.failures.joined(separator: "; "), true)
            }
        } catch {
            outcome = (L10n.text("Файлы не возвращены: ", "Files were not restored: ") + error.localizedDescription, true)
        }
    }

    static func message(_ plan: RestorePlan) -> String {
        var lines = [L10n.text("Вернутся только файлы: разговор и история чата не изменятся. Файлы, созданные в этом ходе, будут удалены.",
                               "Only files are restored: the conversation and chat history stay as they are. Files created in this turn will be deleted.")]
        lines.append("")
        for file in plan.files.prefix(20) {
            var line = "• " + file.path
            if file.status == .added || file.status == .copied { line += L10n.text(" — будет удалён", " — will be deleted") }
            if file.status == .renamed, let old = file.oldPath { line += L10n.text(" — вернётся как \(old)", " — back to \(old)") }
            if plan.edited.contains(file.path) || file.oldPath.map(plan.edited.contains) == true {
                line += L10n.text(" (изменён после этого хода)", " (edited after this turn)")
            }
            lines.append(line)
        }
        if plan.files.count > 20 { lines.append(L10n.text("…и ещё \(plan.files.count - 20)", "…and \(plan.files.count - 20) more")) }
        if !plan.edited.isEmpty {
            lines.append("")
            lines.append(L10n.text("Файлы, изменённые после этого хода, потеряют и эти более поздние правки.",
                                   "Files edited after this turn will lose those later edits too."))
        }
        if let issue = plan.checkIssue {
            lines.append("")
            lines.append(L10n.text("Не удалось проверить, менялись ли файлы после хода: ", "Could not check whether the files changed after this turn: ") + issue)
        }
        return lines.joined(separator: "\n")
    }
}

struct TurnChangesView: View {
    @ObservedObject var viewer: TurnChangesViewer
    /// Not observed here: only the restore button follows the model's running chats.
    let model: DeskModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewer.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let issue = viewer.loadIssue {
                Text(issue).foregroundStyle(DeskPalette.muted).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    fileList.frame(minWidth: 220, idealWidth: 300, maxWidth: 460)
                    diff.frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(DeskPalette.canvas)
        .task { await viewer.load() }
        .alert(L10n.text("Вернуть файлы к началу хода?", "Restore files to before this turn?"),
               isPresented: Binding(get: { viewer.plan != nil }, set: { if !$0 { viewer.plan = nil } }), presenting: viewer.plan) { plan in
            Button(L10n.text("Вернуть файлы", "Restore files"), role: .destructive) { Task { await viewer.restore(plan) } }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) {}
        } message: { plan in
            Text(TurnChangesViewer.message(plan))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).font(.system(size: 13, weight: .semibold)).foregroundStyle(DeskPalette.ink)
                if viewer.changes.otherChats == true {
                    Text(L10n.text("Во время хода в этой папке работал другой чат: его правки могут быть здесь.",
                                   "Another chat worked in this folder during the turn: its edits may be included."))
                        .font(.system(size: 12)).foregroundStyle(DeskPalette.attentionInk)
                }
                if let outcome = viewer.outcome {
                    Text(outcome.text).font(.system(size: 12)).textSelection(.enabled)
                        .foregroundStyle(outcome.failed ? DeskPalette.problemInk : DeskPalette.accentDeep)
                }
                if viewer.comments.isEmpty {
                    Text(L10n.text("Нажмите на номер строки, чтобы прокомментировать её для агента; Shift-клик выделяет диапазон.",
                                   "Click a line number to comment on it for the agent; Shift-click selects a range."))
                        .font(.system(size: 11.5)).foregroundStyle(DeskPalette.muted)
                } else {
                    let count = viewer.comments.count
                    Text(L10n.text("Комментариев в сообщении чата: \(count). Они уйдут агенту, когда вы отправите сообщение.",
                                   "\(count) \(count == 1 ? "comment" : "comments") in the chat's message. They reach the agent when you send it."))
                        .font(.system(size: 11.5)).foregroundStyle(DeskPalette.accentDeep)
                }
            }
            Spacer(minLength: 12)
            if viewer.preparing || viewer.restoring { ProgressView().controlSize(.small) }
            if !viewer.comments.isEmpty {
                Button(L10n.text("Перейти к сообщению", "Go to message")) { goToMessage() }
            }
            if let file = selectedFile, file.status != .deleted {
                Button(EditorLauncher.openTitle) {
                    EditorLauncher.open(viewer.absolutePath(file.path), line: firstChangedLine)
                }
                .help(L10n.text("Открыть файл на первом изменении", "Open the file at its first change"))
            }
            RestoreButton(viewer: viewer, model: model)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var selectedFile: GitCheckpoints.FileChange? { viewer.files.first { $0.path == viewer.selection } }

    private var firstChangedLine: Int? {
        guard case .loaded(let lines, _) = viewer.patch else { return nil }
        return lines.first { $0.kind == .added }?.new ?? lines.firstIndex { $0.kind == .removed }.flatMap { DiffComment.editorLine($0, in: lines) }
    }

    /// Opens the chat this turn belongs to with the comments in its composer.
    private func goToMessage() {
        TurnChangesWindow.showMainWindow?()
        Task {
            if let id = viewer.chatID, id != model.chatID, let chat = model.state.chats.first(where: { $0.id == id }) {
                await model.openChat(chat)
            }
            model.focusComposer()
        }
    }

    private var summary: String {
        guard !viewer.loading, viewer.loadIssue == nil else { return viewer.changes.label() }
        var counted = viewer.changes
        counted.files = viewer.files.count
        counted.added = viewer.files.reduce(0) { $0 + ($1.added ?? 0) }
        counted.removed = viewer.files.reduce(0) { $0 + ($1.removed ?? 0) }
        counted.otherChats = nil
        return counted.label()
    }

    private var fileList: some View {
        List(viewer.files, selection: $viewer.selection) { file in
            HStack(spacing: 8) {
                Text(Self.badge(file.status))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.tint(file.status))
                    .frame(width: 14)
                    .help(Self.statusTitle(file.status))
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
                    let folder = (file.path as NSString).deletingLastPathComponent
                    if let old = file.oldPath {
                        Text(L10n.text("из ", "from ") + old).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                            .lineLimit(1).truncationMode(.middle)
                    } else if !folder.isEmpty {
                        Text(folder).font(.system(size: 11)).foregroundStyle(DeskPalette.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if file.isBinary {
                    Text(L10n.text("двоичный", "binary")).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                } else {
                    Text("+\(file.added ?? 0)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DeskPalette.accentDeep)
                    Text("−\(file.removed ?? 0)").font(.system(size: 11).monospacedDigit()).foregroundStyle(DeskPalette.problem)
                }
            }
            .padding(.vertical, 2)
            .tag(file.path)
            .contextMenu {
                if file.status != .deleted {
                    OpenInEditorMenu(path: viewer.absolutePath(file.path))
                    Button(L10n.text("Показать в Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: viewer.absolutePath(file.path))])
                    }
                    Divider()
                }
                Button(L10n.text("Скопировать путь", "Copy path")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var diff: some View {
        switch viewer.patch {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            notice(L10n.text("Двоичный файл: построчное сравнение не показывается.", "Binary file: no line-by-line diff."))
        case .tooLarge:
            notice(L10n.text("Изменение слишком большое для просмотра.", "This change is too large to show."))
        case .failed(let message):
            notice(L10n.text("Не удалось показать изменения: ", "Could not show the changes: ") + message)
        case .loaded(let lines, let truncated):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty {
                        Text(L10n.text("Содержимое не изменилось (только режим или имя).", "No content change (mode or name only)."))
                            .font(.system(size: 12)).foregroundStyle(DeskPalette.muted).padding(12)
                    }
                    ForEach(lines) { line in
                        DiffLineRow(line: line, selected: viewer.lineSelection?.contains(line.id) == true) { extend in
                            viewer.selectLine(line.id, extend: extend)
                        }
                        .contextMenu { lineMenu(line, lines: lines) }
                        if viewer.lineSelection?.upperBound == line.id {
                            DiffCommentEditor(viewer: viewer, lines: lines, model: model)
                        }
                        ForEach(viewer.comments.filter { $0.file == viewer.selection && $0.lines.upperBound == line.id }) { comment in
                            DiffCommentNote(text: comment.text)
                        }
                    }
                    if truncated {
                        Text(L10n.text("Изменение слишком большое: показано начало.", "This change is too large: only the beginning is shown."))
                            .font(.system(size: 12)).foregroundStyle(DeskPalette.attentionInk).padding(12)
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder private func lineMenu(_ line: DiffLine, lines: [DiffLine]) -> some View {
        if line.kind != .hunk && line.kind != .note {
            Button(L10n.text("Прокомментировать для агента", "Comment for the agent")) { viewer.selectLine(line.id, extend: false) }
        }
        if let file = selectedFile, file.status != .deleted, let number = DiffComment.editorLine(line.id, in: lines) {
            Button(EditorLauncher.openTitle + L10n.text(" на строке \(number)", " at line \(number)")) {
                EditorLauncher.open(viewer.absolutePath(file.path), line: number)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(DeskPalette.muted).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func badge(_ status: GitCheckpoints.FileChange.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        }
    }

    static func statusTitle(_ status: GitCheckpoints.FileChange.Status) -> String {
        switch status {
        case .added: L10n.text("Добавлен", "Added")
        case .modified: L10n.text("Изменён", "Modified")
        case .deleted: L10n.text("Удалён", "Deleted")
        case .renamed: L10n.text("Переименован", "Renamed")
        case .copied: L10n.text("Скопирован", "Copied")
        case .typeChanged: L10n.text("Изменён тип", "Type changed")
        }
    }

    static func tint(_ status: GitCheckpoints.FileChange.Status) -> Color {
        switch status {
        case .added, .copied: DeskPalette.accent
        case .deleted: DeskPalette.problem
        case .renamed, .typeChanged: DeskPalette.attention
        case .modified: DeskPalette.muted
        }
    }
}

/// Disabled while any chat in the project (or the same repository) is running.
private struct RestoreButton: View {
    @ObservedObject var viewer: TurnChangesViewer
    @ObservedObject var model: DeskModel

    var body: some View {
        let blocked = model.turnChangesBlocked(viewer.changes, chatID: viewer.chatID)
        Button(L10n.text("Вернуть файлы к началу хода", "Restore files to before this turn")) {
            Task { await viewer.prepareRestore() }
        }
        .disabled(blocked || viewer.loading || viewer.files.isEmpty || viewer.preparing || viewer.restoring)
        .help(blocked ? L10n.text("Недоступно, пока в этом проекте работает чат.", "Unavailable while a chat in this project is running.")
                      : L10n.text("Возвращает только файлы этого хода; разговор не меняется.", "Restores only this turn's files; the conversation is unchanged."))
    }
}

/// One diff line: old and new line numbers, then the text on a green (added) or red (removed) wash.
/// The line numbers are the comment handle: a click picks the line, Shift-click extends the pick.
private struct DiffLineRow: View {
    let line: DiffLine
    var selected = false
    var pick: (_ extend: Bool) -> Void = { _ in }
    @State private var hovering = false
    private static let added = Color(nsColor: DeskPalette.ns.accent.withAlphaComponent(0.13))
    private static let removed = Color(nsColor: DeskPalette.ns.problem.withAlphaComponent(0.11))
    private static let picked = Color(nsColor: DeskPalette.ns.attention.withAlphaComponent(0.22))

    private var commentable: Bool { line.kind != .hunk && line.kind != .note }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                number(line.old)
                number(line.new)
            }
            .background(hovering && commentable ? DeskPalette.subtle : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && commentable }
            .onTapGesture {
                guard commentable else { return }
                pick(NSEvent.modifierFlags.contains(.shift))
            }
            .pointingHandCursor()
            .disabled(!commentable)
            .help(commentable ? L10n.text("Прокомментировать строку для агента (Shift — диапазон)", "Comment on this line for the agent (Shift for a range)") : "")
            Group {
                if hovering { Image(systemName: "plus.bubble").font(.system(size: 9.5)).foregroundStyle(DeskPalette.accentDeep) }
                else { Text(sign).foregroundStyle(DeskPalette.muted) }
            }
            .frame(width: 16, alignment: .center)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? DeskPalette.muted : DeskPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 3 : 0.5)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(DeskPalette.attention).frame(width: 3) }
        }
        .background(selected ? Self.picked : .clear)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Self.added
        case .removed: Self.removed
        case .hunk: DeskPalette.subtle
        case .context, .note: .clear
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(DeskPalette.muted.opacity(0.75))
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

/// Under the last picked line: the comment, then "Add to message" puts lines and comment into the chat draft.
private struct DiffCommentEditor: View {
    @ObservedObject var viewer: TurnChangesViewer
    let lines: [DiffLine]
    let model: DeskModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let range = viewer.lineSelection, let file = viewer.selection {
                Text(DiffComment.location(path: file, lines: DiffComment.codeLines(lines[range])))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(DeskPalette.muted)
            }
            TextField(L10n.text("Что изменить или проверить в этих строках?", "What should change or be checked in these lines?"),
                      text: $viewer.commentText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...10)
                .focused($focused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeskPalette.focusBorder, lineWidth: 1))
            HStack {
                Text(L10n.text("Комментарий попадёт в сообщение чата; отправите его вы.", "The comment goes into the chat's message; you send it."))
                    .font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                Spacer()
                Button(L10n.text("Отмена", "Cancel")) { viewer.clearLineSelection() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Добавить в сообщение", "Add to message")) { viewer.addComment(lines: lines, model: model) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewer.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("⌘↩")
            }
        }
        .padding(10)
        .background(DeskPalette.subtle)
        .padding(.leading, 116).padding(.trailing, 16).padding(.vertical, 6)
        .onAppear { focused = true }
    }
}

/// A comment already in the chat draft, under the lines it is about.
private struct DiffCommentNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(DeskPalette.accentDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 12.5)).foregroundStyle(DeskPalette.ink).textSelection(.enabled)
                Text(L10n.text("В сообщении чата", "In the chat's message")).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(DeskPalette.subtle))
        .padding(.leading, 116).padding(.trailing, 16).padding(.vertical, 4)
    }
}
