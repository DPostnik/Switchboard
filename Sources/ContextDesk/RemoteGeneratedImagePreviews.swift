import Foundation
import ImageIO
import UniformTypeIdentifiers
import ContextCore

/// Only generated images in this chat's dedicated agent session may leave the Mac.
/// Image decoding runs on the actor executor, not on the main application thread.
actor RemoteGeneratedImagePreviews {
    struct Result: Sendable {
        var images: [RemoteMessageImage] = []
        var failed = false
    }
    private struct Entry {
        var modified: Date
        var size: Int
        var image: RemoteMessageImage
    }
    private var cache: [String: Entry] = [:]
    func previews(text: String, session: String?) -> Result {
        guard let session, UUID(uuidString: session) != nil else { return Result() }
        let root = Locations.codexHome.appendingPathComponent("generated_images").appendingPathComponent(session)
            .standardizedFileURL
        var result = Result()
        for block in MarkdownBlocks.parse(text) {
            guard case .image(_, let source) = block else { continue }
            guard let resolved = Self.allowedFile(source: source, root: root) else { continue }
            guard result.images.count < 4 else { result.failed = true; break }
            guard let image = preview(resolved) else { result.failed = true; continue }
            if !result.images.contains(where: { $0.id == image.id }) { result.images.append(image) }
        }
        return result
    }
    nonisolated static func allowedFile(source: String, root: URL) -> URL? {
        let lexicalRoot = root.standardizedFileURL
        guard lexicalRoot.path == lexicalRoot.resolvingSymlinksInPath().path else { return nil }
        let url: URL
        if source.hasPrefix("file://"), let file = URL(string: source), file.isFileURL,
           file.host == nil || file.host == "" || file.host == "localhost" { url = file }
        else if source.hasPrefix("/") { url = URL(fileURLWithPath: source.removingPercentEncoding ?? source) }
        else { return nil }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == url.standardizedFileURL.path,
              url.standardizedFileURL.deletingLastPathComponent().path == lexicalRoot.path,
              resolved.deletingLastPathComponent().path == lexicalRoot.path else { return nil }
        return resolved
    }
    private func preview(_ url: URL) -> RemoteMessageImage? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 40 * 1024 * 1024,
              let modified = values.contentModificationDate else { return nil }
        if let entry = cache[url.path], entry.modified == modified, entry.size == size { return entry.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280
              ] as CFDictionary) else { return nil }
        for quality in [0.8, 0.6, 0.4, 0.2, 0.1] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination), data.length <= 96 * 1024 else { continue }
            let attachment = RemoteMessageImage(id: url.lastPathComponent, name: url.deletingPathExtension().lastPathComponent + ".jpg",
                                                mimeType: "image/jpeg", data: (data as Data).base64EncodedString())
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[url.path] = Entry(modified: modified, size: size, image: attachment)
            return attachment
        }
        return nil
    }
}
