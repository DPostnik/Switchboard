import AppKit
import Testing
import ContextTranscript

@Test @MainActor func transcriptMarkdownLinksRenderTitlesAndPreserveCode() {
    let result = TranscriptLinks.render("[Сайт](https://example.com/a?q=a%26b)\n[Файл](</tmp/My File.swift:12>)\n`[код](https://example.com)`", attributes: [:])
    #expect(result.string == "Сайт\nФайл\n[код](https://example.com)")
    let site = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
    #expect(site?.absoluteString == "https://example.com/a?q=a%26b")
    let file = result.attribute(.link, at: 5, effectiveRange: nil) as? URL
    #expect(file?.path == "/tmp/My File.swift")
    #expect(result.attribute(.link, at: 10, effectiveRange: nil) == nil)
}

@Test @MainActor func fileChipsInCodeShareOneFontForTheirThinSpace() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chips-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for index in 0..<40 { try Data().write(to: folder.appendingPathComponent("File\(index).swift")) }
    let text = (0..<40).map { "См. `\(folder.path)/File\($0).swift:\($0 + 1)` и [ссылку](\(folder.path)/File\($0).swift)." }.joined(separator: "\n")
    let rendered = TranscriptLinks.render(text, attributes: [.font: NSFont.systemFont(ofSize: 14)],
                                          options: TranscriptLinks.Options(chips: true, baseDirectory: folder))
    // In a text system, as in the transcript: fonts are fixed for characters their font lacks.
    let storage = NSTextStorage(attributedString: rendered)
    let manager = NSLayoutManager(); storage.addLayoutManager(manager)
    let container = NSTextContainer(size: NSSize(width: 600, height: 1e7)); manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
    var fonts = Set<ObjectIdentifier>(), spaces = 0
    let string = storage.string as NSString
    storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        guard let font = value as? NSFont else { return }
        fonts.insert(ObjectIdentifier(font))
        if string.substring(with: range).contains("\u{2009}") { spaces += 1 }
    }
    #expect(spaces >= 40)
    // A few shared fonts (prose, code, the thin space's fallback), not one per chip.
    #expect(fonts.count < 8)
    // The chip's thin space keeps its width: the font draws U+2009 itself.
    let chip = string.range(of: "\u{FFFC}\u{2009}")
    try #require(chip.location != NSNotFound)
    let spaceFont = try #require(storage.attribute(.font, at: chip.location + 1, effectiveRange: nil) as? NSFont)
    var glyph = CGGlyph(0), character = UniChar(0x2009)
    #expect(CTFontGetGlyphsForCharacters(spaceFont as CTFont, &character, &glyph, 1))
}

@Test @MainActor func transcriptLinkSchemesAndBareURLs() {
    for value in ["javascript:alert(1)", "data:text/html,hi", "contextdesk-action:injected", "ssh://host", "file://remote/tmp/file"] {
        #expect(TranscriptLinks.destination(value) == nil)
    }
    #expect(TranscriptLinks.destination("file:///tmp/test.txt")?.isFileURL == true)
    #expect(TranscriptLinks.destination("/tmp/test.swift:10:2")?.path == "/tmp/test.swift")
    let rendered = TranscriptLinks.render("Открой https://example.com", attributes: [:])
    #expect(rendered.attribute(.link, at: 7, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
}

@Test @MainActor func pastedImagePathsBecomeThumbnailsWithFileLinks() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("images-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let shot = folder.appendingPathComponent("Screenshot 2026-10-10 at 14.35.30.png")
    try png.write(to: shot)
    try Data("text".utf8).write(to: folder.appendingPathComponent("notes.txt"))

    // Spaces in the name, text after the path on the same line, `file://` and missing files.
    let text = "почему не работает \(shot.path) выделение\n\(shot.absoluteString)\n\(folder.path)/missing.png \(folder.path)/notes.txt"
    let found = TranscriptImagePaths.find(in: text)
    #expect(found.map(\.url.path) == [shot.path, shot.path])
    #expect((text as NSString).substring(with: found[0].range) == shot.path)
    #expect(TranscriptImagePaths.find(in: "/tmp/a.png.swift and a/b.png").isEmpty)

    let rendered = TranscriptImagePaths.render("почему не работает \(shot.path) выделение", attributes: [.font: NSFont.systemFont(ofSize: 14)])
    // A chip in the line, as in the composer, in place of the path.
    #expect(rendered.string == "почему не работает \u{FFFC} выделение")
    let attachment = try #require(rendered.attribute(.attachment, at: 19, effectiveRange: nil) as? NSTextAttachment)
    #expect(attachment.bounds.height == 18)
    #expect(attachment.bounds.width > 40 && attachment.bounds.width < 100)
    #expect((rendered.attribute(.link, at: 19, effectiveRange: nil) as? URL)?.path == shot.path)
    #expect(TranscriptImagePaths.render(shot.path, attributes: [:]).string == "\u{FFFC}")
}
