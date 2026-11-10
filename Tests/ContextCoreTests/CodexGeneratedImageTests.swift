import Foundation
import Testing
import AgentContract
import ContextCore
@testable import CodexAdapter

private extension CodexClient {
    func configureImageFixture(root: URL, session: AgentSessionReference) {
        generatedImagesHome = root
        knownSessions.insert(session)
    }
    func hasImageBaseline(_ session: AgentSessionReference) -> Bool { generatedImageBaselines[session] != nil }
}

@Test func generatedImagesStayInsideTheirSessionAndIgnoreSymbolicLinks() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: UUID().uuidString)
    let folder = root.appendingPathComponent(session.nativeID)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appendingPathComponent("first.png"), second = folder.appendingPathComponent("second.webp")
    try Data([1]).write(to: first)
    try Data([2]).write(to: second)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: second.path)
    try Data([3]).write(to: folder.appendingPathComponent("notes.txt"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.png"), withDestinationURL: first)
    let client = CodexClient()
    await client.configureImageFixture(root: root, session: session)
    #expect(await client.generatedImages(session).map(\.url.lastPathComponent) == ["first.png", "second.webp"])
    #expect(await client.generatedImages(.init(connection: .originalCodex, nativeID: "../" + session.nativeID)).isEmpty)
    #expect(await client.generatedImages(.init(connection: .originalCodex, nativeID: UUID().uuidString)).isEmpty)
}

@Test func generatedImagesPublishOnlyNewFilesAtCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: UUID().uuidString)
    let folder = root.appendingPathComponent(session.nativeID)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1]).write(to: folder.appendingPathComponent("old.png"))
    let client = CodexClient()
    await client.configureImageFixture(root: root, session: session)
    let params: JSONValue = .object(["threadId": .string(session.nativeID), "turn": .object(["id": .string("turn-1")])])
    await client.publishGeneratedImages(method: "turn/started", params: params)
    #expect(await client.hasImageBaseline(session))
    let url = folder.appendingPathComponent("new (image).png")
    try Data([2]).write(to: url)
    await client.publishGeneratedImages(method: "turn/completed", params: params)
    #expect(await !client.hasImageBaseline(session))
    var events = client.events.makeAsyncIterator()
    let event = await events.next()
    guard case .item(let item) = event?.payload else { Issue.record("Expected generated image item"); return }
    #expect(item.id == "generated-image:new (image).png")
    #expect(item.turnID == "turn-1")
    let blocks = MarkdownBlocks.parse(item.text)
    guard case .image(_, let source) = blocks.first, let delivered = URL(string: source) else {
        Issue.record("Expected a Markdown image URL"); return
    }
    #expect(delivered.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
    #expect(item.kind == "assistant" && !item.showsAuthor && !item.showsCopyControl)
    #expect(await client.generatedImageItem(url, turn: "turn-1").id == item.id)
    // A duplicate completion has no baseline and cannot publish the same files again.
    await client.publishGeneratedImages(method: "turn/completed", params: params)
    #expect(await !client.hasImageBaseline(session))
}
