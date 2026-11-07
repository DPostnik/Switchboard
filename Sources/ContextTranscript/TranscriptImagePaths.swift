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

    private static let start = try? NSRegularExpression(pattern: #"(?:^|(?<=[\s"'(<\[]))(?:file://|~/|/)"#, options: [.anchorsMatchLines])
    private static let end = try? NSRegularExpression(pattern: #"\.(?:png|jpe?g|gif|heic|tiff?|bmp|webp)(?![\w.])"#, options: [.caseInsensitive])

    /// Absolute, `~/` and `file://` paths of existing image files. A path may hold spaces (macOS screenshots are named
    /// "Screenshot 2026-10-10 at 14.35.30.png") and is followed by other text on the same line; the shortest
    /// existing file wins. A path in square brackets (`[/path/shot.png]`, as the composer writes it) is found with its
    /// brackets and needs no space around it; a path with only one of the brackets is text the user opened, not an image.
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
                let opens = from > 0 && string.character(at: from - 1) == 0x5B
                let closes = to < string.length && string.character(at: to) == 0x5D
                if opens != closes { break }
                result.append((opens ? NSRange(location: from - 1, length: range.length + 2) : range, url))
                break
            }
        }
        return result
    }

    /// One clipboard item with the image's bytes and its file: other apps (messengers, editors) paste the picture, the
    /// composer pastes the original file as a chip instead of saving a copy.
    @discardableResult public static func copyImage(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let ext = url.pathExtension.lowercased()
        if ext == "png", let data = try? Data(contentsOf: url) { item.setData(data, forType: .png) }
        if let tiff = NSImage(contentsOf: url)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        guard item.types.count > 1 else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// How the composer writes an image path: in brackets, so it stays one chip next to any text.
    public static func chipText(_ path: String) -> String { "[" + path + "]" }

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

    /// The message text with each image path replaced by a chip in the line ("Image 1" with a small preview, numbered
    /// by distinct image in order), as in the composer; the rest renders as `TranscriptLinks.render` does. Paths of files
    /// that cannot be decoded stay text.
    public static func render(_ text: String, attributes: [NSAttributedString.Key: Any],
                              isFile: (String) -> Bool = { ChatFiles.cachedIsFile($0) }) -> NSAttributedString {
        let images = find(in: text, isFile: isFile).filter { thumbnail($0.url) != nil }
        guard !images.isEmpty else { return TranscriptLinks.render(text, attributes: attributes) }
        let string = text as NSString
        let result = NSMutableAttributedString()
        var numbers: [URL: Int] = [:]
        var position = 0
        for (range, url) in images {
            result.append(TranscriptLinks.render(string.substring(with: NSRange(location: position, length: range.location - position)),
                                                 attributes: attributes))
            let key = url.standardizedFileURL
            if numbers[key] == nil { numbers[key] = numbers.count + 1 }
            result.append(chip(url, number: numbers[key] ?? 1, attributes: attributes))
            position = NSMaxRange(range)
        }
        result.append(TranscriptLinks.render(string.substring(from: position), attributes: attributes))
        return result
    }

    /// The message as `render` lays it out, for sizing a hugging bubble; nil when it names no image.
    static func measuringText(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard text.contains("/"), !find(in: text).filter({ thumbnail($0.url) != nil }).isEmpty else { return nil }
        return render(text, attributes: attributes)
    }

    public static func thumbnail(_ url: URL) -> NSImage? { TranscriptMarkdown.image(at: url) }

    private static func chip(_ url: URL, number: Int, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let label = ComposerImages.label(number)
        let size = ComposerImages.chipSize(label)
        let image = NSImage(size: size, flipped: true) { rect in
            MainActor.assumeIsolated { ComposerImages.drawChip(url, label: label, in: rect, selected: false) }
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centered on the text's middle: half the capital height above the baseline.
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        attachment.bounds = NSRect(x: 0, y: (font.capHeight / 2 - size.height / 2).rounded(), width: size.width, height: size.height)
        let result = NSMutableAttributedString(attachment: attachment)
        var style = attributes
        style[.link] = url
        style[.imagePreview] = url
        style[.toolTip] = url.path + "\n" + L10n.text("Нажмите, чтобы открыть; правая кнопка - скопировать путь",
                                                      "Click to open; right-click to copy the path")
        result.addAttributes(style, range: NSRange(location: 0, length: result.length))
        return result
    }
}
