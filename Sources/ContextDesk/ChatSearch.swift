import Foundation
import ContextCore

/// Chat search (plan `docs/agent-chat-search-plan.md`): keeps the local full-text index current and opens
/// a Claude chat that finds earlier chats with the read-only chat tools.
extension DeskModel {
    var chatSearchIndexFile: URL { jobStore.file.deletingLastPathComponent().appendingPathComponent(ChatSearchIndex.fileName) }
    /// User-editable copy of the recipe. It stays outside `workflows`, so Codex chats never load it as a skill.
    var chatSearchRecipe: URL { jobStore.file.deletingLastPathComponent().appendingPathComponent("chat-search/SKILL.md") }
    static let chatSearchModel = "claude-sonnet-5-5"

    /// Chats the index covers: everything a person wrote or read, not scheduled records or search chats themselves.
    func chatSearchInfos() -> [ChatSearchIndex.ChatInfo] {
        let projects = Dictionary(state.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return state.chats.compactMap { chat in
            guard !chat.isScheduledRecord, chat.chatSearch != true, let project = projects[chat.projectID] else { return nil }
            let summary = archiveSummaries[chat.id].flatMap { record in
                record.status == .ready ? record.parts.flatMap { [$0.content.overview] + $0.content.activities.map(\.goal) }.joined(separator: "\n") : nil
            } ?? ""
            return .init(id: chat.id, projectID: project.id.uuidString, project: project.name, projectPath: project.path, title: chat.title,
                         agent: chat.nativeSession?.connection == .appClaude ? "Claude" : "Codex", archived: chat.isArchived,
                         updated: chat.updated, summary: summary, session: chat.nativeSession)
        }
    }

    /// Brings the index up to date in the background; a run already in progress is left alone, and nothing runs while
    /// the chats still match the last completed run (the scheduler calls this every 15 s).
    func refreshChatSearchIndex() {
        guard chatIndexTask == nil else { return }
        let infos = chatSearchInfos()
        guard infos != chatIndexedInfos else { return }
        let index = chatSearchIndex, store = store
        chatIndexTask = Task.detached(priority: .utility) { [weak self] in
            var completed = false
            do {
                let plan = try await index.plan(infos)
                if !plan.isEmpty {
                    let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    if !plan.removed.isEmpty { try await index.remove(plan.removed) }
                    if !plan.metadata.isEmpty { try await index.updateMetadata(plan.metadata.compactMap { byID[$0] }) }
                    // Small batches: a transcript blob can reach tens of megabytes.
                    for start in stride(from: 0, to: plan.content.count, by: 8) {
                        try Task.checkCancellation()
                        let batch = Array(plan.content[start..<min(start + 8, plan.content.count)])
                        let blobs = try await store.transcriptBlobs(conversationIDs: batch)
                        try await index.index(batch.compactMap { id in byID[id].map { ($0, blobs[id]) } })
                    }
                    AppLog.lifecycle.notice("Chat index updated: \(plan.content.count, privacy: .public) read, \(plan.metadata.count, privacy: .public) renamed, \(plan.removed.count, privacy: .public) removed")
                }
                completed = true
            } catch is CancellationError {
            } catch {
                AppLog.lifecycle.error("Chat index update failed: \(error.localizedDescription, privacy: .public)")
            }
            // A failed or cancelled run leaves no memo, so the next tick tries again.
            await MainActor.run { self?.chatIndexTask = nil; self?.chatIndexedInfos = completed ? infos : nil }
        }
    }

    /// Text matches for the archive search: chat id and a short snippet. Empty while the index is not built.
    func chatTextMatches(_ query: String) async -> [String: String] {
        let hits = (try? await chatSearchIndex.search(query)) ?? []
        return Dictionary(hits.map { ($0.chatID, $0.snippet) }, uniquingKeysWith: { first, _ in first })
    }

    /// A `switchboard-chat:` link in an answer; an unknown or deleted chat is ignored.
    func openChatLink(_ id: String) {
        guard let chat = state.chats.first(where: { $0.id == id }) else { return }
        Task { await openChat(chat) }
    }

    var canStartChatSearch: Bool { claudeConnected && claudeAuthenticated }

    func prepareChatSearchRecipe() throws {
        guard !FileManager.default.fileExists(atPath: chatSearchRecipe.path),
              let source = summaryResources?.appendingPathComponent("chat-search/SKILL.md"),
              FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: chatSearchRecipe.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: chatSearchRecipe)
    }

    /// Opens a Claude chat with read-only access and the chat tools, and sends the request to it.
    func startChatSearch(query: String, projectID: UUID?) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, canStartChatSearch,
              let project = projectID.flatMap({ id in state.projects.first { $0.id == id } }) ?? selectedProject ?? state.projects.first else { return }
        let model = ClaudeModel.catalog.first { $0.id == Self.chatSearchModel && $0.isSupported() }?.id ?? ClaudeModel.resolved(state.claudeModel)
        let effort = ClaudeEffort.resolved(state.claudeEffort)
        let role = roleCatalog.role(AgentRoleID.reader) ?? project.chatRole(roleCatalog)
        do {
            try prepareChatSearchRecipe()
            refreshChatSearchIndex()
            let session = try await claudeConnection.createSession(projectPath: project.path, permissions: role.profile(for: project), model: model, route: .direct)
            guard ConversationIdentity.appID(for: session.nativeID, in: state, connection: session.connection) == nil else { throw ConversationIdentity.invalidStorage }
            var chat = Chat(session: session, projectID: project.id, title: L10n.text("Поиск: ", "Search: ") + String(query.prefix(60)), model: model)
            chat.effort = effort; chat.route = .direct
            chat.roleID = role.id; chat.accessMode = role.legacyAccessMode; chat.inheritsProjectAccess = false
            // Access before the first send, so the first turn already has the tools.
            chat.chatDirectoryAccess = true; chat.chatSearch = true
            state.chats.append(chat)
            try await store.save(state)
            loadedThreads.insert(chat.id)
            await refreshChatDirectory()
            await openChat(chat)
            let scope = projectID.flatMap { id in state.projects.first { $0.id == id } }
                .map { L10n.text("\nПроект: \($0.name)", "\nProject: \($0.name)") } ?? ""
            await deliver(text: L10n.text("Найди чат: ", "Find the chat: ") + query + scope, project: project, threadID: chat.id,
                          localID: "local-user:" + UUID().uuidString, selectedModel: model, selectedEffort: effort)
        } catch { self.error = L10n.text("Не удалось начать поиск: ", "Could not start the search: ") + error.localizedDescription }
    }
}
