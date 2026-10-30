import Foundation
import AgentContract
import ContextCore
import ContextTranscript

/// Text the user copies from a chat's menu to point another agent at that chat. The chat ID is the one the chat
/// directory tools (`read_chat`) use; the link opens the chat from an answer; the engine session ID finds the native
/// transcript on disk.
@MainActor enum ChatReference {
    static func link(_ chat: Chat) -> String { TranscriptLinks.chatScheme + ":" + chat.id }
    static func text(_ chat: Chat, projectPath: String?, language: AppLanguage = L10n.language) -> String {
        func text(_ russian: String, _ english: String) -> String { L10n.text(russian, english, language: language) }
        var lines = [text("Чат Switchboard: «\(chat.title)»", "Switchboard chat: \"\(chat.title)\""), text("ID чата: ", "Chat ID: ") + chat.id,
                     text("Ссылка: ", "Link: ") + link(chat)]
        if let session = chat.nativeSession {
            let agent = switch session.connection.agent {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            default: session.connection.agent.rawValue
            }
            lines.append(text("Сессия \(agent): ", "\(agent) session: ") + session.nativeID)
        }
        if let projectPath { lines.append(text("Проект: ", "Project: ") + projectPath) }
        return lines.joined(separator: "\n")
    }
}
