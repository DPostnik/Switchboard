import AppKit
import Testing
import ContextCore
@testable import ContextTranscript

@MainActor private func renderedView(_ text: String, width: CGFloat = 760, height: CGFloat = 900, project: String? = nil,
                                     pasteboard: NSPasteboard? = nil) -> TranscriptScrollView {
    let view = pasteboard.map { TranscriptScrollView(pasteboard: $0) } ?? TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    view.update(items: [TranscriptItem(id: "answer", kind: "assistant", text: text)], conversationID: "markdown",
                followOutput: false, projectPath: project)
    view.layoutSubtreeIfNeeded()
    return view
}

@MainActor private func location(of text: String, in view: TranscriptScrollView) -> Int {
    (view.transcript.string as NSString).range(of: text).location
}

@MainActor private func links(in view: TranscriptScrollView, prefix: String) -> [(Int, String)] {
    let storage = view.transcript.textStorage!
    var result: [(Int, String)] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        if let value = value as? String, value.hasPrefix(prefix) { result.append((range.location, value)) }
    }
    return result
}

@MainActor private func writeRender(_ view: TranscriptScrollView, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["SWITCHBOARD_MARKDOWN_RENDER_DIR"] else { return }
    view.drawsBackground = true
    view.backgroundColor = .textBackgroundColor
    let manager = try #require(view.transcript.layoutManager)
    manager.ensureLayout(for: try #require(view.transcript.textContainer))
    view.frame.size.height = min(4000, view.transcript.frame.height + 10)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}

private let sampleAnswer = """
# План работ

Короткое вступление с **жирным**, *курсивом*, ~~зачёркнутым~~, ==выделенным== текстом и `inline code`.
Ссылка на [документацию](https://developer.apple.com/documentation/appkit) и сноска[^1].

## Шаги

1. Подготовить окружение
2. Собрать проект
   - проверить `swift build`
   - [x] тесты зелёные
   - [ ] обновить документацию
10. Десятый пункт

---

> [!WARNING]
> Не запускайте миграцию без резервной копии.

> [!TIP] Подсказка
> Используйте `--filter` для выборочных тестов.

```swift
import AppKit

/// Пример
struct Card: View {
    let title = "Hello" // comment
    var count = 42
}
```

```console
$ swift build
Compiling ContextDesk
$ swift test
```

```diff
@@ -1,3 +1,3 @@
 unchanged
-removed line
+added line
```

| Сервис | Запросов | Доля |
| --- | --- | --- |
| API | 1 200 | 54% |
| Web | 980 | 44% |
| CLI | 40 | 2% |

> Готовый текст письма.
>
> С уважением,
> Даниил

<details>
<summary>Подробности</summary>

Скрытый текст.
</details>

[^1]: Текст сноски.
"""

@Test @MainActor func answerMarkdownRendersBlocksWithoutMarkup() throws {
    let view = renderedView(sampleAnswer)
    let string = view.transcript.string
    for markup in ["# План", "## Шаги", "**жирным**", "~~зач", "==выдел", "[^1]", "> [!WARNING]", "```", "| --- |", "<details>", "- [x]"] {
        #expect(!string.contains(markup), "Markup leaked: \(markup)")
    }
    for text in ["План работ", "Шаги", "жирным", "выделенным", "Подготовить окружение", "Десятый пункт", "Внимание",
                 "Подсказка", "import AppKit", "swift build", "added line", "Сервис", "Готовый текст письма.", "Подробности", "Текст сноски."] {
        #expect(string.contains(text), "Missing: \(text)")
    }
    #expect(!string.contains("Скрытый текст."))
    let storage = try #require(view.transcript.textStorage)
    let heading = location(of: "План работ", in: view)
    #expect((storage.attribute(.font, at: heading, effectiveRange: nil) as? NSFont)?.pointSize == 21)
    let bold = location(of: "жирным", in: view)
    #expect((storage.attribute(.font, at: bold, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(storage.attribute(.strikethroughStyle, at: location(of: "зачёркнутым", in: view), effectiveRange: nil) != nil)
    #expect(storage.attribute(.backgroundColor, at: location(of: "выделенным", in: view), effectiveRange: nil) != nil)
    // Keywords are colored, numbers right-aligned in tables.
    let keyword = location(of: "struct", in: view)
    #expect(storage.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor == .systemPink)
    let number = location(of: "1 200", in: view)
    #expect((storage.attribute(.paragraphStyle, at: number, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right)
    // Ten-line code blocks would be numbered; this six-line one is not.
    var numbers = 0
    storage.enumerateAttribute(.codeLineNumber, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value != nil { numbers += 1 } }
    #expect(numbers == 0)
    for width: CGFloat in [760, 380] {
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.transcript.layoutManager)
        let container = try #require(view.transcript.textContainer)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).maxX <= container.containerSize.width + 1)
        try writeRender(view, name: "markdown-\(Int(width))")
    }
}

@Test @MainActor func codeTableAndSectionControlsCopyTheirOwnSource() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = renderedView(sampleAnswer, pasteboard: pasteboard)
    let storage = try #require(view.transcript.textStorage)
    var controls: [(Int, String)] = []
    storage.enumerateAttribute(.blockCopy, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        if let text = value as? String { controls.append((range.location, text)) }
    }
    let texts = controls.map(\.1)
    #expect(texts.contains("import AppKit\n\n/// Пример\nstruct Card: View {\n    let title = \"Hello\" // comment\n    var count = 42\n}"))
    #expect(texts.contains("swift build\nswift test"))
    #expect(texts.contains { $0.hasPrefix("## Шаги\n\n1. Подготовить") && $0.contains("10. Десятый пункт") })
    let console = try #require(controls.first { $0.1 == "swift build\nswift test" })
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-block-copy", at: console.0)
    #expect(pasteboard.string(forType: .string) == "swift build\nswift test")
    #expect(view.transcript.string.contains(L10n.text("Скопировано", "Copied")))

    let tsv = try #require(links(in: view, prefix: "contextdesk-table:tsv").first)
    _ = view.textView(view.transcript, clickedOnLink: tsv.1, at: tsv.0)
    #expect(pasteboard.string(forType: .string) == "Сервис\tЗапросов\tДоля\nAPI\t1 200\t54%\nWeb\t980\t44%\nCLI\t40\t2%")
    let markdown = try #require(links(in: view, prefix: "contextdesk-table:md").first)
    _ = view.textView(view.transcript, clickedOnLink: markdown.1, at: markdown.0)
    #expect(pasteboard.string(forType: .string)?.hasPrefix("| Сервис | Запросов | Доля |\n| --- | --- | --- |") == true)
    // The whole-message copy still copies the original source.
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:answer", at: 0)
    #expect(pasteboard.string(forType: .string) == sampleAnswer)
}

@Test @MainActor func longCodeCollapsesWithNumbersAndDetailsExpand() throws {
    let code = (1...40).map { "line \($0)" }.joined(separator: "\n")
    let view = renderedView("```python\n\(code)\n```\n\n<details><summary>More</summary>\nHidden body\n</details>")
    let storage = try #require(view.transcript.textStorage)
    #expect(view.transcript.string.contains("line 20"))
    #expect(!view.transcript.string.contains("line 21"))
    #expect(view.transcript.string.contains(L10n.text("Показать ещё 20 строк", "Show 20 more lines")))
    var numbers: [Int] = []
    storage.enumerateAttribute(.codeLineNumber, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if let value = value as? Int { numbers.append(value) }
    }
    #expect(numbers == Array(1...20))
    let toggles = links(in: view, prefix: "contextdesk-toggle:")
    #expect(toggles.count == 2)
    _ = view.textView(view.transcript, clickedOnLink: toggles[0].1, at: toggles[0].0)
    #expect(view.transcript.string.contains("line 40"))
    #expect(view.transcript.string.contains(L10n.text("Свернуть", "Collapse")))
    let details = try #require(links(in: view, prefix: "contextdesk-toggle:").last)
    _ = view.textView(view.transcript, clickedOnLink: details.1, at: details.0)
    #expect(view.transcript.string.contains("Hidden body"))
    // Copy keeps all 40 lines even while collapsed.
    var copied: String?
    storage.enumerateAttribute(.blockCopy, in: NSRange(location: 0, length: storage.length)) { value, _, _ in copied = copied ?? value as? String }
    #expect(copied == code)
}

@Test @MainActor func fileReferencesBecomeChipsOnlyWhenTheFileExists() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md-links-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Sources/View.swift")
    try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
    let text = "Правка в Sources/View.swift:12 и `Sources/View.swift`, нет файла Sources/Missing.swift, "
        + "ссылка [\(file.path):3](\(file.path):3) и сайт https://example.com/very/long/path/that/keeps/going/and/going/on"
    let view = renderedView(text, project: directory.path)
    let storage = try #require(view.transcript.textStorage)
    var fileLinks: [(String, URL)] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        guard let url = value as? URL, url.isFileURL else { return }
        fileLinks.append(((storage.string as NSString).substring(with: range), url))
    }
    #expect(fileLinks.count == 3)
    #expect(fileLinks.allSatisfy { $0.1.standardizedFileURL.path == file.standardizedFileURL.path })
    #expect(fileLinks.contains { $0.0.hasSuffix("Sources/View.swift:12") })
    #expect(fileLinks.contains { $0.0.hasSuffix("View.swift:3") && !$0.0.contains("/") })
    #expect(!view.transcript.string.contains(directory.path))
    #expect(storage.attribute(.link, at: location(of: "Missing.swift", in: view), effectiveRange: nil) == nil)
    // A long bare URL is shortened but opens the full address.
    let site = location(of: "example.com/very/long/…", in: view)
    try #require(site != NSNotFound)
    #expect((storage.attribute(.link, at: site, effectiveRange: nil) as? URL)?.absoluteString.hasSuffix("/and/going/on") == true)
    // Without a project, relative paths stay text.
    let plain = renderedView("Sources/View.swift:12")
    #expect(plain.transcript.textStorage?.attribute(.link, at: 0, effectiveRange: nil) == nil)
    try writeRender(view, name: "markdown-links")
}

@Test @MainActor func linkContextMenuOffersOpenCopyAndReveal() throws {
    let view = renderedView("Docs: [Apple](https://apple.com) and [file](/tmp)")
    let storage = try #require(view.transcript.textStorage)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let web = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: location(of: "Apple", in: view)))
    #expect(web.items.map(\.title).prefix(2) == [L10n.text("Открыть ссылку", "Open Link"), L10n.text("Скопировать ссылку", "Copy Link")])
    let fileIndex = location(of: "file", in: view)
    #expect((storage.attribute(.link, at: fileIndex, effectiveRange: nil) as? URL)?.isFileURL == true)
    let file = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: fileIndex))
    #expect(file.items.map(\.title).contains(L10n.text("Показать в Finder", "Show in Finder")))
    let text = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: location(of: "Docs", in: view)))
    #expect(text.items.isEmpty)
}

@Test @MainActor func fileLinkMenuCopiesRelativeAndAbsolutePaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md-paths-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Sources/View.swift")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "struct View {}".write(to: file, atomically: true, encoding: .utf8)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = renderedView("См. Sources/View.swift:12 и [tmp](/tmp)", project: directory.path, pasteboard: pasteboard)
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    func run(_ menu: NSMenu, _ title: String) throws -> String? {
        let item = try #require(menu.items.first { $0.title == title })
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        return pasteboard.string(forType: .string)
    }
    let relativeTitle = L10n.text("Скопировать относительный путь", "Copy Relative Path")
    let absoluteTitle = L10n.text("Скопировать абсолютный путь", "Copy Absolute Path")
    let menu = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: location(of: "View.swift", in: view)))
    #expect(try run(menu, relativeTitle) == "Sources/View.swift")
    #expect(try run(menu, absoluteTitle).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == file.standardizedFileURL.path)
    // Files outside the project offer only the absolute path.
    let outside = try #require(view.textView(view.transcript, menu: NSMenu(), for: event, at: location(of: "tmp", in: view)))
    #expect(!outside.items.contains { $0.title == relativeTitle })
    #expect(try run(outside, absoluteTitle) == "/tmp")
    #expect(TranscriptScrollView.relativePath("/a/b", project: "/a/b") == nil)
    #expect(TranscriptScrollView.relativePath("/a/bc/d", project: "/a/b") == nil)
    #expect(TranscriptScrollView.relativePath("/a/b/c/d.swift", project: "/a/b/") == "c/d.swift")
}

@Test @MainActor func manyWebLinksAddACollapsedSourcesList() throws {
    let text = "См. [один](https://a.example/1), [два](https://b.example/2), https://c.example/3 и снова [один](https://a.example/1).\n```\nhttps://code.example\n```"
    #expect(TranscriptMarkdown.webSources(in: text).map(\.url.host) == ["a.example", "b.example", "c.example"])
    let view = renderedView(text)
    let title = L10n.text("Источники · 3", "Sources · 3")
    #expect(view.transcript.string.contains(title))
    #expect(!view.transcript.string.contains("b.example —"))
    let toggle = try #require(links(in: view, prefix: "contextdesk-toggle:").last)
    _ = view.textView(view.transcript, clickedOnLink: toggle.1, at: toggle.0)
    #expect(view.transcript.string.contains("b.example — два"))
    #expect(!renderedView("Одна [ссылка](https://a.example)").transcript.string.contains(title))
}

@Test func webSourcesReuseParsedBlocksAndRepeatTheSameAnswer() {
    // CRLF text, a code block, a trailing slash, a bare URL and a non-web scheme.
    let text = "Intro [doc](https://docs.example/guide/) and https://docs.example/guide again.\r\n\r\n" +
        "[ftp](ftp://files.example/x) [same](https://docs.example/guide)\r\n" +
        "```\nhttps://code.example/literal\n```\r\nTail https://tail.example/path?q=1."
    let direct = TranscriptMarkdown.webSources(in: text)
    #expect(direct.map(\.url.absoluteString) == ["https://docs.example/guide/", "https://tail.example/path?q=1"])
    #expect(direct.map(\.title) == ["doc", nil])
    // The renderer passes its own nodes and lines; the answer is the same, also when served from the cache.
    let shared = TranscriptMarkdown.webSources(in: text, nodes: MarkdownBlocks.nodes(text), lines: MarkdownBlocks.lines(text))
    #expect(shared.map(\.url) == direct.map(\.url) && shared.map(\.title) == direct.map(\.title))
    let again = TranscriptMarkdown.webSources(in: text)
    #expect(again.map(\.url) == direct.map(\.url) && again.map(\.title) == direct.map(\.title))
    // A different text (the next streaming tick) is not confused with the cached one.
    let grown = TranscriptMarkdown.webSources(in: text + " https://more.example")
    #expect(grown.map(\.url.host) == ["docs.example", "tail.example", "more.example"])
    #expect(TranscriptMarkdown.webSources(in: "").isEmpty)
    #expect(TranscriptMarkdown.webSources(in: "```\nhttps://only.example\n```").isEmpty)
}

@Test @MainActor func localImagesEmbedAndRemoteImagesStayLinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = NSImage(size: NSSize(width: 1200, height: 600), flipped: false) { rect in
        NSColor.systemBlue.setFill(); rect.fill(); return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("chart.png"))
    let view = renderedView("![График](chart.png)\n\n![Remote](https://example.com/x.png)", project: directory.path)
    let storage = try #require(view.transcript.textStorage)
    var sizes: [NSSize] = []
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment, attachment.image?.size.width ?? 0 > 100 { sizes.append(attachment.bounds.size) }
    }
    #expect(sizes.count == 1)
    #expect((sizes.first?.width ?? 0) <= 520)
    #expect(view.transcript.string.contains("График"))
    let remote = location(of: "Remote", in: view)
    #expect((storage.attribute(.link, at: remote, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/x.png")
}

@Test @MainActor func quoteCopySharesTheFirstLineWhenItFits() throws {
    let long = String(repeating: "Длинная первая строка письма ", count: 6)
    let view = renderedView("> Короткая строка.\n>\n> Вторая.\n\n> \(long)\n> Дальше.", width: 760)
    let storage = try #require(view.transcript.textStorage)
    var controls: [Int] = []
    storage.enumerateAttribute(NSAttributedString.Key("ContextDeskQuoteCopy"), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        if value != nil { controls.append(range.location) }
    }
    try #require(controls.count == 2)
    let string = storage.string as NSString
    // Short first line: the control ends the same paragraph as the text.
    #expect(string.substring(with: string.paragraphRange(for: NSRange(location: controls[0], length: 0))).hasPrefix("Короткая строка."))
    // Long first line: the control keeps its own row above the text.
    #expect(!string.substring(with: string.paragraphRange(for: NSRange(location: controls[1], length: 0))).contains("Длинная"))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let copying = renderedView("> Короткая строка.\n>\n> Вторая.", pasteboard: pasteboard)
    var control = 0
    copying.transcript.textStorage!.enumerateAttribute(NSAttributedString.Key("ContextDeskQuoteCopy"),
                                                       in: NSRange(location: 0, length: copying.transcript.textStorage!.length)) { value, range, stop in
        if value != nil { control = range.location; stop.pointee = true }
    }
    _ = copying.textView(copying.transcript, clickedOnLink: "contextdesk-quote-copy", at: control)
    #expect(pasteboard.string(forType: .string) == "Короткая строка.\n\nВторая.")
    for width: CGFloat in [760, 380] {
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.transcript.layoutManager)
        let container = try #require(view.transcript.textContainer)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).maxX <= container.containerSize.width + 1)
        try writeRender(view, name: "quote-\(Int(width))")
    }
}
