import Foundation
import AgentContract

/// A change to project settings that an agent proposes and only the user applies (the agent can never change them).
/// The agent writes one JSON file into `SettingsProposalInbox.directory`; the app shows it as a review and applies it on
/// the user's click. The file is data: every field is checked against the current state before it is shown.
public struct SettingsProposal: Codable, Sendable {
    public struct Change: Codable, Sendable {
        /// The project's folder path (`~/` allowed) or its exact name.
        public var project: String
        public var sandbox: Bool?
        public var addPresets: [String]?
        public var removePresets: [String]?
        public var addFolders: [AgentPermissionProfile.Root]?
        public var removeFolders: [String]?
        public var addCommands: [String]?
        public var removeCommands: [String]?
        /// Named Keychain items (`KeychainItemRule`): exact service and optional account, never a pattern.
        public var addKeychainItems: [AgentPermissionProfile.KeychainItem]?
        public var removeKeychainItems: [AgentPermissionProfile.KeychainItem]?
        public init(project: String) { self.project = project }
    }
    /// The proposing chat's session ID. Agent-written, so it is read only for a file in the inbox root (sessions started
    /// before per-chat folders); a file in a chat's own folder gets its author from the folder and this field is ignored.
    /// It only chooses where the request card is shown; the message that chat later receives is fixed app text.
    public var chat: String?
    public var reason: String?
    public var changes: [Change]
    public init(chat: String? = nil, reason: String? = nil, changes: [Change]) { self.chat = chat; self.reason = reason; self.changes = changes }
}

/// One proposal checked against the current state: only the parts that would change something.
public struct SettingsProposalReview: Identifiable, Equatable, Sendable {
    public struct ProjectDiff: Equatable, Sendable {
        public var projectID: UUID
        public var name: String
        public var sandbox: Bool?
        public var addPresets: [String] = []
        public var removePresets: [String] = []
        /// New folders and folders whose write flag changes.
        public var addFolders: [AgentPermissionProfile.Root] = []
        public var removeFolders: [String] = []
        public var addCommands: [String] = []
        public var removeCommands: [String] = []
        /// Checked items (`KeychainItemRule.checked`) the project does not have yet, and listed items to remove.
        public var addKeychainItems: [AgentPermissionProfile.KeychainItem] = []
        public var removeKeychainItems: [AgentPermissionProfile.KeychainItem] = []
        public var isEmpty: Bool {
            sandbox == nil && addPresets.isEmpty && removePresets.isEmpty && addFolders.isEmpty && removeFolders.isEmpty
                && addCommands.isEmpty && removeCommands.isEmpty && addKeychainItems.isEmpty && removeKeychainItems.isEmpty
        }
    }
    /// The file's path relative to the inbox: `<name>.json` in the root, `<folder>/<name>.json` in a chat's folder.
    public var id: String
    /// The session ID of the chat that asked. For a file in a chat's folder the app sets it from the folder
    /// (`folder` is non-nil); for a root file it is the agent-written `chat` field.
    public var chat: String?
    /// The per-chat folder the file lies in, chosen by the app at launch; nil for a file in the inbox root.
    public var folder: String?
    public var reason: String?
    public var projects: [ProjectDiff]
    /// Parts that were dropped, in the user's language (unknown project, relative path, unknown set).
    public var skipped: [String]

    static let maximumText = 300

    /// `author` is the app's mapping of `folder` to a session ID; with a folder the proposal's own `chat` is ignored.
    public init(id: String, proposal: SettingsProposal, state: SavedState, home: String = NSHomeDirectory(), folder: String? = nil, author: String? = nil) {
        self.id = id
        self.folder = folder
        chat = folder == nil ? proposal.chat.map { String($0.prefix(80)) } : author
        reason = proposal.reason.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumText)) }.flatMap { $0.isEmpty ? nil : $0 }
        var projects: [ProjectDiff] = [], skipped: [String] = []
        for change in proposal.changes.prefix(32) {
            let target = change.project.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = Self.absolute(target, home: home)
            let byPath = path.flatMap { path in state.projects.filter { $0.path == path } } ?? []
            let byName = state.projects.filter { $0.name == target }
            guard let project = byPath.first ?? (byName.count == 1 ? byName.first : nil) else {
                skipped.append(L10n.text("Проект не найден: \(target.prefix(120))", "Project not found: \(target.prefix(120))")); continue
            }
            var diff = projects.first { $0.projectID == project.id } ?? ProjectDiff(projectID: project.id, name: project.name)
            if let sandbox = change.sandbox, sandbox != project.usesCommandSandbox { diff.sandbox = sandbox }
            let presets = Set(project.accessPresets ?? [])
            for id in change.addPresets ?? [] {
                guard AccessPresetCatalog.preset(id) != nil else { skipped.append(L10n.text("Неизвестный набор: \(id.prefix(40))", "Unknown set: \(id.prefix(40))")); continue }
                if !presets.contains(id), !diff.addPresets.contains(id) { diff.addPresets.append(id) }
            }
            for id in change.removePresets ?? [] where presets.contains(id) && !diff.removePresets.contains(id) { diff.removePresets.append(id) }
            let roots = project.extraRoots ?? []
            for folder in change.addFolders ?? [] {
                guard let path = Self.absolute(folder.path, home: home), path != project.path, path != "/" else {
                    skipped.append(L10n.text("Папка должна быть полным путём: \(folder.path.prefix(120))", "A folder must be a full path: \(folder.path.prefix(120))")); continue
                }
                if roots.contains(.init(path: path, writable: folder.writable)) || diff.addFolders.contains(where: { $0.path == path }) { continue }
                diff.addFolders.append(.init(path: path, writable: folder.writable))
            }
            for raw in change.removeFolders ?? [] {
                if let path = Self.absolute(raw, home: home), roots.contains(where: { $0.path == path }), !diff.removeFolders.contains(path) { diff.removeFolders.append(path) }
            }
            let commands = project.sandboxCommands ?? []
            for raw in change.addCommands ?? [] {
                let command = raw.trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty, command.count <= Self.maximumText, !command.contains(where: \.isNewline) else {
                    skipped.append(L10n.text("Команда пустая, длинная или в несколько строк", "A command is empty, too long or has several lines")); continue
                }
                if !commands.contains(command), !diff.addCommands.contains(command) { diff.addCommands.append(command) }
            }
            for raw in change.removeCommands ?? [] {
                let command = raw.trimmingCharacters(in: .whitespaces)
                if commands.contains(command), !diff.removeCommands.contains(command) { diff.removeCommands.append(command) }
            }
            let items = KeychainItemRule.usable(project.keychainItems ?? [])
            for raw in change.removeKeychainItems ?? [] {
                if case .success(let item) = KeychainItemRule.checked(raw), items.contains(item), !diff.removeKeychainItems.contains(item) {
                    diff.removeKeychainItems.append(item)
                }
            }
            for raw in (change.addKeychainItems ?? []).prefix(KeychainItemRule.maximumPerChange) {
                switch KeychainItemRule.checked(raw) {
                case .failure(let rejection): skipped.append(rejection.message(raw))
                case .success(let item):
                    if items.contains(item) || diff.addKeychainItems.contains(item) { continue }
                    let kept = items.filter { !diff.removeKeychainItems.contains($0) }.count + diff.addKeychainItems.count
                    guard kept < KeychainItemRule.maximumPerProject else {
                        let line = KeychainItemRule.limitMessage()
                        if !skipped.contains(line) { skipped.append(line) }
                        continue
                    }
                    diff.addKeychainItems.append(item)
                }
            }
            if let index = projects.firstIndex(where: { $0.projectID == project.id }) { projects[index] = diff } else { projects.append(diff) }
        }
        self.projects = projects.filter { !$0.isEmpty }
        self.skipped = skipped
    }

    /// The app chat that asked: an existing, unarchived, interactive chat whose agent session ID (or app chat ID) equals
    /// `chat`. Nil otherwise; such a proposal stays a global review with `unknownAuthorNotice`. For a root file the label
    /// is agent-written, so it only picks where the card is shown: the chat later receives fixed app text
    /// (`SettingsProposalOutcome.message`), never its strings.
    public func requestingChat(in chats: [Chat]) -> Chat? { Self.chat(labeled: chat, in: chats) }
    static func chat(labeled label: String?, in chats: [Chat]) -> Chat? {
        guard let label, !label.isEmpty else { return nil }
        return chats.first { chat in
            !chat.isArchived && !chat.isScheduledRecord && (chat.nativeSession?.nativeID == label || chat.id == label)
        }
    }

    /// Shown on a global review (no requesting chat): nothing continues the task after the decision.
    public static func unknownAuthorNotice(language: AppLanguage = L10n.language) -> String {
        L10n.text("Неизвестно, какой чат запросил это изменение, поэтому после «Применить» задача сама не продолжится: вернись в тот чат и скажи ему продолжить.",
                  "The chat that requested this change is unknown, so after Apply the task will not continue by itself: return to that chat and tell it to continue.",
                  language: language)
    }

    /// `~/` expanded, standardized; nil for relative paths and `..` components.
    static func absolute(_ raw: String, home: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

extension SavedState {
    /// Applies a reviewed proposal; returns whether anything changed.
    @discardableResult public mutating func apply(_ review: SettingsProposalReview) -> Bool {
        var changed = false
        for diff in review.projects {
            guard let index = projects.firstIndex(where: { $0.id == diff.projectID }) else { continue }
            var project = projects[index]
            if let sandbox = diff.sandbox { project.commandSandbox = sandbox ? nil : false }
            var presets = (project.accessPresets ?? []).filter { !diff.removePresets.contains($0) }
            presets += diff.addPresets.filter { !presets.contains($0) }
            project.accessPresets = AccessPresetCatalog.all.map(\.id).filter(presets.contains)
            var roots = (project.extraRoots ?? []).filter { root in !diff.removeFolders.contains(root.path) && !diff.addFolders.contains { $0.path == root.path } }
            roots += diff.addFolders
            project.extraRoots = roots
            var commands = (project.sandboxCommands ?? []).filter { !diff.removeCommands.contains($0) }
            commands += diff.addCommands.filter { !commands.contains($0) }
            project.sandboxCommands = commands.isEmpty ? nil : commands
            var items = KeychainItemRule.usable(project.keychainItems ?? []).filter { !diff.removeKeychainItems.contains($0) }
            items += diff.addKeychainItems.filter { !items.contains($0) }
            items = Array(items.prefix(KeychainItemRule.maximumPerProject))
            project.keychainItems = items.isEmpty ? nil : items
            if project != projects[index] { projects[index] = project; changed = true }
        }
        return changed
    }
}

/// The user's decision on a proposal, and the one fixed message the requesting chat receives for it. The message never
/// carries text from the proposal (paths, commands, reason): any chat can name another chat in its proposal.
public enum SettingsProposalOutcome: Sendable {
    /// `appliedWithoutEffect`: applied, but every added trusted command stays inside this chat's external boundary
    /// (`SettingsProposalOutcome.afterApply(_:notes:)`), so nothing new applies and a retry would fail the same way.
    case applied, appliedWithoutEffect, rejected
    public func message(language: AppLanguage = L10n.language) -> String {
        switch self {
        case .applied: L10n.text(
            "Switchboard: пользователь применил твой запрос на изменение настроек проекта. Новые права действуют с этого сообщения. Повтори шаг, которому не хватало доступа, и продолжай задачу.",
            "Switchboard: the user applied your project settings request. The new access applies from this message. Retry the step that lacked access and continue the task.",
            language: language)
        case .appliedWithoutEffect: L10n.text(
            "Switchboard: пользователь применил твой запрос на изменение настроек проекта, но этот чат работает под внешней границей: добавленная доверенная команда всё равно выполняется внутри неё и не получает дополнительного доступа. Не повторяй тот же шаг. Сообщи, что задача заблокирована, или запроси правильный доступ: набор доступа с командой-посредником, папку, запись Связки ключей (`addKeychainItems`) или инструмент приложения.",
            "Switchboard: the user applied your project settings request, but this chat runs under the external boundary: the added trusted command still runs inside it and gets no extra access. Do not retry the same step. Report that the task is blocked, or request the right access: an access set with a mediated command, a folder, a Keychain item (`addKeychainItems`) or an app-owned tool.",
            language: language)
        case .rejected: L10n.text(
            "Switchboard: пользователь отклонил твой запрос на изменение настроек проекта. Не ищи другой способ получить тот же доступ. Продолжай независимую часть задачи или сообщи, что без этого доступа задача заблокирована.",
            "Switchboard: the user rejected your project settings request. Do not look for another way to get the same access. Continue the independent part of the task, or report that the task is blocked without this access.",
            language: language)
        }
    }
}

/// The folder agents write proposals to and its reader. Each chat's provider process gets its own subfolder, chosen by the
/// app at launch (`chatFolder`): the variable points there and the write grant covers only it, so the app knows the author
/// of a proposal from the folder it lies in, without any agent-written field. Files in the root come from sessions started
/// before per-chat folders and keep the old rule (the agent-written `chat`).
public enum SettingsProposalInbox {
    public static let environmentKey = "SWITCHBOARD_SETTINGS_PROPOSALS"
    public static var directory: URL { Locations.root.appendingPathComponent("settings-proposals", isDirectory: true) }
    static let maximumFiles = 20, maximumSize = 64 * 1024, maximumFolders = 500
    /// An empty folder of no current chat is removed only after this long, so a launch that has just created it (a new
    /// Codex thread before its ID is known) never loses it.
    static let staleFolderAge: TimeInterval = 3600

    /// A folder name the app chose: a session ID or an app token. ASCII letters, digits, `-` and `_` only, starting with a
    /// letter or digit, so it can never be `..`, a nested path or hidden.
    public static func isFolderName(_ name: String) -> Bool {
        (1...100).contains(name.count) && name.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    /// One chat's folder: `name` is the session ID the app launched the process for (Claude) or an app token (a Codex
    /// worker). Nil for a name the app would not create. With `create`, the folder exists afterwards.
    public static func chatFolder(_ name: String, directory: URL = directory, create: Bool = false) -> URL? {
        guard isFolderName(name) else { return nil }
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return folder
    }
    /// Where the app records which session a token folder belongs to (a new Codex thread gets its ID only after its worker
    /// started). Next to the inbox, never inside it: no agent grant covers it.
    public static func authorsFile(directory: URL = directory) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-authors.json")
    }
    /// Records that `folder` belongs to `session`; entries of folders that no longer exist are dropped. Called by the app
    /// only, with a name it chose and the session ID the provider returned.
    public static func recordAuthor(folder: String, session: String, directory: URL = directory) {
        guard isFolderName(folder), !session.isEmpty, session.count <= 100 else { return }
        var map = authors(directory: directory).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.key).path) }
        map[folder] = session
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: authorsFile(directory: directory), options: .atomic)
    }
    static func authors(directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: authorsFile(directory: directory)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map.filter { isFolderName($0.key) }
    }
    /// Removes a folder only while it is empty (`rmdir`): a file written meanwhile is never deleted with it.
    public static func removeEmptyFolder(_ folder: URL) { _ = rmdir(folder.path) }

    /// Pending proposals, oldest first. Unreadable or oversized files and proposals that change nothing are removed.
    /// Reads the root and one level of per-chat folders; links are never followed. A file in a folder is authored by the
    /// session the folder belongs to; an empty folder of no current chat is removed once it is stale.
    public static func load(state: SavedState, directory: URL = directory, manager: FileManager = .default, now: Date = Date()) -> [SettingsProposalReview] {
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let map = authors(directory: directory)
        func proposalFiles(_ urls: [URL]) -> [URL] { urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") } }
        var files: [(url: URL, folder: String?)] = proposalFiles(entries).map { ($0, nil) }
        var folders = 0
        for entry in entries where isFolderName(entry.lastPathComponent) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            folders += 1
            guard folders <= maximumFolders else { break }
            let name = entry.lastPathComponent
            let inside = proposalFiles((try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: keys)) ?? [])
            if inside.isEmpty {
                if SettingsProposalReview.chat(labeled: map[name] ?? name, in: state.chats) == nil,
                   now.timeIntervalSince(values?.contentModificationDate ?? now) > staleFolderAge { removeEmptyFolder(entry) }
                continue
            }
            files += inside.map { ($0, name) }
        }
        func id(_ file: (url: URL, folder: String?)) -> String { (file.folder.map { $0 + "/" } ?? "") + file.url.lastPathComponent }
        files.sort { (date($0.url) ?? .distantPast, id($0)) < (date($1.url) ?? .distantPast, id($1)) }
        var result: [SettingsProposalReview] = []
        for file in files.prefix(maximumFiles) {
            let values = try? file.url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, (values?.fileSize ?? .max) <= maximumSize,
                  let data = try? Data(contentsOf: file.url), let proposal = try? JSONDecoder().decode(SettingsProposal.self, from: data) else {
                try? manager.removeItem(at: file.url); continue
            }
            let review = SettingsProposalReview(id: id(file), proposal: proposal, state: state, folder: file.folder,
                                                author: file.folder.map { map[$0] ?? $0 })
            if review.projects.isEmpty && review.skipped.isEmpty { try? manager.removeItem(at: file.url); continue }
            result.append(review)
        }
        return result
    }
    /// Removes one proposal file; true when it is gone afterwards. A decided proposal is continued only after its file
    /// is gone, so a restart can never show it again and a continuation is sent at most once. The id is `<name>` or
    /// `<folder>/<name>` and never reaches outside the inbox: no `..`, no deeper path, no hidden name, no linked folder.
    @discardableResult public static func remove(_ id: String, directory: URL = directory) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let name = parts.last, !name.isEmpty, !name.hasPrefix(".") else { return false }
        var parent = directory
        if parts.count == 2 {
            guard isFolderName(parts[0]) else { return false }
            parent = directory.appendingPathComponent(parts[0], isDirectory: true)
            // `attributesOfItem` does not follow a link; a missing folder means the file is gone.
            guard let type = (try? FileManager.default.attributesOfItem(atPath: parent.path))?[.type] as? FileAttributeType else { return true }
            guard type == .typeDirectory else { return false }
        }
        let file = parent.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
        return (try? FileManager.default.attributesOfItem(atPath: file.path)) == nil
    }
    /// How a chat writes a proposal, shared by every provider whose sessions can write to the inbox. Without
    /// `sharedChatVariable` the variable names the chat's own folder and the app knows the author, so the format has no
    /// `chat`. With it (a process that writes to the shared root) `chat` is required and holds that variable's value.
    public static func instructions(sharedChatVariable: String? = nil, language: AppLanguage = L10n.language) -> String {
        let presets = AccessPresetCatalog.all.map(\.id).joined(separator: ", ")
        let chat = sharedChatVariable.map { #""chat": "<$"# + $0 + #">", "# } ?? ""
        let format = "{" + chat + #""reason": "...", "changes": [{"project": "<project path or name>", "addPresets": ["vercel"], "removePresets": [], "addFolders": [{"path": "~/path", "writable": false}], "removeFolders": [], "addCommands": ["zsh scripts/build.sh"], "removeCommands": [], "addKeychainItems": [{"service": "example-api", "account": "me"}], "removeKeychainItems": [], "sandbox": true}]}"#
        let author = sharedChatVariable.map { variable in L10n.text(
            "- Поле `chat` ОБЯЗАТЕЛЬНО: впиши значение `$\(variable)`. Без него приложение не знает, какой чат просит, и после решения пользователя задача сама не продолжится.",
            "- The `chat` field is REQUIRED: put the value of `$\(variable)` there. Without it the app does not know which chat asks, and the task will not continue by itself after the user decides.",
            language: language) } ?? L10n.text(
            "- Эта папка принадлежит этому чату: приложение само знает, какой чат просит, поле `chat` не нужно.",
            "- This folder belongs to this chat: the app knows which chat asks, so no `chat` field is needed.",
            language: language)
        return L10n.text(
            """
            Настройки проектов в Switchboard (песочница команд, наборы доступа, папки вне проекта, команды вне песочницы, записи Связки ключей) меняет только пользователь. Если задаче нужен доступ, которого нет, или пользователь просит изменить эти настройки, предложи изменение:
            - Запиши один JSON-файл в папку "$\(environmentKey)" (она доступна на запись в песочнице), например "$\(environmentKey)/<короткое-имя>.json". Формат: \(format). Пропускай ненужные поля; в одном файле может быть несколько проектов. Причина (`reason`) - до \(SettingsProposalReview.maximumText) символов, остальное обрезается.
            \(author)
            - Наборы: \(presets).
            \(boundaryCommandRule(language: .russian))
            \(keychainItemRule(language: .russian))
            - Приложение покажет пользователю список изменений в этом чате; применит их только он. Скажи пользователю, что предложение ждёт его решения. Предлагай только то, что нужно задаче; команды вне песочницы получают доступ ко всему Mac.
            - Когда пользователь решит, этот чат получит сообщение от приложения. До тех пор продолжай независимую часть задачи.
            """,
            """
            Project settings in Switchboard (the command sandbox, access sets, folders outside the project, commands outside the sandbox, Keychain items) are changed only by the user. When the task needs access that is missing, or the user asks to change these settings, propose the change:
            - Write one JSON file into the folder "$\(environmentKey)" (writable inside the sandbox), for example "$\(environmentKey)/<short-name>.json". Format: \(format). Omit fields you do not need; one file may cover several projects. Keep `reason` within \(SettingsProposalReview.maximumText) characters; the rest is cut.
            \(author)
            - Sets: \(presets).
            \(boundaryCommandRule(language: .english))
            \(keychainItemRule(language: .english))
            - The app shows the user the list of changes in this chat; only the user applies them. Tell the user the proposal waits for their decision. Propose only what the task needs; commands outside the sandbox get access to the whole Mac.
            - When the user decides, this chat receives a message from the app. Until then continue the independent part of the task.
            """, language: language)
    }
    /// Under the external boundary a trusted command stays inside (PERMISSIONS.md, section 1); shared with the Claude
    /// boundary instructions.
    public static func boundaryCommandRule(language: AppLanguage = L10n.language) -> String {
        L10n.text("- Под внешней границей (`SWITCHBOARD_EXTERNAL_SANDBOX=1`) `addCommands` не выводит команду наружу: она всё равно выполняется внутри. Для записи Связки ключей запрашивай `addKeychainItems`, для учётных данных или сетевой идентичности - набор доступа с командой-посредником (`addPresets`), но не доверенную команду.",
                  "- Under the external boundary (`SWITCHBOARD_EXTERNAL_SANDBOX=1`) `addCommands` does not take a command outside: it still runs inside. For a Keychain item request `addKeychainItems`; for a credential or a network identity, an access set with a mediated command (`addPresets`); never a trusted command.",
                  language: language)
    }
    /// How a project script reads a granted Keychain item under the external boundary, and the one request when it is missing.
    public static func keychainItemRule(language: AppLanguage = L10n.language) -> String {
        L10n.text("- Под внешней границей `security` читает только записи Связки ключей, перечисленные в настройках проекта, в форме `security find-generic-password -s <сервис> [-a <учётная запись>] -w`, вызванной по имени (не `/usr/bin/security`). Отказ «command policy denied security» значит, что записи нет в списке: запиши одно предложение с `addKeychainItems` (точный сервис и учётная запись, без шаблонов) и причиной. Никогда не выводи секрет в ответ, файл или журнал.",
                  "- Under the external boundary `security` reads only the Keychain items listed in the project settings, in the form `security find-generic-password -s <service> [-a <account>] -w`, called by name (not `/usr/bin/security`). A \"command policy denied security\" refusal means the item is not listed: write one proposal with `addKeychainItems` (exact service and account, no wildcards) and the reason. Never print the secret into a reply, a file or a log.",
                  language: language)
    }
    private static func date(_ file: URL) -> Date? { try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}
