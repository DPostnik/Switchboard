import AppKit
import SwiftUI
import ContextCore

struct UserChromeSetupView: View {
    let enabled: Bool
    @State private var status: UserChromeControl.Status?
    @State private var code = ""
    @State private var candidate: UserChromeControl.Profile?
    @State private var busy = false
    @State private var refreshing = false
    @State private var issue: String?
    @State private var connectionIssue: String?
    @State private var notice: String?
    @State private var installed = FileManager.default.fileExists(atPath: UserChromeControl.extensionDirectory.appendingPathComponent("manifest.json").path)
    @State private var currentComponents = false

    private var profiles: [UserChromeControl.Profile] { status?.profiles ?? [] }
    private var pairingCode: String { code.filter { $0.isASCII && $0.isNumber } }
    private func name(_ profile: UserChromeControl.Profile) -> String {
        let value = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Chrome" : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Твои вкладки и входы на сайты в обычном Chrome. Доступ разрешается отдельно для каждого чата.",
                           "Your tabs and website sign-ins in regular Chrome. Access is allowed separately for each chat."))
                .font(.ui(.callout)).foregroundStyle(.secondary)
            if !enabled {
                Label(L10n.text("Включи доступ к Chrome переключателем выше, чтобы настроить подключение.",
                                "Turn on Chrome access above to set up a connection."), systemImage: "pause.circle")
            } else if !installed {
                installation
            } else {
                if !currentComponents {
                    Label(L10n.text("Нужно обновить компоненты подключения", "Connection components need an update"), systemImage: "arrow.down.circle")
                    Text(L10n.text("Обнови файлы здесь, затем нажми значок перезагрузки у Switchboard на chrome://extensions в нужном профиле Chrome.",
                                   "Update the files here, then click Reload for Switchboard at chrome://extensions in the Chrome profile you want."))
                        .font(.ui(.callout)).foregroundStyle(.secondary)
                    Button(L10n.text("Обновить компоненты", "Update components")) { install() }.disabled(busy)
                }
                profileList
                connectionSetup
            }
            if busy { ProgressView().controlSize(.small) }
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.ui(.callout))
            }
            if let connectionIssue {
                Text(connectionIssue).font(.ui(.callout)).foregroundStyle(.red).textSelection(.enabled)
            }
            if let issue {
                Text(issue).font(.ui(.callout)).foregroundStyle(.red).textSelection(.enabled)
            }
            if installed {
                DisclosureGroup(L10n.text("Установка и обновление расширения", "Extension installation and updates")) {
                    installation.padding(.top, 8)
                }
                DisclosureGroup(L10n.text("Диагностика", "Diagnostics")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(profiles) { profile in
                            Text("\(name(profile)) · \(profile.id)")
                        }
                        Button(L10n.text("Проверить снова", "Check again")) { perform { try await refresh() } }
                            .disabled(busy || refreshing)
                    }.font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: enabled) {
            checkComponents()
            while !Task.isCancelled {
                if enabled, installed, !busy {
                    do { try await refresh() } catch {
                        if !Task.isCancelled { connectionIssue = error.localizedDescription }
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .onChange(of: code) { _, _ in candidate = nil; issue = nil }
    }

    @ViewBuilder private var profileList: some View {
        let saved = profiles.filter(\.paired)
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Подключённые профили", "Connected profiles")).font(.ui(.headline))
                ForEach(saved) { profile in
                    HStack(spacing: 12) {
                        Image(systemName: profile.connected ? "checkmark.circle.fill" : "moon.circle")
                            .foregroundStyle(profile.connected ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name(profile)).font(.ui(.callout).weight(.semibold))
                            if saved.filter({ name($0) == name(profile) }).count > 1 {
                                Text("ID: " + String(profile.id.suffix(8)))
                                    .font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                            Text(profile.connected
                                 ? L10n.text("Chrome на связи", "Chrome is online")
                                 : L10n.text("Открой этот профиль Chrome и расширение Switchboard.", "Open this Chrome profile and the Switchboard extension."))
                                .font(.ui(.caption)).foregroundStyle(.secondary)
                            if status?.selectedProfileId == profile.id {
                                Text(L10n.text("Выбран для новых подключений чатов", "Selected for new chat connections"))
                                    .font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if status?.selectedProfileId != profile.id {
                            Button(L10n.text("Использовать", "Use")) {
                                perform {
                                    try await UserChromeControl.shared.selectProfile(profile.id)
                                    notice = L10n.text("Выбран профиль \(name(profile)).", "Selected profile \(name(profile)).")
                                    try await refresh()
                                }
                            }.disabled(busy || !profile.connected)
                        }
                    }
                }
                Text(L10n.text("Следующий шаг: в меню роли нужного чата включи «Мой Chrome». Настройка профиля сама по себе не даёт чату доступ.",
                               "Next: turn on My Chrome in the chat’s role menu. Setting up a profile alone does not give a chat access."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(profiles.contains(where: \.paired)
                 ? L10n.text("Подключить ещё профиль", "Connect another profile")
                 : L10n.text("Подключить мой Chrome", "Connect my Chrome")).font(.ui(.headline))
            Text(L10n.text("Открой расширение Switchboard в нужном окне Chrome. Скопируй показанный код и вставь его сюда.",
                           "Open the Switchboard extension in the Chrome window you want. Copy the code it shows and paste it here."))
                .font(.ui(.callout)).foregroundStyle(.secondary)
            Text(L10n.text("Код из расширения", "Code from the extension"))
                .font(.ui(.callout).weight(.medium))
            TextField("", text: $code, prompt: Text("000000"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 22, weight: .medium, design: .monospaced))
                    .controlSize(.large)
                    .frame(maxWidth: .ui(320), minHeight: .ui(40))
                    .accessibilityLabel(L10n.text("Код подключения Chrome", "Chrome connection code"))
                    .onSubmit { findProfile() }
                    .disabled(busy || !currentComponents)
            Button(L10n.text("Найти Chrome", "Find Chrome")) { findProfile() }
                    .disabled(pairingCode.count != 6 || busy || !currentComponents)
            if let candidate {
                Label(L10n.text("Найден профиль: \(name(candidate))", "Profile found: \(name(candidate))"), systemImage: "person.crop.circle")
                Button(L10n.text("Подключить этот профиль", "Connect this profile")) {
                    let id = candidate.id, confirmedCode = pairingCode
                    perform {
                        try await UserChromeControl.shared.pair(profile: id, code: confirmedCode)
                        code = ""
                        self.candidate = nil
                        try await refresh()
                        notice = L10n.text("Профиль подключён. Теперь разреши «Мой Chrome» в нужном чате.",
                                           "Profile connected. Now allow My Chrome in the chat that needs it.")
                    }
                }.buttonStyle(.borderedProminent).disabled(busy || !currentComponents)
            }
            if profiles.contains(where: \.paired) {
                Text(L10n.text("Уже подключённый профиль выбирается в списке выше. Повторный код не нужен.",
                               "Choose an already connected profile from the list above. No new code is needed."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Text(L10n.text("Состояние обновляется автоматически.", "Connection status updates automatically."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Установи расширение в тот профиль Chrome, которым хочешь пользоваться.",
                           "Install the extension in the Chrome profile you want to use."))
                .font(.ui(.callout))
            Button(installed ? L10n.text("Обновить файлы расширения", "Update extension files")
                             : L10n.text("Подготовить расширение", "Prepare extension")) { install() }.disabled(busy)
            Text(L10n.text("1. Нажми кнопку выше — откроется папка расширения.\n2. В Chrome открой chrome://extensions и включи режим разработчика.\n3. Нажми «Загрузить распакованное расширение» и выбери эту папку.\n4. Открой расширение Switchboard и скопируй код. Поле для него появится здесь автоматически.",
                           "1. Click the button above to open the extension folder.\n2. In Chrome, open chrome://extensions and turn on Developer mode.\n3. Click Load unpacked and choose that folder.\n4. Open the Switchboard extension and copy its code. The code field will appear here automatically."))
                .font(.ui(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
            if installed {
                Text(L10n.text("Если расширение уже установлено: после обновления файлов нажми значок перезагрузки у Switchboard на chrome://extensions.",
                               "If the extension is already installed: after updating its files, click Reload for Switchboard at chrome://extensions."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                Button(L10n.text("Открыть папку расширения", "Open extension folder")) {
                    NSWorkspace.shared.open(UserChromeControl.extensionDirectory)
                }
            }
        }
    }

    private func findProfile() {
        guard !busy, currentComponents, pairingCode.count == 6 else { return }
        let submitted = pairingCode
        candidate = nil
        perform {
            let found = try await UserChromeControl.shared.resolvePairingCode(submitted)
            guard submitted == pairingCode else { return }
            candidate = found
        }
    }
    private func refresh() async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        status = try await UserChromeControl.shared.status()
        connectionIssue = nil
    }
    private func checkComponents() {
        guard let resources = Bundle.main.resourceURL else { return }
        currentComponents = [
            ("UserChromeRuntime/server.py", "runtime/server.py"),
            ("UserChromeExtension/popup.js", "extension/popup.js")
        ].allSatisfy { source, target in
            let bundled = try? Data(contentsOf: resources.appendingPathComponent(source))
            let deployed = try? Data(contentsOf: UserChromeControl.directory.appendingPathComponent(target))
            return bundled != nil && bundled == deployed
        }
    }
    private func install() {
        perform {
            guard let resources = Bundle.main.resourceURL else { return }
            try await UserChromeControl.shared.install(resources: resources)
            installed = true
            checkComponents()
            try await UserChromeControl.shared.setEnabled(enabled)
            try await refresh()
            NSWorkspace.shared.open(UserChromeControl.extensionDirectory)
            notice = L10n.text("Файлы готовы. Загрузи или перезагрузи расширение в Chrome.",
                               "Files are ready. Load or reload the extension in Chrome.")
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; issue = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { issue = error.localizedDescription }
        }
    }
}
