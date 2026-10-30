import Foundation
import Testing
import AgentContract
import ContextCore
@testable import ContextDesk

@MainActor @Test func chatReferenceNamesTheChatSessionAndProjectInBothLanguages() {
    var chat = Chat(session: AgentSessionReference(connection: .appClaude, nativeID: "S-1"), projectID: UUID(), title: "Dev server", model: "m")
    chat.id = "C-1"
    #expect(ChatReference.text(chat, projectPath: "/work/app", language: .english)
        == "Switchboard chat: \"Dev server\"\nChat ID: C-1\nLink: switchboard-chat:C-1\nClaude Code session: S-1\nProject: /work/app")
    #expect(ChatReference.text(chat, projectPath: "/work/app", language: .russian)
        == "Чат Switchboard: «Dev server»\nID чата: C-1\nСсылка: switchboard-chat:C-1\nСессия Claude Code: S-1\nПроект: /work/app")
    // A chat without an engine session or a known project still names itself.
    chat.nativeSession = nil
    #expect(ChatReference.text(chat, projectPath: nil, language: .english)
        == "Switchboard chat: \"Dev server\"\nChat ID: C-1\nLink: switchboard-chat:C-1")
}
