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
    // 600 × 300 fits 120 × 72 at 120 × 60; the line grows to hold it.
    let frame = try #require(editor.images.frames(in: editor).first?.frame)
    #expect(frame.size == NSSize(width: 120, height: 60))
    #expect(manager.usedRect(for: container).height >= 60 + 2 * ComposerImages.padding)
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
