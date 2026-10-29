import AppKit
import ContextTranscript
import SwiftUI
import ContextCore

struct ChromeCookieImportView: View {
    let session: AgentSessionReference
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [ChromeCookieProfile] = []
    @State private var selection = ""
    @State private var loading = true
    @State private var importing = false
    @State private var error: String?
    @State private var result: ChromeCookieImportResult?
    @State private var receipt: ChromeCookieImportReceipt?
    @State private var automaticSite = "linkedin.com"
    @State private var automaticPolicy: ChromeSessionImportPolicy?
    @State private var sharedPolicy: ChromeSessionImportPolicy?
    @State private var automaticAnySite = false
    @State private var automaticAllChats = false
    @AppStorage("chromeCookieSourceProfile") private var lastProfile = "Default"
    @AppStorage("parallelBrowserLimit") private var maxBrowsers = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Импортировать только cookies", "Import cookies only")).font(.ui(.title2).bold())
            Text(L10n.text("Cookies сайтов станут доступны выбранному браузеру и агенту этого чата. Если профиль сохранён, они будут доступны и следующим чатам, которым ты передашь этот профиль.",
                           "Website cookies will be available to this chat’s selected browser and agent. If you save the profile, later chats you assign to it will also have access."))
            Text(L10n.text("Обычный Google Chrome можно не закрывать; если он не даст прочитать cookies, заверши его через Cmd+Q и повтори. Если браузер чата открыт, сначала закрой его через меню «Браузер». macOS может запросить доступ к Chrome Safe Storage в Связке ключей.",
                           "Regular Google Chrome can stay open; if it blocks reading cookies, quit it with Cmd+Q and try again. If this chat’s browser is open, close it from the Browser menu first. macOS may request access to Chrome Safe Storage in Keychain."))
                .font(.ui(.callout))
            if loading {
                ProgressView(L10n.text("Поиск профилей…", "Finding profiles…"))
            } else if !profiles.isEmpty {
                Picker(L10n.text("Профиль Chrome", "Chrome profile"), selection: $selection) {
                    ForEach(profiles) { profile in Text("\(profile.name) (\(profile.id))").tag(profile.id) }
                }.disabled(importing)
            }
            Text(L10n.text("Импорт заменит совпадающие cookies. Некоторые сайты потребуют входа заново. Пароли и файлы авторизации Codex / Claude Code не переносятся.",
                           "Import replaces matching cookies. Some sites will require signing in again. Passwords and Codex / Claude Code authentication files are not transferred."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            Text(L10n.text("Эта кнопка переносит только cookies; IndexedDB, аккаунт Chrome и значок профиля не переносятся. Импорт сессии агентом ниже дополнительно переносит localStorage сайта. Проверка cookies не подтверждает вход на сайте.",
                           "This button transfers cookies only; IndexedDB, the Chrome account and profile avatar are not transferred. The agent session import below also transfers the site’s local storage. Cookie verification does not confirm website sign-in."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            Divider()
            Text(L10n.text("Импорт сессии агентом", "Agent session import")).font(.ui(.headline))
            Toggle(L10n.text("Любой сайт", "Any site"), isOn: $automaticAnySite).disabled(importing)
            if !automaticAnySite {
                TextField(L10n.text("Домен сайта, например linkedin.com", "Site domain, for example linkedin.com"), text: $automaticSite)
                    .disabled(importing)
            }
            Toggle(L10n.text("Во всех чатах", "In every chat"), isOn: $automaticAllChats).disabled(importing)
            Text(L10n.text("Разреши агенту переносить сессию сайта из выбранного профиля Chrome при отсутствии входа: cookies и localStorage открытой страницы (там держат токен входа такие сайты, как Discord). Для одного сайта переносятся cookies сайта и его поддоменов; для любого сайта — только cookies, которые Chrome отправил бы открытой странице. localStorage переносится только для origin открытой вкладки. Разрешение для чата действует для этого браузерного профиля, включая чаты, которым он будет передан; разрешение для всех чатов — для каждого браузера чата. Обычный Chrome можно не закрывать.",
                           "Allow the agent to import the site session from the selected Chrome profile when sign-in is missing: cookies and the open page’s local storage (where sites like Discord keep the login token). For one site, cookies of the site and its subdomains are imported; for any site, only the cookies Chrome would send to the open page. Local storage is transferred only for the open tab’s origin. Chat permission applies to this browser profile, including chats it is handed to; every-chat permission applies to each chat browser. Regular Chrome can stay open."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            if let automaticPolicy {
                HStack {
                    Text(L10n.text("Разрешено в этом чате: ", "Enabled in this chat: ") + siteLabel(automaticPolicy) + " · " + automaticPolicy.profile).font(.ui(.callout))
                    Button(L10n.text("Отключить", "Disable")) { saveAutomaticPolicy(enabled: false, shared: false) }.disabled(importing)
                }
            }
            if let sharedPolicy {
                HStack {
                    Text(L10n.text("Разрешено во всех чатах: ", "Enabled in every chat: ") + siteLabel(sharedPolicy) + " · " + sharedPolicy.profile).font(.ui(.callout))
                    Button(L10n.text("Отключить", "Disable")) { saveAutomaticPolicy(enabled: false, shared: true) }.disabled(importing)
                }
            }
            Button(L10n.text("Разрешить импорт агенту", "Enable agent import")) { saveAutomaticPolicy(enabled: true, shared: automaticAllChats) }
                .disabled(importing || loading || selection.isEmpty)
            if let receipt, result == nil {
                Text(L10n.text("Последний импорт: ", "Last import: ") + receipt.date.formatted(date: .abbreviated, time: .shortened) + " · " +
                     L10n.text("Проверено cookies: \(receipt.result.verified). Вход на сайте не проверен.",
                               "Cookies verified: \(receipt.result.verified). Website sign-in has not been checked."))
                    .font(.ui(.callout))
            }
            if let result {
                Text(L10n.text("Проверено cookies: \(result.verified). Пропущено: \(result.skipped). Не подтверждено: \(result.unverified). Открой нужный сайт в браузере чата и проверь вход.",
                               "Cookies verified: \(result.verified). Skipped: \(result.skipped). Unverified: \(result.unverified). Open the site in this chat’s browser to check your sign-in."))
                    .textSelection(.enabled)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L10n.text("Обновить профили", "Refresh profiles")) { loadProfiles() }
                    .disabled(loading || importing)
                Spacer()
                if importing { ProgressView().uiSmallSpinner() }
                Button(L10n.text("Закрыть", "Close")) { dismiss() }.disabled(importing)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Импортировать", "Import")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(importing || loading || selection.isEmpty || result != nil)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(importing)
        .onAppear { loadProfiles() }
    }

    private func loadProfiles() {
        loading = true; error = nil; result = nil
        Task {
            defer { loading = false }
            do {
                profiles = try await Task.detached { try ChromeCookieSource.profiles() }.value
                sharedPolicy = try ChromeSessionImportPolicy.loadShared()
                if let environment = try BrowserEnvironmentStore.existingEnvironment(session: session) {
                    receipt = try ChromeCookieImportReceipt.last(environment: environment)
                    automaticPolicy = try ChromeSessionImportPolicy.load(environment: environment)
                }
                if let current = automaticPolicy ?? sharedPolicy {
                    automaticAnySite = current.coversAnySite
                    automaticAllChats = automaticPolicy == nil
                    if !current.coversAnySite { automaticSite = current.site }
                }
                let preferred = automaticPolicy?.profile ?? sharedPolicy?.profile ?? lastProfile
                selection = profiles.contains(where: { $0.id == preferred }) ? preferred : profiles.first?.id ?? ""
                if profiles.isEmpty { error = L10n.text("Профили обычного Google Chrome не найдены.", "No regular Google Chrome profiles were found.") }
            } catch {
                profiles = []; selection = ""
                self.error = (error as? ChromeCookieError ?? .unavailable).localizedDescription
            }
        }
    }

    private func siteLabel(_ policy: ChromeSessionImportPolicy) -> String {
        policy.coversAnySite ? L10n.text("любой сайт", "any site") : policy.site
    }

    private func saveAutomaticPolicy(enabled: Bool, shared: Bool) {
        error = nil
        do {
            let site = automaticAnySite ? ChromeSessionImportPolicy.anySite : automaticSite
            if shared {
                let policy = enabled ? try ChromeSessionImportPolicy(profile: selection, site: site) : nil
                try ChromeSessionImportPolicy.saveShared(policy)
                sharedPolicy = policy
                return
            }
            guard let root = try BrowserEnvironmentStore.existingEnvironment(session: session) else { throw ChromeCookieError.missingEnvironment }
            let store = BrowserProfileStore(), reference = session
            let grant = try store.current(session: reference) == nil ? nil : store.ownedGrant(session: reference, allowHuman: true)
            let policy = enabled ? try ChromeSessionImportPolicy(profile: selection, site: site) : nil
            try ChromeSessionImportPolicy.save(policy, environment: root, grant: grant)
            automaticPolicy = policy
        } catch {
            self.error = (error as? BrowserProfileError)?.localizedDescription ??
                L10n.text("Не удалось сохранить разрешение. Проверь домен и профиль Chrome; дождись завершения операции браузера.",
                          "Could not save permission. Check the domain and Chrome profile; wait for the browser operation to finish.")
        }
    }

    private func start() {
        guard !importing, !selection.isEmpty else { return }
        importing = true; error = nil; result = nil
        let profile = selection, reference = session, limit = maxBrowsers
        let resources = Bundle.main.resourceURL
        Task {
            defer { importing = false }
            do {
                guard let root = try BrowserEnvironmentStore.existingEnvironment(session: reference), let resources else {
                    throw ChromeCookieError.missingEnvironment
                }
                result = try await Task.detached {
                    let store = BrowserProfileStore()
                    let grant = try store.current(session: reference) == nil ? nil : store.ownedGrant(session: reference, allowHuman: true)
                    return try await ChromeCookieImporter.run(profile: profile, environment: root,
                        runtime: resources.appendingPathComponent("BrowserRuntime"), maxBrowsers: limit, grant: grant,
                        sourceIsRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty })
                }.value
                lastProfile = profile
                onImported()
            } catch {
                self.error = (error as? BrowserProfileError)?.localizedDescription ?? (error as? ChromeCookieError ?? .unavailable).localizedDescription
            }
        }
    }
}
