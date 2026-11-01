import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// A turn's changed files in their own window: the file list on the left, the unified diff of the selected file on
/// the right, and "Restore files to before this turn". Opened from the changes row under an answer.
@MainActor final class TurnChangesWindow: NSObject, NSWindowDelegate {
    private static var open: [TurnChangesWindow] = []
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

    let changes: TurnChanges
    let chatID: String?
    let engine: GitCheckpoints
    @Published private(set) var files: [GitCheckpoints.FileChange] = []
    @Published private(set) var loadIssue: String?
    @Published private(set) var loading = true
    @Published var selection: String? { didSet { if selection != oldValue { loadPatch() } } }
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
            }
            Spacer(minLength: 12)
            if viewer.preparing || viewer.restoring { ProgressView().controlSize(.small) }
            RestoreButton(viewer: viewer, model: model)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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
                    ForEach(lines) { line in DiffLineRow(line: line) }
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
private struct DiffLineRow: View {
    let line: DiffLine
    private static let added = Color(nsColor: DeskPalette.ns.accent.withAlphaComponent(0.13))
    private static let removed = Color(nsColor: DeskPalette.ns.problem.withAlphaComponent(0.11))

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.old)
            number(line.new)
            Text(sign).foregroundStyle(DeskPalette.muted).frame(width: 16, alignment: .center)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? DeskPalette.muted : DeskPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 3 : 0.5)
        .background(background)
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
