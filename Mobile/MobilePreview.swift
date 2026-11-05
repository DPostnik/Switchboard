import SwiftUI
import Foundation

// Simulator-only fixtures for visual checks and UI tests; no cloud or agent access.
// Launch arguments: -mobile-preview (required), -preview-chat, -preview-long, -preview-rich,
// -preview-actions, -preview-settings, -preview-read-only, -preview-project-list, -preview-offline,
// -preview-file <path>, -preview-groups (running, approval and read-only chats in a second project),
// -preview-unconfirmed (an unconfirmed send in the first chat and an undelivered new chat).
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
        if ProcessInfo.processInfo.arguments.contains("-preview-actions") {
            receiptStorage = RemoteSessionStorage(read: { _ in nil }, write: { _, _ in })
            chat.approvals = [RemoteApproval(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", details: "echo permission-fixture", canAllow: true)]
            var empty = project; empty.id = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"; empty.name = L10n.text("Пустой проект", "Empty project")
            projects.append(empty)
            if ProcessInfo.processInfo.arguments.contains("-preview-settings") { chat.approvals = [] }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MobilePreviewTransport.self]
            api = try? RemoteAPI(url: "https://preview.invalid", key: "sb_publishable_fixture", transport: URLSession(configuration: configuration),
                storage: RemoteSessionStorage(read: { _ in Data(#"{"access_token":"fixture","refresh_token":"fixture","expires_at":4102444800,"user":{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd"}}"#.utf8) }, write: { _, _ in }))
        }
        chat.settings = RemoteChatSettings(options: RemoteChatOptions(model: "fixture-a"), projectAccess: .standard, canEdit: chat.approvals.isEmpty)
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
        let schema = request.url?.path == "/rest/v1/rpc/remote_settings_version"
        let code = schema ? 200 : request.httpMethod == "POST" && request.url?.path == "/rest/v1/remote_commands" ? 201 : 400
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if schema { client?.urlProtocol(self, didLoad: Data("1".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
