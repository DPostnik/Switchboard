import AppKit
import ContextCore
import UserNotifications

/// `Switchboard --nightly-tests-report <failed|flaky> <summary>`, called by scripts/nightly-tests.sh.
/// The running app posts the notification (a bare CLI process has no notification permission), so a click
/// opens the run's log instead of Script Editor. The click opens only the fixed log path below; nothing in
/// the request selects a file. Same-login-session channel, like the restart request.
enum NightlyTestsReport {
    static let notification = Notification.Name("local.daniil.switchboard.nightly-tests-report.v1")
    static let userInfoKey = "nightlyTestsLog"
    static let identifier = "nightly-tests"
    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Switchboard/nightly-tests/latest.log")
    }

    static func content(result: String, summary: String) -> UNMutableNotificationContent? {
        let content = UNMutableNotificationContent()
        switch result {
        case "failed": content.title = L10n.text("Ночные тесты Switchboard не прошли", "Switchboard nightly tests failed")
        case "flaky": content.title = L10n.text("Ночные тесты Switchboard: нестабильные тесты", "Switchboard nightly tests: flaky tests")
        default: return nil
        }
        content.subtitle = L10n.text("Нажми, чтобы открыть лог", "Click to open the log")
        content.body = String(summary.prefix(300))
        content.userInfo = [userInfoKey: true]
        return content
    }

    /// Exits non-zero when no instance of this bundle runs, so the script can fall back to osascript.
    /// Delivery to the running instance is not acknowledged.
    @MainActor static func run(arguments: [String]) -> Bool {
        guard arguments.dropFirst().first == "--nightly-tests-report" else { return false }
        guard arguments.count == 4, content(result: arguments[2], summary: arguments[3]) != nil else {
            fputs("usage: Switchboard --nightly-tests-report <failed|flaky> <summary>\n", stderr)
            exit(2)
        }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app", NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.standardizedFileURL == bundle
        }) else {
            fputs(L10n.text("Работающий экземпляр этого приложения не найден.\n", "No running instance of this app bundle was found.\n"), stderr)
            exit(1)
        }
        DistributedNotificationCenter.default().postNotificationName(notification, object: bundle.path,
            userInfo: ["result": arguments[2], "summary": String(arguments[3].prefix(300))], deliverImmediately: true)
        return true
    }

    /// Observes requests in the running app; the returned token keeps the observer alive.
    @MainActor static func observe() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: notification,
            object: Bundle.main.bundleURL.standardizedFileURL.path, queue: .main) { request in
            guard let result = request.userInfo?["result"] as? String, let summary = request.userInfo?["summary"] as? String,
                  let content = content(result: result, summary: summary) else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if let error { AppLog.lifecycle.error("Nightly tests notification not shown: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    static func isReport(_ userInfo: [AnyHashable: Any]) -> Bool { userInfo[userInfoKey] != nil }

    @MainActor static func openLog() {
        guard FileManager.default.fileExists(atPath: log.path) else { return }
        NSWorkspace.shared.open(log)
    }
}
