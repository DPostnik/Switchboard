import AppKit
import ContextCore
import SwiftUI

/// The release identity of the running app: the semantic version from `VERSION` and the commit count
/// that `scripts/build-app.sh` writes into the bundle, plus the build record left next to the binary.
struct AppVersion: Equatable {
    static let repository = "https://github.com/DPostnik/Switchboard"
    static let current = AppVersion(bundle: .main)

    let version: String
    let build: String
    let commit: String?
    let dirty: Bool
    let builtAt: Date?

    init(info: [String: Any], record: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "dev"
        build = (info["CFBundleVersion"] as? String) ?? (info["CFBundleVersion"] as? Int).map(String.init) ?? "0"
        commit = record["commit"] as? String
        dirty = record["dirty"] as? Bool ?? false
        builtAt = (record["builtAt"] as? String).flatMap(AppVersion.date)
    }

    init(bundle: Bundle) {
        var record: [String: Any] = [:]
        if let url = bundle.url(forResource: "build-info", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            record = object
        }
        self.init(info: bundle.infoDictionary ?? [:], record: record)
    }

    /// "1.0.0 (263)"
    var label: String { "\(version) (\(build))" }

    /// One line for bug reports: version, build, commit and build time.
    func report(language: AppLanguage = L10n.language) -> String {
        var parts = ["Switchboard \(label)"]
        if let commit { parts.append(dirty ? "\(commit)+" : commit) }
        if let builtAt { parts.append(AppVersion.formatted(builtAt, language: language)) }
        return parts.joined(separator: ", ")
    }

    static func formatted(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Parses the ISO 8601 stamp of `build-info.json` ("2026-10-31T14:28:20.323830+00:00"); the fraction
    /// may have more digits than Foundation accepts, so it is dropped first.
    static func date(_ stamp: String) -> Date? {
        let trimmed = stamp.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

/// Settings → General → About: version, build and changelog, with a copy button for bug reports.
struct AboutSettings: View {
    var app = AppVersion.current
    @State private var copied = false

    var body: some View {
        Section(L10n.text("О приложении", "About")) {
            LabeledContent(L10n.text("Версия", "Version"), value: app.label)
            if let commit = app.commit {
                LabeledContent(L10n.text("Коммит", "Commit"), value: app.dirty
                               ? L10n.text("\(commit) с незакоммиченными изменениями", "\(commit) with uncommitted changes")
                               : commit)
            }
            if let builtAt = app.builtAt {
                LabeledContent(L10n.text("Собрано", "Built"), value: AppVersion.formatted(builtAt, language: L10n.language))
            }
            HStack {
                Button(L10n.text("История изменений", "Changelog")) {
                    NSWorkspace.shared.open(URL(string: "\(AppVersion.repository)/blob/main/CHANGELOG.md")!)
                }
                Button(copied ? L10n.text("Скопировано", "Copied") : L10n.text("Скопировать версию", "Copy version")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.report(), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
            }
            Text(L10n.text("Версия приложения и номер сборки (число коммитов) также видны в меню Switchboard → О программе.",
                           "The app version and build number (commit count) are also shown in Switchboard → About."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }
}
