import AppKit
import SwiftUI
import ContextCore

struct UserChromeSetupView: View {
    let enabled: Bool
    @State private var status: UserChromeControl.Status?
    @State private var selectedProfile = ""
    @State private var code = ""
    @State private var diagnosticProfile = ""
    @State private var installationExpanded = false
    @State private var busy = false
    @State private var issue: String?
    @State private var installed = FileManager.default.fileExists(atPath: UserChromeControl.extensionDirectory.appendingPathComponent("manifest.json").path)

    private var connectedProfiles: [UserChromeControl.Profile] { status?.profiles.filter(\.connected) ?? [] }
    private var selectableProfiles: [UserChromeControl.Profile] {
        connectedProfiles.filter { profile in connectedProfiles.filter { name($0) == name(profile) }.count == 1 }
    }
    private var activeProfile: UserChromeControl.Profile? {
        status?.profiles.first { $0.id == status?.selectedProfileId }
    }
    private var candidate: UserChromeControl.Profile? {
        connectedProfiles.first { $0.id == selectedProfile }
    }
    private var ready: Bool { enabled && status?.enabled == true && activeProfile?.paired == true && activeProfile?.connected == true }
    private func name(_ profile: UserChromeControl.Profile) -> String {
        let value = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Chrome" : value
    }
    private var ambiguousName: Bool {
        guard let candidate else { return false }
        return connectedProfiles.filter { name($0) == name(candidate) }.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Мой Chrome", "My Chrome")).font(.ui(.headline))
            if !enabled {
                Label(L10n.text("Доступ к Chrome выключен", "Chrome access is off"), systemImage: "pause.circle")
            } else if ready, let activeProfile {
                Label(L10n.text("Подключён: \(name(activeProfile))", "Connected: \(name(activeProfile))"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L10n.text("Готово. Чтобы агент работал с твоими вкладками и входами, разреши «Мой Chrome» в нужном чате.", "Ready. Allow My Chrome in the chat that needs your tabs and sign-ins."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
            } else {
                connectionSetup
            }
            if ready {
                DisclosureGroup(L10n.text("Подключить другой Chrome", "Connect another Chrome")) {
                    connectionSetup.padding(.top, 8)
                }
            }
            DisclosureGroup(L10n.text("Установка и обслуживание", "Installation and maintenance"), isExpanded: $installationExpanded) {
                installation.padding(.top, 8)
            }
            DisclosureGroup(L10n.text("Технические сведения", "Technical details")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Эти ID принадлежат расширению Switchboard. Они не совпадают с именами профилей в настройках Chrome.", "These IDs belong to the Switchboard extension. They do not match profile names in Chrome settings."))
                    ForEach(status?.profiles ?? []) { profile in
                        Text("\(name(profile)) · \(profile.id) · " + (profile.connected ? L10n.text("на связи", "online") : L10n.text("отключён", "offline")) + (profile.id == status?.selectedProfileId ? L10n.text(" · используется", " · in use") : ""))
                    }
                    if let status, !status.profiles.filter(\.paired).isEmpty {
                        Picker(L10n.text("Сохранённое подключение", "Saved connection"), selection: $diagnosticProfile) {
                            Text(L10n.text("Выбери подключение", "Choose a connection")).tag("")
                            ForEach(status.profiles.filter(\.paired)) { profile in
                                Text("\(name(profile)) · \(profile.id)").tag(profile.id)
                            }
                        }
                        Button(L10n.text("Использовать сохранённое подключение", "Use saved connection")) {
                            let id = diagnosticProfile
                            perform { try await UserChromeControl.shared.selectProfile(id); try await refresh() }
                        }.disabled(busy || !enabled || !status.profiles.contains(where: { $0.id == diagnosticProfile && $0.paired }))
                    }
                }.font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
            }
            if busy { ProgressView().controlSize(.small) }
            if let issue { Text(issue).font(.ui(.caption)).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task(id: enabled) {
            guard installed else { return }
            do { try await refresh() } catch { issue = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard installed, !busy else { return }
            perform { try await refresh() }
        }
    }

    @ViewBuilder private var connectionSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !installed {
                Text(L10n.text("Сначала установи расширение Switchboard в обычный Chrome.", "First, install the Switchboard extension in regular Chrome."))
                Button(L10n.text("Подготовить расширение", "Prepare extension")) { install() }
            } else if connectedProfiles.isEmpty {
                Label(L10n.text("Chrome не подключён", "Chrome is not connected"), systemImage: "exclamationmark.circle")
                Text(L10n.text("Открой нужное окно Chrome и нажми значок расширения Switchboard. Затем проверь соединение здесь.", "Open the Chrome window you want to use and click the Switchboard extension icon. Then check the connection here."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
            } else {
                if connectedProfiles.count > 1 {
                    if !selectableProfiles.isEmpty {
                        Picker(L10n.text("Какой Chrome использовать", "Which Chrome to use"), selection: $selectedProfile) {
                            Text(L10n.text("Выбери по имени в расширении", "Choose the name shown in the extension")).tag("")
                            ForEach(selectableProfiles) { profile in Text(name(profile)).tag(profile.id) }
                        }
                    }
                    Text(L10n.text("Имена задаются в расширении Switchboard. Если они одинаковые, дай нужному Chrome своё имя в расширении и нажми «Проверить соединение».", "Names are set in the Switchboard extension. If they match, give the Chrome you want a distinct name in the extension, then click Check connection."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                } else if let candidate {
                    Text(L10n.text("Найден: \(name(candidate))", "Found: \(name(candidate))"))
                }
                if let candidate {
                    if !candidate.paired {
                        Text(L10n.text("Введи код, который показывает расширение Switchboard в этом Chrome.", "Enter the code shown by the Switchboard extension in this Chrome."))
                            .font(.ui(.callout)).foregroundStyle(.secondary)
                        TextField(L10n.text("Код из расширения", "Code from extension"), text: $code).frame(maxWidth: 220)
                    }
                    Button(L10n.text("Подключить этот Chrome", "Connect this Chrome")) {
                        let id = candidate.id, pairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                        perform {
                            if candidate.paired { try await UserChromeControl.shared.selectProfile(id) }
                            else { try await UserChromeControl.shared.pair(profile: id, code: pairingCode) }
                            code = ""
                            try await refresh()
                        }
                    }.disabled(busy || !enabled || ambiguousName || (!candidate.paired && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            if installed {
                Button(L10n.text("Проверить соединение", "Check connection")) { perform { try await refresh() } }
            }
        }.disabled(busy)
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(installed ? L10n.text("Обновить расширение", "Update extension") : L10n.text("Подготовить расширение", "Prepare extension")) { install() }
                Button(L10n.text("Открыть папку расширения", "Open extension folder")) { NSWorkspace.shared.open(UserChromeControl.extensionDirectory) }
                    .disabled(!installed)
                Button(L10n.text("Проверить соединение", "Check connection")) { perform { try await refresh() } }.disabled(!installed)
            }.disabled(busy)
            Text(L10n.text("1. Подготовь или обнови расширение кнопкой выше и оставь открывшуюся папку.\n2. В нужном Chrome открой chrome://extensions и включи режим разработчика.\n3. Нажми «Загрузить распакованное расширение» и выбери эту папку.\n4. Открой значок Switchboard в Chrome, затем проверь соединение здесь.", "1. Prepare or update the extension with the button above and keep the opened folder.\n2. In the Chrome you want to use, open chrome://extensions and enable Developer mode.\n3. Click Load unpacked and select that folder.\n4. Open the Switchboard icon in Chrome, then check the connection here."))
                .font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(L10n.text("После обновления файлов нажми «Обновить» у расширения на chrome://extensions.", "After updating the files, click Reload for the extension at chrome://extensions."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }

    private func refresh() async throws {
        let fresh = try await UserChromeControl.shared.status()
        status = fresh
        if !fresh.profiles.contains(where: { $0.id == diagnosticProfile && $0.paired }) {
            diagnosticProfile = fresh.selectedProfileId ?? ""
        }
        let connected = fresh.profiles.filter(\.connected)
        // Choose a local form value only; authority changes require the Connect button.
        if connected.count == 1 { selectedProfile = connected[0].id }
        else if !selectableProfiles.contains(where: { $0.id == selectedProfile }) { selectedProfile = "" }
    }
    private func install() {
        perform {
            guard let resources = Bundle.main.resourceURL else { return }
            try await UserChromeControl.shared.install(resources: resources)
            installed = true
            installationExpanded = true
            try await UserChromeControl.shared.setEnabled(enabled)
            try await refresh()
            NSWorkspace.shared.open(UserChromeControl.extensionDirectory)
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; issue = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { issue = error.localizedDescription }
        }
    }
}
