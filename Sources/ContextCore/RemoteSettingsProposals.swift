import Foundation

/// Host-owned handles for reviewed settings requests. The phone sends only a decision and a handle,
/// never settings. Handles expire when the file, target settings, chat or host process changes.
public struct RemoteSettingsProposals {
    private struct Entry {
        var handle = UUID().uuidString
        var review: SettingsProposalReview
        var chat: String
        var projects: [Project]
        var notes: [SettingsProposalBoundaryNote] = []
        var published = false
    }
    private var entries: [Entry] = []
    public init() {}

    public mutating func refresh(_ reviews: [SettingsProposalReview], state: SavedState, boundaryNotes: (SettingsProposalReview) -> [SettingsProposalBoundaryNote] = { _ in [] }) {
        entries = reviews.compactMap { review in
            guard let label = review.chat,
                  let chat = state.chats.first(where: { $0.id == label || $0.nativeSession?.nativeID == label }),
                  !chat.isArchived, !chat.isScheduledRecord,
                  review.projects.contains(where: { $0.projectID == chat.projectID }) else { return nil }
            let projects = review.projects.compactMap { diff in state.projects.first { $0.id == diff.projectID } }
            guard projects.count == review.projects.count else { return nil }
            let notes = boundaryNotes(review)
            return entries.first { $0.review == review && $0.chat == chat.id && $0.projects == projects && $0.notes == notes }
                ?? Entry(review: review, chat: chat.id, projects: projects, notes: notes)
        }
    }

    /// Only explicitly shared projects may cross the cloud boundary, including every target of a multi-project request.
    public mutating func approvals(chat: String, sharedProjects: Set<String>) -> [RemoteApproval] {
        var result: [RemoteApproval] = []
        for index in entries.indices where entries[index].chat == chat {
            guard entries[index].projects.allSatisfy({ sharedProjects.contains($0.id.uuidString) }) else { continue }
            let review = entries[index].review
            let details = review.remoteDetails(boundaryNotes: entries[index].notes)
            entries[index].published = true
            result.append(RemoteApproval(id: entries[index].handle, details: String(details.prefix(8000)),
                canAllow: !review.projects.isEmpty && review.skipped.isEmpty && details.count <= 8000,
                projectSettings: true))
        }
        return result
    }

    /// Single-use, exact reviewed content. A missing/stale handle cannot become an ordinary tool approval.
    public mutating func take(handle: String, chat: String, allow: Bool, sharedProjects: Set<String>) -> SettingsProposalReview? {
        guard let identifier = UUID(uuidString: handle),
              let index = entries.firstIndex(where: { UUID(uuidString: $0.handle) == identifier && $0.chat == chat && $0.published }),
              entries[index].projects.allSatisfy({ sharedProjects.contains($0.id.uuidString) }),
              !allow || (entries[index].review.skipped.isEmpty && entries[index].review.remoteDetails(boundaryNotes: entries[index].notes).count <= 8000) else { return nil }
        return entries.remove(at: index).review
    }
}

extension SettingsProposalReview {
    /// Full effective diff, with persistent scope stated explicitly. Text supplied by an agent remains literal data.
    public func remoteDetails(language: AppLanguage = L10n.language, boundaryNotes: [SettingsProposalBoundaryNote] = []) -> String {
        func text(_ ru: String, _ en: String) -> String { L10n.text(ru, en, language: language) }
        var lines = [text("Изменение доступа к проекту", "Project access change"),
                     text("Это постоянное изменение настроек проекта для всех его чатов, а не разрешение одной команды. Новые права применяются при следующем запуске агента. Чат получит твоё решение и продолжит работу.",
                          "This permanently changes project settings for all its chats, rather than approving one command. New permissions apply at the next agent launch. The chat receives your decision and continues.")]
        if let reason { lines += [text("Причина: ", "Reason: ") + reason] }
        for diff in projects {
            lines += ["", text("Проект: ", "Project: ") + diff.name]
            if let sandbox = diff.sandbox {
                lines += [sandbox ? text("+ Включить песочницу команд", "+ Enable command sandbox")
                                  : text("! Выключить песочницу команд: доступ ко всему Mac", "! Disable command sandbox: access to the whole Mac")]
            }
            for id in diff.addPresets { lines += [text("+ Набор доступа: ", "+ Access set: ") + id] }
            for id in diff.removePresets { lines += [text("− Набор доступа: ", "− Access set: ") + id] }
            for root in diff.addFolders {
                lines += [text("+ Папка: ", "+ Folder: ") + root.path + (root.writable ? text(" (чтение и запись)", " (read and write)") : text(" (только чтение)", " (read only)"))]
            }
            for path in diff.removeFolders { lines += [text("− Папка: ", "− Folder: ") + path] }
            for command in diff.addCommands { lines += [text("! Доверенная команда: ", "! Trusted command: ") + command] }
            for note in boundaryNotes where note.projectID == diff.projectID { lines += [note.text(language: language)] }
            for item in diff.addKeychainItems { lines += [KeychainItemRule.addLine(item, language: language)] }
            for item in diff.removeKeychainItems { lines += [KeychainItemRule.removeLine(item, language: language)] }
            for command in diff.removeCommands { lines += [text("− Команда вне песочницы: ", "− Command outside the sandbox: ") + command] }
        }
        if !skipped.isEmpty { lines += ["", text("Пропущено; проверь запрос на Mac:", "Skipped; review the request on Mac:")] + skipped }
        return lines.joined(separator: "\n")
    }
}
