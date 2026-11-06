import AppKit
import ContextCore
import Foundation

extension NSAttributedString.Key {
    /// A thumbnail of an image file named in a user's message; the value is the file URL.
    static let imagePreview = NSAttributedString.Key("ContextDeskImagePreview")
}

/// Image files pasted into a user's message as paths show as thumbnails. A click previews the file in the app
/// (the thumbnail carries the file link), the context menu copies its path.
@MainActor public enum TranscriptImagePaths {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]
    /// Set by the app: shows an image in its viewer. Without it images open in the default app.
    public static var openImage: ((URL) -> Void)?
    public static func open(_ url: URL) {
        if let openImage { openImage(url) } else { NSWorkspace.shared.open(url) }
    }
    /// The file is an image the viewer shows.
    public static func isImage(_ url: URL) -> Bool { url.isFileURL && extensions.contains(url.pathExtension.lowercased()) }
    /// Thumbnails fit this box; the bubble grows to the widest one.
    static let maxSize = NSSize(width: 260, height: 180)

    private static let start = try? NSRegularExpression(pattern: #"(?:^|(?<=[\s"'(<\[]))(?:file://|~/|/)"#, options: [.anchorsMatchLines])
    private static let end = try? NSRegularExpression(pattern: #"\.(?:png|jpe?g|gif|heic|tiff?|bmp|webp)(?![\w.])"#, options: [.caseInsensitive])

    /// Absolute, `~/` and `file://` paths of existing image files. A path may hold spaces (macOS screenshots are named
    /// "Screenshot 2026-10-10 at 14.35.30.png") and is followed by other text on the same line; the shortest
    /// existing file wins.
    public static func find(in text: String, isFile: (String) -> Bool = { ChatFiles.cachedIsFile($0) }) -> [(range: NSRange, url: URL)] {
        guard text.contains("/"), let start, let end else { return [] }
        let string = text as NSString
        let all = NSRange(location: 0, length: string.length)
        let ends = end.matches(in: text, range: all).map { NSMaxRange($0.range) }
        guard !ends.isEmpty else { return [] }
        var result: [(range: NSRange, url: URL)] = []
        for match in start.matches(in: text, range: all) {
            let from = match.range.location
            if let last = result.last, from < NSMaxRange(last.range) { continue }
            for to in ends where to > from + 1 {
                let range = NSRange(location: from, length: to - from)
                let candidate = string.substring(with: range)
                if candidate.contains("\n") || range.length > 1024 { break }
                guard let url = fileURL(candidate), isFile(url.path) else { continue }
                result.append((range, url))
                break
            }
        }
        return result
    }

    static func fileURL(_ candidate: String) -> URL? {
        var path = candidate
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
        }
        // Terminal drops escape spaces.
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(1) }
        guard path.hasPrefix("/"), extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The message text with each image path replaced by its thumbnail on a line of its own; the rest renders as
    /// `TranscriptLinks.render` does. Paths of files that cannot be decoded stay text.
    public static func render(_ text: String, attributes: [NSAttributedString.Key: Any],
                              isFile: (String) -> Bool = { ChatFiles.cachedIsFile($0) }) -> NSAttributedString {
        let images = find(in: text, isFile: isFile).compactMap { found in thumbnail(found.url).map { (found.range, found.url, $0) } }
        guard !images.isEmpty else { return TranscriptLinks.render(text, attributes: attributes) }
        let string = text as NSString
        let result = NSMutableAttributedString()
        var position = 0
        for (range, url, image) in images {
            // Spaces around the path go with it; the thumbnail takes its own line.
            let before = string.substring(with: NSRange(location: position, length: range.location - position))
                .replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            result.append(TranscriptLinks.render(before, attributes: attributes))
            if result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            result.append(preview(url, image: image, attributes: attributes))
            position = NSMaxRange(range)
            let rest = string.substring(from: position)
            let skipped = rest.prefix { $0 == " " || $0 == "\t" }
            position += (String(skipped) as NSString).length
            if position < string.length, string.character(at: position) != 0x0A {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        result.append(TranscriptLinks.render(string.substring(from: position), attributes: attributes))
        return result
    }

    /// Point size of a thumbnail inside `maxSize`.
    static func size(of image: NSImage) -> NSSize {
        let scale = min(1, maxSize.width / max(1, image.size.width), maxSize.height / max(1, image.size.height))
        return NSSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
    }

    /// The widest thumbnail of a message and its text without the image paths, for sizing a hugging bubble.
    static func measure(_ text: String) -> (text: String, width: CGFloat)? {
        let images = find(in: text).compactMap { found in thumbnail(found.url).map { (found.range, $0) } }
        guard !images.isEmpty else { return nil }
        let rest = NSMutableString(string: text)
        for (range, _) in images.reversed() { rest.replaceCharacters(in: range, with: "") }
        return (rest as String, images.map { size(of: $0.1).width }.max() ?? 0)
    }

    static func thumbnail(_ url: URL) -> NSImage? { TranscriptMarkdown.image(at: url) }

    private static func preview(_ url: URL, image: NSImage, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let size = size(of: image)
        // Rounded corners and a hairline edge; NSImage keeps the drawn bitmap, so scrolling does not rescale the source.
        let rounded = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = rounded
        attachment.bounds = NSRect(origin: .zero, size: size)
        let line = NSMutableAttributedString(attachment: attachment)
        var style = attributes
        style[.link] = url
        style[.imagePreview] = url
        style[.toolTip] = url.path + "\n" + L10n.text("Нажмите, чтобы открыть в приложении; правая кнопка - скопировать путь",
                                                      "Click to open in the app; right-click to copy the path")
        line.addAttributes(style, range: NSRange(location: 0, length: line.length))
        return line
    }
}
