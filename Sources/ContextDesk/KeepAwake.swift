import ContextCore
import ContextTranscript
import SwiftUI
import IOKit.pwr_mgt

/// One process-owned assertion, independent of windows, connections and running chats.
@MainActor final class KeepAwake: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var error: String?
    private(set) var assertionID: IOPMAssertionID?
    private let file: URL

    init(file: URL = Locations.root.appendingPathComponent("keep-awake.json")) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                enabled = try JSONDecoder().decode(Bool.self, from: Data(contentsOf: file))
            }
            if enabled { try acquire() }
        } catch { self.error = Self.failure(error) }
    }

    func setEnabled(_ value: Bool) {
        do {
            // Acquire before saving so failed activation never looks successful.
            if value { try acquire() }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: file, options: .atomic)
            } catch {
                if !enabled { try? release() }
                throw error
            }
            enabled = value
            if !value { try release() }
            error = nil
        } catch { self.error = Self.failure(error) }
    }

    func stop() {
        do { try release() } catch { self.error = Self.failure(error) }
    }

    private func acquire() throws {
        guard assertionID == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            L10n.text("Switchboard: запрет автоматического сна", "Switchboard: prevent automatic sleep") as CFString,
            &id)
        guard result == kIOReturnSuccess else { throw PowerError(code: result) }
        assertionID = id
    }

    private func release() throws {
        guard let id = assertionID else { return }
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else { throw PowerError(code: result) }
        assertionID = nil
    }

    private struct PowerError: Error { let code: IOReturn }
    private static func failure(_ error: Error) -> String {
        let detail = (error as? PowerError).map { String($0.code) } ?? String((error as NSError).code)
        return L10n.text("Не удалось применить настройку сна. Код ошибки: \(detail).", "Could not apply the sleep setting. Error code: \(detail).")
    }

    deinit {
        if let assertionID { IOPMAssertionRelease(assertionID) }
    }
}

struct KeepAwakeSettings: View {
    @ObservedObject var controller: KeepAwake
    var body: some View {
        Section(L10n.text("Сон Mac", "Mac sleep")) {
            Toggle(L10n.text("Не давать Mac засыпать", "Keep Mac awake"),
                   isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
            Text(L10n.text(
                "Пока Switchboard запущен, Mac не засыпает от бездействия, даже если окно закрыто. Настройка сохраняется. Экран может гаснуть; закрытие крышки и ручной сон по-прежнему работают. Расход батареи может увеличиться.",
                "While Switchboard is running, your Mac stays awake when idle, even with the window closed. This setting is saved. The display can sleep; closing the lid and manual sleep still work. Battery use may increase."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            if let error = controller.error {
                Text(error).font(.ui(.caption)).foregroundStyle(DeskPalette.problem)
                Button(L10n.text("Повторить", "Retry")) { controller.setEnabled(controller.enabled) }
            } else if controller.assertionID != nil {
                Text(L10n.text("Защита от автоматического сна активна", "Automatic sleep prevention is active"))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}
