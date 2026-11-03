import AppKit
import Foundation
import Testing
@testable import ContextTranscript

private func writePNG(width: Int, height: Int, dpi: Double = 72, to url: URL) throws {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
}

@Test @MainActor func largeTranscriptImagesAreDecodedDownsampledAtTheirOriginalPointSize() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A Retina screenshot: 3000 x 2000 pixels at 144 DPI is 1500 x 1000 points.
    let large = root.appendingPathComponent("screen.png"), small = root.appendingPathComponent("icon.png")
    try writePNG(width: 3000, height: 2000, dpi: 144, to: large)
    try writePNG(width: 400, height: 300, to: small)
    let original = try #require(NSImage(contentsOf: large))
    // The thumbnail is decoded at the cap, and its cost counts those pixels, not the original's.
    let thumbnail = try #require(TranscriptMarkdown.downsampled(large))
    let decoded = try #require(thumbnail.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(max(decoded.width, decoded.height) == TranscriptMarkdown.imagePixels && thumbnail.pixels == decoded.width * decoded.height)
    let image = try #require(TranscriptMarkdown.image(at: large))
    #expect(abs(image.size.width - original.size.width) < 1 && abs(image.size.height - original.size.height) < 1)
    // Small images load as they are; a second read is served from the cache.
    #expect(TranscriptMarkdown.downsampled(small) == nil)
    #expect(TranscriptMarkdown.image(at: small)?.size == NSSize(width: 400, height: 300))
    #expect(TranscriptMarkdown.image(at: large) === image)
    TranscriptCaches.release()
    #expect(TranscriptMarkdown.image(at: large) !== image)
}
