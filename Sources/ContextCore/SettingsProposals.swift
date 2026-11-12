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
        public init(project: String) { self.project = project }
    }
    /// The proposing chat's session ID (`SWITCHBOARD_CHAT_ID` for Claude, `CODEX_THREAD_ID` for Codex). Agent-written: it only
    /// chooses where the request card is shown; the message that chat later receives is fixed app text.
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
        public var isEmpty: Bool {
            sandbox == nil && addPresets.isEmpty && removePresets.isEmpty && addFolders.isEmpty && removeFolders.isEmpty
                && addCommands.isEmpty && removeCommands.isEmpty
        }
    }
    /// The file name in the inbox.
    public var id: String
    public var chat: String?
    public var reason: String?
    public var projects: [ProjectDiff]
    /// Parts that were dropped, in the user's language (unknown project, relative path, unknown set).
    public var skipped: [String]

    static let maximumText = 300

    public init(id: String, proposal: SettingsProposal, state: SavedState, home: String = NSHomeDirectory()) {
        self.id = id
        chat = proposal.chat.map { String($0.prefix(80)) }
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
            if let index = projects.firstIndex(where: { $0.projectID == project.id }) { projects[index] = diff } else { projects.append(diff) }
        }
        self.projects = projects.filter { !$0.isEmpty }
        self.skipped = skipped
    }

    /// The app chat the proposal names: an existing, unarchived, interactive chat whose agent session ID (or app chat ID)
    /// equals `chat`. Nil otherwise; such a proposal stays a global review. The label is agent-written, so it only picks
    /// where the card is shown: the chat later receives fixed app text (`SettingsProposalOutcome.message`), never its strings.
    public func requestingChat(in chats: [Chat]) -> Chat? {
        guard let label = chat, !label.isEmpty else { return nil }
        return chats.first { chat in
            !chat.isArchived && !chat.isScheduledRecord && (chat.nativeSession?.nativeID == label || chat.id == label)
        }
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
            if project != projects[index] { projects[index] = project; changed = true }
        }
        return changed
    }
}

/// The user's decision on a proposal, and the one fixed message the requesting chat receives for it. The message never
/// carries text from the proposal (paths, commands, reason): any chat can name another chat in its proposal.
public enum SettingsProposalOutcome: Sendable {
    case applied, rejected
    public func message(language: AppLanguage = L10n.language) -> String {
        switch self {
        case .applied: L10n.text(
            "Switchboard: пользователь применил твой запрос на изменение настроек проекта. Новые права действуют с этого сообщения. Повтори шаг, которому не хватало доступа, и продолжай задачу.",
            "Switchboard: the user applied your project settings request. The new access applies from this message. Retry the step that lacked access and continue the task.",
            language: language)
        case .rejected: L10n.text(
            "Switchboard: пользователь отклонил твой запрос на изменение настроек проекта. Не ищи другой способ получить тот же доступ. Продолжай независимую часть задачи или сообщи, что без этого доступа задача заблокирована.",
            "Switchboard: the user rejected your project settings request. Do not look for another way to get the same access. Continue the independent part of the task, or report that the task is blocked without this access.",
            language: language)
        }
    }
}

/// The folder agents write proposals to (writable inside every command sandbox) and its reader.
public enum SettingsProposalInbox {
    public static let environmentKey = "SWITCHBOARD_SETTINGS_PROPOSALS"
    public static var directory: URL { Locations.root.appendingPathComponent("settings-proposals", isDirectory: true) }
    static let maximumFiles = 20, maximumSize = 64 * 1024

    /// Pending proposals, oldest first. Unreadable or oversized files and proposals that change nothing are removed.
    public static func load(state: SavedState, directory: URL = directory, manager: FileManager = .default) -> [SettingsProposalReview] {
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { (date($0) ?? .distantPast, $0.lastPathComponent) < (date($1) ?? .distantPast, $1.lastPathComponent) }
        var result: [SettingsProposalReview] = []
        for file in files.prefix(maximumFiles) {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= maximumSize,
                  let data = try? Data(contentsOf: file), let proposal = try? JSONDecoder().decode(SettingsProposal.self, from: data) else {
                try? manager.removeItem(at: file); continue
            }
            let review = SettingsProposalReview(id: file.lastPathComponent, proposal: proposal, state: state)
            if review.projects.isEmpty && review.skipped.isEmpty { try? manager.removeItem(at: file); continue }
            result.append(review)
        }
        return result
    }
    /// Removes one proposal file; true when it is gone afterwards. A decided proposal is continued only after its file
    /// is gone, so a restart can never show it again and a continuation is sent at most once.
    @discardableResult public static func remove(_ id: String, directory: URL = directory) -> Bool {
        guard !id.contains("/"), !id.hasPrefix(".") else { return false }
        let file = directory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: file)
        return !FileManager.default.fileExists(atPath: file.path)
    }
    /// How a chat writes a proposal, shared by every provider whose sessions can write to the inbox. `chatVariable` is the
    /// environment variable that holds the chat's own session ID in its commands (`SWITCHBOARD_CHAT_ID`, `CODEX_THREAD_ID`).
    public static func instructions(chatVariable: String, language: AppLanguage = L10n.language) -> String {
        let presets = AccessPresetCatalog.all.map(\.id).joined(separator: ", ")
        let format = #"{"chat": "<$"# + chatVariable + #">", "reason": "...", "changes": [{"project": "<project path or name>", "addPresets": ["vercel"], "removePresets": [], "addFolders": [{"path": "~/path", "writable": false}], "removeFolders": [], "addCommands": ["zsh scripts/build.sh"], "removeCommands": [], "sandbox": true}]}"#
        return L10n.text(
            """
            Настройки проектов в Switchboard (песочница команд, наборы доступа, папки вне проекта, команды вне песочницы) меняет только пользователь. Если задаче нужен доступ, которого нет, или пользователь просит изменить эти настройки, предложи изменение:
            - Запиши один JSON-файл в папку "$\(environmentKey)" (она доступна на запись в песочнице), например "$\(environmentKey)/<короткое-имя>.json". Формат: \(format). Пропускай ненужные поля; в одном файле может быть несколько проектов.
            - Наборы: \(presets).
            - Приложение покажет пользователю список изменений в этом чате; применит их только он. Скажи пользователю, что предложение ждёт его решения. Предлагай только то, что нужно задаче; команды вне песочницы получают доступ ко всему Mac.
            - Когда пользователь решит, этот чат получит сообщение от приложения. До тех пор продолжай независимую часть задачи.
            """,
            """
            Project settings in Switchboard (the command sandbox, access sets, folders outside the project, commands outside the sandbox) are changed only by the user. When the task needs access that is missing, or the user asks to change these settings, propose the change:
            - Write one JSON file into the folder "$\(environmentKey)" (writable inside the sandbox), for example "$\(environmentKey)/<short-name>.json". Format: \(format). Omit fields you do not need; one file may cover several projects.
            - Sets: \(presets).
            - The app shows the user the list of changes in this chat; only the user applies them. Tell the user the proposal waits for their decision. Propose only what the task needs; commands outside the sandbox get access to the whole Mac.
            - When the user decides, this chat receives a message from the app. Until then continue the independent part of the task.
            """, language: language)
    }
    private static func date(_ file: URL) -> Date? { try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}
