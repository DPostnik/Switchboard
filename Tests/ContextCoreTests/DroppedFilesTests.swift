import ContextCore
import Foundation
import Testing

@Suite struct DroppedFilesTests {
    let shot = URL(fileURLWithPath: "/Users/me/Desktop/Снимок экрана 2026-10-11 в 12.00.00.png")

    @Test func pastedImageIsSavedAsScreenshotNamedPNG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-06T22:15:30Z"))
        let file = try DroppedFiles.savePasted(png: Data([1, 2, 3]), in: directory, date: date)
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == directory.path)
        #expect(file.lastPathComponent.hasPrefix("Pasted image 2026-11-0") && file.pathExtension == "png")
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
    }
    @Test func emptyDraftBecomesThePath() {
        #expect(DroppedFiles.appending([shot], to: "") == shot.path)
    }
    @Test func appendsAfterTextWithSingleSeparator() {
        #expect(DroppedFiles.appending([shot], to: "Посмотри") == "Посмотри " + shot.path)
        #expect(DroppedFiles.appending([shot], to: "Посмотри\n") == "Посмотри\n" + shot.path)
    }
    @Test func severalFilesGoOnSeparateLines() {
        let other = URL(fileURLWithPath: "/tmp/b.png")
        #expect(DroppedFiles.appending([shot, other], to: "") == shot.path + "\n/tmp/b.png")
    }
    @Test func ignoresNonFileURLs() {
        let web = URL(string: "https://example.com/a.png")!
        #expect(DroppedFiles.appending([web], to: "text") == "text")
        #expect(DroppedFiles.appending([], to: "") == "")
    }
    @Test func screenshotThumbnailFilesAreTemporary() {
        let tmp = URL(fileURLWithPath: "/var/folders/8h/abc/T/", isDirectory: true)
        #expect(DroppedFiles.isTemporary(URL(fileURLWithPath: "/var/folders/8h/abc/T/TemporaryItems/NSIRD_screencaptureui_PQm2Ba/Screenshot.png"), temporaryDirectory: tmp))
        #expect(DroppedFiles.isTemporary(URL(fileURLWithPath: "/private/var/folders/8h/abc/T/x.png"), temporaryDirectory: tmp))
        #expect(DroppedFiles.isTemporary(URL(fileURLWithPath: "/tmp/b.png"), temporaryDirectory: tmp))
        #expect(!DroppedFiles.isTemporary(shot, temporaryDirectory: tmp))
        #expect(!DroppedFiles.isTemporary(URL(string: "https://example.com/a.png")!, temporaryDirectory: tmp))
    }
    @Test func temporaryFilesAreCopiedAndOthersKept() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true)
        let store = fm.temporaryDirectory.appendingPathComponent("dropped-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: store) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Screenshot 2026-10-14 at 11.53.42.png")
        try Data("png".utf8).write(to: file)
        let missing = source.appendingPathComponent("gone.png")

        let result = DroppedFiles.preserving([file, shot, missing], in: store)
        #expect(result.count == 3)
        #expect(result[0].lastPathComponent == file.lastPathComponent)
        #expect(result[0].path.hasPrefix(store.path))
        #expect(try Data(contentsOf: result[0]) == Data("png".utf8))
        try fm.removeItem(at: file)
        #expect(fm.fileExists(atPath: result[0].path)) // the copy outlives the source's cleanup
        #expect(result[1] == shot)
        #expect(result[2] == missing) // a file that cannot be copied keeps its path
    }
}
