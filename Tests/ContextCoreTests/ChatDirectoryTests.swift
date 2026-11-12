import Foundation
import SQLite3
import Testing
@testable import ClaudeAdapter
@testable import ContextCore
@testable import ContextDesk

private let directoryServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ChatDirectoryRuntime/server.py")

/// Runs the server once with the given JSON-RPC lines and returns its replies by id.
private func serve(_ requests: [[String: Any]], snapshot: URL, chat: String) throws -> [Int: [String: Any]] {
    try serve(requests, arguments: ["--snapshot", snapshot.path, "--chat", chat])
}
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
    let diagnosticsOnly = try #require(model.chatDirectoryArguments(for: master.id, script: directoryServer))
    #expect(diagnosticsOnly.contains("--diagnostics-project"))
    #expect(!diagnosticsOnly.contains("--root") && !diagnosticsOnly.contains("--snapshot"))
    model.state.chats[0].roleID = AgentRoleID.reader
    #expect(model.chatDirectoryArguments(for: master.id, script: directoryServer) == nil)
    model.state.chats[0].roleID = nil
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

/// A `metadata.sqlite` with the app's `state` table holding the given JSON values.
private func writeState(_ rows: [String: Any], to url: URL) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK)
    for (key, value) in rows {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO state VALUES (?, ?)", -1, &statement, nil)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient); sqlite3_bind_text(statement, 2, json, -1, transient)
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
    }
}

@Test func inspectChatResolvesAnyIDAndKeepsToReferencedChats() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = UUID().uuidString, caller = UUID().uuidString, session = UUID().uuidString, turn = UUID().uuidString, project = UUID().uuidString
    let web = WebChats.prefix + UUID().uuidString.lowercased()
    try writeState([
        "app": ["projects": [["id": project, "name": "switchboard", "path": "/p"]],
                "chats": [["id": target, "title": "Files", "projectID": project, "updated": 815_741_411,
                           "nativeSession": ["nativeID": session, "connection": ["agent": "claude-code", "id": "c"]]],
                          ["id": caller, "title": "Caller", "projectID": project],
                          ["id": web, "title": "Web", "projectID": project]]],
        "timing:" + target: [turn: ["startedAt": 815_741_411, "completedAt": 815_741_495, "tokens": ["counts": ["output": 5]]]],
    ], to: root.appendingPathComponent("metadata.sqlite"))
    let folder = root.appendingPathComponent("claude/projects/-p")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let lines: [[String: Any]] = [
        ["type": "user", "timestamp": "2026-11-07T10:50:11Z", "message": ["role": "user", "content": "Build it"]],
        ["type": "assistant", "timestamp": "2026-11-07T10:51:32Z", "message": ["content": [
            ["type": "thinking", "thinking": "hidden"], ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "zsh build.sh"]]]]],
        ["type": "user", "timestamp": "2026-11-07T10:51:33Z", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "denied"]]]],
        ["type": "assistant", "isSidechain": true, "timestamp": "2026-11-07T10:51:34Z", "message": ["content": [["type": "text", "text": "sub-agent"]]]],
        ["type": "user", "timestamp": "2026-11-07T10:51:35Z", "message": ["content": "<task-notification>\n<status>failed</status>\n<summary>Build failed</summary>\n</task-notification>"]],
    ]
    try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        .write(to: folder.appendingPathComponent(session + ".jsonl"), atomically: true, encoding: .utf8)
    ChatEventLog.append(chat: target, kind: "turn", text: "Turn \(turn) finished: completed", root: root)
    ChatEventLog.append(chat: session, kind: "process", text: "Process terminated (chat ended): pid 1", root: root)
    let references = try #require(ChatReferences.file(chat: caller, root: root))
    func call(_ id: String, events: Int = 10, before: Int = 0) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "inspect_chat", "arguments": ["id": id, "events": events, "before": before]]]
    }
    let limited = ["--chat", caller, "--root", root.path, "--references", references.path]
    let refused = try serve([["jsonrpc": "2.0", "id": 1, "method": "tools/list"], call("switchboard-chat:" + target)], arguments: limited)
    // Without a snapshot or index only inspect_chat is offered, and only for chats the user named in the caller.
    #expect(((refused[1]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["inspect_chat"])
    #expect((refused[2]?["result"] as? [String: Any])?["isError"] as? Bool == true)
    try ChatReferences.record([target], chat: caller, root: root)
    let byChat = text(try serve([call("switchboard-chat:" + target.lowercased())], arguments: limited)[2])
    #expect(byChat["chat_id"] as? String == target && byChat["matched_as"] as? String == "chat" && byChat["agent_session_id"] as? String == session)
    #expect((byChat["transcript_file"] as? String)?.hasSuffix(session + ".jsonl") == true)
    #expect((byChat["turns"] as? [[String: Any]])?.first?["seconds"] as? Int == 84)
    #expect((byChat["app_events"] as? [[String: Any]])?.compactMap { $0["kind"] as? String } == ["turn", "process"])
    let events = try #require(byChat["transcript_events"] as? [[String: Any]])
    #expect(events.compactMap { $0["kind"] as? String } == ["user", "tool_call", "tool_result", "task_notification"])
    #expect(events[2]["error"] as? Bool == true && events[3]["status"] as? String == "failed")
    #expect(text(try serve([call(session, events: 1)], arguments: limited)[2])["matched_as"] as? String == "agent session")
    let byTurn = text(try serve([call(turn, events: 2)], arguments: limited)[2])
    #expect(byTurn["matched_as"] as? String == "turn" && (byTurn["transcript_events"] as? [[String: Any]])?.count == 2)
    let paged = text(try serve([call(target, events: 1, before: 1)], arguments: limited)[2])
    #expect((paged["transcript_events"] as? [[String: Any]])?.first?["kind"] as? String == "tool_result")
    // A chat with access to all chats needs no reference.
    let open = try serve([call(target)], arguments: ["--chat", UUID().uuidString, "--root", root.path])
    #expect(text(open[2])["chat_id"] as? String == target)
    // A web client chat keeps its `web:` prefix in the ID.
    let webChat = try serve([call("switchboard-chat:" + web)], arguments: ["--chat", UUID().uuidString, "--root", root.path])
    #expect(text(webChat[2])["chat_id"] as? String == web)
}

@Test func chatReferencesAndEventsStayInTheirFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "5985D481-7071-4F2B-AC10-84D4259F8979"
    #expect(ChatReferences.identifiers(in: "see switchboard-chat:\(id) and \(id.lowercased()), not 5985D481") == [id.lowercased()])
    #expect(ChatReferences.file(chat: "../x", root: root) == nil && ChatEventLog.file(chat: "a/b", root: root) == nil)
    #expect(try ChatReferences.record(["a", "b", "own"], chat: "own", root: root) == ["a", "b"])
    #expect(try ChatReferences.record(["b", "c"], chat: "own", root: root) == ["a", "b", "c"])
    let file = try #require(ChatReferences.file(chat: "own", root: root))
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    for index in 0..<600 { ChatEventLog.append(chat: "own", kind: "turn", text: "event \(index) " + String(repeating: "x", count: 200), root: root) }
    let events = ChatEventLog.events(chat: "own", root: root)
    #expect(events.count <= 600 && events.count >= ChatEventLog.keep && events.last?.text.hasPrefix("event 599") == true)
    let log = try #require(ChatEventLog.file(chat: "own", root: root))
    #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int == 0o600)
    #expect((try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int ?? 0) <= ChatEventLog.trimBytes + 1024)
    ChatReferences.remove(chat: "own", root: root); ChatEventLog.remove(chat: "own", root: root)
    #expect(ChatReferences.load(chat: "own", root: root).isEmpty && ChatEventLog.events(chat: "own", root: root).isEmpty)
}

@Test(arguments: [AgentConnectionID.appClaude, .originalCodex]) @MainActor func namingAChatAttachesOnlyInspectChat(connection: AgentConnectionID) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil)
    let project = Project(path: root.path)
    let caller = Chat(session: .init(connection: connection, nativeID: UUID().uuidString), projectID: project.id, title: "Caller", model: "claude")
    let other = Chat(session: .init(connection: .appClaude, nativeID: UUID().uuidString), projectID: project.id, title: "Other", model: "claude")
    model.state.projects = [project]; model.state.chats = [caller, other]
    defer { ChatReferences.remove(chat: caller.id) }
    ChatReferences.remove(chat: caller.id)
    let diagnosticsOnly = try #require(model.chatDirectoryArguments(for: caller.id, script: directoryServer))
    #expect(diagnosticsOnly.contains("--diagnostics-project"))
    #expect(!diagnosticsOnly.contains("--root") && !diagnosticsOnly.contains("--references") && !diagnosticsOnly.contains("--index") && !diagnosticsOnly.contains("--snapshot"))
    model.noteChatReferences(chatID: caller.id, text: "Why did " + UUID().uuidString + " and our own " + caller.id + " stop?")
    #expect(model.chatDirectoryArguments(for: caller.id, script: directoryServer) == diagnosticsOnly)
    // The agent session ID names its chat too.
    model.noteChatReferences(chatID: caller.id, text: "session " + (other.nativeSession?.nativeID ?? ""))
    #expect(ChatReferences.load(chat: caller.id) == [other.id])
    // A web client chat is named by its UUID without the `web:` prefix.
    var web = Chat(session: .init(connection: .appClaude, nativeID: UUID().uuidString), projectID: project.id, title: "Web", model: "claude")
    web.id = WebChats.prefix + UUID().uuidString.lowercased()
    model.state.chats.append(web)
    #expect(web.startedOnWeb && !other.startedOnWeb)
    model.noteChatReferences(chatID: caller.id, text: "switchboard-chat:" + web.id)
    #expect(ChatReferences.load(chat: caller.id) == [other.id, web.id])
    let args = try #require(model.chatDirectoryArguments(for: caller.id, script: directoryServer))
    #expect(args.contains("--references") && args.contains("--root") && !args.contains("--snapshot") && !args.contains("--index"))
    model.toggleChatDirectory(caller.id)
    let full = try #require(model.chatDirectoryArguments(for: caller.id, script: directoryServer))
    #expect(full.contains("--snapshot") && full.contains("--root") && !full.contains("--references"))
}

@Test func projectDiagnosticsRejectsExtraArgumentsAndHasNoChatAccess() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let replies = try serve([
        ["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "project_diagnostics", "arguments": ["operation": "load"]]],
        ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "project_diagnostics", "arguments": ["operation": "load", "project": "/"]]],
        ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "inspect_chat", "arguments": ["id": UUID().uuidString]]],
        ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "project_diagnostics", "arguments": ["operation": "shell"]]],
    ], arguments: ["--diagnostics-project", root.path])
    #expect(((replies[1]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["project_diagnostics"])
    #expect(text(replies[2])["cores"] as? Int != nil)
    for id in [3, 4, 5] { #expect((replies[id]?["result"] as? [String: Any])?["isError"] as? Bool == true) }
}
