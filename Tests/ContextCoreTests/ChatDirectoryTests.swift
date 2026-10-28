import Foundation
import Testing
@testable import ClaudeAdapter
@testable import ContextCore
@testable import ContextDesk

private let directoryServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ChatDirectoryRuntime/server.py")

/// Runs the server once with the given JSON-RPC lines and returns its replies by id.
private func serve(_ requests: [[String: Any]], snapshot: URL, chat: String) throws -> [Int: [String: Any]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", directoryServer.path, "--snapshot", snapshot.path, "--chat", chat]
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
private func text(_ reply: [String: Any]?) -> [String: Any] {
    let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    return (try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]) ?? [:]
}

@Test func chatDirectoryServerListsAndReadsTheSnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(ChatDirectory.fileName)
    let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
    try ChatDirectory.write(.init(generatedAt: Date(), chats: [
        .init(id: "master", title: "Master", project: "wiki", agent: "Claude", state: "idle", detail: nil, activity: nil, updated: new, messages: []),
        .init(id: "a", title: "Mail", project: "super-wiki", agent: "Claude", state: "unread", detail: "Done.", activity: nil, updated: new,
              messages: (1...10).map { .init(role: $0.isMultiple(of: 2) ? "assistant" : "user", text: "m\($0)") }),
        .init(id: "b", title: "Batch", project: "super-wiki", agent: "Codex", state: "needs-approval", detail: "Action required: Bash", activity: nil, updated: old, messages: []),
        .init(id: "c", title: "Build", project: "switchboard", agent: "Codex", state: "working", detail: nil, activity: "Bash", updated: new, messages: []),
    ]), to: file)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let replies = try serve([
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_chats", "arguments": [:]]],
        ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "list_chats", "arguments": ["filter": "all", "project": "SWITCH"]]],
        ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "read_chat", "arguments": ["chat_id": "a", "last_n": 3]]],
        ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "read_chat", "arguments": ["chat_id": "missing"]]],
        ["jsonrpc": "2.0", "id": 7, "method": "resources/write"],
    ], snapshot: file, chat: "master")
    #expect(((replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["list_chats", "read_chat"])
    // Waiting chats only, most urgent first; the calling chat is left out.
    #expect((text(replies[3])["chats"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["b", "a"])
    #expect((text(replies[4])["chats"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["c"])
    #expect((text(replies[5])["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["m8", "m9", "m10"])
    #expect((replies[6]?["result"] as? [String: Any])?["isError"] as? Bool == true)
    #expect(replies[7]?["error"] != nil && replies.count == 7)
}

@Test func chatDirectoryIsAttachedOnlyWhenGiven() throws {
    let base = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .standard, model: "", effort: nil)
    #expect(!base.joined(separator: " ").contains(ChatDirectory.serverName))
    let args = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: AgentRoleCatalog.preset(AgentRoleID.editor).profile,
                                               model: "", effort: nil, chatDirectory: ["/x/server.py", "--snapshot", "/x/s.json", "--chat", "c1"])
    let config = try #require(args.firstIndex(of: "--mcp-config").map { args[$0 + 1] })
    #expect(config.contains(#""switchboard_chats":{"args":["-I","/x/server.py","--snapshot","/x/s.json","--chat","c1"]"#))
    #expect(args.contains("mcp__switchboard_chats") && !args.contains("--safe-mode"))
    #expect(ClaudeLaunchPolicy(AgentRoleCatalog.preset(AgentRoleID.reader).profile, scheduled: false, userChromeEnabled: false)
        .permits(tool: "mcp__switchboard_chats__list_chats"))
    #expect(ChatDirectory.Message(role: "user", text: String(repeating: "x", count: 2000)).text.count == ChatDirectory.messageLimit + 1)
}

@Test @MainActor func chatDirectorySnapshotExistsOnlyWhileAChatHasAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil)
    let project = Project(path: root.path)
    let master = Chat(session: .init(connection: .appClaude, nativeID: "m"), projectID: project.id, title: "Master", model: "claude")
    var other = Chat(session: .init(connection: .originalCodex, nativeID: "o"), projectID: project.id, title: "Other", model: "codex")
    other.unreadCompletionID = "turn:o:1"; other.recap = "Batch sent."
    model.state.projects = [project]; model.state.chats = [master, other]
    try? FileManager.default.removeItem(at: model.chatDirectoryFile)
    await model.refreshChatDirectory()
    #expect(!FileManager.default.fileExists(atPath: model.chatDirectoryFile.path))
    #expect(model.chatDirectoryArguments(for: master.id) == nil)
    model.toggleChatDirectory(master.id)
    #expect(model.state.chats.first?.chatDirectoryAccess == true)
    await model.refreshChatDirectory()
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(ChatDirectory.Snapshot.self, from: Data(contentsOf: model.chatDirectoryFile))
    let entry = try #require(snapshot.chats.first { $0.id == other.id })
    #expect(entry.state == "unread" && entry.detail == "Batch sent." && entry.agent == "Codex")
    model.toggleChatDirectory(master.id)
    await model.refreshChatDirectory()
    #expect(!FileManager.default.fileExists(atPath: model.chatDirectoryFile.path))
}
