import AppKit
import AgentContract
import ContextCore
import Foundation
import Testing
@testable import ContextDesk
@testable import ContextTranscript

private func writeImage(_ url: URL, width: Int = 600, height: Int = 300) throws {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0))
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
}

@Test func composerCaretStepsOverAnImagePathAndSelectionsTakeItWhole() {
    let path = [NSRange(location: 4, length: 10)]
    // Right from the start lands after the path, left from the end before it.
    #expect(ComposerImages.snap(NSRange(location: 5, length: 0), from: NSRange(location: 4, length: 0), ranges: path) == NSRange(location: 14, length: 0))
    #expect(ComposerImages.snap(NSRange(location: 13, length: 0), from: NSRange(location: 14, length: 0), ranges: path) == NSRange(location: 4, length: 0))
    #expect(ComposerImages.snap(NSRange(location: 2, length: 0), from: NSRange(location: 0, length: 0), ranges: path) == NSRange(location: 2, length: 0))
    // A selection ending inside grows to the whole path.
    #expect(ComposerImages.snap(NSRange(location: 0, length: 6), from: NSRange(location: 0, length: 0), ranges: path) == NSRange(location: 0, length: 14))
    #expect(ComposerImages.snap(NSRange(location: 8, length: 10), from: NSRange(location: 18, length: 0), ranges: path) == NSRange(location: 4, length: 14))
}

@Test func deletingIntoAnImagePathRemovesTheWholePath() {
    let path = [NSRange(location: 4, length: 10)]
    // Backspace after the path removes its last character: the whole path goes.
    #expect(ComposerImages.expanded(NSRange(location: 13, length: 1), ranges: path) == NSRange(location: 4, length: 10))
    #expect(ComposerImages.expanded(NSRange(location: 2, length: 4), ranges: path) == NSRange(location: 2, length: 12))
    #expect(ComposerImages.expanded(NSRange(location: 0, length: 20), ranges: path) == nil)
    #expect(ComposerImages.expanded(NSRange(location: 0, length: 3), ranges: path) == nil)
    #expect(ComposerImages.expanded(NSRange(location: 6, length: 0), ranges: path) == nil)
}

@Test @MainActor func composerDrawsAThumbnailForAnImagePathAndKeepsTheText() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let shot = folder.appendingPathComponent("Screenshot 2026-11-06 at 23.12.49.png")
    try writeImage(shot)

    let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
    editor.layoutManager?.delegate = editor.images
    let text = "Посмотри \(shot.path) тут"
    editor.string = text
    editor.refreshImages()
    #expect(editor.string == text)
    #expect(editor.images.ranges.map(\.url.path) == [shot.path])
    #expect(editor.images.ranges.first?.range == (text as NSString).range(of: shot.path))

    let manager = try #require(editor.layoutManager), container = try #require(editor.textContainer)
    manager.ensureLayout(for: container)
    // A chip with its number; the line holds it.
    let frame = try #require(editor.images.frames(in: editor).first?.frame)
    #expect(frame.height == ComposerImages.chipHeight)
    #expect(frame.width > 40 && frame.width < 100)
    #expect(editor.images.number(for: shot) == 1)
    #expect(manager.usedRect(for: container).height >= ComposerImages.chipHeight)
    // The path's text takes no room: the line holds the words, the gap and the thumbnail only.
    #expect(manager.usedRect(for: container).width < 300)

    editor.string = "без картинок"
    editor.refreshImages()
    #expect(editor.images.ranges.isEmpty)
}

@Test @MainActor func imageViewerStepsThroughTheChatsPastedImages() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("a.png"), second = folder.appendingPathComponent("b c.png")
    try writeImage(first); try writeImage(second)
    let items = [
        TranscriptItem(id: "1", kind: "user", text: "\(first.path) и \(second.path)"),
        TranscriptItem(id: "2", kind: "assistant", text: "\(first.path)"),
        TranscriptItem(id: "3", kind: "user", text: "снова \(first.path)")
    ]
    let gallery = ImageViewerState.gallery(items)
    #expect(gallery.map(\.lastPathComponent) == ["a.png", "b c.png"])

    let viewer = ImageViewerState()
    viewer.show(second, gallery: gallery)
    #expect(viewer.current?.lastPathComponent == "b c.png")
    viewer.step(1)
    #expect(viewer.current?.lastPathComponent == "a.png")
    // A file outside the gallery opens alone.
    viewer.show(folder.appendingPathComponent("other.png"), gallery: gallery)
    #expect(viewer.images.count == 1)
    viewer.close()
    #expect(viewer.current == nil)
}

@Test @MainActor func composerBarListsDistinctImagesAndRemovingOneTakesItsChipsOut() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("Screenshot 1.png"), second = folder.appendingPathComponent("b.png")
    try writeImage(first); try writeImage(second)
    let composer = ComposerState()
    composer.text = "до \(first.path) середина \(second.path) и снова \(first.path) конец"
    #expect(composer.images.map(\.lastPathComponent) == ["Screenshot 1.png", "b.png"])
    composer.removeImage(first)
    #expect(composer.text == "до середина \(second.path) и снова конец")
    #expect(composer.images.map(\.lastPathComponent) == ["b.png"])
    // Typing the chip away (the path leaves the text) empties the bar.
    composer.editorChanged("только текст")
    #expect(composer.images.isEmpty)
}

@Test func deletingABracketOfAChipOpensItIntoText() {
    let chip = [NSRange(location: 4, length: 12)]
    // Backspace right after "]" deletes only the bracket; forward delete of "[" likewise.
    #expect(ComposerImages.expanded(NSRange(location: 15, length: 1), ranges: chip, opened: chip) == nil)
    #expect(ComposerImages.expanded(NSRange(location: 4, length: 1), ranges: chip, opened: chip) == nil)
    // Without brackets the whole path goes.
    #expect(ComposerImages.expanded(NSRange(location: 15, length: 1), ranges: chip) == chip[0])
}

@Test @MainActor func bracketedImagePathsNeedNoSpacesAndAnOpenedOneIsText() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brackets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let shot = folder.appendingPathComponent("Screenshot 2026-11-06 at 23.36.45.png")
    try writeImage(shot)
    let glued = "фото[\(shot.path)]текст"
    let found = TranscriptImagePaths.find(in: glued)
    #expect(found.count == 1)
    #expect((glued as NSString).substring(with: found[0].range) == "[\(shot.path)]")
    // One bracket left: the path is text again.
    #expect(TranscriptImagePaths.find(in: "фото [\(shot.path)").isEmpty)
    #expect(TranscriptImagePaths.find(in: "фото \(shot.path)] x").isEmpty)
    // The sent message shows the chip without the brackets.
    #expect(TranscriptImagePaths.render("до [\(shot.path)] после", attributes: [:]).string == "до \u{FFFC} после")
}

@Test @MainActor func copiedImageCarriesItsBytesAndFileAndTheComposerAcceptsIt() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let shot = folder.appendingPathComponent("Screenshot 2026-11-07 at 10.00.00.png")
    try writeImage(shot)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("switchboard-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    #expect(TranscriptImagePaths.copyImage(shot, to: pasteboard))
    // One item: other apps take the picture, the composer takes the original file.
    #expect(pasteboard.pasteboardItems?.count == 1)
    #expect(NSImage(pasteboard: pasteboard) != nil)
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    #expect(urls?.map(\.path) == [shot.path])
    // Paste is enabled for image data and files, not only for text.
    let editor = ComposerTextView(frame: .zero)
    #expect(Set([.png, .tiff, .fileURL]).isSubset(of: Set(editor.readablePasteboardTypes)))
}
