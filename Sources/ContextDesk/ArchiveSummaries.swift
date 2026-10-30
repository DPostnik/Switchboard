import Foundation
import ContextCore

extension DeskModel {
    func supportsSummaries(_ id: String) -> Bool {
        state.chats.first { $0.id == id }.map(supportsSummaries) ?? false
    }

    /// Takes the chat itself so list views avoid a linear lookup per row.
    func supportsSummaries(_ chat: Chat) -> Bool {
        !chat.isScheduledRecord && [.originalCodex, .appClaude].contains(chat.nativeSession?.connection)
    }

    /// Generation for a chat runs on its own agent connection, never on another agent's account.
    func canGenerateSummary(_ id: String) -> Bool {
        state.chats.first { $0.id == id }.map(canGenerateSummary) ?? false
    }

    func canGenerateSummary(_ chat: Chat) -> Bool {
        guard supportsSummaries(chat) else { return false }
        return chat.nativeSession?.connection == .appClaude ? claudeConnected && claudeAuthenticated : connected && authenticated
    }

    func generationRunner(for id: String) -> AgentGenerationRunner {
        state.chats.first { $0.id == id }?.nativeSession?.connection == .appClaude ? claudeSummaryRunner : summaryRunner
    }

    func generationEnvironment(for id: String, workspace: String, recipe: String? = nil) -> AgentGenerationEnvironment {
        let claude = state.chats.first { $0.id == id }?.nativeSession?.connection == .appClaude
        return .init(executable: claude ? nil : summaryExecutable, home: claude ? claudeHome : summaryHome,
                     workspace: summarySkillsDirectory.appendingPathComponent(workspace),
                     recipeDirectory: recipe.map { summarySkillsDirectory.appendingPathComponent($0) })
    }

    /// The chat's own model; Claude falls back to its app default, never to the Codex model.
    func generationModel(for chat: Chat) -> String {
        if chat.nativeSession?.connection == .appClaude { return ClaudeModel.resolved(chat.model.isEmpty ? state.claudeModel : chat.model) }
        return chat.model.isEmpty ? state.model : chat.model
    }

    /// Stops in-flight summary work owned by one agent after its account or connection changed.
    func interruptSummaries(_ agent: AgentConnectionID, issue: String) async {
        let owned = { (id: String) in self.state.chats.first { $0.id == id }?.nativeSession?.connection == agent }
        if let active = summaryActiveThread, owned(active) { summaryTask?.cancel() }
        for id in archiveSummaries.keys where owned(id) {
            guard var record = archiveSummaries[id], [.queued, .reading, .generating].contains(record.status) else { continue }
            record.status = record.status == .generating ? .uncertain : .stale
            record.issue = issue
            archiveSummaries[id] = record
            do { try await store.saveArchiveSummary(record) } catch { self.error = error.localizedDescription }
        }
    }

    var summarySkillsDirectory: URL { summaryHome.deletingLastPathComponent().appendingPathComponent("workflows") }

    func prepareSummarySkills() throws {
        guard let summaryResources else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: summarySkillsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["archive-summary", "routine-optimizer", "history-patterns"] {
            let destination = summarySkillsDirectory.appendingPathComponent(name)
            // Recipes are user-editable. Rebuilding the app does not overwrite them.
            if !manager.fileExists(atPath: destination.path) {
                try manager.copyItem(at: summaryResources.appendingPathComponent(name), to: destination)
            }
        }
    }

    func restoreSummaryQueue() async {
        do {
            archiveSummaries = try await store.loadArchiveSummaries()
            for id in archiveSummaries.keys.sorted() {
                guard var record = archiveSummaries[id] else { continue }
                record.recover()
                if record.status == .queued && !isArchived(id) { record.status = .stale }
                archiveSummaries[id] = record
                try await store.saveArchiveSummary(record)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Explicit backfill also covers an archive confirmed by Codex but not persisted locally.
    func queueMissingArchiveSummaries() async {
        do {
            for chat in state.chats where chat.isArchived && supportsSummaries(chat.id) && archiveSummaries[chat.id] == nil {
                let record = ArchiveSummaryRecord(threadID: chat.id, projectID: chat.projectID)
                try await store.saveArchivingChat(state, summary: record)
                archiveSummaries[chat.id] = record
            }
            startSummaryQueue()
        } catch { self.error = error.localizedDescription }
    }

    func retryArchiveSummary(_ id: String) async {
        guard supportsSummaries(id), isArchived(id), !isChangingChat(id), var record = archiveSummaries[id],
              [.failed, .uncertain, .stale].contains(record.status) else { return }
        record.enqueue()
        do { try await store.saveArchiveSummary(record); archiveSummaries[id] = record; startSummaryQueue() }
        catch { self.error = error.localizedDescription }
    }

    func startSummaryQueue() {
        guard summaryTask == nil,
              archiveSummaries.values.contains(where: { $0.status == .queued && isArchived($0.threadID) && canGenerateSummary($0.threadID) }) else { return }
        summaryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.summaryActiveThread = nil; self.summaryTask = nil }
            while !Task.isCancelled {
                guard let next = self.archiveSummaries.values.filter({ $0.status == .queued && self.isArchived($0.threadID) && self.canGenerateSummary($0.threadID) })
                    .sorted(by: { $0.updatedAt < $1.updatedAt }).first else { return }
                self.summaryActiveThread = next.threadID
                await self.buildArchiveSummary(next)
                self.summaryActiveThread = nil
            }
        }
    }

    private func saveSummaryProgress(_ record: ArchiveSummaryRecord) async throws {
        guard archiveSummaries[record.threadID]?.attempt == record.attempt,
              state.chats.contains(where: { $0.id == record.threadID && $0.isArchived }) else { throw CancellationError() }
        try await store.saveArchiveSummary(record)
        archiveSummaries[record.threadID] = record
    }

    private func markSummaryGenerating(id: String, attempt: UUID) async throws {
        try Task.checkCancellation()
        guard var record = archiveSummaries[id], record.attempt == attempt, isArchived(id) else { throw CancellationError() }
        record.status = .generating
        try await saveSummaryProgress(record)
    }

    private func buildArchiveSummary(_ queued: ArchiveSummaryRecord) async {
        var record = queued
        do {
            guard let chat = state.chats.first(where: { $0.id == record.threadID }) else { return }
            try prepareSummarySkills()
            let recipe = try ArchiveSummaryRecipe(directory: summarySkillsDirectory.appendingPathComponent("archive-summary"))
            let recipeDigest = SummarySource.hash(Data((recipe.digest + L10n.language.rawValue).utf8))
            record.status = .reading; record.issue = nil
            try await saveSummaryProgress(record)
            let source = try await readSummarySource(record.threadID)
            let reuse = record.recipeDigest == recipeDigest
            var matching = 0
            if reuse {
                for (part, chunk) in zip(record.parts, source.chunks) {
                    guard part.sourceDigest == chunk.digest else { break }
                    matching += 1
                }
            }
            record.parts = Array(record.parts.prefix(matching))
            record.sourceDigest = source.digest; record.recipeDigest = recipeDigest
            record.sourceReferences = source.references; record.omittedDetails = source.omittedDetails
            record.sourceTurnDates = source.turnDates
            record.partCount = source.chunks.count
            record.model = generationModel(for: chat)
            record.route = chat.route ?? .direct
            guard routeIsAvailable(record.route), !record.model.isEmpty else {
                throw ClientFailure(L10n.text("Модель или маршрут чата недоступны для подготовки итога", "The chat model or route is unavailable for summarization"))
            }
            try await saveSummaryProgress(record)
            for chunk in source.chunks.dropFirst(matching) {
                try Task.checkCancellation()
                let id = record.threadID, attempt = record.attempt
                let part = try await generationRunner(for: id).summarize(source: sessionForChat(record.threadID), chunk: chunk, model: record.model,
                    route: record.route, environment: generationEnvironment(for: id, workspace: ".summary-workspace", recipe: "archive-summary"),
                    language: L10n.language) { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.markSummaryGenerating(id: id, attempt: attempt)
                    }
                record.parts.append(part); record.status = .reading
                try await saveSummaryProgress(record)
            }
            let latest = try await readSummarySource(record.threadID)
            guard latest.digest == source.digest else {
                record.status = .stale
                record.issue = L10n.text("Переписка изменилась во время подготовки итога", "Conversation changed during summarization")
                try await saveSummaryProgress(record)
                return
            }
            record.status = .ready; record.updatedAt = Date()
            try await saveSummaryProgress(record)
        } catch {
            record.status = (error as? AgentOperationFailure)?.uncertain == true || archiveSummaries[record.threadID]?.status == .generating ? .uncertain : .failed
            // A completed, rejected result has a known outcome and can be explicitly regenerated.
            if let failure = error as? AgentOperationFailure, !failure.uncertain { record.status = .failed }
            record.issue = error.localizedDescription; record.updatedAt = Date()
            do { try await saveSummaryProgress(record) }
            catch {
                // Stop this in-memory attempt even if storage is unavailable; no tight retry loop.
                archiveSummaries[record.threadID] = record
                self.error = L10n.text("Не удалось сохранить состояние итога: ", "Could not save summary state: ") + error.localizedDescription
            }
        }
    }

    private func readSummarySource(_ id: String) async throws -> SummarySource {
        try await clientForChat(id).summarySource(sessionForChat(id))
    }
}
