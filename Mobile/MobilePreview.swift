import SwiftUI
import Foundation

// Simulator-only fixtures for visual checks and UI tests; no cloud or agent access.
// Launch arguments: -mobile-preview (required), -preview-chat, -preview-long, -preview-rich,
// -preview-actions, -preview-settings, -preview-read-only, -preview-project-list, -preview-offline,
// -preview-file <path>, -preview-groups (running, approval and read-only chats in a second project),
// -preview-unconfirmed (an unconfirmed send in the first chat and an undelivered new chat),
// -preview-question (a working first chat asks a question with options and "Other", then a form waits),
// -preview-form-maconly (a form with a secret field: Mac-only, Decline only),
// -preview-queue (a working first chat with three of five queued messages; add -preview-queue-paused for a paused queue),
// -preview-roles (roles and add-ons in chat and project settings: Developer with mail and My Chrome on, My Chrome beyond the default).
// Every flag that sends commands acknowledges them through `MobilePreviewTransport`; nothing reaches a cloud.
#if targetEnvironment(simulator)
extension MobileModel {
    func loadPreview() {
        var project = RemoteProject(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Switchboard", canCreateChat: true)
        project.models = [RemoteModelOption(id: "fixture-a", name: "Model A"), RemoteModelOption(id: "fixture-b", name: "Model B")]
        project.newChatModels = [RemoteModelOption(id: "fixture-a", name: "Model A", agent: RemoteModelOption.codexAgent),
                                 RemoteModelOption(id: "fixture-b", name: "Model B", agent: RemoteModelOption.codexAgent),
                                 RemoteModelOption(id: "fixture-claude", name: "Claude Model", agent: RemoteModelOption.claudeAgent)]
        project.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: true)
        project.canReadFiles = true
        let arguments = ProcessInfo.processInfo.arguments
        let roles = [RemoteRoleOption(id: "reader", name: L10n.text("Читатель", "Reader")), RemoteRoleOption(id: "editor", name: L10n.text("Редактор", "Editor")),
                     RemoteRoleOption(id: "developer", name: L10n.text("Разработчик", "Developer"))]
        let mail = RemoteAddOnOption(id: "mail", name: L10n.text("Почта и коннекторы", "Mail and connectors"),
                                     summary: L10n.text("Gmail, Календарь и другие коннекторы: чтение без вопросов, отправка и изменения с подтверждением.", "Gmail, Calendar and other connectors: reads without prompts, sends and changes ask first."), symbol: "envelope")
        let chrome = RemoteAddOnOption(id: "userChrome", name: L10n.text("Мой Chrome", "My Chrome"),
                                       summary: L10n.text("Агент может работать в вашем Chrome, где вы уже вошли на сайты.", "The agent can work in your Chrome, where you are already signed in to sites."), symbol: "globe")
        if arguments.contains("-preview-roles") {
            project.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: true,
                                                  projectRole: "developer", roles: roles, addOns: [mail], projectAddOns: ["mail"])
        }
        var chat = RemoteChat(id: "preview-chat", project: project.id, title: L10n.text("Мобильное приложение", "Mobile app"), running: false,
            messages: [RemoteMessage(id: "m1", role: "user", text: L10n.text("Сделаем удобный интерфейс для iPhone. Поле ввода должно быть всегда под рукой.", "Let's make the iPhone interface comfortable. Keep the message field within reach.")),
                       RemoteMessage(id: "m2", role: "assistant", text: L10n.text("Готово. Теперь переписка занимает весь экран, а поле ввода закреплено внизу.\n\n**Что изменилось**\n• Поиск по чатам\n• Превью последних сообщений\n• Кнопка скрытия клавиатуры\n\nПосле отправки клавиатура закрывается автоматически.", "Done. The conversation now fills the screen, with the composer pinned at the bottom.\n\n**What's new**\n• Chat search\n• Latest message previews\n• A button to hide the keyboard\n\nThe keyboard closes automatically after sending."))], approvals: [])
        if ProcessInfo.processInfo.arguments.contains("-preview-long") {
            chat.messages = (0..<20).map { index in
                RemoteMessage(id: "long-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: "Message \(index)\n" + String(repeating: "Long transcript layout verification. ", count: index.isMultiple(of: 3) ? 70 : 10))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-preview-rich") {
            let answer = L10n.text("## Итог проверки\n\nСборка прошла, осталось **два** шага. Подробности — https://developer.apple.com/documentation/swiftui/grid и в `Sources/ContextCore/MobileRemote.swift`.\n\n- [x] Тесты ядра\n- [ ] Проверка на телефоне\n  - снимок экрана\n\n> [!WARNING]\n> Профиль подписи истекает 12.10.\n\n```swift\nlet limit = 2000 // phone history\nfunc clip(_ text: String) -> String { String(text.prefix(limit)) }\n```\n\n```bash\n$ zsh scripts/build-mobile.sh\nBUILD SUCCEEDED\n```\n\n| Проверка | Время, с |\n|---|---|\n| Ядро | 12 |\n| UI | 184 |",
                                   "## Check summary\n\nThe build passed, **two** steps remain. Details: https://developer.apple.com/documentation/swiftui/grid and `Sources/ContextCore/MobileRemote.swift`.\n\n- [x] Core tests\n- [ ] Phone check\n  - screenshot\n\n> [!WARNING]\n> The signing profile expires on Oct 12.\n\n```swift\nlet limit = 2000 // phone history\nfunc clip(_ text: String) -> String { String(text.prefix(limit)) }\n```\n\n```bash\n$ zsh scripts/build-mobile.sh\nBUILD SUCCEEDED\n```\n\n| Check | Time, s |\n|---|---|\n| Core | 12 |\n| UI | 184 |")
            var long = RemoteMessage(id: "rich-cut", role: "assistant", fullText: String(repeating: L10n.text("Длинный ответ. ", "Long answer. "), count: 160))
            long.text = String(long.text.prefix(120))
            chat.messages = [RemoteMessage(id: "rich-user", role: "user", text: L10n.text("Как прошла проверка?", "How did the check go?")),
                             RemoteMessage(id: "rich", role: "assistant", text: answer), long]
            chat.running = true
            chat.activity = "Bash · zsh scripts/test.sh --changed"
            chat.runningSince = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-75))
        }
        var projects = [project]
        if ["-preview-actions", "-preview-question", "-preview-form-maconly", "-preview-queue", "-preview-roles"].contains(where: arguments.contains) {
            receiptStorage = RemoteSessionStorage(read: { _ in nil }, write: { _, _ in })
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MobilePreviewTransport.self]
            api = try? RemoteAPI(url: "https://preview.invalid", key: "sb_publishable_fixture", transport: URLSession(configuration: configuration),
                storage: RemoteSessionStorage(read: { _ in Data(#"{"access_token":"fixture","refresh_token":"fixture","expires_at":4102444800,"user":{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd"}}"#.utf8) }, write: { _, _ in }))
        }
        if arguments.contains("-preview-actions") {
            chat.approvals = [RemoteApproval(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", details: "echo permission-fixture", canAllow: true)]
            var empty = project; empty.id = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"; empty.name = L10n.text("Пустой проект", "Empty project")
            projects.append(empty)
            if ProcessInfo.processInfo.arguments.contains("-preview-settings") { chat.approvals = [] }
        }
        if arguments.contains("-preview-question") || arguments.contains("-preview-queue") || arguments.contains("-preview-form-maconly") {
            chat.running = true; chat.turn = "preview-turn"
            chat.activity = "Bash · zsh scripts/build-mobile.sh"
            chat.runningSince = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-128))
        }
        if arguments.contains("-preview-question") {
            chat.interactions = [
                RemoteInteraction(id: "11111111-1111-1111-1111-111111111111", kind: .questions, questions: [
                    RemoteQuestion(id: "database", header: L10n.text("База данных", "Database"), text: L10n.text("Какую базу данных использовать для сайта?", "Which database should the site use?"), options: [
                        RemoteQuestionOption(label: "PostgreSQL", description: L10n.text("Серверная база, подходит для многих пользователей", "A server database, best for many users"), preview: "DATABASE_URL=postgres://localhost/site_dev"),
                        RemoteQuestionOption(label: "SQLite", description: L10n.text("Один файл рядом с приложением", "A single file next to the app"))
                    ], allowsOther: true, required: true)
                ], canAnswer: true, canDecline: false),
                RemoteInteraction(id: "22222222-2222-2222-2222-222222222222", kind: .form, message: L10n.text("Инструмент выпуска просит данные для черновика.", "The release tool needs details for the draft."), questions: [
                    RemoteQuestion(id: "branch", text: L10n.text("Ветка", "Branch"), options: [], required: true),
                    RemoteQuestion(id: "notes", text: L10n.text("Заметки", "Notes"), options: [], required: false)
                ], canAnswer: true, canDecline: true)
            ]
        }
        if arguments.contains("-preview-form-maconly") {
            chat.interactions = [RemoteInteraction(id: "33333333-3333-3333-3333-333333333333", kind: .form,
                message: L10n.text("Войди в сервис публикации, чтобы продолжить.", "Sign in to the deployment service to continue."),
                questions: [RemoteQuestion(id: "token", text: L10n.text("API-токен", "API token"), options: [], secret: true, required: true)],
                canAnswer: false, canDecline: true, macOnly: .secret)]
        }
        if arguments.contains("-preview-queue") {
            chat.canQueue = true; chat.canInterrupt = !arguments.contains("-preview-queue-paused")
            chat.queue = [RemoteQueuedMessage(id: "queue-1", text: L10n.text("Потом обнови README.", "Then update the README."), claimed: true),
                          RemoteQueuedMessage(id: "queue-2", text: L10n.text("И прогони UI-тесты на симуляторе, пожалуйста, оба языка.", "And run the UI tests on the simulator, both languages please."), command: "44444444-4444-4444-4444-444444444444"),
                          RemoteQueuedMessage(id: "queue-3", text: L10n.text("Скриншоты положи в .build/mobile-shots.", "Put the screenshots in .build/mobile-shots."))]
            chat.queueCount = 5
            if arguments.contains("-preview-queue-paused") { chat.queuePaused = true }
        }
        chat.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: chat.approvals.isEmpty && (chat.interactions ?? []).isEmpty)
        if arguments.contains("-preview-roles") {
            // My Chrome was turned on at the Mac beyond the project default, which grants only mail.
            chat.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a", addOns: ["mail", "userChrome"]), projectAccess: .standard, canEdit: true,
                                               projectRole: "developer", roles: roles, addOns: [mail, chrome], projectAddOns: ["mail"])
        }
        if ProcessInfo.processInfo.arguments.contains("-preview-read-only") { chat.readOnly = true; chat.supportsPhotos = false; chat.settings = nil }
        var chats = [chat]
        if ProcessInfo.processInfo.arguments.contains("-preview-project-list") {
            var second = project; second.id = "second-project"; second.name = "Second project"
            var empty = project; empty.id = "empty-project"; empty.name = "Empty project"
            projects = [project, second, empty]
            chats = [project, second].flatMap { item in
                (1...12).map { index in
                    RemoteChat(id: item.id + "-\(index)", project: item.id, title: "\(item.name) chat \(index)", running: index % 4 == 1,
                        messages: [RemoteMessage(id: "list-message", role: "assistant", text: "Live preview \(index)")],
                        approvals: index == 12 ? [RemoteApproval(id: "list-approval", details: "Fixture", canAllow: true)] : [])
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-preview-groups") {
            var site = project; site.id = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"; site.name = L10n.text("Сайт", "Website")
            projects.append(site)
            var release = RemoteChat(id: "preview-running", project: site.id, title: L10n.text("Заметки к выпуску", "Release notes"), running: true,
                messages: [RemoteMessage(id: "g1", role: "user", text: L10n.text("Собери заметки к выпуску 1.4.", "Draft the 1.4 release notes.")),
                           RemoteMessage(id: "g2", role: "assistant", text: L10n.text("Читаю журнал изменений и коммиты с прошлого выпуска.", "Reading the changelog and commits since the last release."))], approvals: [])
            release.activity = "Bash · " + "gi" + "t log --oneline v1.3.0..HEAD"
            release.runningSince = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-195))
            release.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-b"), projectAccess: .standard, canEdit: false)
            var migration = RemoteChat(id: "preview-approval", project: site.id, title: L10n.text("Миграция базы", "Database migration"), running: true,
                messages: [RemoteMessage(id: "g3", role: "assistant", text: L10n.text("Миграция готова. Нужно разрешение, чтобы применить её к локальной базе.", "The migration is ready. I need permission to apply it to the local database."))],
                approvals: [RemoteApproval(id: "99999999-9999-9999-9999-999999999999", details: "psql -d site_dev -f migrations/0042_add_index.sql", canAllow: true)])
            migration.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: false)
            var nightly = RemoteChat(id: "preview-nightly", project: site.id, title: L10n.text("Ночная проверка ссылок", "Nightly link check"), running: false,
                messages: [RemoteMessage(id: "g4", role: "assistant", text: L10n.text("Все 214 ссылок отвечают.", "All 214 links respond."))], approvals: [])
            nightly.readOnly = true; nightly.supportsPhotos = false
            chats += [release, migration, nightly]
        }
        devices = [RemoteDevice(id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", owner: "dddddddd-dddd-dddd-dddd-dddddddddddd", snapshot: RemoteSnapshot(projects: projects, chats: chats))]
        connectionState = ProcessInfo.processInfo.arguments.contains("-preview-offline") ? .offline : .connected
        onlineMacs = Set(devices.map(\.id))
        signedIn = true
        if ProcessInfo.processInfo.arguments.contains("-preview-unconfirmed"), let device = devices.first {
            receiptStorage = RemoteSessionStorage(read: { _ in nil }, write: { _, _ in })
            previewReceipt(RemoteCommand(owner: device.owner, device: device.id, project: project.id, chat: chat.id, kind: "send",
                text: L10n.text("Добавь тёмную тему в настройки.", "Add a dark theme to settings.")), undelivered: false)
            previewReceipt(RemoteCommand.newChat(owner: device.owner, device: device.id, project: project.id,
                text: L10n.text("Проверь сборку на iOS 27.", "Check the iOS 27 build.")), undelivered: true)
        }
    }
}

extension MobileModel {
    /// Synthetic file content: Markdown for `.md`, a rendered page for `.pdf`, text otherwise.
    static func previewFile(_ path: String) -> RemoteFile {
        let name = (path as NSString).lastPathComponent
        switch (path as NSString).pathExtension.lowercased() {
        case "md":
            return RemoteFile(kind: .markdown, path: path, text: L10n.text("# План\n\nФайл с Mac, показан на телефоне.\n\n- Первый шаг\n- Второй шаг", "# Plan\n\nA file from the Mac, shown on the phone.\n\n- First step\n- Second step"), size: 120)
        case "pdf":
            let page = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                (name as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
            }
            return RemoteFile(kind: .pages, path: path, pages: [page, page], pageCount: 5, size: 90_000, truncated: true)
        default:
            return RemoteFile(kind: .text, path: path, text: (1...60).map { "let line\($0) = \($0) // preview" }.joined(separator: "\n"),
                              size: 600_000, truncated: true)
        }
    }
}

/// Simulator-only deterministic acknowledgement. No cloud or agent access in UI fixtures.
final class MobilePreviewTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let schema = ["/rest/v1/rpc/remote_settings_version", "/rest/v1/rpc/remote_interactions_version"].contains(request.url?.path ?? "")
        let code = schema ? 200 : request.httpMethod == "POST" && request.url?.path == "/rest/v1/remote_commands" ? 201 : 400
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if schema { client?.urlProtocol(self, didLoad: Data("1".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
