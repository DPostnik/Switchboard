import AppKit
import Quartz
import SwiftUI
import ContextCore

/// How a previewed file is shown: Markdown and source through the transcript renderer,
/// everything else (PDF, images, Office, plain text) through Quick Look.
public enum DocumentPreviewKind: Equatable, Sendable {
    case markdown
    case code(language: String)
    case quickLook
}

public enum DocumentPreview {
    /// Larger files go to Quick Look instead of the text renderer.
    public static let maxRenderedBytes = 2_000_000

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    static let codeLanguages: [String: String] = [
        "swift": "swift", "js": "js", "mjs": "js", "cjs": "js", "jsx": "jsx", "ts": "ts", "tsx": "tsx", "py": "python",
        "sh": "sh", "bash": "bash", "zsh": "zsh", "fish": "fish", "json": "json", "jsonc": "jsonc", "yaml": "yaml", "yml": "yaml",
        "toml": "toml", "ini": "ini", "go": "go", "rs": "rust", "c": "c", "h": "h", "cpp": "cpp", "cc": "cpp", "hpp": "cpp",
        "m": "objc", "mm": "objc", "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "cs", "sql": "sql",
        // Web sources are shown as text; they are never loaded as pages.
        "html": "html", "htm": "html", "xml": "xml", "svg": "xml", "plist": "plist", "css": "css", "scss": "scss",
    ]

    public static func kind(for url: URL, size: Int? = nil) -> DocumentPreviewKind {
        let ext = url.pathExtension.lowercased()
        let size = size ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= maxRenderedBytes else { return .quickLook }
        if markdownExtensions.contains(ext) { return .markdown }
        if let language = codeLanguages[ext] { return .code(language: language) }
        // Extensionless project files read best as plain code.
        if ["Makefile", "Dockerfile", "Gemfile", "Podfile"].contains(url.lastPathComponent) { return .code(language: "sh") }
        return .quickLook
    }

    /// Splits a long Markdown document at headings into parts of roughly `target` bytes, so the pane
    /// can show the first part at once and render the rest without freezing. Joining parts restores the text.
    public static func chunks(_ text: String, kind: DocumentPreviewKind, target: Int = 15_000, first: Int = 8_000) -> [String] {
        guard kind == .markdown, text.utf8.count > first else { return [text] }
        let lines = MarkdownBlocks.lines(text)
        var result: [String] = []
        var start = 0, size = 0
        for node in MarkdownBlocks.nodes(text) {
            let isHeading: Bool = { if case .heading = node.block { return true }; return false }()
            // A small first part paints at once; later parts are larger.
            let limit = result.isEmpty ? first : target
            if node.lines.lowerBound > start, size >= limit && isHeading || size >= limit * 4 {
                result.append(lines[start..<node.lines.lowerBound].joined(separator: "\n"))
                start = node.lines.lowerBound; size = 0
            }
            size += lines[node.lines].reduce(0) { $0 + $1.utf8.count + 1 }
        }
        result.append(lines[start...].joined(separator: "\n"))
        return result
    }

    /// Transcript source for a file: Markdown as is, source code as one fenced block that cannot be closed by its content.
    public static func transcriptText(_ content: String, kind: DocumentPreviewKind) -> String {
        guard case .code(let language) = kind else { return content }
        var longest = 0, run = 0
        for character in content {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + content + (content.hasSuffix("\n") || content.isEmpty ? "" : "\n") + fence
    }
}

/// One previewed file. It reloads when the file changes on disk; it never writes to it.
@MainActor public final class DocumentPreviewModel: ObservableObject {
    /// The file, without any `#anchor`.
    public let url: URL
    @Published public private(set) var kind: DocumentPreviewKind
    @Published public private(set) var text: String?
    /// `text` split for progressive rendering (Markdown only; one part otherwise).
    @Published public private(set) var chunks: [String] = []
    @Published public private(set) var failure: String?
    /// Increments on every observed change, also for Quick Look content.
    @Published public private(set) var revision = 0
    /// Where to scroll: a source line (code) or a heading anchor. `focusToken` changes on every request.
    @Published public private(set) var line: Int?
    @Published public private(set) var anchor: String?
    @Published public private(set) var focusToken = 0
    public nonisolated var id: String { url.path }
    weak var documentView: TranscriptScrollView?
    /// Kept with the document, not the view: expanding the preview recreates the view in another place,
    /// and the new one continues from the same reading position instead of the first lines or the link target.
    let readingPositions = TranscriptReadingPositions()
    var appliedFocusToken = -1
    var hasBeenShown = false
    private var stamp: [String]?
    private var splitting: Task<Void, Never>?

    public init(url: URL, line: Int? = nil) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path)
        self.line = line
        anchor = url.fragment.flatMap { $0.removingPercentEncoding ?? $0 }
        kind = DocumentPreview.kind(for: self.url)
        checkForChanges()
    }

    func focus(line: Int?, anchor: String?) {
        self.line = line; self.anchor = anchor; focusToken += 1
    }

    /// Re-reads the file when its modification date, size or identity changed (atomic saves replace the file).
    public func checkForChanges() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let current = attributes.map { [
            String(describing: $0[.modificationDate] ?? ""), String(describing: $0[.size] ?? ""),
            String(describing: $0[.systemFileNumber] ?? "")
        ] }
        guard current != stamp || (stamp == nil && failure == nil && text == nil) else { return }
        stamp = current
        guard current != nil else {
            setText(nil)
            failure = L10n.text("Файл не найден или недоступен.", "The file is missing or not readable.")
            revision += 1
            return
        }
        kind = DocumentPreview.kind(for: url)
        failure = nil
        if kind == .quickLook {
            setText(nil)
        } else if let data = try? Data(contentsOf: url) {
            if let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                setText(DocumentPreview.transcriptText(content, kind: kind))
            } else {
                // Not text after all: let Quick Look decide how to show it.
                kind = .quickLook; setText(nil)
            }
        } else {
            setText(nil)
            failure = L10n.text("Не удалось прочитать файл.", "Could not read the file.")
        }
        revision += 1
    }

    private func setText(_ value: String?) {
        text = value
        splitting?.cancel()
        guard let value else { chunks = []; return }
        let kind = kind
        // Small files split instantly; large ones off the main thread so the pane stays responsive.
        guard value.utf8.count > 200_000 else { chunks = DocumentPreview.chunks(value, kind: kind); return }
        if chunks.isEmpty { chunks = [String(value.prefix(20_000))] }
        splitting = Task { [weak self] in
            let parts = await Task.detached(priority: .userInitiated) { DocumentPreview.chunks(value, kind: kind) }.value
            guard !Task.isCancelled, let self, self.text == value else { return }
            self.chunks = parts
        }
    }

    func showFind() {
        guard let view = documentView else { return }
        view.window?.makeFirstResponder(view.transcript)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.transcript.performTextFinderAction(item)
    }
}

/// A selection in the preview, quoted into the chat draft so the user can ask the agent to change it.
public enum DocumentQuote {
    /// Source lines of a rendered Markdown selection: its first and last lines must each match one source line.
    public static func lines(of selection: String, in source: String) -> ClosedRange<Int>? {
        let wanted = selection.components(separatedBy: .newlines).map(plain).filter { !$0.isEmpty }
        guard let first = wanted.first, let last = wanted.last else { return nil }
        let lines = source.components(separatedBy: .newlines).map(plain)
        func unique(_ text: String) -> Int? {
            let hits = lines.indices.filter { lines[$0].contains(text) }
            return hits.count == 1 ? hits[0] + 1 : nil
        }
        guard let start = unique(first), let end = unique(last), end >= start else { return nil }
        return start...end
    }

    /// The file, its lines and the quote after the current draft; the user adds the request below it.
    public static func draft(path: String, lines: ClosedRange<Int>?, text: String, appendingTo draft: String) -> String {
        let location = lines.map { $0.count == 1 ? "\(path):\($0.lowerBound)" : "\(path):\($0.lowerBound)-\($0.upperBound)" } ?? path
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        let head = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (head.isEmpty ? "" : head + "\n\n") + "`" + location + "`\n" + quote + "\n\n"
    }

    /// A line without Markdown markup or rendered list marks, so rendered text matches its source.
    static func plain(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*((#{1,6}|[-*+]|\d+[.)]|>|[•◦▪‣☐☑✓])\s+|\[[ xX]\]\s+)*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Files opened in the pane with back and forward history.
@MainActor public final class DocumentPreviewSession: ObservableObject {
    @Published public private(set) var current: DocumentPreviewModel?
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    /// The preview fills the whole window: the chat and the sidebar step aside until it is collapsed or closed.
    @Published public var expanded = false
    private var back: [(URL, Int?)] = []
    private var forward: [(URL, Int?)] = []

    public init() {}

    public func open(_ url: URL, line: Int? = nil) {
        if let current { back.append(location(current)) }
        forward.removeAll()
        show(url, line: line)
    }

    public func goBack() {
        guard let previous = back.popLast() else { return }
        if let current { forward.append(location(current)) }
        show(previous.0, line: previous.1)
    }

    public func goForward() {
        guard let next = forward.popLast() else { return }
        if let current { back.append(location(current)) }
        show(next.0, line: next.1)
    }

    public func close() {
        current = nil; expanded = false; back.removeAll(); forward.removeAll(); updateFlags()
    }

    private func location(_ model: DocumentPreviewModel) -> (URL, Int?) {
        (TranscriptLinks.withAnchor(model.url, model.anchor), model.line)
    }

    private func show(_ url: URL, line: Int?) {
        let path = URL(fileURLWithPath: url.standardizedFileURL.path).path
        // Another place in the same file: keep the rendered document and just scroll.
        if let current, current.url.path == path {
            current.focus(line: line, anchor: url.fragment.flatMap { $0.removingPercentEncoding ?? $0 })
        } else {
            current = DocumentPreviewModel(url: url, line: line)
        }
        updateFlags()
    }

    private func updateFlags() { canGoBack = !back.isEmpty; canGoForward = !forward.isEmpty }
}

/// The preview pane: a header with navigation and file actions, the document below it.
public struct DocumentPreviewView: View {
    @ObservedObject var session: DocumentPreviewSession
    @ObservedObject var model: DocumentPreviewModel
    /// Puts a selected fragment (file, source lines, text) into the chat draft; nil hides the menu item.
    let onQuote: ((URL, String, ClosedRange<Int>?) -> Void)?

    public init(session: DocumentPreviewSession, model: DocumentPreviewModel, onQuote: ((URL, String, ClosedRange<Int>?) -> Void)? = nil) {
        self.session = session; self.model = model; self.onQuote = onQuote
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).help(L10n.text("Назад", "Back"))
                    .keyboardShortcut("[", modifiers: .command)
                Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward).help(L10n.text("Вперёд", "Forward"))
                    .keyboardShortcut("]", modifiers: .command)
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.url.path))
                    .resizable().frame(width: 16, height: 16)
                Text(model.url.lastPathComponent + (model.line.map { ":\($0)" } ?? ""))
                    .font(.ui(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .help(model.url.path)
                Spacer(minLength: 8)
                if model.text != nil {
                    Button { model.showFind() } label: { Image(systemName: "magnifyingglass") }
                        .help(L10n.text("Найти в документе (⌘F)", "Find in document (⌘F)"))
                }
                Button { NSWorkspace.shared.open(model.url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help(L10n.text("Открыть в программе по умолчанию", "Open in default app"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { Image(systemName: "folder") }
                    .help(L10n.text("Показать в Finder", "Show in Finder"))
                Button { session.expanded.toggle() } label: {
                    Image(systemName: session.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                    .help(session.expanded ? L10n.text("Вернуть рядом с чатом (⇧⌘↩)", "Back beside the chat (⇧⌘↩)")
                                           : L10n.text("Развернуть на всё окно (⇧⌘↩)", "Expand to the whole window (⇧⌘↩)"))
                    .accessibilityLabel(session.expanded ? L10n.text("Вернуть рядом с чатом", "Back beside the chat")
                                                         : L10n.text("Развернуть на всё окно", "Expand to the whole window"))
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button { if session.expanded { session.expanded = false } else { session.close() } } label: { Image(systemName: "xmark") }
                    .help(session.expanded ? L10n.text("Вернуть рядом с чатом (Esc)", "Back beside the chat (Esc)") : L10n.text("Закрыть предпросмотр", "Close preview"))
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(L10n.text("Предпросмотр документа", "Document preview"))
        .task(id: model.url) {
            // Follow edits by the agent or the user while the pane is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                model.checkForChanges()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark").font(.ui(size: 28)).foregroundStyle(.secondary)
                Text(failure).foregroundStyle(.secondary)
            }
        } else if model.text != nil {
            DocumentTextView(model: model, onOpenFile: { session.open($0, line: $1) },
                             onQuote: onQuote.map { quote in { [model] text, codeLines in
                                 // Code documents number their lines; Markdown is found in its source.
                                 let lines = model.kind == .markdown ? model.text.flatMap { DocumentQuote.lines(of: text, in: $0) } : codeLines
                                 quote(model.url, text, lines)
                             } })
        } else {
            QuickLookPreview(url: model.url, revision: model.revision)
        }
    }
}

/// Markdown and source code rendered by the transcript engine in document mode.
/// Long documents appear part by part so the window never freezes.
struct DocumentTextView: NSViewRepresentable {
    @ObservedObject var model: DocumentPreviewModel
    let onOpenFile: (URL, Int?) -> Void
    var onQuote: ((String, ClosedRange<Int>?) -> Void)?
    let zoom = InterfaceZoom.shared.scale

    func makeNSView(context: Context) -> TranscriptScrollView {
        let view = TranscriptScrollView(positions: model.readingPositions)
        view.isDocument = true
        view.transcript.usesFindBar = true
        view.transcript.isIncrementalSearchingEnabled = true
        return view
    }

    func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.onOpenFile = onOpenFile
        view.onQuoteSelection = onQuote
        view.zoom = zoom
        view.documentURL = model.url
        model.documentView = view
        let coordinator = context.coordinator
        if coordinator.chunks != model.chunks {
            coordinator.chunks = model.chunks
            coordinator.feeding?.cancel()
            let items = Self.items(model.chunks)
            let conversation = model.url.path
            let project = model.url.deletingLastPathComponent().path
            func show(_ count: Int) {
                view.update(items: Array(items.prefix(count)), conversationID: conversation, followOutput: false, projectPath: project)
            }
            // First parts at once, the rest a part per run-loop turn; parts already shown re-render only if changed.
            // A view recreated for an already shown document gets every part at once, so its saved position exists.
            let initial = min(items.count, max(1, model.hasBeenShown && coordinator.shown == 0 ? items.count : coordinator.shown))
            model.hasBeenShown = true
            show(initial)
            coordinator.shown = initial
            let pending = model.appliedFocusToken != model.focusToken
            coordinator.fed = false
            coordinator.feeding = Task { @MainActor in
                defer { coordinator.fed = !Task.isCancelled }
                var count = initial
                while count < items.count {
                    try? await Task.sleep(for: .milliseconds(15))
                    if Task.isCancelled { return }
                    count += 1
                    show(count)
                    coordinator.shown = count
                }
                if pending { coordinator.applyFocus(model, view) }
            }
        } else if model.appliedFocusToken != model.focusToken, coordinator.fed {
            coordinator.applyFocus(model, view)
        }
    }

    static func dismantleNSView(_ view: TranscriptScrollView, coordinator: Coordinator) { coordinator.feeding?.cancel() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var chunks: [String] = []
        var shown = 0
        var feeding: Task<Void, Never>?
        var fed = true
        func applyFocus(_ model: DocumentPreviewModel, _ view: TranscriptScrollView) {
            model.appliedFocusToken = model.focusToken
            if let line = model.line { view.scrollToCodeLine(line) }
            else if let anchor = model.anchor { view.scroll(toAnchor: TranscriptLinks.slug(anchor)) }
        }
    }

    static func items(_ chunks: [String]) -> [TranscriptItem] {
        chunks.enumerated().map { item($0.element, id: "document-\($0.offset)") }
    }

    static func item(_ text: String, id: String = "document") -> TranscriptItem {
        var item = TranscriptItem(id: id, kind: "assistant", text: text)
        item.showsAuthor = false
        item.showsCopyControl = false
        return item
    }
}

/// System Quick Look for PDF, images, Office documents, media and plain text.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        context.coordinator.state = (url, revision)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.state?.0 != url || context.coordinator.state?.1 != revision else { return }
        context.coordinator.state = (url, revision)
        if (view.previewItem as? NSURL) as URL? == url { view.refreshPreviewItem() } else { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var state: (URL, Int)? }
}

extension TranscriptScrollView {
    /// Scrolls to the heading whose slug matches (exactly, or as a prefix for shortened anchors).
    public func scroll(toAnchor slug: String) {
        guard !slug.isEmpty, let storage = transcript.textStorage else { return }
        var exact: Int?, prefix: Int?
        storage.enumerateAttribute(.headingSlug, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let heading = value as? String else { return }
            if heading == slug { exact = range.location; stop.pointee = true }
            else if prefix == nil, heading.hasPrefix(slug) || slug.hasPrefix(heading) && !heading.isEmpty { prefix = range.location }
        }
        guard let target = exact ?? prefix else { return }
        reveal(characterAt: target, context: 12)
    }

    private func reveal(characterAt target: Int, context: CGFloat) {
        guard let storage = transcript.textStorage, let manager = transcript.layoutManager,
              let container = transcript.textContainer else { return }
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: target)
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + transcript.textContainerOrigin.y - context)))
        reflectScrolledClipView(contentView)
        transcript.setSelectedRange(NSRange(location: target, length: 0))
        transcript.showFindIndicator(for: (storage.string as NSString).lineRange(for: NSRange(location: target, length: 0)))
    }

    /// Scrolls a numbered code document to a source line.
    public func scrollToCodeLine(_ line: Int) {
        guard let storage = transcript.textStorage else { return }
        var target: Int?
        storage.enumerateAttribute(.codeLineNumber, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? Int == line { target = range.location; stop.pointee = true }
        }
        // Leave a few lines of context above the target.
        if let target { reveal(characterAt: target, context: 80) }
    }
}
