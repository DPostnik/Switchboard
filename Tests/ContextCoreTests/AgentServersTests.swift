import Foundation
import Testing
import ContextCore

private func record(_ pid: Int32, parent: Int32 = 500, chat: String? = nil, instance: String? = "me",
                    command: String = "node server.js", path: String = "/usr/local/bin/node") -> ProcessRecord {
    ProcessRecord(pid: pid, parent: parent, started: Date(timeIntervalSince1970: Double(pid)), path: path, command: command,
                  chat: chat, instance: instance)
}

@Test func agentServersAreListeningProcessesOfThisInstanceButNotTheAgentCLI() {
    let servers = AgentServers.select([
        (record(10, chat: "s1"), [5173, 24678, 5173], "/p"),
        (record(11, chat: "s1"), [3000], "/p"),
        (record(12, chat: "s1"), [], "/p"),                               // not listening
        (record(13, chat: "s1", instance: "other"), [8080], "/p"),        // another Switchboard
        (record(14, parent: 99, chat: "s1"), [9000], "/p"),               // the CLI itself, a child of the app
        (record(15, chat: "s1", path: "/A/Google Chrome for Testing.app/Contents/MacOS/x"), [9222], "/p"),
    ], instance: "me", selfPID: 99)
    #expect(servers.map(\.record.pid) == [11, 10])
    #expect(servers[1].ports == [5173, 24678])
    #expect(servers[0].url.absoluteString == "http://localhost:3000")
}

@Test func chatServersMatchTheSessionLabelOrUnlabelledOnesInTheChatFolder() {
    let all = [AgentServer(record: record(1, chat: "s1"), ports: [3000], directory: "/elsewhere"),
               AgentServer(record: record(2, chat: "s2"), ports: [3001], directory: "/p"),
               AgentServer(record: record(3), ports: [3002], directory: "/p/web"),
               AgentServer(record: record(4), ports: [3003], directory: "/pp")]
    #expect(AgentServers.servers(all, chat: "s1", folder: "/p").map(\.port) == [3000, 3002])
    #expect(AgentServers.servers(all, chat: nil, folder: "/p").map(\.port) == [3002])
    #expect(AgentServers.servers(all, chat: "s3", folder: nil).isEmpty)
}

@Test func stoppingAServerTakesItsDescendants() {
    let table = [record(1, parent: 0), record(2, parent: 1), record(3, parent: 2), record(4, parent: 1), record(5, parent: 9)]
    #expect(Set(AgentServers.tree(of: table[1], in: table).map(\.pid)) == [2, 3])
    #expect(Set(AgentServers.tree(of: table[0], in: table).map(\.pid)) == [1, 2, 3, 4])
}

@Test func serverNamesShowTheScriptOfAnInterpreter() {
    #expect(AgentServers.name(command: "node /p/node_modules/.bin/next dev", path: "") == "next")
    #expect(AgentServers.name(command: "/opt/homebrew/bin/node --inspect /p/node_modules/vite/bin/vite.js", path: "") == "vite")
    #expect(AgentServers.name(command: "python3.12 -m http.server 8000", path: "") == "http.server")
    #expect(AgentServers.name(command: "/usr/local/bin/caddy run", path: "") == "caddy")
    #expect(AgentServers.name(command: "", path: "/usr/bin/ruby") == "ruby")
}
