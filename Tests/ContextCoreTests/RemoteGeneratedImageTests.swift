import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test func generatedPreviewsRejectOtherSessionsAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("session")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let image = session.appendingPathComponent("preview with spaces.png")
    try Data([1]).write(to: image)
    #expect(RemoteGeneratedImagePreviews.allowedFile(source: image.path, root: session) == image)
    #expect(RemoteGeneratedImagePreviews.allowedFile(source: image.absoluteString, root: session) == image)
    #expect(RemoteGeneratedImagePreviews.allowedFile(source: root.appendingPathComponent("other.png").path, root: session) == nil)
    #expect(RemoteGeneratedImagePreviews.allowedFile(source: "https://example.com/image.png", root: session) == nil)
    let link = root.appendingPathComponent("linked-session")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: session)
    #expect(RemoteGeneratedImagePreviews.allowedFile(source: link.appendingPathComponent(image.lastPathComponent).path, root: link) == nil)
    let outside = root.appendingPathComponent("outside.png")
    try Data([1]).write(to: outside)
    let linkedImage = session.appendingPathComponent("outside.png")
    try FileManager.default.createSymbolicLink(at: linkedImage, withDestinationURL: outside)
    #expect(RemoteGeneratedImagePreviews.allowedFile(source: linkedImage.path, root: session) == nil)
}

@Test func webChunksAccountForGeneratedImageBytes() throws {
    let attachment = RemoteMessageImage(id: "image", name: "image.jpg", mimeType: "image/jpeg", data: String(repeating: "A", count: 600_000))
    var first = RemoteWebMessage(id: "1", seq: 0, role: "assistant", fullText: "Generated")
    first.images = [attachment]
    var second = first
    second.id = "2"; second.seq = 1
    #expect(WebChats.chunks([first, second]).count == 2)
    let decoded = try JSONDecoder().decode(RemoteWebMessage.self, from: JSONEncoder().encode(first))
    #expect(decoded.images == [attachment])
}
