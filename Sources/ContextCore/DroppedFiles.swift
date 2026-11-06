import Foundation

/// Files dropped anywhere on a chat are added to its draft as plain paths, the same text
/// the editor inserts when a file lands on it directly.
public enum DroppedFiles {
    /// Images the composer shows as chips; their paths go in brackets (`[/path/shot.png]`) so each stays one chip
    /// whatever is typed next to it.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]

    /// Appends the paths of local files, one per line, after any existing text; image paths in brackets.
    public static func appending(_ urls: [URL], to draft: String) -> String {
        let paths = urls.filter(\.isFileURL).filter { !$0.path.isEmpty }
            .map { imageExtensions.contains($0.pathExtension.lowercased()) ? "[" + $0.path + "]" : $0.path }
        guard !paths.isEmpty else { return draft }
        let joined = paths.joined(separator: "\n")
        guard let last = draft.last else { return joined }
        return draft + (last.isWhitespace ? "" : " ") + joined
    }

    /// Where copies of dropped temporary files are kept, inside the app's own home.
    public static var directory: URL { Locations.root.appendingPathComponent("dropped-files", isDirectory: true) }

    /// A screenshot thumbnail hands over a file in a temporary folder (`…/T/TemporaryItems/NSIRD_screencaptureui_…`)
    /// and removes it once the drop ends, so its path would point at nothing by the time the agent reads it.
    public static func isTemporary(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        guard url.isFileURL else { return false }
        // Foundation spells /var and /tmp with or without /private depending on the call, so compare without it.
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let bare = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
            return bare.hasSuffix("/") ? bare : bare + "/"
        }
        let path = normalized(url)
        let roots = [temporaryDirectory, URL(fileURLWithPath: "/var/folders"), URL(fileURLWithPath: "/tmp")].map(normalized)
        return roots.contains { path.hasPrefix($0) && path != $0 }
    }

    /// Saves image data pasted from the clipboard (a screenshot taken with Control) as a PNG in its own folder under
    /// `directory`, named like a macOS screenshot, and returns the file.
    public static func savePasted(png: Data, in directory: URL, date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("Pasted image \(formatter.string(from: date)).png")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: file)
        return file
    }

    /// Copies temporary files into `directory` (each into its own folder, keeping the file name) and returns
    /// the paths to use. Other files, and any file that cannot be copied, keep their original path.
    public static func preserving(_ urls: [URL], in directory: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                                  fileManager: FileManager = .default) -> [URL] {
        urls.map { url in
            guard isTemporary(url, temporaryDirectory: temporaryDirectory) else { return url }
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try fileManager.copyItem(at: url, to: copy)
                return copy
            } catch {
                try? fileManager.removeItem(at: folder)
                return url
            }
        }
    }
}
