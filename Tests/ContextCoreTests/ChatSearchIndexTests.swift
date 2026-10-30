import AgentContract
import Foundation
import Testing
@testable import ContextCore
@testable import ContextTranscript

private let directoryServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ChatDirectoryRuntime/server.py")

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func info(_ id: String, title: String, project: String = "super-wiki", archived: Bool = true,
                  updated: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ChatSearchIndex.ChatInfo {
    .init(id: id, projectID: "P-" + project, project: project, projectPath: "/tmp/" + project, title: title, agent: "Claude",
          archived: archived, updated: updated, session: AgentSessionReference(connection: .appClaude, nativeID: "native-" + id))
}

/// A saved transcript blob as `AppStore` keeps it: user and assistant text plus tool output that must stay out of the index.
private func blob(_ chat: ChatSearchIndex.ChatInfo, _ messages: [(String, String)], answeredAt: Date? = nil) throws -> Data {
    var items = messages.enumerated().map { offset, message in TranscriptItem(id: "item-\(offset)", kind: message.0, text: message.1) }
    if let answeredAt, let index = items.firstIndex(where: { $0.kind == "assistant" }) {
        items[index].timing = ResponseTiming(startedAt: nil, completedAt: answeredAt)
    }
    items.append(TranscriptItem(id: "tool", kind: "tool", text: "tool output: secret-build-log"))
    let snapshot = try LocalHistory.snapshot(conversation: ConversationID(chat.id), source: chat.session!, items: items)
    return try JSONEncoder().encode(snapshot)
}

@Test func chatIndexFindsDialogueTextButNotToolOutput() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let form = info("form", title: "Andersen projects")
    let other = info("other", title: "Weekly digest")
    try await index.index([(form, blob(form, [("user", "Заполни анкету Andersen по проектам"), ("assistant", "Готово, анкета заполнена")])),
                           (other, blob(other, [("user", "Собери дайджест"), ("assistant", "Дайджест готов")]))])
    // Prefix matching finds other word forms; every word is required.
    #expect(try await index.search("анкет").map(\.chatID) == ["form"])
    #expect(try await index.search("анкет дайджест").isEmpty)
    #expect(try await index.search("Andersen").first?.chatID == "form")
    #expect(try await index.search("secret-build-log").isEmpty)
    #expect(try await index.search("\"\" ***").isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(ChatSearchIndex.fileName).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func chatIndexPlanRereadsChangedChatsAndDropsDeletedOnes() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let kept = info("kept", title: "Old title"), gone = info("gone", title: "Gone")
    #expect(try await index.plan([kept, gone]).content.sorted() == ["gone", "kept"])
    try await index.index([(kept, blob(kept, [("user", "hello")])), (gone, nil)])
    #expect(try await index.plan([kept, gone]).isEmpty)

    var renamed = kept; renamed.title = "Renamed chat"; renamed.archived = false
    var touched = gone; touched.updated = touched.updated.addingTimeInterval(60)
    #expect(try await index.plan([renamed, touched]) == .init(content: ["gone"], metadata: ["kept"], removed: []))
    try await index.updateMetadata([renamed])
    #expect(try await index.search("Renamed").map(\.chatID) == ["kept"])
    #expect(try await index.search("Old").isEmpty)
    #expect(try await index.search("hello").map(\.chatID) == ["kept"])

    #expect(try await index.plan([renamed]).removed == ["gone"])
    try await index.remove(["gone"])
    #expect(try await index.plan([renamed]).isEmpty)
}

@Test func chatIndexIgnoresATranscriptOfAnotherSession() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let chat = info("chat", title: "Visible title")
    var foreign = chat; foreign.session = AgentSessionReference(connection: .appClaude, nativeID: "someone-else")
    try await index.index([(chat, blob(foreign, [("user", "foreign words")]))])
    #expect(try await index.search("foreign").isEmpty)
    #expect(try await index.search("Visible").map(\.chatID) == ["chat"])
}

@Test func chatIndexMatchQueryQuotesEveryWord() {
    #expect(ChatSearchIndex.matchQuery("форма Андрюса") == "\"форма\"* \"Андрюса\"*")
    #expect(ChatSearchIndex.matchQuery("say \"hi\" OR NOT") == "\"say\"* \"hi\"* \"OR\"* \"NOT\"*")
    #expect(ChatSearchIndex.matchQuery("  -- ** ") == nil)
}

// MARK: Server tools

private func serve(_ requests: [[String: Any]], arguments: [String]) throws -> [Int: [String: Any]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", directoryServer.path] + arguments
    let input = Pipe(), output = Pipe()
    process.standardInput = input; process.standardOutput = output
    try process.run()
    for request in requests { input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)) }
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    var replies: [Int: [String: Any]] = [:]
    for line in String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
        if let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = reply["id"] as? Int { replies[id] = reply }
    }
    return replies
}

private func payload(_ reply: [String: Any]?) -> [String: Any] {
    let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    return (try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]) ?? [:]
}

private func call(_ id: Int, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
}

@Test func chatSearchToolsSearchOutlineAndReadTheIndex() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(ChatSearchIndex.fileName)
    let index = ChatSearchIndex(file: file)
    let day = DateComponents(calendar: Calendar.current, year: 2026, month: 10, day: 29, hour: 14).date!
    let form = info("form", title: "Andersen projects", updated: day)
    let old = info("old", title: "Old form", project: "switchboard", archived: false, updated: day.addingTimeInterval(-10 * 86_400))
    let own = info("own", title: "Search: form", updated: day)
    let long = (1...30).map { ("user", "Шаг \($0): заполни форму") }
    try await index.index([(form, blob(form, [("user", "Заполни форму Andersen"), ("assistant", "Форма заполнена")], answeredAt: day)),
                           (old, blob(old, long)), (own, blob(own, [("user", "Найди форму")]))])
    let recipe = root.appendingPathComponent("SKILL.md")
    try "---\nname: chat-search\n---\n\n# Chat search\nSearch carefully.".write(to: recipe, atomically: true, encoding: .utf8)
    let arguments = ["--snapshot", root.appendingPathComponent("missing.json").path, "--chat", "own", "--index", file.path, "--recipe", recipe.path]

    let replies = try serve([
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        call(3, "search_chats", ["query": "форм"]),
        call(4, "search_chats", ["query": "форм", "since": "2026-10-29", "until": "2026-10-29"]),
        call(5, "search_chats", ["query": "форм", "project": "switch", "archived": "active"]),
        call(6, "search_chats", ["since": "2026-10-28"]),
        call(7, "chat_outline", ["chat_id": "old"]),
        call(8, "read_messages", ["chat_id": "old", "start": 28, "count": 5]),
        call(9, "search_chats", ["since": "yesterday"]),
        call(10, "list_chats", [:]),
    ], arguments: arguments)

    #expect((replies[1]?["result"] as? [String: Any])?["instructions"] as? String == "# Chat search\nSearch carefully.")
    let tools = (((replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    #expect(tools == ["list_chats", "read_chat", "search_chats", "chat_outline", "read_messages"])

    // The search chat itself is never a result.
    let all = (payload(replies[3])["chats"] as? [[String: Any]]) ?? []
    #expect(Set(all.compactMap { $0["chat_id"] as? String }) == ["form", "old"])
    #expect(all.first { $0["chat_id"] as? String == "form" }?["link"] as? String == "switchboard-chat:form")
    #expect(((all.first?["snippets"] as? [[String: Any]])?.first?["text"] as? String)?.contains("«") == true)
    #expect(((payload(replies[4])["chats"] as? [[String: Any]]) ?? []).compactMap { $0["chat_id"] as? String } == ["form"])
    #expect(((payload(replies[5])["chats"] as? [[String: Any]]) ?? []).compactMap { $0["chat_id"] as? String } == ["old"])
    #expect(((payload(replies[6])["chats"] as? [[String: Any]]) ?? []).compactMap { $0["chat_id"] as? String } == ["form"])

    let outline = payload(replies[7])
    #expect((outline["user_messages"] as? [[String: Any]])?.count == 30 && outline["messages"] as? Int == 30)
    let window = payload(replies[8])
    #expect((window["messages"] as? [[String: Any]])?.compactMap { $0["position"] as? Int } == [28, 29])
    #expect(window["next_start"] is NSNull)
    #expect((replies[9]?["result"] as? [String: Any])?["isError"] as? Bool == true)
    // The snapshot tools still need the snapshot.
    #expect((replies[10]?["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test func chatSearchToolsNeedTheIndexAndInstructionsNeedTheRecipe() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = root.appendingPathComponent("s.json")
    let plain = try serve([["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]], ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                           call(3, "search_chats", ["query": "x"])], arguments: ["--snapshot", snapshot.path])
    #expect((plain[1]?["result"] as? [String: Any])?["instructions"] == nil)
    #expect((((plain[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).count == 2)
    #expect((plain[3]?["result"] as? [String: Any])?["isError"] as? Bool == true)

    // An index that is not built yet reports that instead of failing the turn.
    let missing = try serve([call(1, "search_chats", ["query": "x"])],
                            arguments: ["--snapshot", snapshot.path, "--index", root.appendingPathComponent("none.sqlite").path])
    let text = (((missing[1]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    #expect(text.contains("not available yet"))
}

@MainActor @Test func chatLinksOpenOnlyWhenTheAppHandlesThem() {
    let previous = TranscriptLinks.openChat; defer { TranscriptLinks.openChat = previous }
    TranscriptLinks.openChat = nil
    #expect(TranscriptLinks.destination("switchboard-chat:abc") == nil)
    TranscriptLinks.openChat = { _ in }
    #expect(TranscriptLinks.destination("switchboard-chat:abc")?.absoluteString == "switchboard-chat:abc")
    #expect(TranscriptLinks.destination("switchboard-chat:") == nil)
}

@Test func chatDirectoryArgumentsCarryIndexAndRecipe() {
    #expect(ChatDirectory.serverArguments(script: "/s.py", snapshot: "/d.json", chat: "c") == ["/s.py", "--snapshot", "/d.json", "--chat", "c"])
    #expect(ChatDirectory.serverArguments(script: "/s.py", snapshot: "/d.json", chat: "c", index: "/i.sqlite", recipe: "/r.md")
            == ["/s.py", "--snapshot", "/d.json", "--chat", "c", "--index", "/i.sqlite", "--recipe", "/r.md"])
}
