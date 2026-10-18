import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ContextCore

private func withProject(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

@Test func phoneClipKeepsWholeBlocksAndNeverSplitsCodeOrTables() {
    let limit = 200
    let intro = String(repeating: "Intro sentence here. ", count: 5) // 105 characters
    let code = "```swift\n" + String(repeating: "let value = 1\n", count: 10) + "```"
    let clipped = RemoteMessage.clip(intro + "\n\n" + code + "\n\nTail.", limit: limit)
    #expect(clipped == intro.trimmingCharacters(in: .whitespaces))
    let table = "| a | b |\n|---|---|\n" + String(repeating: "| 1 | 2 |\n", count: 20)
    let cutTable = RemoteMessage.clip(intro + "\n\n" + table, limit: limit)
    #expect(!cutTable.contains("|"))
    let list = RemoteMessage.clip(intro + "\n" + (1...20).map { "- item \($0)" }.joined(separator: "\n"), limit: limit)
    #expect(list.hasSuffix("item \(list.components(separatedBy: "\n").count - 1)") && list.count <= limit)
    // One long paragraph falls back to the last sentence; an open fence is closed.
    let paragraph = RemoteMessage.clip(String(repeating: "Word word word. ", count: 30), limit: limit)
    #expect(paragraph.hasSuffix(".") && paragraph.count <= limit)
    let fenced = RemoteMessage.clip("```\n" + String(repeating: "line of code\n", count: 40), limit: limit)
    #expect(fenced.hasSuffix("\n```") && fenced.hasPrefix("```"))
    #expect(RemoteMessage.clip("short", limit: limit) == "short")
}

@Test func fileCommandsCarryOnlyAPath() throws {
    let owner = UUID().uuidString, device = UUID().uuidString, project = UUID().uuidString
    let file = RemoteCommand.file(owner: owner, device: device, project: project, chat: "chat", path: "docs/plan.md")
    try file.validate()
    #expect(file.kind == "file" && file.text == "docs/plan.md")
    for path in ["", "  ", "a\nb", String(repeating: "a", count: RemoteFile.pathLimit + 1)] {
        #expect(throws: RemoteFailure.self) { try RemoteCommand.file(owner: owner, device: device, project: project, chat: "chat", path: path).validate() }
    }
    var withTurn = file; withTurn.turn = "turn"
    #expect(throws: RemoteFailure.self) { try withTurn.validate() }
    let decoded = try JSONDecoder().decode(RemoteFile.self, from: JSONEncoder().encode(RemoteFile(kind: .pages, path: "a.pdf", pages: [Data([1, 2])], pageCount: 3, truncated: true)))
    #expect(decoded.pages == [Data([1, 2])] && decoded.pageCount == 3 && decoded.name == "a.pdf")
    // Older hosts and phones decode projects without the capability.
    #expect(try JSONDecoder().decode(RemoteProject.self, from: Data(#"{"id":"p","name":"Old"}"#.utf8)).canReadFiles == nil)
    for failure in RemoteFile.Failure.allCases {
        let ru = failure.message(language: .russian), en = failure.message(language: .english)
        #expect(!ru.isEmpty && !en.isEmpty && ru != en)
    }
}

@Test func readerReturnsProjectTextAndMarkdown() throws {
    try withProject { root in
        try "# Plan\n\nПривет".write(to: root.appendingPathComponent("docs/plan.md"), atomically: true, encoding: .utf8)
        try "let a = 1\n".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let markdown = RemoteFileReader.read("docs/plan.md", root: root.path)
        #expect(markdown.kind == .markdown && markdown.text == "# Plan\n\nПривет" && markdown.path == "docs/plan.md" && markdown.truncated == nil)
        #expect(markdown.size == Int64("# Plan\n\nПривет".utf8.count))
        // Absolute, line-suffixed and file:// forms resolve to the same project file.
        #expect(RemoteFileReader.read(root.path + "/main.swift:1", root: root.path).text == "let a = 1\n")
        #expect(RemoteFileReader.read("main.swift#L1", root: root.path).kind == .text)
        #expect(RemoteFileReader.read(root.appendingPathComponent("main.swift").absoluteString, root: root.path).kind == .text)
        // Large UTF-8 text is cut on a character boundary.
        let big = String(repeating: "я", count: RemoteFile.textBytes) // two bytes each
        try big.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let cut = RemoteFileReader.read("big.txt", root: root.path)
        #expect(cut.truncated == true && cut.text?.count == RemoteFile.textBytes / 2)
        let odd = "a" + big
        try odd.write(to: root.appendingPathComponent("odd.txt"), atomically: true, encoding: .utf8)
        #expect(RemoteFileReader.read("odd.txt", root: root.path).text?.utf8.count == RemoteFile.textBytes - 1)
    }
}

@Test func readerRefusesPathsOutsideTheProjectSecretsAndBinaries() throws {
    try withProject { root in
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        #expect(RemoteFileReader.read(outside.path, root: root.path).failure == .outsideProject)
        #expect(RemoteFileReader.read("link.txt", root: root.path).failure == .outsideProject)
        #expect(RemoteFileReader.read("../../" + outside.lastPathComponent, root: root.appendingPathComponent("docs").path).failure == .outsideProject)
        #expect(RemoteFileReader.read("missing.md", root: root.path).failure == .notFound)
        #expect(RemoteFileReader.read("docs", root: root.path).failure == .directory)
        for name in [".env", ".env.local", "server.pem", "id_rsa"] {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            #expect(RemoteFileReader.read(name, root: root.path).failure == .protected)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        #expect(RemoteFileReader.read(".git/config", root: root.path).failure == .protected)
        try Data([0x00, 0x01, 0x02]).write(to: root.appendingPathComponent("blob.bin"))
        #expect(RemoteFileReader.read("blob.bin", root: root.path).failure == .unsupported)
    }
}

@Test func readerRendersPDFPagesAndImagesAsJPEG() throws {
    try withProject { root in
        let pdf = root.appendingPathComponent("docs/report.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for _ in 0..<(RemoteFile.pageLimit + 2) {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 100, y: 100, width: 200, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
        let pages = RemoteFileReader.read("docs/report.pdf", root: root.path)
        #expect(pages.kind == .pages && pages.pageCount == RemoteFile.pageLimit + 2 && pages.truncated == true)
        #expect(pages.pages?.count == RemoteFile.pageLimit)
        #expect(pages.pages?.allSatisfy { $0.starts(with: [0xff, 0xd8, 0xff]) && $0.count <= RemoteFile.pageBytes } == true)
        let payload = try JSONEncoder().encode(pages)
        #expect(payload.count <= RemoteFile.payloadBytes)

        let png = root.appendingPathComponent("shot.png")
        let bitmap = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(bitmap.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = RemoteFileReader.read("shot.png", root: root.path)
        #expect(image.kind == .pages && image.pages?.count == 1 && image.pages?.first?.starts(with: [0xff, 0xd8, 0xff]) == true)
    }
}

@Test func answerFormatRuleIsSharedInBothLanguages() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("Формат ответа в Switchboard") && ru.contains("ASD-STE100") && ru.contains("1800"))
    #expect(en.contains("Answer format in Switchboard") && en.contains("ASD-STE100") && en.contains("1,800"))
}
