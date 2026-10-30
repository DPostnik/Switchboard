import AppKit
import ContextCore
import SwiftUI

@main enum AppEntry {
    @MainActor static func main() async {
        if RestartCommand.run(arguments: CommandLine.arguments) { return }
        if await ChromeSessionImportCommand.run(arguments: CommandLine.arguments) { return }
        if await ChromeIndexedDBImportCommand.run(arguments: CommandLine.arguments) { return }
        if NightlyTestsReport.run(arguments: CommandLine.arguments) { return }
        guard LaunchMigration.run() else { return }
        ContextDeskApp.main()
    }
}

/// One-time moves from the pre-rename app (Context Desk → Switchboard, 2026-10-17). Runs before anything
/// reads the data folder or preferences; helper commands above never move data under a running app.
@MainActor enum LaunchMigration {
    static func run() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        if bundleID != LegacyPreferencesMigration.legacyDomain,
           !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyPreferencesMigration.legacyDomain).isEmpty {
            return stop(L10n.text("Сначала закрой старую версию приложения (Context Desk) через Cmd+Q, затем открой Switchboard снова.",
                                  "Quit the old version of the app (Context Desk) with Cmd+Q first, then open Switchboard again."))
        }
        if LegacyPreferencesMigration.run(domain: bundleID) {
            AppLog.lifecycle.info("Preferences copied from \(LegacyPreferencesMigration.legacyDomain, privacy: .public)")
        }
        switch LegacyDataMigration.run(legacy: Locations.legacyRoot, current: Locations.root) {
        case .none: return true
        case .moved:
            AppLog.lifecycle.info("Data folder moved to \(Locations.root.path, privacy: .public)")
            return true
        case .conflict:
            return stop(L10n.text("Найдены две папки данных: «\(Locations.legacyRoot.path)» и «\(Locations.root.path)». Ничего не перемещено и не объединено. Оставь одну из них и открой приложение снова.",
                                  "Two data folders were found: “\(Locations.legacyRoot.path)” and “\(Locations.root.path)”. Nothing was moved or merged. Keep one of them and open the app again."))
        case .failed(let reason):
            return stop(L10n.text("Не удалось перенести папку данных в «\(Locations.root.path)»: \(reason)",
                                  "Could not move the data folder to “\(Locations.root.path)”: \(reason)"))
        }
    }

    private static func stop(_ message: String) -> Bool {
        AppLog.lifecycle.error("Launch migration stopped: \(message, privacy: .public)")
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = L10n.text("Switchboard не запущен", "Switchboard did not start")
        alert.informativeText = message
        alert.runModal()
        return false
    }
}
