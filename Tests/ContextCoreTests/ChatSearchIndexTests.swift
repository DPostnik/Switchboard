import AgentContract
import Foundation
import Testing
import os
@testable import ContextCore
@testable import ContextDesk
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

/// A time whose seconds since 1970 do not restore the same `Date`: the reference-date seconds keep one bit more than
/// the 1970 value can hold. About half of all clock readings are like this.
private func fragileDate() -> Date {
    while true {
        let date = Date(timeIntervalSinceReferenceDate: Double.random(in: 800_000_000..<830_000_000))
        if Date(timeIntervalSince1970: date.timeIntervalSince1970) != date { return date }
    }
}

@Test func chatIndexPlanIsEmptyForATimeThatDoesNotRoundTrip() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let date = fragileDate()
    #expect(Date(timeIntervalSince1970: date.timeIntervalSince1970) != date)
    let chat = info("chat", title: "Fragile time", updated: date)
    try await index.index([(chat, blob(chat, [("user", "hello")]))])
    #expect(try await index.plan([chat]).isEmpty)
    var renamed = chat; renamed.title = "Renamed"
    #expect(try await index.plan([renamed]) == .init(content: [], metadata: ["chat"], removed: []))
    try await index.updateMetadata([renamed])
    #expect(try await index.plan([renamed]).isEmpty)
    var later = renamed; later.updated = date.addingTimeInterval(1)
    #expect(try await index.plan([later]).content == ["chat"])
}

@Test func chatIndexDeletesMessagesByRowidInsteadOfScanning() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let a = info("a", title: "Alpha chat"), b = info("b", title: "Beta chat")
    try await index.index([(a, blob(a, [("user", "alpha words"), ("assistant", "alpha reply")])), (b, blob(b, [("user", "beta words")]))])
    let plan = try await index.rows("EXPLAIN QUERY PLAN " + ChatSearchIndex.deleteMessagesSQL).map { $0[3] }
    let scan = try #require(plan.first { $0.contains("messages VIRTUAL TABLE") })
    // FTS5 reports every access as SCAN; an empty index string after `INDEX 0:` is the full scan, `=` the rowid lookup.
    #expect(!scan.hasSuffix("INDEX 0:") && scan.contains("INDEX 0:="))
    #expect(plan.contains { $0.contains("message_rows USING INDEX") })

    func counts() async throws -> [String?] {
        [try await index.rows("SELECT count(*) FROM messages").first?.first, try await index.rows("SELECT count(*) FROM message_rows").first?.first]
    }
    // Header updates, reindexing and removal keep one mapping row per message and leave other chats intact.
    var summarized = a; summarized.summary = "Overview of alpha"
    try await index.updateMetadata([summarized])
    #expect(try await counts() == ["6", "6"])
    #expect(try await index.search("Overview").map(\.chatID) == ["a"])
    #expect(try await index.search("reply").map(\.chatID) == ["a"])
    try await index.index([(a, blob(a, [("user", "gamma words")]))])
    #expect(try await counts() == ["4", "4"])
    #expect(try await index.search("reply").isEmpty)
    #expect(try await index.search("gamma").map(\.chatID) == ["a"])
    try await index.remove(["a"])
    #expect(try await counts() == ["2", "2"])
    #expect(try await index.search("beta").map(\.chatID) == ["b"])
}

@Test func chatIndexUsesWalAndServesASecondConnection() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(ChatSearchIndex.fileName)
    let writer = ChatSearchIndex(file: file), reader = ChatSearchIndex(file: file)
    let chat = info("chat", title: "Shared index")
    try await writer.index([(chat, blob(chat, [("user", "words for the reader")]))])
    #expect(try await writer.rows("PRAGMA journal_mode").first?.first == "wal")
    #expect(FileManager.default.fileExists(atPath: file.path + "-wal"))
    #expect(try await reader.search("reader").map(\.chatID) == ["chat"])
    // Both connections stay open; a later write on one is visible to the other.
    var renamed = chat; renamed.title = "Renamed index"
    try await writer.updateMetadata([renamed])
    #expect(try await reader.search("Renamed").map(\.chatID) == ["chat"])
    #expect(try await reader.plan([renamed]).isEmpty)
    // A failed call drops the connection; the next call opens a new one.
    await #expect(throws: (any Error).self) { try await writer.rows("SELECT * FROM missing_table") }
    #expect(try await writer.search("Renamed").map(\.chatID) == ["chat"])
}

@Test @MainActor func chatIndexRefreshSkipsUnchangedChats() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"),
                          summaryResources: nil, jobStore: JobStore(file: root.appendingPathComponent("scheduled-jobs.json")))
    let project = Project(path: root.path)
    model.state.projects = [project]
    model.state.chats = [Chat(session: .init(connection: .appClaude, nativeID: "m"), projectID: project.id, title: "First title", model: "claude")]
    model.refreshChatSearchIndex()
    await try #require(model.chatIndexTask).value
    #expect(model.chatIndexTask == nil && model.chatIndexedInfos == model.chatSearchInfos())
    #expect(try await model.chatSearchIndex.search("First").count == 1)
    // The same chats again: no run. A changed title: a run that updates the memo.
    model.refreshChatSearchIndex()
    #expect(model.chatIndexTask == nil)
    model.state.chats[0].title = "Second title"
    model.refreshChatSearchIndex()
    await try #require(model.chatIndexTask).value
    #expect(try await model.chatSearchIndex.search("Second").count == 1)
    #expect(model.chatIndexedInfos?.first?.title == "Second title")
}

@Test func chatIndexReturnsTheBestRowPerChatWithASnippet() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let long = info("long", title: "Long chat"), short = info("short", title: "Short chat")
    let words = (1...40).map { "word\($0)" }.joined(separator: " ")
    try await index.index([(long, blob(long, [("user", "\(words) needle \(words)"), ("assistant", "needle again"), ("user", "a needle")])),
                           (short, blob(short, [("user", "needles")]))])
    let hits = try await index.search("needle")
    #expect(hits.count == 2 && Set(hits.map(\.chatID)) == ["long", "short"])
    let snippets = Dictionary(uniqueKeysWithValues: hits.map { ($0.chatID, $0.snippet) })
    #expect(snippets["short"] == "needles")
    #expect(try await index.search("needle", limit: 1).count == 1)
    // The row that ranks best per chat carries the snippet; every candidate row is a short one here.
    #expect(["needle again", "a needle"].contains(snippets["long"]))
}

@Test func chatIndexSnippetKeepsAWindowAroundTheFirstMatch() {
    let words = (1...30).map { "w\($0)" }
    let text = (words[0..<10] + ["Анкета,"] + words[10...]).joined(separator: " ")
    // Five words before the match, the match, six after; cuts on both sides.
    #expect(ChatSearchIndex.snippet(text, terms: ["анкет"]) == "…w6 w7 w8 w9 w10 Анкета, w11 w12 w13 w14 w15 w16…")
    // At the start and the end the window shifts instead of shrinking.
    #expect(ChatSearchIndex.snippet(text, terms: ["w1"]) == "w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 Анкета, w11…")
    #expect(ChatSearchIndex.snippet(text, terms: ["w30"]) == "…w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30")
    // Only a word start counts; a short text stays whole; line breaks become spaces.
    #expect(ChatSearchIndex.snippet("x subword\nword", terms: ["word"]) == "x subword word")
    #expect(ChatSearchIndex.snippet("Café crème", terms: ["creme"]) == "Café crème")
    #expect(ChatSearchIndex.snippet("", terms: ["a"]) == "")
}

@Test func chatIndexOrdersOneAndTwoCharacterQueriesByRecency() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    // "older" matches the short word many times, so bm25 ranks it first; "newer" was indexed last.
    let older = info("older", title: "Older"), newer = info("newer", title: "Newer")
    try await index.index([(older, blob(older, [("user", "ab ab ab ab ab")]))])
    try await index.index([(newer, blob(newer, [("user", "ab and a much longer message with many other words in it")]))])
    #expect(try await index.search("ab").map(\.chatID) == ["newer", "older"])
    #expect(try await index.search("ab ab").map(\.chatID) == ["newer", "older"])
    #expect(try await index.search("ab and").map(\.chatID) == ["newer"])
}

@Test func chatIndexCancelledOrSupersededSearchReturnsNothing() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let chats = (0..<200).map { info("c\($0)", title: "Chat \($0)") }
    try await index.index(try chats.map { ($0, try blob($0, [("user", "common words here"), ("assistant", "common reply")])) })
    // A later search in the same scope supersedes an earlier one; other scopes are independent.
    let first = index.interrupt(scope: "archive"), other = index.interrupt(scope: "palette")
    let second = index.interrupt(scope: "archive")
    #expect(first.isSet && !second.isSet && !other.isSet)
    await #expect(throws: CancellationError.self) { try await index.search("common", limit: 300, interrupt: first) }
    // Stops inside the query: the first progress check passes, later ones report a newer search.
    let checks = OSAllocatedUnfairLock(initialState: 0)
    let midway = ChatSearchIndex.Interrupt { checks.withLock { $0 += 1; return $0 > 1 } }
    await #expect(throws: CancellationError.self) { try await index.search("common", limit: 300, interrupt: midway) }
    #expect(checks.withLock { $0 } > 1)
    // A cancelled task gets nothing; the connection keeps working afterwards.
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await index.search("common", scope: "archive")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await index.search("common", scope: "archive").count == 200)
}

@Test func chatIndexSearchDoesNotWaitForIndexing() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    let small = info("small", title: "Ready chat")
    try await index.index([(small, blob(small, [("user", "already indexed")]))])
    _ = try await index.search("already")
    let big = info("big", title: "Big chat")
    let text = (1...200).map { "filler\($0)" }.joined(separator: " ")
    let bigBlob = try blob(big, (0..<4000).map { ($0 % 2 == 0 ? "user" : "assistant", "\(text) \($0)") })
    let order = OSAllocatedUnfairLock(initialState: [String]())
    let writer = Task { try await index.index([(big, bigBlob)]); order.withLock { $0.append("index") } }
    try await Task.sleep(for: .milliseconds(20))
    // Served from the last commit on the reader connection while the writer is still busy.
    #expect(try await index.search("already").map(\.chatID) == ["small"])
    order.withLock { $0.append("search") }
    try await writer.value
    #expect(order.withLock { $0 } == ["search", "index"])
    #expect(try await index.search("filler1").map(\.chatID) == ["big"])
}

@Test func chatIndexAppendsMessagesOfATranscriptThatOnlyGrew() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let index = ChatSearchIndex(file: root.appendingPathComponent(ChatSearchIndex.fileName))
    var chat = info("chat", title: "Growing chat"), other = info("other", title: "Other chat")
    try await index.index([(chat, blob(chat, [("user", "first question"), ("assistant", "first answer")])),
                           (other, blob(other, [("user", "untouched")]))])
    func rows() async throws -> [[String]] {
        try await index.rows("SELECT position, row FROM message_rows WHERE chat_id='chat' AND position>=0 ORDER BY position")
    }
    func card() async throws -> [String]? { try await index.rows("SELECT title, message_count, first_request FROM chats WHERE id='chat'").first }
    let before = try await rows()
    #expect(before.map(\.first) == ["0", "1"])

    // One more turn: the stored rows stay, the new ones follow; the title row follows the rename.
    chat.title = "Grown chat"; chat.updated = chat.updated.addingTimeInterval(60)
    try await index.index([(chat, blob(chat, [("user", "first question"), ("assistant", "first answer"), ("user", "second question")]))])
    let grown = try await rows()
    #expect(Array(grown.prefix(2)) == before && grown.map(\.first) == ["0", "1", "2"])
    #expect(try await card() == ["Grown chat", "3", "first question"])
    #expect(try await index.search("second").map(\.chatID) == ["chat"])
    #expect(try await index.search("Grown").map(\.chatID) == ["chat"])
    #expect(try await index.search("Growing").isEmpty)
    #expect(try await index.plan([chat, other]).isEmpty)

    // An edited earlier message or a shorter transcript replaces every row.
    try await index.index([(chat, blob(chat, [("user", "edited question"), ("assistant", "first answer"), ("user", "second question")]))])
    #expect(try await rows().map(\.first) == ["0", "1", "2"])
    #expect(try await index.rows("SELECT text FROM messages WHERE rowid IN (SELECT row FROM message_rows WHERE chat_id='chat' AND position=0)") == [["edited question"]])
    #expect(try await index.rows("SELECT count(*) FROM messages").first == ["6"])
    #expect(try await index.search("edited").map(\.chatID) == ["chat"])
    #expect(try await card() == ["Grown chat", "3", "edited question"])
    try await index.index([(chat, blob(chat, [("user", "edited question")]))])
    #expect(try await rows().map(\.first) == ["0"])
    #expect(try await index.search("second").isEmpty)
    #expect(try await index.search("answer").isEmpty)
    #expect(try await index.rows("SELECT count(*) FROM messages").first == ["4"])
    #expect(try await index.rows("SELECT count(*) FROM message_rows").first == ["4"])
    #expect(try await index.rows("SELECT count(*) FROM message_digests").first == ["2"])
    #expect(try await index.search("untouched").map(\.chatID) == ["other"])
}

@Test func chatIndexDigestSeesEveryChangeToTheStoredMessages() {
    typealias Message = ChatSearchIndex.Message
    let messages = [Message(role: "user", text: "a", date: nil), Message(role: "assistant", text: "b", date: Date(timeIntervalSince1970: 5))]
    let full = ChatSearchIndex.digests(messages, prefix: 2)
    #expect(full.prefix == full.all)
    #expect(ChatSearchIndex.digests(messages + [Message(role: "user", text: "c", date: nil)], prefix: 2).prefix == full.all)
    #expect(ChatSearchIndex.digests([messages[0], Message(role: "assistant", text: "b", date: nil)], prefix: 2).all != full.all)
    #expect(ChatSearchIndex.digests([messages[0], Message(role: "user", text: "b", date: messages[1].date)], prefix: 2).all != full.all)
    #expect(ChatSearchIndex.digests([Message(role: "user", text: "ab", date: nil)], prefix: 1).all
            != ChatSearchIndex.digests([Message(role: "user", text: "a", date: nil), Message(role: "user", text: "b", date: nil)], prefix: 1).all)
    #expect(ChatSearchIndex.digests([], prefix: 0).prefix == ChatSearchIndex.digests(messages, prefix: 0).prefix)
}

@Test func chatIndexRebuildsAnOlderSchemaWithIncrementalVacuum() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(ChatSearchIndex.fileName)
    let old = ChatSearchIndex(file: file)
    let chat = info("chat", title: "Old schema chat")
    try await old.index([(chat, blob(chat, [("user", "stored before the upgrade")]))])
    // What a file from schema 2 looks like: no auto-vacuum, an older version stamp.
    _ = try await old.rows("PRAGMA auto_vacuum=0")
    _ = try await old.rows("VACUUM")
    _ = try await old.rows("UPDATE meta SET value='2' WHERE key='schema'")
    #expect(try await old.rows("PRAGMA auto_vacuum").first == ["0"])

    let upgraded = ChatSearchIndex(file: file)
    #expect(try await upgraded.rows("PRAGMA auto_vacuum").first == ["2"])
    #expect(try await upgraded.rows("SELECT value FROM meta WHERE key='schema'").first == [ChatSearchIndex.schemaVersion])
    #expect(try await upgraded.rows("PRAGMA journal_mode").first == ["wal"])
    #expect(try await upgraded.plan([chat]).content == ["chat"])
    #expect(try await upgraded.search("upgrade").isEmpty)

    // Removing chats gives their pages back instead of leaving them free inside the file.
    let text = String(repeating: "padding words for many pages ", count: 400)
    let chats = (0..<60).map { info("c\($0)", title: "Chat \($0)") }
    try await upgraded.index(try chats.map { ($0, try blob($0, (0..<20).map { ("user", "\(text) \($0)") })) })
    let pages = Int(try await upgraded.rows("PRAGMA page_count").first?.first ?? "") ?? 0
    try await upgraded.remove(chats.map(\.id))
    let free = Int(try await upgraded.rows("PRAGMA freelist_count").first?.first ?? "") ?? -1
    let after = Int(try await upgraded.rows("PRAGMA page_count").first?.first ?? "") ?? 0
    #expect(free >= 0 && free < 256 && after < pages / 2)
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
