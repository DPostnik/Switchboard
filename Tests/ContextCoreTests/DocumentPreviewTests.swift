import AppKit
import SwiftUI
import Testing
import ContextCore
@testable import ContextTranscript

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doc-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func documentPreviewChoosesRendererByTypeAndSize() {
    #expect(DocumentPreview.kind(for: URL(fileURLWithPath: "/x/README.md"), size: 10) == .markdown)
    #expect(DocumentPreview.kind(for: URL(fileURLWithPath: "/x/View.swift"), size: 10) == .code(language: "swift"))
    #expect(DocumentPreview.kind(for: URL(fileURLWithPath: "/x/page.html"), size: 10) == .code(language: "html"))
    #expect(DocumentPreview.kind(for: URL(fileURLWithPath: "/x/Makefile"), size: 10) == .code(language: "sh"))
    for name in ["report.pdf", "photo.png", "slides.key", "notes.txt", "data.csv"] {
        #expect(DocumentPreview.kind(for: URL(fileURLWithPath: "/x/" + name), size: 10) == .quickLook)
    }
    #expect(DocumentPreview.kind(for: URL(fileURLWithPath: "/x/big.md"), size: DocumentPreview.maxRenderedBytes + 1) == .quickLook)
    // Source containing a fence cannot close the block that wraps it.
    let wrapped = DocumentPreview.transcriptText("let s = \"```\"\n````\nend", kind: .code(language: "swift"))
    #expect(MarkdownBlocks.parse(wrapped) == [.code(MarkdownCode(language: "swift", text: "let s = \"```\"\n````\nend"))])
    #expect(DocumentPreview.transcriptText("# Title", kind: .markdown) == "# Title")
}

@Test @MainActor func documentPreviewModelFollowsFileChanges() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("NOTES.md")
    try "# First".write(to: file, atomically: true, encoding: .utf8)
    let model = DocumentPreviewModel(url: file)
    #expect(model.kind == .markdown)
    #expect(model.text == "# First")
    let revision = model.revision
    model.checkForChanges()
    #expect(model.revision == revision)
    // Atomic replacement (as editors and agents save) is picked up.
    try "# Second\n\nBody".write(to: file, atomically: true, encoding: .utf8)
    model.checkForChanges()
    #expect(model.text == "# Second\n\nBody")
    #expect(model.revision == revision + 1)
    try FileManager.default.removeItem(at: file)
    model.checkForChanges()
    #expect(model.text == nil)
    #expect(model.failure == L10n.text("Файл не найден или недоступен.", "The file is missing or not readable."))
    try "back".write(to: file, atomically: true, encoding: .utf8)
    model.checkForChanges()
    #expect(model.failure == nil && model.text == "back")
    // Binary content under a text extension falls back to Quick Look.
    let binary = directory.appendingPathComponent("blob.json")
    try Data([0xFF, 0xFE, 0x00, 0xD8, 0x00]).write(to: binary)
    let fallback = DocumentPreviewModel(url: binary)
    #expect(fallback.kind == .quickLook || fallback.text != nil)
}

@Test @MainActor func documentPreviewModelFollowsFileWithoutPolling() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("WATCHED.md")
    try "# First".write(to: file, atomically: true, encoding: .utf8)
    let model = DocumentPreviewModel(url: file)
    #expect(model.text == "# First")
    #expect(model.isWatching)
    func settle(until condition: @escaping @MainActor () -> Bool) async throws {
        // Changes are coalesced for 250 ms and read off the main thread; nobody calls checkForChanges here.
        for _ in 0..<60 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }
    // An atomic save replaces the inode; the watcher follows the path again afterwards.
    try "# Second\n\nBody".write(to: file, atomically: true, encoding: .utf8)
    try await settle { model.text == "# Second\n\nBody" }
    #expect(model.text == "# Second\n\nBody")
    #expect(model.isWatching)
    // A write in place (same inode) is picked up too.
    try Data("# Third".utf8).write(to: file, options: [])
    try await settle { model.text == "# Third" }
    #expect(model.text == "# Third")
    // Several quick edits produce one coalesced reload with the final content.
    let revision = model.revision
    for step in 1...5 { try Data("# Burst \(step)".utf8).write(to: file, options: []) }
    try await settle { model.text == "# Burst 5" }
    #expect(model.text == "# Burst 5")
    #expect(model.revision == revision + 1)
    // Deleting the file drops the watcher; the fallback poll re-arms it once the file is back.
    try FileManager.default.removeItem(at: file)
    try await settle { model.text == nil }
    #expect(model.text == nil && model.failure != nil)
    #expect(!model.isWatching)
    try "back".write(to: file, atomically: true, encoding: .utf8)
    await model.pollIfUnwatched()
    #expect(model.text == "back" && model.failure == nil)
    #expect(model.isWatching)
    // Missing files give no watcher; the model still reports the failure.
    let missing = DocumentPreviewModel(url: directory.appendingPathComponent("absent.md"))
    #expect(!missing.isWatching && missing.failure != nil)
}

@Test @MainActor func documentModeShowsWholeCodeWithoutChatChrome() throws {
    let code = (1...60).map { "let value\($0) = \($0)" }.joined(separator: "\n")
    let view = TranscriptScrollView()
    view.isDocument = true
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.update(items: [DocumentTextView.item(DocumentPreview.transcriptText(code, kind: .code(language: "swift")))],
                conversationID: "doc", followOutput: false)
    view.layoutSubtreeIfNeeded()
    let string = view.transcript.string
    #expect(string.contains("let value60 = 60"))
    #expect(!string.contains("Codex"))
    #expect(!string.contains(L10n.text("Показать ещё", "Show")))
    let storage = try #require(view.transcript.textStorage)
    var copyAll = false
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if (value as? String)?.hasPrefix("contextdesk-copy:") == true { copyAll = true }
    }
    #expect(!copyAll)
    view.scrollToCodeLine(45)
    let selected = view.transcript.selectedRange().location
    #expect((string as NSString).substring(from: selected).hasPrefix("let value45 = 45"))
    #expect(view.contentView.bounds.origin.y > 0)
}

@Test @MainActor func fileLinksOpenThePreviewWithTheirLine() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("Sources/View.swift")
    try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    var opened: [(URL, Int?)] = []
    view.onOpenFile = { opened.append(($0, $1)) }
    view.update(items: [TranscriptItem(id: "a", kind: "assistant", text: "См. Sources/View.swift:12 и папку [Sources](\(directory.path)/Sources)")],
                conversationID: "c", followOutput: false, projectPath: directory.path)
    let storage = try #require(view.transcript.textStorage)
    let index = (storage.string as NSString).range(of: "View.swift:12").location
    let link = try #require(storage.attribute(.link, at: index, effectiveRange: nil))
    _ = view.textView(view.transcript, clickedOnLink: link, at: index)
    #expect(opened.count == 1)
    #expect(opened.first?.0.standardizedFileURL.path == file.standardizedFileURL.path)
    #expect(opened.first?.1 == 12)
    // Folders open in Finder, not in the preview; modifiers choose Finder or the default app.
    #expect(TranscriptScrollView.fileClickAction([], url: directory, canPreview: true) == .open)
    #expect(TranscriptScrollView.fileClickAction([], url: file, canPreview: true) == .preview)
    #expect(TranscriptScrollView.fileClickAction([.command], url: file, canPreview: true) == .open)
    #expect(TranscriptScrollView.fileClickAction([.option], url: file, canPreview: true) == .reveal)
    #expect(TranscriptScrollView.fileClickAction([], url: file, canPreview: false) == .open)
    #expect(TranscriptScrollView.fileClickAction([], url: directory.appendingPathComponent("missing.md"), canPreview: true) == .open)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: index))
    #expect(menu.items.first?.title == L10n.text("Предпросмотр", "Preview"))
    menu.items.first.map { item in _ = (item.target as AnyObject?)?.perform(item.action, with: item) }
    #expect(opened.count == 2 && opened.last?.1 == 12)
}

@Test @MainActor func previewPaneRendersMarkdownDocument() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("GUIDE.md")
    try "# Guide\n\nIntro with `code` and a [link](https://example.com).\n\n- one\n- two\n\n| A | B |\n| --- | ---: |\n| x | 1 |\n\n```sh\n$ make\n```\n"
        .write(to: file, atomically: true, encoding: .utf8)
    let session = DocumentPreviewSession()
    session.open(file)
    let model = try #require(session.current)
    let host = NSHostingView(rootView: DocumentPreviewView(session: session, model: model)
        .frame(width: 520, height: 560))
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
    host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> TranscriptScrollView? {
        if let view = view as? TranscriptScrollView { return view }
        return view.subviews.lazy.compactMap(find).first
    }
    let document = try #require(find(host))
    #expect(document.isDocument)
    #expect(document.transcript.string.hasPrefix("Guide"))
    #expect(!document.transcript.string.contains("# Guide"))
    if let directory = ProcessInfo.processInfo.environment["SWITCHBOARD_MARKDOWN_RENDER_DIR"] {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("preview-pane.png"))
    }
}

@Test func markdownFrontMatterAndCommentsAreNotContent() {
    let blocks = MarkdownBlocks.parse("---\ntitle: \"Объективна ли мораль?\"\ndate: 2026-06-13\ntags: [philosophy, club]\naliases:\n  - Мораль\n---\n\n# Title\n<!-- note\nfor editors -->\nText")
    #expect(blocks == [
        .properties([MarkdownProperty(name: "title", values: ["Объективна ли мораль?"]), MarkdownProperty(name: "date", values: ["2026-06-13"]),
                     MarkdownProperty(name: "tags", values: ["philosophy", "club"]), MarkdownProperty(name: "aliases", values: ["Мораль"])]),
        .heading(level: 1, text: "Title"),
        .paragraph("Text"),
    ])
    // Dashes that are not front matter keep their Markdown meaning.
    #expect(MarkdownBlocks.parse("---\nJust text\n---") == [.rule, .paragraph("Just text"), .rule])
    #expect(MarkdownBlocks.parse("Intro\n\n---\nkey: value\n---").first == .paragraph("Intro"))
}

@Test func wikiIndexResolvesLikeObsidian() throws {
    let vault = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: vault) }
    try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    for path in ["wiki/index.md", "wiki/job-search/pipeline.md", "wiki/job-search/notes/deep.md", "archive/pipeline.md", "wiki/node_modules/x.md"] {
        let url = vault.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# \(path)".write(to: url, atomically: true, encoding: .utf8)
    }
    let index = WikiIndex(root: vault)
    let from = vault.appendingPathComponent("wiki/index.md")
    #expect(WikiIndex.root(for: vault.appendingPathComponent("wiki/job-search/pipeline.md"))?.standardizedFileURL.path == vault.standardizedFileURL.path)
    #expect(index.resolve("job-search/pipeline", from: from)?.path.hasSuffix("wiki/job-search/pipeline.md") == true)
    #expect(index.resolve("Index", from: from)?.path.hasSuffix("wiki/index.md") == true)
    #expect(index.resolve("deep.md", from: from)?.path.hasSuffix("notes/deep.md") == true)
    // Ambiguous names prefer the page closest to the linking file.
    #expect(index.resolve("pipeline", from: from)?.path.hasSuffix("wiki/job-search/pipeline.md") == true)
    #expect(index.resolve("pipeline", from: vault.appendingPathComponent("archive/other.md"))?.path.hasSuffix("archive/pipeline.md") == true)
    #expect(index.resolve("x", from: from) == nil)
    #expect(index.resolve("missing", from: from) == nil)
    #expect(WikiIndex.parse("page#Heading|Alias") == ("page", "Heading", "Alias"))
    #expect(WikiIndex.parse("#Local") == ("", "Local", nil))
}

@Test @MainActor func wikiLinksAnchorsAndInlineHTMLRenderInDocuments() throws {
    let vault = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: vault) }
    try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault.appendingPathComponent("wiki/job-search"), withIntermediateDirectories: true)
    let pipeline = vault.appendingPathComponent("wiki/job-search/pipeline.md")
    try "# Pipeline".write(to: pipeline, atomically: true, encoding: .utf8)
    let document = vault.appendingPathComponent("wiki/index.md")
    let text = """
    ---
    title: Index
    tags: [wiki]
    ---
    # Обзор раздела

    См. [[job-search/pipeline]], [[job-search/pipeline#Next steps|дальше]], [[nowhere]] и `[[code]]`.
    Строка<br>вторая, <b>жирно</b>. <!-- hidden --> [К разделу](#детали) и [файл](job-search/pipeline.md#pipeline).

    | ID | Blocker |
    | --- | --- |
    | V-1 | [[job-search/pipeline\\|Q-0138]] |

    ## Детали
    Конец.
    """
    try text.write(to: document, atomically: true, encoding: .utf8)
    let view = TranscriptScrollView()
    view.isDocument = true
    view.documentURL = document
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    var opened: [URL] = []
    view.onOpenFile = { url, _ in opened.append(url) }
    view.update(items: [DocumentTextView.item(text)], conversationID: "d", followOutput: false, projectPath: document.deletingLastPathComponent().path)
    view.layoutSubtreeIfNeeded()
    let storage = try #require(view.transcript.textStorage)
    let string = storage.string as NSString
    for hidden in ["---", "[[job", "[[now", "<br>", "<b>", "hidden", "title: Index"] { #expect(!storage.string.contains(hidden), "Leaked: \(hidden)") }
    #expect(storage.string.contains("#wiki"))
    #expect(storage.string.contains("Строка\nвторая"))
    #expect(storage.string.contains("[[code]]")) // inline code stays literal
    func link(_ text: String) -> Any? { storage.attribute(.link, at: string.range(of: text).location, effectiveRange: nil) }
    #expect((link("job-search/pipeline") as? URL)?.path == pipeline.standardizedFileURL.path)
    let anchored = try #require(link("дальше") as? URL)
    #expect(anchored.path == pipeline.standardizedFileURL.path && anchored.fragment?.removingPercentEncoding == "Next steps")
    #expect((link("Q-0138") as? URL)?.path == pipeline.standardizedFileURL.path)
    #expect(link("nowhere") == nil)
    #expect((link("файл") as? URL)?.fragment == "pipeline")
    #expect(link("К разделу") as? String == "contextdesk-anchor:детали")
    // The anchor scrolls to its heading; a wiki link opens the preview.
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-anchor:детали", at: string.range(of: "К разделу").location)
    #expect(string.substring(from: view.transcript.selectedRange().location).hasPrefix("Детали"))
    let wiki = string.range(of: "дальше").location
    _ = view.textView(view.transcript, clickedOnLink: try #require(link("дальше")), at: wiki)
    #expect(opened.last?.fragment != nil)
}

@Test @MainActor func longDocumentsSplitAtHeadingsAndTablesLimitRows() throws {
    let section = (1...200).map { "Строка абзаца номер \($0) с текстом." }.joined(separator: "\n\n")
    let text = (1...6).map { "## Раздел \($0)\n\n" + section }.joined(separator: "\n\n")
    let parts = DocumentPreview.chunks(text, kind: .markdown)
    #expect(parts.count > 1)
    #expect(parts.joined(separator: "\n") == text)
    #expect(parts.dropFirst().allSatisfy { $0.hasPrefix("## Раздел") })
    #expect(DocumentPreview.chunks(text, kind: .code(language: "swift")) == [text])

    let rows = (1...250).map { "| \($0) | value |" }.joined(separator: "\n")
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    view.update(items: [TranscriptItem(id: "t", kind: "assistant", text: "| N | V |\n| --- | --- |\n" + rows)], conversationID: "t", followOutput: false)
    #expect(view.transcript.string.contains("100\n"))
    #expect(!view.transcript.string.contains("101\n"))
    let title = L10n.text("Показать все 250 строк", "Show all 250 rows")
    let location = (view.transcript.string as NSString).range(of: title).location
    try #require(location != NSNotFound)
    let toggle = try #require(view.transcript.textStorage?.attribute(.link, at: location, effectiveRange: nil) as? String)
    _ = view.textView(view.transcript, clickedOnLink: toggle, at: location)
    #expect(view.transcript.string.contains("250\n"))
}

@Test @MainActor func previewSessionKeepsHistoryAndReusesTheOpenFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("a.md"), second = directory.appendingPathComponent("b.md")
    try "# A".write(to: first, atomically: true, encoding: .utf8)
    try "# B".write(to: second, atomically: true, encoding: .utf8)
    let session = DocumentPreviewSession()
    session.open(first)
    let model = try #require(session.current)
    session.open(TranscriptLinks.withAnchor(first, "Section"))
    #expect(session.current === model)
    #expect(model.anchor == "Section")
    session.open(second, line: 3)
    #expect(session.current?.url.lastPathComponent == "b.md")
    #expect(session.canGoBack && !session.canGoForward)
    session.goBack()
    #expect(session.current?.url.lastPathComponent == "a.md" && session.current?.anchor == "Section")
    #expect(session.canGoForward)
    session.goForward()
    #expect(session.current?.url.lastPathComponent == "b.md" && session.current?.line == 3)
    session.close()
    #expect(session.current == nil && !session.canGoBack)
}

@Test @MainActor func expandedPreviewCollapsesWhenClosedAndKeepsItsDocument() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("PLAN.md")
    try "# Plan\n\nText\n".write(to: file, atomically: true, encoding: .utf8)
    let session = DocumentPreviewSession()
    session.open(file)
    let model = try #require(session.current)
    session.expanded = true
    // Moving between the inspector and the whole window keeps the same document model.
    session.expanded = false
    #expect(session.current === model)
    session.expanded = true
    session.close()
    #expect(session.current == nil)
    #expect(!session.expanded)
}

@Test @MainActor func streamingUpdatesWaitUntilALinkClickEnds() throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Question"),
                 TranscriptItem(id: "t1", kind: "activity", text: "First tool")]
    view.update(items: items, conversationID: "c", followOutput: false, isWorking: true)
    let storage = try #require(view.transcript.textStorage)
    var index = NSNotFound, toggle: Any?
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
        if (value as? String)?.hasPrefix("contextdesk-action:") == true { index = range.location; toggle = value; stop.pointee = true }
    }
    let link = try #require(toggle)
    // AppKit's click tracking still runs streaming updates; they must not replace the clicked row until it ends.
    var duringClick = ""
    view.holdingEdits {
        view.update(items: items + [TranscriptItem(id: "t2", kind: "activity", text: "Second tool")],
                    conversationID: "c", followOutput: false, isWorking: true)
        duringClick = view.transcript.string
        _ = view.textView(view.transcript, clickedOnLink: link, at: index)
        #expect(view.transcript.string.contains("First tool"))
    }
    #expect(!duringClick.contains("Second tool"))
    #expect(view.transcript.string.contains("Second tool"))
    // Without a click updates apply at once.
    view.update(items: items, conversationID: "c", followOutput: false, isWorking: true)
    #expect(!view.transcript.string.contains("Second tool"))
}

@Test func quotedMarkdownSelectionFindsItsSourceLines() {
    let source = """
    # Plan

    The **first** step uses `cv.md` and [the guide](docs/guide.md).
    - Send the batch
    - [ ] Check the reply
    Repeated line
    Repeated line
    """
    // Rendered text has no markup; list marks may be part of the selection.
    #expect(DocumentQuote.lines(of: "The first step uses cv.md and the guide.", in: source) == 3...3)
    #expect(DocumentQuote.lines(of: "Plan\n\nThe first step uses cv.md", in: source) == 1...3)
    #expect(DocumentQuote.lines(of: "• Send the batch\nCheck the reply", in: source) == 4...5)
    // Several or no matches give no lines rather than a wrong range.
    #expect(DocumentQuote.lines(of: "Repeated line", in: source) == nil)
    #expect(DocumentQuote.lines(of: "Not in the file", in: source) == nil)
    #expect(DocumentQuote.lines(of: "  \n ", in: source) == nil)
}

@Test func quotedSelectionGoesIntoTheDraftWithFileAndLines() {
    #expect(DocumentQuote.draft(path: "docs/plan.md", lines: 3...5, text: "one\n\ntwo\n", appendingTo: "")
            == "`docs/plan.md:3-5`\n> one\n>\n> two\n\n")
    #expect(DocumentQuote.draft(path: "cv.md", lines: 7...7, text: "line", appendingTo: "Fix this:  \n")
            == "Fix this:\n\n`cv.md:7`\n> line\n\n")
    #expect(DocumentQuote.draft(path: "/tmp/a.txt", lines: nil, text: "x", appendingTo: "") == "`/tmp/a.txt`\n> x\n\n")
}

@Test @MainActor func codeSelectionMenuQuotesTheTextWithItsLines() throws {
    let code = (1...60).map { "let value\($0) = \($0)" }.joined(separator: "\n")
    let view = TranscriptScrollView()
    view.isDocument = true
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.update(items: [DocumentTextView.item(DocumentPreview.transcriptText(code, kind: .code(language: "swift")))],
                conversationID: "doc", followOutput: false)
    view.layoutSubtreeIfNeeded()
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    var quoted: [(String, ClosedRange<Int>?)] = []
    view.onQuoteSelection = { quoted.append(($0, $1)) }
    // No selection: no quote item.
    view.transcript.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: 0)).items.isEmpty)
    let string = view.transcript.string as NSString
    let start = string.range(of: "value45 = 45").location
    let end = NSMaxRange(string.range(of: "let value46"))
    view.transcript.setSelectedRange(NSRange(location: start, length: end - start))
    let menu = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: start))
    #expect(menu.items.first?.title == L10n.text("Попросить агента изменить", "Ask Agent to Edit"))
    menu.items.first.map { item in _ = (item.target as AnyObject?)?.perform(item.action, with: item) }
    #expect(quoted.count == 1 && quoted.first?.0 == "value45 = 45\nlet value46" && quoted.first?.1 == 45...46)
}
