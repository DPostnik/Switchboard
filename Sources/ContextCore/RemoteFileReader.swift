import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads one project file for the phone: Markdown and text as text, PDF pages and images as JPEG.
/// Only regular files inside the project folder (after resolving symbolic links) are returned.
public enum RemoteFileReader {
    public static func read(_ requested: String, root: String) -> RemoteFile {
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        guard let file = resolve(requested, base: base) else { return .failed(.notFound, path: display(requested)) }
        guard let shown = relative(file, base: base) else { return .failed(.outsideProject, path: display(requested)) }
        if isProtected(shown) { return .failed(.protected, path: shown) }
        guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            return .failed(.unreadable, path: shown)
        }
        if values.isDirectory == true { return .failed(.directory, path: shown) }
        guard values.isRegularFile == true else { return .failed(.unsupported, path: shown) }
        let size = Int64(values.fileSize ?? 0)
        let type = UTType(filenameExtension: file.pathExtension.lowercased())
        var result: RemoteFile
        if type?.conforms(to: .pdf) == true {
            result = pdf(file, path: shown)
        } else if let type, type.conforms(to: .image) {
            result = image(file, path: shown)
        } else {
            result = text(file, path: shown, markdown: ["md", "markdown", "mdx", "mdown"].contains(file.pathExtension.lowercased()))
        }
        if result.kind != .failure { result.size = size }
        return result
    }

    /// Accepts project-relative, absolute, `~/` and `file://` paths, with an optional `:line[:column]` or `#L12` suffix.
    static func resolve(_ requested: String, base: URL) -> URL? {
        var value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("file://"), let url = URL(string: value) { value = url.path }
        if value.hasPrefix("~/") { value = FileManager.default.homeDirectoryForCurrentUser.path + value.dropFirst(1) }
        var candidates = [value]
        for pattern in [#":\d+(:\d+)?$"#, #"#L\d+(-L?\d+)?$"#] {
            if let range = value.range(of: pattern, options: .regularExpression) { candidates.append(String(value[..<range.lowerBound])) }
        }
        for candidate in candidates where !candidate.isEmpty {
            let url = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : base.appendingPathComponent(candidate)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        }
        return nil
    }

    static func relative(_ file: URL, base: URL) -> String? {
        let root = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard file.path.hasPrefix(root) else { return nil }
        return String(file.path.dropFirst(root.count))
    }

    /// Credentials and repository internals never leave the Mac, even inside the project.
    static func isProtected(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: { [".git", ".ssh", ".gnupg", ".aws", ".netrc"].contains($0) }) { return true }
        guard let name = parts.last else { return true }
        if name == ".env" || name.hasPrefix(".env.") || [".netrc", ".npmrc", ".pypirc", "credentials", "id_rsa", "id_ed25519", "id_ecdsa"].contains(name) { return true }
        return ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "mobileprovision", "jks", "keystore"].contains((name as NSString).pathExtension)
    }

    private static func display(_ requested: String) -> String {
        String(requested.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    private static func text(_ file: URL, path: String, markdown: Bool) -> RemoteFile {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .failed(.unreadable, path: path) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: RemoteFile.textBytes + 1) else { return .failed(.unreadable, path: path) }
        let truncated = data.count > RemoteFile.textBytes
        var bytes = data.prefix(RemoteFile.textBytes)
        if bytes.contains(0) { return .failed(.unsupported, path: path) }
        // A cut can split a multi-byte character: drop at most three trailing bytes.
        var decoded = String(data: bytes, encoding: .utf8)
        var dropped = 0
        while decoded == nil, truncated, dropped < 3, !bytes.isEmpty {
            bytes = bytes.dropLast(); dropped += 1
            decoded = String(data: bytes, encoding: .utf8)
        }
        guard let decoded else { return .failed(.unsupported, path: path) }
        return RemoteFile(kind: markdown ? .markdown : .text, path: path, text: decoded, truncated: truncated ? true : nil)
    }

    private static func image(_ file: URL, path: String) -> RemoteFile {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary),
              let jpeg = jpeg(flattened(thumbnail) ?? thumbnail) else { return .failed(.unsupported, path: path) }
        return RemoteFile(kind: .pages, path: path, pages: [jpeg])
    }

    private static func pdf(_ file: URL, path: String) -> RemoteFile {
        guard let document = CGPDFDocument(file as CFURL) else { return .failed(.unreadable, path: path) }
        if document.isEncrypted && !document.isUnlocked { return .failed(.protected, path: path) }
        let count = document.numberOfPages
        guard count > 0 else { return .failed(.unreadable, path: path) }
        var pages: [Data] = []
        var total = 0
        for number in 1...min(count, RemoteFile.pageLimit) {
            // Stop at the first page that cannot be sent so the shown pages stay consecutive.
            guard let page = document.page(at: number), let image = render(page), let data = jpeg(image) else { break }
            // Base64 grows the payload by a third.
            guard total + data.count * 4 / 3 <= RemoteFile.payloadBytes - 64 * 1024 else { break }
            pages.append(data); total += data.count * 4 / 3
        }
        guard !pages.isEmpty else { return .failed(.tooLarge, path: path) }
        return RemoteFile(kind: .pages, path: path, pages: pages, pageCount: count, truncated: pages.count < count ? true : nil)
    }

    /// Phone-width rendering: about 1400 px wide, white paper, page rotation applied.
    private static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1400 / size.width, 2400 / size.height, 4)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Transparent images become JPEG on white instead of black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        for quality in [0.8, 0.65, 0.5, 0.35] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= RemoteFile.pageBytes { return data as Data }
        }
        return nil
    }
}
