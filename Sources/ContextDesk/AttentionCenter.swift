import AppKit
import Foundation
import UserNotifications
import ContextCore

@MainActor extension DeskModel {
    var openAttentionCount: Int { attention.items.filter(\.isOpen).count }

    func loadAttention() async {
        do { attention = try await attentionStore.load() }
        catch { self.error = L10n.text("Не удалось открыть важные сообщения: ", "Could not open important messages: ") + error.localizedDescription }
        refreshDockBadge()
    }

    /// Collects explicit blockers and failed outcomes of a finished scheduled run.
    func recordAttention(_ run: JobRun, status: JobRunStatus, output: String) async {
        var text = output
        // App chats keep the final answer in the engine's history; a print-run record already passed it as output.
        if let thread = run.threadID, state.chats.first(where: { $0.id == thread })?.isScheduledRecord != true,
           let answer = await finalAnswer(threadID: thread, turnID: run.turnID) {
            text = answer + "\n" + output
        }
        let source = AttentionSource(jobID: run.jobID, jobName: run.name, runID: run.id, threadID: run.threadID)
        let finished = run.finished ?? Date(), report = text
        do {
            let (ledger, created) = try await attentionStore.update { $0.record(source, status: status, output: report, now: finished) }
            attention = ledger
            created.forEach(postAttentionNotification)
        } catch {
            self.error = L10n.text("Не удалось сохранить важное сообщение: ", "Could not save an important message: ") + error.localizedDescription
        }
        refreshDockBadge()
    }

    private func finalAnswer(threadID: String, turnID: String?) async -> String? {
        guard let turns = try? await clientForChat(threadID).history(sessionForChat(threadID)) else { return nil }
        let turn = turns.last { turnID != nil && $0.id == turnID } ?? turns.last
        return turn?.items.last { $0.kind == "assistant" }?.text
    }

    func openAttention() {
        showingArchive = false; archiveViewingChat = false; showingJobs = false
        showingAttention = true
    }
    func resolveAttention(_ id: UUID) async {
        await changeAttention { $0.resolve(id) }
        removeAttentionNotifications([id])
    }
    func reopenAttention(_ id: UUID) async {
        let reopened = await changeAttention { $0.reopen(id) }
        if reopened == false {
            error = L10n.text("Это сообщение уже снова открыто после нового запуска.", "This message is already open again after a newer run.")
        }
    }
    func clearResolvedAttention() async { await changeAttention { $0.clearResolved() } }

    @discardableResult
    private func changeAttention<T: Sendable>(_ change: @escaping @Sendable (inout AttentionLedger) -> T) async -> T? {
        do {
            let (ledger, result) = try await attentionStore.update(change)
            attention = ledger; refreshDockBadge()
            return result
        } catch {
            self.error = L10n.text("Не удалось сохранить важные сообщения: ", "Could not save important messages: ") + error.localizedDescription
            return nil
        }
    }

    /// One badge for everything waiting on the user: pending approvals plus unresolved important messages.
    func refreshDockBadge() {
        let count = pending.count + openAttentionCount + pullRequests.openAlerts.count
        NSApplication.shared.dockTile.badgeLabel = count == 0 ? nil : String(count)
    }

    private func postAttentionNotification(_ item: AttentionItem) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = item.kind == .blocker
            ? L10n.text("Блокер: \(item.jobName)", "Blocker: \(item.jobName)")
            : L10n.text("Проблема с заданием: \(item.jobName)", "Task problem: \(item.jobName)")
        content.body = item.kind == .blocker ? item.text : [item.text, item.detail].compactMap { $0 }.joined(separator: " — ")
        content.sound = .default
        content.userInfo = ["attentionID": item.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "attention:" + item.id.uuidString, content: content, trigger: nil), withCompletionHandler: nil)
    }
    private func removeAttentionNotifications(_ ids: [UUID]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map { "attention:" + $0.uuidString })
    }
}
