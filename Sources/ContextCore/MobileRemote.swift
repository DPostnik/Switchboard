import Foundation
import Security
import ImageIO

/// Installer handoff in the app's own container. Consume once; never bundle credentials.
public struct RemoteSetup: Codable, Sendable {
    public var url: String
    public var key: String
    public var email: String
    public var password: String
    public static func consume(_ file: URL) throws -> RemoteSetup? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 16_384 else { throw RemoteFailure.configuration }
        let setup = try JSONDecoder().decode(Self.self, from: data)
        _ = try RemoteAPI(url: setup.url, key: setup.key)
        guard !setup.email.isEmpty, !setup.password.isEmpty else { throw RemoteFailure.configuration }
        try FileManager.default.removeItem(at: file)
        return setup
    }
}

/// Version 1 is shared verbatim with the native iOS target. No engine credentials cross this boundary.
public enum RemoteAccessMode: String, Codable, CaseIterable, Sendable {
    case standard, fullAccess
    public var title: String {
        self == .fullAccess ? L10n.text("Полный доступ", "Full access") : L10n.text("С подтверждениями", "Ask for approval")
    }
}
public struct RemoteModelOption: Codable, Identifiable, Sendable, Equatable {
    public static let codexAgent = "codex", claudeAgent = "claude"
    public var id: String
    public var name: String
    /// Engine that runs the model; nil means Codex (older hosts). Kept a string so a future agent never breaks snapshot decoding.
    public var agent: String?
    public init(id: String, name: String, agent: String? = nil) { self.id = id; self.name = name; self.agent = agent }
    public var agentTitle: String { agent == Self.claudeAgent ? "Claude" : "Codex" }
}
public struct RemoteChatOptions: Codable, Sendable, Equatable {
    public var model: String
    /// nil inherits the project's interactive default without changing it.
    public var access: RemoteAccessMode?
    public init(model: String, access: RemoteAccessMode? = nil) { self.model = model; self.access = access }
    public func validate() throws {
        guard !model.isEmpty, model.utf8.count <= 200 else { throw RemoteFailure.invalidCommand }
    }
}
public struct RemoteChatSettings: Codable, Sendable, Equatable {
    public var options: RemoteChatOptions
    public var projectAccess: RemoteAccessMode
    public var canEdit: Bool
    public init(options: RemoteChatOptions, projectAccess: RemoteAccessMode, canEdit: Bool) {
        self.options = options; self.projectAccess = projectAccess; self.canEdit = canEdit
    }
}
public struct RemoteSettingsChange: Codable, Sendable, Equatable {
    public var options: RemoteChatOptions
    public var expected: RemoteChatOptions?
    public var expectedProjectAccess: RemoteAccessMode?
    public init(options: RemoteChatOptions, expected: RemoteChatOptions? = nil, expectedProjectAccess: RemoteAccessMode? = nil) {
        self.options = options; self.expected = expected; self.expectedProjectAccess = expectedProjectAccess
    }
}
public struct RemoteProject: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Absent on older hosts. Creation is an initial send to a reserved app conversation ID.
    public var canCreateChat: Bool?
    /// Codex models for existing Codex chats' settings.
    public var models: [RemoteModelOption]?
    /// Models a new chat can start with, from every ready agent; the chosen model selects the agent. Absent on older hosts: use `models`.
    public var newChatModels: [RemoteModelOption]?
    public var settings: RemoteChatSettings?
    /// Absent on older hosts and when the cloud schema has no file table: path chips only copy.
    public var canReadFiles: Bool?
    public init(id: String, name: String, canCreateChat: Bool? = nil) {
        self.id = id; self.name = name; self.canCreateChat = canCreateChat
    }
}
public struct RemoteChat: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var project: String
    public var title: String
    public var running: Bool
    public var turn: String?
    public var messages: [RemoteMessage]
    public var approvals: [RemoteApproval]
    public var supportsPhotos: Bool?
    public var settings: RemoteChatSettings?
    /// Absent on older hosts. A Claude scheduled-run record accepts no messages from any device.
    public var readOnly: Bool?
    /// The running turn's current action ("Bash · npm test") or agent status; nil when idle or on older hosts.
    public var activity: String?
    /// ISO 8601 start of the running turn; nil when idle or on older hosts.
    public var runningSince: String?
    public static let activityLimit = 160
    public init(id: String, project: String, title: String, running: Bool, messages: [RemoteMessage], approvals: [RemoteApproval], turn: String? = nil) { self.id = id; self.project = project; self.title = title; self.running = running; self.messages = messages; self.approvals = approvals; self.turn = turn; supportsPhotos = true }
    public static var readOnlyNotice: String {
        L10n.text("Запись запуска задания Claude — только для чтения. Чтобы продолжить, начни новый чат.",
                  "A Claude scheduled run record is read-only. Start a new chat to follow up.")
    }
}
extension RemoteChat {
    /// Compact elapsed time of the running turn, matching the desktop working row.
    public func elapsed(now: Date = Date()) -> String? {
        guard running, let runningSince, let start = ISO8601DateFormatter().date(from: runningSince) else { return nil }
        let value = now.timeIntervalSince(start)
        guard value.isFinite, value < 1e9 else { return nil }
        let seconds = max(0, Int(value))
        return seconds >= 60
            ? L10n.text("\(seconds / 60) мин \(seconds % 60) с", "\(seconds / 60)m \(seconds % 60)s")
            : L10n.text("\(seconds) с", "\(seconds)s")
    }
}
public struct RemoteMessage: Codable, Identifiable, Sendable, Equatable {
    /// Phone history keeps at most this many characters per message.
    public static let textLimit = 2000
    public var id: String
    public var role: String
    public var text: String
    /// Set when the Mac cut the message at `textLimit`; absent on older hosts.
    public var truncated: Bool?
    public init(id: String, role: String, text: String) { self.id = id; self.role = role; self.text = text }
    /// Clips the full message text to the phone limit and records whether anything was cut.
    public init(id: String, role: String, fullText: String) {
        self.init(id: id, role: role, text: Self.clip(fullText))
        if fullText.count > Self.textLimit { truncated = true }
    }
    /// Appends streamed text within the limit.
    public mutating func append(_ more: String) {
        guard truncated != true else { return }
        let combined = text + more
        text = Self.clip(combined)
        if combined.count > Self.textLimit { truncated = true }
    }
    /// Cuts at the last whole Markdown block that fits, never inside a code fence or table.
    /// Falls back to a sentence or word boundary (closing an open fence), then to a hard cut.
    public static func clip(_ text: String, limit: Int = textLimit) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        func fence(_ line: Substring) -> Bool {
            let value = line.drop { $0 == " " }
            return value.hasPrefix("```") || value.hasPrefix("~~~")
        }
        func table(_ line: Substring) -> Bool { line.drop { $0 == " " }.hasPrefix("|") }
        func blockStart(_ line: Substring) -> Bool {
            let value = line.drop { $0 == " " }
            if value.isEmpty || value.hasPrefix("#") || value.hasPrefix(">") || fence(line) || table(line) { return true }
            if ["- ", "* ", "+ "].contains(where: value.hasPrefix) { return true }
            return value.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) != nil
        }
        // Character offsets where a line ends and the next one starts a new block outside a fence.
        var inFence = false, offset = 0, block: Int?
        var fences: [(end: Int, open: Bool)] = []
        for (index, line) in lines.enumerated() {
            if fence(line) { inFence.toggle() }
            offset += line.count
            fences.append((offset, inFence))
            if index + 1 < lines.count {
                let next = lines[index + 1]
                if !inFence, blockStart(next), !(table(line) && table(next)), offset >= limit * 2 / 5 { block = offset }
            }
            offset += 1
        }
        if let block {
            return String(head.prefix(block)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let minimum = head.index(head.startIndex, offsetBy: limit * 2 / 5)
        let sentences = try! NSRegularExpression(pattern: #"[.!?…](?=\s)"#)
        let sentence = sentences.matches(in: head, range: NSRange(minimum..., in: head)).last
            .flatMap { Range($0.range, in: head)?.upperBound }
        let word = head[minimum...].lastIndex(where: \.isWhitespace)
        guard let cut = sentence ?? word else { return head }
        var result = String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let position = head.distance(from: head.startIndex, to: cut)
        if fences.last(where: { $0.end < position })?.open == true { result += "\n```" }
        return result
    }
}
public struct RemoteApproval: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var details: String
    public var canAllow: Bool
    public init(id: String, details: String, canAllow: Bool) { self.id = id; self.details = details; self.canAllow = canAllow }
}
public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public var version = 1
    public var projects: [RemoteProject]
    public var chats: [RemoteChat]
    public init(projects: [RemoteProject], chats: [RemoteChat]) { self.projects = projects; self.chats = chats }
}
public struct RemoteDevice: Codable, Identifiable, Sendable {
    public var id: String
    public var owner: String
    public var name: String
    public var seen: String
    public var snapshot: RemoteSnapshot
    public var projects: [String]
    public var revision: Int64?
    public init(id: String, owner: String, snapshot: RemoteSnapshot) {
        self.id = id; self.owner = owner; name = "Mac"
        seen = ISO8601DateFormatter().string(from: Date()); self.snapshot = snapshot
        projects = snapshot.projects.map(\.id)
    }
}
/// One project file as the Mac read it for the phone. Lives in a short-lived owner-only row.
public struct RemoteFile: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case markdown, text, pages, failure }
    /// Why the Mac did not return content. Codes stay stable; the phone owns the wording.
    public enum Failure: String, Codable, Sendable, CaseIterable {
        case notFound, outsideProject, protected, directory, unsupported, unreadable, tooLarge
        public func message(language: AppLanguage = L10n.language) -> String {
            switch self {
            case .notFound: L10n.text("Файл не найден на Mac.", "File not found on the Mac.", language: language)
            case .outsideProject: L10n.text("Файл лежит вне папки проекта. С телефона открываются только файлы проекта.", "The file is outside the project folder. Only project files can be opened from the phone.", language: language)
            case .protected: L10n.text("Этот файл может содержать секреты, поэтому с телефона он не открывается.", "This file may contain secrets, so it cannot be opened from the phone.", language: language)
            case .directory: L10n.text("Это папка, а не файл.", "This is a folder, not a file.", language: language)
            case .unsupported: L10n.text("Такой тип файла на телефоне не показывается. Поддерживаются текст, Markdown, PDF и изображения.", "This file type cannot be shown on the phone. Text, Markdown, PDF and images are supported.", language: language)
            case .unreadable: L10n.text("Mac не смог прочитать файл.", "The Mac could not read the file.", language: language)
            case .tooLarge: L10n.text("Файл слишком большой для показа на телефоне.", "The file is too large to show on the phone.", language: language)
            }
        }
    }
    public static let pathLimit = 4096
    /// Text is cut to this many UTF-8 bytes; documents are rendered to at most `pageLimit` JPEG pages.
    public static let textBytes = 256 * 1024
    public static let pageLimit = 12
    public static let pageBytes = 450 * 1024
    /// Encoded JSON budget, below the database row check.
    public static let payloadBytes = 3_800_000
    public var kind: Kind
    /// Path relative to the project folder; the file name for display.
    public var path: String
    public var text: String?
    public var pages: [Data]?
    /// Total pages in the document, when more were available than sent.
    public var pageCount: Int?
    /// Size of the file on the Mac, in bytes.
    public var size: Int64?
    public var truncated: Bool?
    public var failure: Failure?
    public init(kind: Kind, path: String, text: String? = nil, pages: [Data]? = nil, pageCount: Int? = nil, size: Int64? = nil, truncated: Bool? = nil, failure: Failure? = nil) {
        self.kind = kind; self.path = path; self.text = text; self.pages = pages
        self.pageCount = pageCount; self.size = size; self.truncated = truncated; self.failure = failure
    }
    public static func failed(_ failure: Failure, path: String) -> Self { Self(kind: .failure, path: path, failure: failure) }
    public var name: String { (path as NSString).lastPathComponent }
}
/// Bounded JPEG payload; filenames and destination paths are generated by the receiving Mac.
public struct RemotePhoto: Codable, Sendable, Equatable, Identifiable {
    public static let maximumCount = 4
    public static let maximumBytes = 512 * 1024
    public var id: UUID
    public var data: Data
    public init(id: UUID = UUID(), data: Data) { self.id = id; self.data = data }
    public func validate() throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw RemoteFailure.invalidPhoto }
    }
}

public struct RemoteCommand: Codable, Identifiable, Sendable {
    public var id: String
    public var owner: String
    public var device: String
    public var project: String
    public var chat: String
    public var kind: String
    public var text: String
    public var approval: String?
    public var turn: String?
    public var status: String
    public var photos: [RemotePhoto]?
    public var settings: RemoteSettingsChange?
    /// Uses the existing immutable send envelope and queue; no database migration required.
    /// The first send owns the new app ID. Later sends cannot recreate a missing conversation.
    public var createsChat: Bool { ["send", "create"].contains(kind) && chat == "mobile:" + id.lowercased() }
    public static func newChat(owner: String, device: String, project: String, text: String, options: RemoteChatOptions? = nil) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: "", kind: options == nil ? "send" : "create", text: text)
        command.chat = "mobile:" + command.id
        command.settings = options.map { RemoteSettingsChange(options: $0) }
        return command
    }
    public static func configure(owner: String, device: String, project: String, chat: String, options: RemoteChatOptions, expected: RemoteChatSettings) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: chat, kind: "configure")
        command.settings = RemoteSettingsChange(options: options, expected: expected.options, expectedProjectAccess: expected.projectAccess)
        return command
    }
    /// Read-only request for one file of the chat's project; `text` carries the path as written in the answer.
    public static func file(owner: String, device: String, project: String, chat: String, path: String) -> Self {
        Self(owner: owner, device: device, project: project, chat: chat, kind: "file", text: path)
    }
    public init(owner: String, device: String, project: String, chat: String, kind: String, text: String = "", approval: String? = nil, turn: String? = nil, photos: [RemotePhoto] = []) {
        id = UUID().uuidString.lowercased(); self.owner = owner; self.device = device
        self.project = project; self.chat = chat; self.kind = kind; self.text = text
        self.approval = approval; self.turn = turn; status = "pending"
        self.photos = photos.isEmpty ? nil : photos
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: project) != nil,
              !chat.isEmpty, text.utf8.count <= 32_000,
              ["send", "stop", "allow", "deny", "create", "configure", "file"].contains(kind),
              !["send", "create"].contains(kind) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(photos ?? []).isEmpty,
              !["allow", "deny"].contains(kind) || approval.flatMap(UUID.init(uuidString:)) != nil
        else { throw RemoteFailure.invalidCommand }
        if kind == "file" {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, text.utf8.count <= RemoteFile.pathLimit, !text.contains("\n"), !text.contains("\0"),
                  approval == nil, turn == nil, (photos ?? []).isEmpty, settings == nil else { throw RemoteFailure.invalidCommand }
        }
        let photos = photos ?? []
        guard photos.count <= RemotePhoto.maximumCount,
              photos.isEmpty || ["send", "create"].contains(kind), Set(photos.map(\.id)).count == photos.count else { throw RemoteFailure.invalidPhoto }
        try photos.forEach { try $0.validate() }
        if ["create", "configure"].contains(kind) {
            guard let settings, approval == nil, turn == nil else { throw RemoteFailure.invalidCommand }
            try settings.options.validate()
            if kind == "create" {
                guard createsChat, settings.expected == nil, settings.expectedProjectAccess == nil else { throw RemoteFailure.invalidCommand }
            } else {
                guard text.isEmpty, photos.isEmpty, let expected = settings.expected, settings.expectedProjectAccess != nil else { throw RemoteFailure.invalidCommand }
                try expected.validate()
            }
        } else if settings != nil { throw RemoteFailure.invalidCommand }
    }
    /// Keep received files for the conversation, including uncertain submissions; never overwrite.
    public func photoPrompt(directory: URL) throws -> String {
        try validate()
        guard let photos, !photos.isEmpty else { return text }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        #if os(macOS)
        try MobilePhotoRetention.register(folder: folder, chat: chat)
        #endif
        var paths: [String] = []
        for photo in photos {
            let file = folder.appendingPathComponent(photo.id.uuidString + ".jpg")
            try photo.data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            paths.append(file.path)
        }
        return text + "\n\n" + L10n.text("Прикреплённые фотографии (открой для обработки):", "Attached photos (open to process):") + "\n" + paths.joined(separator: "\n")
    }
}
public enum RemoteFailure: Error, LocalizedError {
    case configuration, signedOut, request(Int), invalidCommand, uncertain, duplicate
    case invalidPhoto, photoSetup, settingsSetup
    case realtimeSetup, realtimeProtocol, realtimeTimeout
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .invalidPhoto: L10n.text("Не удалось подготовить фото. Выбери до 4 изображений; каждое должно помещаться в 512 КБ после сжатия.", "Could not prepare photos. Choose up to 4 images; each must fit within 512 KB after compression.")
        case .photoSetup: L10n.text("Для отправки фото обнови схему мобильного доступа в Supabase (миграция photos).", "To send photos, update the Supabase mobile access schema (photos migration).")
        case .settingsSetup: L10n.text("Для выбора модели и доступа обнови схему мобильного доступа в Supabase и приложение на Mac.", "To choose a model and access mode, update the Supabase mobile access schema and Mac app.")
        case .configuration: L10n.text("Проверь HTTPS URL Supabase и публичный ключ.", "Check the Supabase HTTPS URL and public key.")
        case .signedOut: L10n.text("Войди в Supabase заново.", "Sign in to Supabase again.")
        case .keychain(let code): Self.keychainDescription(code, language: L10n.language)
        case .request(let code): L10n.text("Ошибка Supabase (\(code)).", "Supabase error (\(code)).")
        case .invalidCommand: L10n.text("Команда недоступна или устарела.", "Command unavailable or stale.")
        case .uncertain: L10n.text("Результат неизвестен. Проверь историю; автоматического повтора нет.", "Outcome unknown. Check history; no automatic retry.")
        case .duplicate: L10n.text("Команда уже обработана или её результат неизвестен.", "Command already handled or its outcome is unknown.")
        case .realtimeSetup: L10n.text("Обнови схему мобильного доступа в Supabase до версии 2.", "Update the Supabase mobile access schema to version 2.")
        case .realtimeProtocol: L10n.text("Не удалось подписаться на защищённые события Supabase. Проверь настройки Realtime.", "Could not subscribe to private Supabase events. Check Realtime settings.")
        case .realtimeTimeout: L10n.text("Сервер не ответил вовремя. Восстанавливаем соединение.", "The server did not respond in time. Reconnecting.")
        }
    }
    static func keychainDescription(_ code: OSStatus, language: AppLanguage) -> String {
        L10n.text("Не удалось получить доступ к сессии в Связке ключей (код \(code)). Проверь, что Связка ключей разблокирована и доступ для Switchboard разрешён.", "Could not access the session in Keychain (code \(code)). Check that Keychain is unlocked and Switchboard is allowed access.", language: language)
    }
}
public enum RemoteVault {
    public static func read(_ account: String) -> Data? {
        try? readChecked(account)
    }
    public static func readChecked(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            // Pre-rename service name: renaming it would mean copying the stored session secret.
            kSecAttrService as String: "ContextDesk.MobileRemote.v1", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try check(status, missingAllowed: true)
        return status == errSecSuccess ? result as? Data : nil
    }
    static func check(_ status: OSStatus, missingAllowed: Bool = false) throws {
        guard status == errSecSuccess || (missingAllowed && status == errSecItemNotFound) else {
            throw RemoteFailure.keychain(status)
        }
    }
    public static func save(_ data: Data?, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ContextDesk.MobileRemote.v1", kSecAttrAccount as String: account]
        if let data {
            let changes: [String: Any] = [kSecValueData as String: data]
            let result = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            if result == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try check(SecItemAdd(item as CFDictionary, nil))
            } else { try check(result) }
        } else { try check(SecItemDelete(query as CFDictionary), missingAllowed: true) }
    }
}
/// Injectable storage keeps authentication tests independent of real Keychain sessions.
public struct RemoteSessionStorage: Sendable {
    public var read: @Sendable (String) throws -> Data?
    public var write: @Sendable (Data?, String) throws -> Void
    public init(read: @escaping @Sendable (String) throws -> Data?, write: @escaping @Sendable (Data?, String) throws -> Void) {
        self.read = read; self.write = write
    }
    public static let keychain = Self(read: { try RemoteVault.readChecked($0) }, write: { try RemoteVault.save($0, account: $1) })
}

public actor RemoteAPI {
    private struct Session: Codable, Sendable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double?
        var user: User
        struct User: Codable, Sendable { var id: String }
    }
    private let transport: URLSession
    private let base: URL
    private let key: String
    private let account: String
    private let storage: RemoteSessionStorage
    private var session: Session?
    private var refreshTask: Task<Session, Error>?
    private var authGeneration = UUID()
    public init(url: String, key: String, transport: URLSession? = nil, storage: RemoteSessionStorage = .keychain) throws {
        guard let base = URL(string: url), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/", !key.isEmpty, !key.hasPrefix("sb_secret_") else { throw RemoteFailure.configuration }
        if key.hasPrefix("ey") {
            let pieces = key.split(separator: ".")
            guard pieces.count == 3 else { throw RemoteFailure.configuration }
            var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["role"] as? String == "anon" else { throw RemoteFailure.configuration }
        } else if !key.hasPrefix("sb_publishable_") { throw RemoteFailure.configuration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        self.transport = transport ?? URLSession(configuration: configuration)
        self.storage = storage
        self.base = base; self.key = key; account = base.absoluteString
        session = try storage.read(account).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }
    public func owner() async throws -> String {
        // Identity lookup must not initiate a token refresh before network
        // reachability is known (e.g. opening the phone in airplane mode).
        if let session { return session.user.id }
        guard let refreshTask else { throw RemoteFailure.signedOut }
        let generation = authGeneration
        let value = try await refreshTask.value
        guard generation == authGeneration else { throw RemoteFailure.signedOut }
        return value.user.id
    }
    public func signIn(email: String, password: String) async throws {
        let data = try await request("auth/v1/token?grant_type=password", method: "POST", body: JSONEncoder().encode(["email": email, "password": password]), auth: false)
        let value = try JSONDecoder().decode(Session.self, from: data)
        try storage.write(JSONEncoder().encode(value), account); session = value
    }
    public func signOut() throws {
        authGeneration = UUID(); refreshTask?.cancel(); refreshTask = nil
        session = nil; try storage.write(nil, account)
    }
    private func validSession() async throws -> Session {
        if let refreshTask {
            let generation = authGeneration
            let value = try await refreshTask.value
            guard authGeneration == generation else { throw RemoteFailure.signedOut }
            return value
        }
        guard let current = session else { throw RemoteFailure.signedOut }
        guard (current.expires_at ?? 0) < Date().timeIntervalSince1970 + 120 else { return current }
        // One refresh for concurrent REST and socket requests. Never retry an
        // uncertain refresh, and never restore a session after sign-out.
        let generation = authGeneration
        session = nil
        // Invalidate the old refresh token before sending, but preserve the
        // Keychain item and its user-granted ACL. Delete/re-add loses that ACL.
        // Empty data restores as signed out after a crash or uncertain refresh.
        try storage.write(Data(), account)
        let task = Task<Session, Error> {
            do {
                let data = try await self.request("auth/v1/token?grant_type=refresh_token", method: "POST",
                    body: JSONEncoder().encode(["refresh_token": current.refresh_token]), auth: false)
                let value = try JSONDecoder().decode(Session.self, from: data)
                try Task.checkCancellation()
                guard self.authGeneration == generation else { throw RemoteFailure.signedOut }
                try self.storage.write(JSONEncoder().encode(value), self.account)
                self.session = value
                return value
            } catch {
                if case RemoteFailure.keychain = error { throw error }
                throw RemoteFailure.signedOut
            }
        }
        refreshTask = task
        defer { if authGeneration == generation { refreshTask = nil } }
        return try await task.value
    }
    public func realtimeCredentials() async throws -> RemoteRealtimeCredentials {
        let value = try await validSession()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"; components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "vsn", value: "1.0.0")]
        return RemoteRealtimeCredentials(url: components.url!, owner: value.user.id, token: value.access_token)
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, auth: Bool = true, prefer: String? = nil) async throws -> Data {
        let credentials = auth ? try await validSession() : nil
        try Task.checkCancellation()
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path) else { throw RemoteFailure.configuration }
        var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "apikey")
        if let credentials { req.setValue("Bearer " + credentials.access_token, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        let (data, response) = try await transport.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw RemoteFailure.request((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
    public func checkRealtimeSchema() async throws {
        do {
            let version = try JSONDecoder().decode(Int.self, from: await request("rest/v1/rpc/remote_protocol_version", method: "POST", body: Data("{}".utf8)))
            guard version == 2 else { throw RemoteFailure.realtimeSetup }
        } catch RemoteFailure.request(404) { throw RemoteFailure.realtimeSetup }
    }
    public func publishChanges(_ device: RemoteDevice, previous: RemoteSnapshot?) async throws {
        _ = try await request("rest/v1/rpc/patch_remote_snapshot", method: "POST",
            body: JSONEncoder().encode(RemoteSnapshotPatch(device: device, previous: previous)))
    }
    public func changes(device: String, since: Int64) async throws -> RemoteSnapshotDelta? {
        struct Query: Encodable { let device_id: String; let since_revision: Int64 }
        guard UUID(uuidString: device) != nil else { throw RemoteFailure.invalidCommand }
        return try JSONDecoder().decode(RemoteSnapshotDelta?.self, from: await request("rest/v1/rpc/read_remote_changes", method: "POST",
            body: JSONEncoder().encode(Query(device_id: device, since_revision: since))))
    }
    public func command(id: String) async throws -> RemoteCommand? {
        guard UUID(uuidString: id) != nil else { throw RemoteFailure.invalidCommand }
        return try JSONDecoder().decode([RemoteCommand].self, from: await request("rest/v1/remote_commands?select=id,owner,device,project,chat,kind,text,approval,turn,status&id=eq.\(id)&limit=1")).first
    }
    public func devices() async throws -> [RemoteDevice] {
        try JSONDecoder().decode([RemoteDevice].self, from: await request("rest/v1/remote_devices?select=*&limit=20"))
    }
    public func publish(_ device: RemoteDevice) async throws {
        _ = try await request("rest/v1/remote_devices?on_conflict=id", method: "POST", body: JSONEncoder().encode(device), prefer: "resolution=merge-duplicates")
    }
    /// Returns false when the cloud schema predates file viewing.
    public func supportsFiles() async throws -> Bool {
        do {
            return try JSONDecoder().decode(Int.self, from: await request("rest/v1/rpc/remote_files_version", method: "POST", body: Data("{}".utf8))) == 1
        } catch RemoteFailure.request(404) { return false }
    }
    /// Mac side: one answer per claimed file command.
    public func publishFile(_ file: RemoteFile, command: String) async throws {
        struct Row: Encodable { let id: String; let payload: RemoteFile }
        guard UUID(uuidString: command) != nil else { throw RemoteFailure.invalidCommand }
        let body = try JSONEncoder().encode(Row(id: command.lowercased(), payload: file))
        guard body.count <= RemoteFile.payloadBytes + 1024 else { throw RemoteFailure.invalidCommand }
        _ = try await request("rest/v1/remote_files", method: "POST", body: body)
    }
    /// Phone side: reads the answer and removes it from the cloud; nil until the Mac has answered.
    public func takeFile(command: String) async throws -> RemoteFile? {
        struct Row: Decodable { let payload: RemoteFile }
        guard UUID(uuidString: command) != nil else { throw RemoteFailure.invalidCommand }
        let id = command.lowercased()
        guard let row = try JSONDecoder().decode([Row].self, from: await request("rest/v1/remote_files?select=payload&id=eq.\(id)&limit=1")).first else { return nil }
        // Best effort: scheduled cleanup removes rows the phone could not delete.
        _ = try? await request("rest/v1/remote_files?id=eq.\(id)", method: "DELETE")
        return row.payload
    }
    public func checkPhotoSchema() async throws {
        do { _ = try await request("rest/v1/remote_commands?select=photos&limit=0") }
        catch RemoteFailure.request(400) { throw RemoteFailure.photoSetup }
    }
    public func checkSettingsSchema() async throws {
        do {
            let version = try JSONDecoder().decode(Int.self, from: await request("rest/v1/rpc/remote_settings_version", method: "POST", body: Data("{}".utf8)))
            guard version == 1 else { throw RemoteFailure.settingsSetup }
        } catch RemoteFailure.request(404) { throw RemoteFailure.settingsSetup }
    }
    public func submit(_ command: RemoteCommand) async throws {
        try command.validate()
        _ = try await request("rest/v1/remote_commands", method: "POST", body: JSONEncoder().encode(command))
    }
    public func claim(device: String) async throws -> [RemoteCommand] {
        try JSONDecoder().decode([RemoteCommand].self, from: await request("rest/v1/rpc/claim_remote_command", method: "POST", body: JSONEncoder().encode(["device_id": device])))
    }
    public func finish(id: String, status: String) async throws {
        guard UUID(uuidString: id) != nil else { throw RemoteFailure.invalidCommand }
        _ = try await request("rest/v1/remote_commands?id=eq.\(id)&status=eq.claimed", method: "PATCH", body: JSONEncoder().encode(["status": status]))
    }
    public func commands(device: String) async throws -> [RemoteCommand] {
        guard UUID(uuidString: device) != nil else { throw RemoteFailure.invalidCommand }
        return try JSONDecoder().decode([RemoteCommand].self, from: await request("rest/v1/remote_commands?select=id,owner,device,project,chat,kind,text,approval,turn,status&device=eq.\(device)&order=created.desc&limit=30"))
    }
    public func deleteDevice(_ id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw RemoteFailure.invalidCommand }
        _ = try await request("rest/v1/remote_devices?id=eq.\(id)", method: "DELETE")
    }
}
/// Record intent before contacting an engine. A crash can lose progress, never permit redispatch.
public actor RemoteJournal {
    private let file: URL
    public init(file: URL) { self.file = file }
    public func begin(_ command: RemoteCommand) throws {
        try command.validate()
        var entries: Set<String> = []
        if FileManager.default.fileExists(atPath: file.path) { entries = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file)) }
        guard entries.insert(command.id.lowercased()).inserted else { throw RemoteFailure.duplicate }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
