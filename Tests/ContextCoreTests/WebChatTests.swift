import Foundation
import Testing
import ContextCore
@testable import ContextDesk

// Web client chats (docs/web-client-plan.md): commands, retention, upload order and the Mac's snapshot.

@Test func webCommandsValidateAndOnlyWebPrefixesCreateWebChats() throws {
    let owner = UUID().uuidString, device = UUID().uuidString, project = UUID().uuidString
    let create = RemoteCommand.newWebChat(owner: owner, device: device, project: project, text: "Привет / Hello",
                                          options: RemoteChatOptions(model: "model"))
    try create.validate()
    #expect(create.chat == "web:" + create.id && create.createsChat && create.createsWebChat)
    let search = RemoteCommand.search(owner: owner, device: device, project: project, query: "анкета Andersen")
    try search.validate()
    #expect(search.createsChat && search.createsWebChat)
    let restore = RemoteCommand.restore(owner: owner, device: device, project: project, chat: "old-chat")
    try restore.validate()
    #expect(!restore.createsChat)
    // Phone chats keep their prefix and are not web chats.
    let phone = RemoteCommand.newChat(owner: owner, device: device, project: project, text: "Hi", options: RemoteChatOptions(model: "model"))
    #expect(phone.createsChat && !phone.createsWebChat)

    var bad = restore; bad.text = "text"
    #expect(throws: RemoteFailure.self) { try bad.validate() }
    bad = search; bad.text = "   "
    #expect(throws: RemoteFailure.self) { try bad.validate() }
    bad = search; bad.text = String(repeating: "a", count: WebChats.searchLimit + 1)
    #expect(throws: RemoteFailure.self) { try bad.validate() }
    bad = search; bad.chat = "mobile:" + search.id
    #expect(throws: RemoteFailure.self) { try bad.validate() }
    bad = search; bad.settings = RemoteSettingsChange(options: RemoteChatOptions(model: "model"))
    #expect(throws: RemoteFailure.self) { try bad.validate() }
    bad = restore; bad.turn = "turn"
    #expect(throws: RemoteFailure.self) { try bad.validate() }
}

@Test func webChatsStayVisibleForFifteenDaysAfterTheLastActivity() {
    let now = Date()
    let day: TimeInterval = 24 * 60 * 60
    #expect(WebChats.isVisible(updated: now, webSince: now, archived: false, now: now))
    #expect(!WebChats.isVisible(updated: now, webSince: nil, archived: false, now: now))
    #expect(!WebChats.isVisible(updated: now, webSince: now, archived: true, now: now))
    #expect(WebChats.isVisible(updated: now.addingTimeInterval(-14 * day), webSince: now.addingTimeInterval(-20 * day), archived: false, now: now))
    #expect(!WebChats.isVisible(updated: now.addingTimeInterval(-16 * day), webSince: now.addingTimeInterval(-20 * day), archived: false, now: now))
    // Restoring an old chat sets `webSince` now, which counts as activity.
    #expect(WebChats.isVisible(updated: now.addingTimeInterval(-90 * day), webSince: now, archived: false, now: now))
    #expect(WebChats.lastActive(updated: now, webSince: now.addingTimeInterval(-day)) == now)
}

@Test func webMessageOrderKeepsPublishedNumbersAndStaysIncreasing() {
    #expect(WebChats.sequence(["a", "b", "c"], previous: [:]) == [0, 1, 2])
    // An appended message takes the next number; the others keep theirs.
    #expect(WebChats.sequence(["a", "b", "c", "d"], previous: ["a": 0, "b": 1, "c": 2]) == [0, 1, 2, 3])
    // Older messages leaving the window do not renumber the rest.
    #expect(WebChats.sequence(["c", "d", "e"], previous: ["b": 1, "c": 2, "d": 3]) == [2, 3, 4])
    // A message inserted in the middle renumbers only what must move.
    #expect(WebChats.sequence(["a", "x", "b", "c"], previous: ["a": 0, "b": 1, "c": 5]) == [0, 1, 2, 5])
}

@Test func webMessagesKeepFullTextUpToTheLimitAndUploadInBoundedChunks() {
    let long = String(repeating: "слово ", count: 15_000)
    let message = RemoteWebMessage(id: "m", seq: 0, role: "assistant", fullText: long)
    #expect(message.text == long && message.truncated == nil)
    let huge = RemoteWebMessage(id: "h", seq: 1, role: "assistant", fullText: String(repeating: "a ", count: 60_000))
    #expect(huge.truncated == true && huge.text.count <= RemoteWebMessage.textLimit)

    let small = (0..<10).map { RemoteWebMessage(id: "s\($0)", seq: $0, role: "user", fullText: String(repeating: "x", count: 300_000)) }
    let chunks = WebChats.chunks(small)
    #expect(chunks.flatMap { $0 }.map(\.id) == small.map(\.id))
    #expect(chunks.allSatisfy { chunk in chunk.count == 1 || chunk.reduce(0) { $0 + $1.text.utf8.count } <= WebChats.chunkBytes })
    #expect(WebChats.chunks([]).isEmpty)
}

@Test func olderSnapshotsAndChatsDecodeWithoutWebFields() throws {
    let chat = RemoteChat(id: "c", project: UUID().uuidString, title: "T", running: false, messages: [], approvals: [])
    let encoded = String(decoding: try JSONEncoder().encode(chat), as: UTF8.self)
    #expect(!encoded.contains("\"web\"") && !encoded.contains("webMessages") && !encoded.contains("chatSearch"))
    let decoded = try JSONDecoder().decode(RemoteChat.self, from: Data(#"{"id":"c","project":"p","title":"T","running":false,"messages":[],"approvals":[]}"#.utf8))
    #expect(decoded.web == nil)
    let saved = try JSONEncoder().encode(Chat(id: "legacy", projectID: UUID(), title: "Old", model: "m"))
    #expect(try JSONDecoder().decode(Chat.self, from: saved).webSince == nil)
}

@Test @MainActor func snapshotListsWebChatsBesideThePhoneChatsWithFewMessages() async throws {
    let model = DeskModel()
    let project = Project(path: "/tmp/web-project")
    model.state.projects = [project]
    var chats = (0..<22).map { index -> Chat in
        var chat = Chat(id: "phone\(index)", projectID: project.id, title: "Chat \(index)", model: "")
        chat.updated = Date().addingTimeInterval(-Double(index))
        return chat
    }
    var web = Chat(id: "web:one", projectID: project.id, title: "Web", model: "")
    web.updated = Date().addingTimeInterval(-3600); web.webSince = web.updated
    var expired = Chat(id: "web:old", projectID: project.id, title: "Old web", model: "")
    expired.updated = Date().addingTimeInterval(-16 * 24 * 3600); expired.webSince = expired.updated
    chats += [web, expired]
    model.state.chats = chats
    model.chatID = "web:one"
    model.items = (0..<8).map { TranscriptItem(id: "m\($0)", kind: $0 % 2 == 0 ? "user" : "assistant", text: String(repeating: "Ответ ", count: 1_000)) }
    let snapshot = await model.remoteSnapshot(projects: [project.id.uuidString])
    #expect(snapshot.chats.count == 21)
    let listed = try #require(snapshot.chats.first { $0.id == "web:one" })
    #expect(listed.web == true && listed.messages.count == WebChats.snapshotMessages)
    #expect(listed.messages.allSatisfy { $0.truncated == true })
    #expect(!snapshot.chats.contains { $0.id == "web:old" })
    #expect(snapshot.chats.filter { $0.web == true }.map(\.id) == ["web:one"])
    // The web reads the full text.
    let full = try #require(await model.webMessages("web:one"))
    #expect(full.count == 8 && full[0].text.count == 6_000)
}

@Test @MainActor func restoreBringsAChatOfItsProjectBackToTheWeb() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("metadata.sqlite")), summaryResources: nil)
    let project = Project(path: "/fixture"), other = Project(path: "/other")
    var old = Chat(id: "old", projectID: project.id, title: "Old", model: "m")
    old.updated = Date().addingTimeInterval(-60 * 24 * 3600)
    var search = Chat(id: "web:search", projectID: project.id, title: "Search", model: "m"); search.chatSearch = true
    model.state.projects = [project, other]
    model.state.chats = [old, search]
    let owner = UUID().uuidString, device = UUID().uuidString
    #expect(!model.state.chats[0].isWebVisible)
    #expect(try await model.executeRemote(.restore(owner: owner, device: device, project: project.id.uuidString, chat: "old")) == "submitted")
    #expect(model.state.chats[0].isWebVisible)
    #expect(try await model.store.load().chats.first { $0.id == "old" }?.webSince != nil)
    // Another project's ID, an unknown chat and a search chat are refused.
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.restore(owner: owner, device: device, project: other.id.uuidString, chat: "old")) }
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.restore(owner: owner, device: device, project: project.id.uuidString, chat: "missing")) }
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.restore(owner: owner, device: device, project: project.id.uuidString, chat: "web:search")) }
    // Without a ready search agent the Mac refuses an archive search.
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(.search(owner: owner, device: device, project: project.id.uuidString, query: "анкета")) }
}
