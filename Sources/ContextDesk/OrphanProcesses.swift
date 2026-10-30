import ContextCore
import ContextTranscript
import SwiftUI

/// Drives the shared `ProcessSweeper` for the app: a startup pass over dead instances, a pass every 5 minutes,
/// the Settings counter and button, and the final pass at quit.
@MainActor final class OrphanProcessController: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var checkedAt: Date?
    @Published private(set) var sweeping = false
    private let sweeper: ProcessSweeper
    private var loop: Task<Void, Never>?
    let interval: Duration

    init(sweeper: ProcessSweeper = .shared, interval: Duration = .seconds(300)) {
        self.sweeper = sweeper; self.interval = interval
    }
    func start() {
        guard loop == nil else { return }
        sweeper.start { message in AppLog.processes.notice("\(message, privacy: .public)") }
        loop = Task { [weak self, sweeper, interval] in
            if let task = sweeper.sweepForeignInstances() { _ = await task.value }
            await self?.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.sweepNow()
            }
        }
    }
    /// Read-only count of leftovers alive now.
    func refresh() async {
        let found = await Task.detached(priority: .utility) { [sweeper] in sweeper.orphans().count }.value
        count = found; checkedAt = Date()
    }
    /// The Settings button and the periodic pass.
    func sweepNow() async {
        guard !sweeping else { return }
        sweeping = true; defer { sweeping = false }
        if let task = sweeper.sweepInactive() { _ = await task.value }
        await refresh()
    }
    func shutdown() async {
        loop?.cancel(); loop = nil
        let outcomes = await sweeper.shutdown()
        AppLog.processes.notice("Quit sweep stopped \(outcomes.count, privacy: .public) process(es)")
    }
}

struct OrphanProcessSettings: View {
    @ObservedObject var controller: OrphanProcessController
    var body: some View {
        Section(L10n.text("Процессы чатов", "Chat processes")) {
            LabeledContent(L10n.text("Процессов завершённых чатов", "Processes of finished chats"), value: String(controller.count))
            Button(controller.sweeping ? L10n.text("Завершаем…", "Terminating…") : Self.terminateTitle(controller.count)) {
                Task { await controller.sweepNow() }
            }.disabled(controller.sweeping || controller.count == 0)
            Text(L10n.text(
                "Фоновые команды агента могут пережить завершение чата. Switchboard помечает процессы каждого чата и останавливает оставшиеся при завершении чата, при выходе из приложения и раз в 5 минут. Браузеры Chrome for Testing и выполняющиеся задания не затрагиваются.",
                "Background commands started by an agent can outlive their chat. Switchboard labels each chat's processes and stops the leftovers when the chat ends, when the app quits and every 5 minutes. Chrome for Testing browsers and running scheduled tasks are left alone."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            if let checked = controller.checkedAt {
                Text(L10n.text("Проверено: ", "Checked: ") + checked.formatted(date: .omitted, time: .standard))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
        .task { await controller.refresh() }
    }

    static func terminateTitle(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        let noun = (11...14).contains(tens) ? "процессов" : ones == 1 ? "процесс" : (2...4).contains(ones) ? "процесса" : "процессов"
        return L10n.text("Завершить \(count) \(noun)", count == 1 ? "Terminate 1 process" : "Terminate \(count) processes")
    }
}
