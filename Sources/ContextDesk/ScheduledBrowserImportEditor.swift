import ContextTranscript
import SwiftUI
import ContextCore

struct ScheduledBrowserImportEditor: View {
    @Binding var policy: ChromeSessionImportPolicy?
    @State private var profiles: [ChromeCookieProfile] = []
    @State private var selection = "Default"
    @State private var site = "linkedin.com"
    @State private var anySite = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Автоматическое восстановление входа", "Automatic sign-in recovery")).font(.ui(.headline))
            Text(L10n.text("Разрешение сохраняется у задания и применяется к каждому новому запуску. Агент сам импортирует cookies при отсутствии входа. Обычный Chrome можно не закрывать; Связка ключей может потребовать подтверждения.",
                           "Permission is saved with the task and applied to every new run. The agent imports cookies when sign-in is missing. Regular Chrome can stay open; Keychain may require confirmation."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            Picker(L10n.text("Профиль Chrome", "Chrome profile"), selection: $selection) {
                ForEach(profiles) { Text($0.name + " (" + $0.id + ")").tag($0.id) }
            }
            Toggle(L10n.text("Любой сайт", "Any site"), isOn: $anySite)
            if !anySite { TextField(L10n.text("Домен сайта", "Site domain"), text: $site) }
            HStack {
                Button(L10n.text("Разрешить для всех запусков", "Allow for every run")) {
                    do { policy = try ChromeSessionImportPolicy(profile: selection, site: anySite ? ChromeSessionImportPolicy.anySite : site); error = nil }
                    catch { self.error = L10n.text("Проверь домен сайта и профиль Chrome.", "Check the site domain and Chrome profile.") }
                }.disabled(profiles.isEmpty)
                Button(L10n.text("Отключить", "Disable")) { policy = nil }.disabled(policy == nil)
            }
            if let policy {
                Text(L10n.text("Разрешено после сохранения задания: ", "Allowed when the task is saved: ") + (policy.coversAnySite ? L10n.text("любой сайт", "any site") : policy.site) + " · " + policy.profile).font(.ui(.caption))
            }
            if let error { Text(error).font(.ui(.caption)).foregroundStyle(DeskPalette.problem) }
        }.task {
            if let policy {
                anySite = policy.coversAnySite
                if !policy.coversAnySite { site = policy.site }
                selection = policy.profile
            }
            do {
                profiles = try await Task.detached { try ChromeCookieSource.profiles() }.value
                if !profiles.contains(where: { $0.id == selection }) { selection = profiles.first?.id ?? "" }
            } catch {
                self.error = L10n.text("Не удалось прочитать список профилей Chrome.", "Could not read the Chrome profile list.")
            }
        }
    }
}
