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
        // Validate configuration only; importing a handoff must not read an existing session.
        _ = try RemoteAPI(url: setup.url, key: setup.key, storage: .init(read: { _ in nil }, write: { _, _ in }))
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
    public var agentTitle: String { Self.agentTitle(agent) }
    public static func agentTitle(_ agent: String?) -> String { agent == claudeAgent ? "Claude" : "Codex" }
}
public struct RemoteChatOptions: Codable, Sendable, Equatable {
    public static let addOnLimit = 8
    public var model: String
    /// nil inherits the project's interactive default without changing it.
    public var access: RemoteAccessMode?
    /// Role id (v2 phones); wins over `access`. Never above the project's default: the Mac rejects anything higher.
    /// Sending it needs the interactions schema (`RemoteAPI.checkInteractionSchema`).
    public var role: String?
    /// Role add-on ids (`RemoteAddOnOption.id`). In a chat's published settings: the add-ons the chat runs with now.
    /// In a `configure` change, nil leaves the chat's add-ons unchanged (older phones never send it); in `create`, nil follows
    /// the project's add-ons. Sending it needs the interactions schema.
    public var addOns: [String]?
    public init(model: String, access: RemoteAccessMode? = nil, role: String? = nil, addOns: [String]? = nil) {
        self.model = model; self.access = access; self.role = role; self.addOns = addOns
    }
    public func validate() throws {
        guard !model.isEmpty, model.utf8.count <= 200 else { throw RemoteFailure.invalidCommand }
        if let role { guard !role.isEmpty, role.utf8.count <= 200 else { throw RemoteFailure.invalidCommand } }
        if let addOns {
            guard addOns.count <= Self.addOnLimit, Set(addOns).count == addOns.count,
                  addOns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { throw RemoteFailure.invalidCommand }
        }
    }
    /// The stale check of a settings change: `self` is what the phone saw. A phone that did not send add-ons
    /// (older builds) is compared without them; add-ons compare as a set.
    public func matches(current: RemoteChatOptions) -> Bool {
        guard model == current.model, access == current.access, role == current.role else { return false }
        guard let addOns else { return true }
        return Set(addOns) == Set(current.addOns ?? [])
    }
    /// Uses fields that only the interactions schema accepts in the cloud queue.
    var needsInteractionSchema: Bool { role != nil || addOns != nil }
}
public struct RemoteChatSettings: Codable, Sendable, Equatable {
    public var options: RemoteChatOptions
    public var projectAccess: RemoteAccessMode
    public var canEdit: Bool
    /// Additive for v2 phones: the project's default role and the roles the phone may pick (never above it).
    public var projectRole: String?
    public var roles: [RemoteRoleOption]?
    /// Add-ons the phone may turn on or off here: those within the project's default plus the ones already on.
    /// Absent on older hosts (no add-on choice). `options.addOns` holds the current ones.
    public var addOns: [RemoteAddOnOption]?
    /// The project's default add-ons for new chats.
    public var projectAddOns: [String]?
    public init(options: RemoteChatOptions, projectAccess: RemoteAccessMode, canEdit: Bool, projectRole: String? = nil, roles: [RemoteRoleOption]? = nil,
                addOns: [RemoteAddOnOption]? = nil, projectAddOns: [String]? = nil) {
        self.options = options; self.projectAccess = projectAccess; self.canEdit = canEdit; self.projectRole = projectRole; self.roles = roles
        self.addOns = addOns; self.projectAddOns = projectAddOns
    }
}
public struct RemoteRoleOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
/// A role add-on ("Mail and connectors", "My Chrome"): widens a chat's role without switching it.
public struct RemoteAddOnOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String?
    /// SF Symbol the desktop role chip shows for it.
    public var symbol: String?
    public init(id: String, name: String, summary: String? = nil, symbol: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.symbol = symbol
    }
}
/// One add-on toggle of the phone's role picker.
public struct RemoteAddOnChoice: Sendable, Equatable, Identifiable {
    public var option: RemoteAddOnOption
    public var isOn: Bool
    /// The phone may turn it on; turning an add-on off is always allowed.
    public var canTurnOn: Bool
    /// On at the Mac but not granted by the project default: once it is off there, only the Mac can turn it on again.
    public var outsideDefault: Bool
    public var id: String { option.id }
    public init(option: RemoteAddOnOption, isOn: Bool, canTurnOn: Bool, outsideDefault: Bool) {
        self.option = option; self.isOn = isOn; self.canTurnOn = canTurnOn; self.outsideDefault = outsideDefault
    }
}
extension RemoteChatSettings {
    /// The phone's add-on rule, from what the host published: `addOns` lists the selectable ones, `options.addOns` the ones on
    /// at the Mac now. A phone may turn on only add-ons the project default grants (`granted`: the project's published
    /// `addOns`; nil when these settings are the project's own, which list only granted ones) or the ones on now,
    /// and may always turn off the ones that are on. `selected` is the edited choice.
    public func addOnChoices(selected: [String], granted: [String]? = nil) -> [RemoteAddOnChoice] {
        let current = Set(options.addOns ?? [])
        let listed = addOns ?? []
        let unlisted = selected.filter { id in !listed.contains { $0.id == id } }.map { RemoteAddOnOption(id: $0, name: $0) }
        return (listed + unlisted).map { option in
            let isGranted = listed.contains(option) && (granted?.contains(option.id) ?? true)
            return RemoteAddOnChoice(option: option, isOn: selected.contains(option.id), canTurnOn: isGranted || current.contains(option.id),
                                     outsideDefault: !isGranted && current.contains(option.id))
        }
    }
    /// `selected` with one add-on switched, in the published order. Turning on an add-on the rule refuses changes nothing.
    public func addOns(_ selected: [String], setting id: String, on: Bool, granted: [String]? = nil) -> [String] {
        let choices = addOnChoices(selected: selected, granted: granted)
        if on, choices.first(where: { $0.id == id })?.canTurnOn != true { return selected }
        let next = on ? Set(selected).union([id]) : Set(selected).subtracting([id])
        return choices.map(\.id).filter(next.contains)
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
    /// The Mac can start an archive search (`RemoteCommand.search`). Web client only; absent on older hosts.
    public var canSearchChats: Bool?
    /// The cloud schema and the Mac carry web chats (`remote_web_version`). Absent on older hosts.
    public var canUseWeb: Bool?
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
    /// The agent running this chat (`RemoteModelOption.codexAgent` or `.claudeAgent`); nil on older hosts and for a chat
    /// whose agent session has not started yet. A string, so a future agent never breaks snapshot decoding.
    public var agent: String?
    /// The running turn's current action ("Bash · npm test") or agent status; nil when idle or on older hosts.
    public var activity: String?
    /// ISO 8601 start of the running turn; nil when idle or on older hosts.
    public var runningSince: String?
    /// Pending questions and tool forms (not approvals); nil on older hosts. At most `RemoteInteraction.chatLimit`.
    public var interactions: [RemoteInteraction]?
    /// The chat's desktop queue in delivery order, at most `RemoteQueuedMessage.chatLimit`; nil on older hosts or when empty.
    public var queue: [RemoteQueuedMessage]?
    /// All queued messages, when more than `queue` lists.
    public var queueCount: Int?
    /// The queue waits for the user on the Mac (after a stop or a failed turn); new messages join it and wait too.
    public var queuePaused: Bool?
    /// The Mac accepts `RemoteCommand.queue` for this chat: the message joins the desktop queue and runs after the current turn.
    public var canQueue: Bool?
    /// The Mac accepts `RemoteCommand.interruptAndSend` for the running `turn` now.
    public var canInterrupt: Bool?
    /// A web chat (`WebChats`): the web client lists only these and reads their full text from `remote_web_messages`.
    public var web: Bool?
    /// Messages of a web chat in `remote_web_messages`.
    public var webMessages: Int?
    /// An archive-search chat; its answers carry `switchboard-chat:<id>` links the web can restore.
    public var chatSearch: Bool?
    public static let activityLimit = 160
    public init(id: String, project: String, title: String, running: Bool, messages: [RemoteMessage], approvals: [RemoteApproval], turn: String? = nil) { self.id = id; self.project = project; self.title = title; self.running = running; self.messages = messages; self.approvals = approvals; self.turn = turn; supportsPhotos = true }
    public static var readOnlyNotice: String {
        L10n.text("Запись запуска задания Claude — только для чтения. Чтобы продолжить, начни новый чат.",
                  "A Claude scheduled run record is read-only. Start a new chat to follow up.")
    }
}
extension RemoteChat {
    /// Agent messages that end a reply: the last one before the user's next message, or the chat's last one once the
    /// turn is over. Only these get Copy and Share; the agent's progress notes in between do not.
    public var answerEnds: Set<String> {
        var ends = Set<String>()
        for (index, message) in messages.enumerated() where message.role != "user" {
            let next = messages.index(after: index)
            if next < messages.endIndex ? messages[next].role == "user" : !running { ends.insert(message.id) }
        }
        return ends
    }

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
/// A bounded generated-image preview. Contains bytes, never a local path or remote URL.
public struct RemoteMessageImage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var data: String
    public init(id: String, name: String, mimeType: String, data: String) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.data = data
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
    public var images: [RemoteMessageImage]?
    public var imageError: Bool?
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
    /// A persistent project settings request rather than a one-time tool approval. Absent on older hosts.
    public var projectSettings: Bool?
    public init(id: String, details: String, canAllow: Bool, projectSettings: Bool? = nil) {
        self.id = id; self.details = details; self.canAllow = canAllow; self.projectSettings = projectSettings
    }
}
/// A pending structured question or tool form, as the desktop's request card shows it. Approvals stay in `RemoteApproval`.
/// Agent text is data. When the phone cannot show the request faithfully, `canAnswer` is false and `macOnly` says why:
/// the phone then shows "answer on the Mac" instead of a reduced form.
public struct RemoteInteraction: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case questions, form, link, unsupported }
    /// Why the request can be answered only on the Mac. Codes stay stable; `message` owns the wording.
    public enum MacOnly: String, Sendable, CaseIterable {
        /// A field asks for a secret; secrets never pass through the cloud queue.
        case secret
        /// Text or option lists exceed the phone limits; a shortened form could send a different answer.
        case tooLarge
        /// The tool's form uses restrictions the app does not support (the desktop can only decline it).
        case unsupported
        /// The tool asks to finish an action on its web page, next to the Mac's session.
        case link
        /// The cloud schema or the Mac app predates phone answers.
        case setup
        public func message(language: AppLanguage = L10n.language) -> String {
            switch self {
            case .secret: L10n.text("Запрос просит секрет. Ответь на Mac: секреты не передаются через облако.", "The request asks for a secret. Answer on the Mac: secrets are never sent through the cloud.", language: language)
            case .tooLarge: L10n.text("Запрос слишком длинный для телефона. Ответь на Mac.", "The request is too long for the phone. Answer on the Mac.", language: language)
            case .unsupported: L10n.text("Такую форму можно только отклонить или заполнить на Mac.", "This form can only be declined here or answered on the Mac.", language: language)
            case .link: L10n.text("Инструмент просит завершить действие на его странице. Сделай это на Mac.", "The tool asks you to finish an action on its page. Do it on the Mac.", language: language)
            case .setup: L10n.text("Чтобы отвечать с телефона, обнови приложение на Mac и схему мобильного доступа в Supabase.", "To answer from the phone, update the Mac app and the Supabase mobile access schema.", language: language)
            }
        }
    }
    public static let chatLimit = 4
    public static let questionLimit = 8, optionLimit = 12
    public static let textLimit = 2000, headerLimit = 200, labelLimit = 300, descriptionLimit = 600, previewLimit = 1500, messageLimit = 4000
    /// All text of one request; above it descriptions and previews are dropped and the request is Mac-only.
    public static let characterBudget = 16_000
    /// One answer value, in UTF-8 bytes.
    public static let answerBytes = 8000
    /// Pending request handle; the answer command carries it in `RemoteCommand.approval`.
    public var id: String
    /// `Kind` raw value; kept a string so a future kind never breaks snapshot decoding.
    public var kind: String
    /// The form's or link's own message; nil for questions.
    public var message: String?
    public var questions: [RemoteQuestion]
    /// The phone may submit `RemoteCommand.answer` for it.
    public var canAnswer: Bool
    /// The phone may submit `RemoteCommand.decline` (the desktop's Decline button). Questions have none, as on the desktop.
    public var canDecline: Bool
    /// `MacOnly` raw value when `canAnswer` is false.
    public var macOnly: String?
    public var kindValue: Kind? { Kind(rawValue: kind) }
    public var macOnlyReason: MacOnly? { macOnly.flatMap(MacOnly.init(rawValue:)) }
    /// What the phone shows instead of a form; a generic Mac hint for codes from newer hosts.
    public var macOnlyMessage: String? {
        guard !canAnswer else { return nil }
        return macOnlyReason?.message() ?? L10n.text("Ответь на Mac.", "Answer on the Mac.")
    }
    public init(id: String, kind: Kind, message: String? = nil, questions: [RemoteQuestion], canAnswer: Bool, canDecline: Bool, macOnly: MacOnly? = nil) {
        self.id = id; self.kind = kind.rawValue; self.message = message; self.questions = questions
        self.canAnswer = canAnswer; self.canDecline = canDecline; self.macOnly = macOnly?.rawValue
    }
    /// Characters of all agent text, for `characterBudget`.
    var characters: Int {
        (message?.count ?? 0) + questions.reduce(0) { total, question in
            total + question.id.count + question.text.count + (question.header?.count ?? 0)
                + question.options.reduce(0) { $0 + $1.label.count + ($1.description?.count ?? 0) + ($1.preview?.count ?? 0) }
        }
    }
    /// Marks the request Mac-only, e.g. while the cloud schema cannot carry answers.
    public mutating func requireMac(_ reason: MacOnly) {
        guard canAnswer else { return }
        canAnswer = false; macOnly = reason.rawValue
    }
    /// The answers the Mac accepts: one value per answered question (an option's exact `label`, or free text where
    /// `allowsOther`), every required question answered, and for `questions` every question. Throws `invalidAnswer`.
    public func validate(answers: [String: String]) throws {
        guard canAnswer, kindValue == .questions || kindValue == .form else { throw RemoteFailure.invalidCommand }
        let ids = Set(questions.map(\.id))
        guard Set(answers.keys).isSubset(of: ids), kindValue != .questions || Set(answers.keys) == ids else { throw RemoteFailure.invalidAnswer }
        for question in questions {
            let value = answers[question.id]
            let blank = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !question.required || !blank, (value?.utf8.count ?? 0) <= Self.answerBytes, value?.contains("\0") != true else { throw RemoteFailure.invalidAnswer }
            if let value, !blank, !question.allowsOther, !question.options.isEmpty {
                guard question.options.contains(where: { $0.label == value }) else { throw RemoteFailure.invalidAnswer }
            }
        }
    }
}
public struct RemoteQuestion: Codable, Identifiable, Sendable, Equatable {
    /// The answer key; send it back unchanged.
    public var id: String
    /// Short label shown above the question (Claude and Codex "header"); nil when the agent sent none.
    public var header: String?
    public var text: String
    public var options: [RemoteQuestionOption]
    /// Several options may be chosen. Never true today: the Mac declines multi-select questions before they reach any UI.
    public var multiSelect: Bool?
    /// A free-text answer is accepted besides the options ("Other"), as the desktop's answer field allows.
    public var allowsOther: Bool
    /// The desktop masks the field; such a request is Mac-only.
    public var secret: Bool?
    public var required: Bool
    public init(id: String, header: String? = nil, text: String, options: [RemoteQuestionOption], multiSelect: Bool? = nil,
                allowsOther: Bool = true, secret: Bool? = nil, required: Bool) {
        self.id = id; self.header = header; self.text = text; self.options = options; self.multiSelect = multiSelect
        self.allowsOther = allowsOther; self.secret = secret; self.required = required
    }
}
public struct RemoteQuestionOption: Codable, Sendable, Equatable {
    /// The value sent back when the option is chosen.
    public var label: String
    public var description: String?
    /// Longer agent text (often code) the desktop shows for the selected option.
    public var preview: String?
    public init(label: String, description: String? = nil, preview: String? = nil) { self.label = label; self.description = description; self.preview = preview }
}
/// One message waiting in a chat's desktop queue.
public struct RemoteQueuedMessage: Codable, Identifiable, Sendable, Equatable {
    public static let chatLimit = 10
    public static let textLimit = 500
    /// Desktop queue identity (not a command ID).
    public var id: String
    public var text: String
    public var truncated: Bool?
    /// The phone command that queued it; nil for messages typed on the Mac or queued by the app.
    public var command: String?
    /// The Mac is sending it now or chose it for "Interrupt and send"; it can no longer change.
    public var claimed: Bool?
    public init(id: String, text: String, command: String? = nil, claimed: Bool? = nil) {
        self.id = id; self.command = command; self.claimed = claimed
        self.text = String(text.prefix(Self.textLimit))
        if text.count > Self.textLimit { truncated = true }
    }
}
/// Web client chats (`docs/web-client-plan.md`). Their full text lives in `remote_web_messages`; the cloud keeps a chat
/// for `retention` after its last activity, the Mac keeps it for good.
public enum WebChats {
    public static let prefix = "web:"
    public static let retention: TimeInterval = 15 * 24 * 60 * 60
    /// The cloud keeps this many latest messages of a chat.
    public static let messageLimit = 500
    public static let searchLimit = 2000
    /// Web chats listed in the snapshot beside the phone's chats.
    public static let snapshotLimit = 40
    /// Clipped messages that a web chat outside the phone's list carries in the snapshot.
    public static let snapshotMessages = 4
    /// Encoded message bytes per upload call.
    public static let chunkBytes = 1_000_000
    /// Last activity of a web chat; nil for other chats.
    public static func lastActive(updated: Date, webSince: Date?) -> Date? { webSince.map { max($0, updated) } }
    public static func isVisible(updated: Date, webSince: Date?, archived: Bool, now: Date = Date()) -> Bool {
        guard !archived, let active = lastActive(updated: updated, webSince: webSince) else { return false }
        return now.timeIntervalSince(active) < retention
    }
    /// Order numbers for a chat's messages that keep the ones already published (`previous`, message ID -> seq), so an
    /// appended message or older messages leaving the window do not renumber the rest. Always strictly increasing.
    public static func sequence(_ ids: [String], previous: [String: Int]) -> [Int] {
        var result: [Int] = [], last = -1
        for id in ids {
            if let seq = previous[id], seq > last { last = seq } else { last += 1 }
            result.append(last)
        }
        return result
    }
    /// Upload batches: each stays under `chunkBytes` of text (a single larger message goes alone).
    public static func chunks(_ messages: [RemoteWebMessage]) -> [[RemoteWebMessage]] {
        var result: [[RemoteWebMessage]] = [], current: [RemoteWebMessage] = [], bytes = 0
        for message in messages {
            let size = (try? JSONEncoder().encode(message).count) ?? chunkBytes
            if !current.isEmpty, bytes + size > chunkBytes { result.append(current); current = []; bytes = 0 }
            current.append(message); bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
#if !os(iOS)
extension Chat {
    /// Started from the web client: such chats keep the `web:` ID they were created with.
    public var startedOnWeb: Bool { id.hasPrefix(WebChats.prefix) }
}
#endif
/// One message of a web chat, full text up to `textLimit` characters.
public struct RemoteWebMessage: Codable, Sendable, Hashable {
    public static let textLimit = 100_000
    public var id: String
    public var seq: Int
    public var role: String
    public var text: String
    public var truncated: Bool?
    public var images: [RemoteMessageImage]?
    public var imageError: Bool?
    public init(id: String, seq: Int, role: String, fullText: String) {
        self.id = id; self.seq = seq; self.role = role
        if fullText.count > Self.textLimit { text = RemoteMessage.clip(fullText, limit: Self.textLimit); truncated = true }
        else { text = fullText }
    }
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
    /// `answer` only: question id -> answer (an option's label or free text). Needs the interactions schema.
    public var answers: [String: String]?
    /// Kinds that bring a message to the agent; the cloud queue runs them one at a time per chat.
    public static let messageKinds: Set<String> = ["send", "create", "queue", "interrupt"]
    /// Kinds that only the interactions schema (`remote_interactions_version`) accepts.
    public static let interactionKinds: Set<String> = ["answer", "queue", "interrupt"]
    /// Kinds that only the web schema (`remote_web_version`) accepts: bring a chat back to the web, start an archive search.
    public static let webKinds: Set<String> = ["restore", "search"]
    /// Existing text column: a client explicitly confirms persistent settings, never an old "Allow once" button.
    public static let projectSettingsDecision = "project-settings"
    public static let kinds = Set(["send", "stop", "allow", "deny", "create", "configure", "file"]).union(interactionKinds).union(webKinds)
    /// Uses the existing immutable send envelope and queue; no database migration required.
    /// The first send owns the new app ID. Later sends cannot recreate a missing conversation.
    public var createsChat: Bool {
        (["send", "create"].contains(kind) && chat == "mobile:" + id.lowercased()) || createsWebChat
    }
    /// A web client's new chat or archive search: the chat is a web chat from the start.
    public var createsWebChat: Bool { ["create", "search"].contains(kind) && chat == WebChats.prefix + id.lowercased() }
    /// A new web chat; `options` as in `newChat`.
    public static func newWebChat(owner: String, device: String, project: String, text: String, options: RemoteChatOptions) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: "", kind: "create", text: text)
        command.chat = WebChats.prefix + command.id
        command.settings = RemoteSettingsChange(options: options)
        return command
    }
    /// Starts an archive-search chat (the archive's "Find with agent") as a web chat.
    public static func search(owner: String, device: String, project: String, query: String) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: "", kind: "search", text: query)
        command.chat = WebChats.prefix + command.id
        return command
    }
    /// Brings an existing chat back to the web (un-archiving it on the Mac).
    public static func restore(owner: String, device: String, project: String, chat: String) -> Self {
        Self(owner: owner, device: device, project: project, chat: chat, kind: "restore")
    }
    public static func newChat(owner: String, device: String, project: String, text: String, options: RemoteChatOptions? = nil) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: "", kind: options == nil ? "send" : "create", text: text)
        command.chat = "mobile:" + command.id
        command.settings = options.map { RemoteSettingsChange(options: $0) }
        return command
    }
    /// `options` is usually `expected.options` with the user's changes. Add-ons are sent only when they change and the
    /// host offers them (`expected.addOns`); otherwise both sides drop them, so the Mac leaves them as they are and a
    /// model-only change keeps working on a cloud schema without the interactions migration.
    public static func configure(owner: String, device: String, project: String, chat: String, options: RemoteChatOptions, expected: RemoteChatSettings) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: chat, kind: "configure")
        var options = options, seen = expected.options
        if expected.addOns == nil || options.addOns.map(Set.init) == seen.addOns.map(Set.init) || options.addOns == nil {
            options.addOns = nil; seen.addOns = nil
        } else if seen.addOns == nil { seen.addOns = [] }
        command.settings = RemoteSettingsChange(options: options, expected: seen, expectedProjectAccess: expected.projectAccess)
        return command
    }
    /// Answers a pending question or form (`RemoteInteraction`) with the exact request handle it was published with.
    /// The Mac rejects unknown, answered or changed requests and answers that `RemoteInteraction.validate(answers:)` refuses.
    public static func answer(owner: String, device: String, project: String, chat: String, interaction: String, answers: [String: String]) -> Self {
        var command = Self(owner: owner, device: device, project: project, chat: chat, kind: "answer", approval: interaction)
        command.answers = answers
        return command
    }
    /// The desktop's Decline for a form, link or unsupported request (`RemoteInteraction.canDecline`); an approval uses `deny` too.
    public static func decline(owner: String, device: String, project: String, chat: String, interaction: String) -> Self {
        Self(owner: owner, device: device, project: project, chat: chat, kind: "deny", approval: interaction)
    }
    /// Puts the message in the chat's desktop queue (`RemoteChat.canQueue`): it runs after the current turn, in queue order,
    /// exactly like a message typed on the Mac while the chat works. A paused queue keeps it waiting for the Mac.
    public static func queue(owner: String, device: String, project: String, chat: String, text: String, photos: [RemotePhoto] = []) -> Self {
        Self(owner: owner, device: device, project: project, chat: chat, kind: "queue", text: text, photos: photos)
    }
    /// The desktop's "Interrupt and send" (`RemoteChat.canInterrupt`): stops the observed `turn` and sends the message next,
    /// with the note that the previous turn was interrupted. Rejected when that turn is no longer the running one.
    public static func interruptAndSend(owner: String, device: String, project: String, chat: String, turn: String, text: String, photos: [RemotePhoto] = []) -> Self {
        Self(owner: owner, device: device, project: project, chat: chat, kind: "interrupt", text: text, turn: turn, photos: photos)
    }
    /// The cloud schema must have the interactions migration before this command can be queued.
    public var needsInteractionSchema: Bool {
        Self.interactionKinds.contains(kind) || settings.map { $0.options.needsInteractionSchema || $0.expected?.needsInteractionSchema == true } == true
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
              Self.kinds.contains(kind),
              !Self.messageKinds.contains(kind) || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(photos ?? []).isEmpty,
              !["allow", "deny", "answer"].contains(kind) || approval.flatMap(UUID.init(uuidString:)) != nil,
              (turn?.utf8.count ?? 0) <= 500
        else { throw RemoteFailure.invalidCommand }
        if kind == "answer" {
            guard let answers, answers.count <= RemoteInteraction.questionLimit, text.isEmpty, turn == nil, (photos ?? []).isEmpty, settings == nil,
                  answers.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= RemoteInteraction.textLimit * 4 && $0.value.utf8.count <= RemoteInteraction.answerBytes }),
                  answers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 24_000 else { throw RemoteFailure.invalidCommand }
        } else if answers != nil { throw RemoteFailure.invalidCommand }
        if kind == "interrupt" {
            guard let turn, !turn.isEmpty else { throw RemoteFailure.invalidCommand }
        }
        if kind == "queue" || kind == "interrupt" {
            guard approval == nil else { throw RemoteFailure.invalidCommand }
        }
        if Self.webKinds.contains(kind) {
            guard approval == nil, turn == nil, (photos ?? []).isEmpty, settings == nil,
                  kind == "restore" ? text.isEmpty : (createsWebChat && text.count <= WebChats.searchLimit
                      && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { throw RemoteFailure.invalidCommand }
        }
        if kind == "file" {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, text.utf8.count <= RemoteFile.pathLimit, !text.contains("\n"), !text.contains("\0"),
                  approval == nil, turn == nil, (photos ?? []).isEmpty, settings == nil else { throw RemoteFailure.invalidCommand }
        }
        let photos = photos ?? []
        guard photos.count <= RemotePhoto.maximumCount,
              photos.isEmpty || Self.messageKinds.contains(kind), Set(photos.map(\.id)).count == photos.count else { throw RemoteFailure.invalidPhoto }
        try photos.forEach { try $0.validate() }
        if ["create", "configure"].contains(kind) {
            guard let settings, approval == nil, turn == nil else { throw RemoteFailure.invalidCommand }
            try settings.options.validate()
            if kind == "create" {
                guard createsChat, settings.expected == nil, settings.expectedProjectAccess == nil else { throw RemoteFailure.invalidCommand }
            } else {
                guard text.isEmpty, photos.isEmpty, let expected = settings.expected, settings.expectedProjectAccess != nil,
                      // An add-on change is checked against the add-ons the phone saw.
                      settings.options.addOns == nil || expected.addOns != nil else { throw RemoteFailure.invalidCommand }
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
    case interactionSetup, invalidAnswer
    case realtimeSetup, realtimeProtocol, realtimeTimeout
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .invalidPhoto: L10n.text("Не удалось подготовить фото. Выбери до 4 изображений; каждое должно помещаться в 512 КБ после сжатия.", "Could not prepare photos. Choose up to 4 images; each must fit within 512 KB after compression.")
        case .photoSetup: L10n.text("Для отправки фото обнови схему мобильного доступа в Supabase (миграция photos).", "To send photos, update the Supabase mobile access schema (photos migration).")
        case .settingsSetup: L10n.text("Для выбора модели и доступа обнови схему мобильного доступа в Supabase и приложение на Mac.", "To choose a model and access mode, update the Supabase mobile access schema and Mac app.")
        case .interactionSetup: L10n.text("Чтобы отвечать на вопросы, ставить сообщения в очередь и выбирать роль с телефона, обнови схему мобильного доступа в Supabase (миграция interactions) и приложение на Mac.", "To answer questions, queue messages and choose roles from the phone, update the Supabase mobile access schema (interactions migration) and the Mac app.")
        case .invalidAnswer: L10n.text("Ответь на все обязательные вопросы. Ничего не отправлено.", "Answer every required question. Nothing was sent.")
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
/// A command submit failed in a way that proves the queue does not hold it.
public struct RemoteNotStored: Error, LocalizedError {
    public let cause: Error
    public var errorDescription: String? { cause.localizedDescription }
}
public enum RemoteVault {
    /// Pre-rename service name of the Supabase session: renaming it would mean copying the stored session secret.
    public static let defaultService = "ContextDesk.MobileRemote.v1"
    public static func read(_ account: String, service: String = defaultService) -> Data? {
        try? readChecked(account, service: service)
    }
    public static func readChecked(_ account: String, service: String = defaultService) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
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
    public static func save(_ data: Data?, account: String, service: String = defaultService) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
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
    /// Internal so feature extensions in other files (push devices) share authentication and error mapping.
    func request(_ path: String, method: String = "GET", body: Data? = nil, auth: Bool = true, prefer: String? = nil) async throws -> Data {
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
    /// Phone: questions, queue, interrupt-and-send, roles and add-ons need the interactions migration. Throws `interactionSetup`.
    public func checkInteractionSchema() async throws {
        guard try await supportsInteractions() else { throw RemoteFailure.interactionSetup }
    }
    /// Returns false when the cloud schema predates phone answers, queueing and role choices.
    public func supportsInteractions() async throws -> Bool {
        do {
            return try JSONDecoder().decode(Int.self, from: await request("rest/v1/rpc/remote_interactions_version", method: "POST", body: Data("{}".utf8))) == 1
        } catch RemoteFailure.request(404) { return false }
    }
    /// Returns false when the cloud schema predates web chats.
    public func supportsWeb() async throws -> Bool {
        do {
            return try JSONDecoder().decode(Int.self, from: await request("rest/v1/rpc/remote_web_version", method: "POST", body: Data("{}".utf8))) == 1
        } catch RemoteFailure.request(404) { return false }
    }
    public func supportsWebImages() async throws -> Bool {
        do {
            _ = try await request("rest/v1/remote_web_messages?select=images,imageError&limit=0")
            return true
        } catch RemoteFailure.request(400) { return false }
    }
    /// Mac side: upserts a web chat and `messages`; with `keep`, the cloud drops the chat's other messages.
    public func putWebChat(device: String, chat: String, active: Date, messages: [RemoteWebMessage], keep: [String]?) async throws {
        struct Body: Encodable { let device_id: String; let chat_id: String; let active: String; let messages: [RemoteWebMessage]; let keep: [String]? }
        guard UUID(uuidString: device) != nil, !chat.isEmpty, messages.count <= WebChats.messageLimit,
              (keep?.count ?? 0) <= WebChats.messageLimit else { throw RemoteFailure.invalidCommand }
        _ = try await request("rest/v1/rpc/put_remote_web_chat", method: "POST", body: JSONEncoder().encode(Body(
            device_id: device, chat_id: chat, active: ISO8601DateFormatter().string(from: active), messages: messages, keep: keep)))
    }
    /// Mac side: removes a web chat and its messages from the cloud.
    public func dropWebChat(device: String, chat: String) async throws {
        guard UUID(uuidString: device) != nil else { throw RemoteFailure.invalidCommand }
        _ = try await request("rest/v1/rpc/drop_remote_web_chat", method: "POST", body: JSONEncoder().encode(["device_id": device, "chat_id": chat]))
    }
    /// Web chats the cloud holds for this Mac.
    public func webChats(device: String) async throws -> [String] {
        struct Row: Decodable { let chat: String }
        guard UUID(uuidString: device) != nil else { throw RemoteFailure.invalidCommand }
        return try JSONDecoder().decode([Row].self, from: await request("rest/v1/remote_web_chats?select=chat&device=eq.\(device.lowercased())&limit=1000")).map(\.chat)
    }
    /// Every schema check the command needs, before a delivery receipt is saved: photos, chat settings, interactions.
    public func preflight(_ command: RemoteCommand) async throws {
        try command.validate()
        if !(command.photos ?? []).isEmpty { try await checkPhotoSchema() }
        if ["create", "configure"].contains(command.kind) { try await checkSettingsSchema() }
        if command.needsInteractionSchema { try await checkInteractionSchema() }
    }
    /// Throws `RemoteNotStored` only when the failure proves the queue does not hold the command;
    /// any other failure leaves the outcome unknown.
    public func submit(_ command: RemoteCommand) async throws {
        try command.validate()
        // Authenticate before sending: a failure here means nothing reached the server.
        do { _ = try await validSession() } catch { throw RemoteNotStored(cause: error) }
        do { _ = try await request("rest/v1/remote_commands", method: "POST", body: JSONEncoder().encode(command)) }
        // The ID is the primary key: a conflict means an earlier attempt with this command was stored.
        catch RemoteFailure.request(409) { return }
        // The server answered and rolled back the insert. Timeouts and 5xx stay unknown.
        catch RemoteFailure.request(let code) where (400..<500).contains(code) && code != 408 {
            throw RemoteNotStored(cause: RemoteFailure.request(code))
        }
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
