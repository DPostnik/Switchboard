import SwiftUI
import Foundation

/// Identifies one chat on one Mac: the scope of drafts, sends in flight, errors and delivery receipts.
struct MobileChatKey: Hashable, Sendable {
    let device: String
    let chat: String
    init(device: String, chat: String) { self.device = device.lowercased(); self.chat = chat }
    init(_ command: RemoteCommand) { self.init(device: command.device, chat: command.chat) }
}

@MainActor final class MobileModel: ObservableObject {
    @Published var url = UserDefaults.standard.string(forKey: "supabaseURL") ?? ""
    @Published var key = UserDefaults.standard.string(forKey: "supabaseKey") ?? ""
    @Published var email = ""
    @Published var password = ""
    @Published var devices: [RemoteDevice] = []
    @Published var commands: [RemoteCommand] = []
    /// Account and connection errors. Errors of one chat's commands live in `chatErrors`.
    @Published var status = ""
    @Published var connecting = false
    @Published var drafts: [String: String] = [:]
    @Published var photoDrafts: [String: [RemotePhoto]] = [:]
    /// Images dropped anywhere on a chat screen, keyed like `photoDrafts`; the chat's composer prepares them.
    @Published var photoDrops: [String: [NSItemProvider]] = [:]
    @Published var signedIn = false
    /// Commands whose queue insert is unconfirmed. Each blocks later commands in its own chat only.
    @Published private(set) var receipts = RemoteReceipts()
    /// Receipts the cloud lookup did not find after their send had ended.
    @Published private(set) var undelivered: Set<String> = []
    /// Chats (and new-chat projects) with a submission in flight.
    @Published private(set) var inFlight: Set<MobileChatKey> = []
    @Published private(set) var chatErrors: [MobileChatKey: String] = [:]
    /// Full unresolved commands, photos included; stored receipts omit photos. Memory only.
    private var unsentBodies: [String: RemoteCommand] = [:]
    var api: RemoteAPI?
    var receiptStorage: RemoteSessionStorage = .keychain
    @Published var connectionState: RemoteConnectionState = .stopped
    @Published var onlineMacs: Set<String> = []
    private var realtime: RemoteRealtime?
    private let updates = RemoteEventWork()
    private var dirtyDevices: Set<String> = []
    private var dirtyCommands: Set<String> = []
    private var needsFullSync = false
    private var active = false
    private var lifecycle = UUID()
    private let phoneID = UUID().uuidString.lowercased()
    #if targetEnvironment(simulator)
    var previewFiles: [String: RemoteFile] = [:]
    #endif

    // MARK: Per-chat state

    func receipt(_ key: MobileChatKey) -> RemoteCommand? { receipts.receipt(device: key.device, chat: key.chat) }
    /// A send, Stop, approval reply or settings change in this chat must wait.
    func isBlocked(_ key: MobileChatKey) -> Bool { inFlight.contains(key) || receipts.blocks(device: key.device, chat: key.chat) }
    func isSending(_ key: MobileChatKey) -> Bool { inFlight.contains(key) }
    func isUndelivered(_ receipt: RemoteCommand) -> Bool { undelivered.contains(receipt.id) }
    /// Sends the same command again. Its ID is the primary key, so the Mac can never receive it twice.
    func canResend(_ receipt: RemoteCommand) -> Bool { undelivered.contains(receipt.id) && unsentBodies[receipt.id] != nil }
    func clearError(_ key: MobileChatKey) { chatErrors[key] = nil }
    /// New-chat creations are keyed by project: a second creation there could duplicate an unconfirmed one.
    static func creationKey(device: String, project: String) -> MobileChatKey { MobileChatKey(device: device, chat: "create:" + project.lowercased()) }
    func creationReceipt(device: String, project: String) -> RemoteCommand? { receipts.creations(device: device, project: project).first }
    /// Unconfirmed new chats that the Mac has not published yet, for the list's "Needs you" group.
    var pendingCreations: [RemoteCommand] {
        receipts.commands.filter { command in
            command.createsChat && !devices.contains { $0.id.lowercased() == command.device.lowercased() && $0.snapshot.chats.contains { $0.id == command.chat } }
        }
    }

    // MARK: Connection

    func restoreConnection() async {
        guard !signedIn else { return }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") { loadPreview(); return }
        #endif
        do {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mobile-setup.json")
            if let setup = try RemoteSetup.consume(file) {
                url = setup.url; key = setup.key; email = setup.email; password = setup.password
            }
            if !url.isEmpty && !key.isEmpty { await connect() }
        } catch { status = error.localizedDescription }
    }
    func connect() async {
        guard !connecting, !signedIn else { return }
        connecting = true
        defer { connecting = false }
        do {
            let client = try RemoteAPI(url: url, key: key)
            if !password.isEmpty { try await client.signIn(email: email, password: password) }
            password = ""
            _ = try await client.owner()
            // Migrates the single receipt of earlier builds into its chat.
            let stored = try RemoteReceipts.load(from: receiptStorage)
            api = client; signedIn = true
            UserDefaults.standard.set(url, forKey: "supabaseURL"); UserDefaults.standard.set(key, forKey: "supabaseKey")
            receipts = stored
            startConnection()
        } catch { password = ""; status = error.localizedDescription }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { startConnection() }
        else {
            lifecycle = UUID(); realtime?.stop(); updates.cancel()
            dirtyDevices = []; dirtyCommands = []; onlineMacs = []
        }
    }
    func startConnection() {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") { return }
        #endif
        guard signedIn, active, let api else { return }
        if realtime == nil {
            let channel = RemoteRealtime(role: "phone", device: phoneID,
                credentials: { try await api.realtimeCredentials() }, ready: { [weak self] in
                    try await api.checkRealtimeSchema()
                    try await self?.synchronize()
                })
            realtime = channel
            channel.onState = { [weak self] value in
                guard let self else { return }
                connectionState = value
                if value == .connecting { lifecycle = UUID(); updates.cancel(); dirtyDevices = []; dirtyCommands = []; needsFullSync = false }
                if value == .connected { status = ""; requestUpdates() }
            }
            channel.onError = { [weak self] error in self?.status = error.localizedDescription }
            channel.onPresence = { [weak self] value in self?.onlineMacs = value.macs }
            channel.onChange = { [weak self] event in
                guard let self, active else { return }
                if event.entity == "device" { dirtyDevices.insert(event.device) }
                else if let id = event.command, UUID(uuidString: id) != nil { dirtyCommands.insert(id) }
                requestUpdates()
            }
        }
        realtime?.start()
    }
    private func synchronize() async throws {
        guard active, let api else { throw CancellationError() }
        let ticket = lifecycle
        let fetched = try await api.devices().filter { $0.snapshot.version == 1 }
        var updated: [RemoteCommand] = []
        for device in fetched { updated += try await api.commands(device: device.id) }
        // An uncertain command may be older than the bounded recent-command list.
        for receipt in receipts.commands where !updated.contains(where: { $0.id == receipt.id }) {
            if let found = try await api.command(id: receipt.id) { updated.append(found) }
        }
        try Task.checkCancellation()
        guard active, ticket == lifecycle, signedIn, self.api === api else { throw CancellationError() }
        for value in fetched {
            if let previous = devices.first(where: { $0.id == value.id }),
               (previous.revision ?? 0) > (value.revision ?? 0) { continue }
            if let index = devices.firstIndex(where: { $0.id == value.id }) { devices[index] = value }
            else { devices.append(value) }
        }
        devices.removeAll { value in !fetched.contains { $0.id == value.id } }
        commands = updated
        try resolveDelivery()
    }
    private func requestUpdates() {
        guard active, connectionState == .connected,
              needsFullSync || !dirtyDevices.isEmpty || !dirtyCommands.isEmpty else { return }
        updates.enqueue(delay: .milliseconds(40), operation: { [weak self] in
            try await self?.applyChanges()
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    private func applyChanges() async throws {
        guard active, let api else { throw CancellationError() }
        let ticket = lifecycle
        if needsFullSync { needsFullSync = false; try await synchronize() }
        let deviceIDs = dirtyDevices; dirtyDevices = []
        let commandIDs = dirtyCommands; dirtyCommands = []
        for id in deviceIDs {
            let previous = devices.first { $0.id == id }
            let delta = try await api.changes(device: id, since: previous?.revision ?? -1)
            try Task.checkCancellation()
            guard active, ticket == lifecycle, self.api === api else { throw CancellationError() }
            if let delta {
                let current = devices.first { $0.id == id }
                let value = delta.applying(to: current)
                if let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = value }
                else { devices.append(value) }
            } else { devices.removeAll { $0.id == id }; commands.removeAll { $0.device == id } }
        }
        for id in commandIDs {
            let value = try await api.command(id: id)
            try Task.checkCancellation()
            guard active, ticket == lifecycle, self.api === api else { throw CancellationError() }
            if let value {
                if let index = commands.firstIndex(where: { $0.id == id }) { commands[index] = value }
                else { commands.insert(value, at: 0) }
            } else { commands.removeAll { $0.id == id } }
        }
        try resolveDelivery()
        commands = Array(commands.prefix(600))
    }

    // MARK: Delivery receipts

    /// A receipt is resolved once the queue reports its command, whatever its status.
    private func resolveDelivery() throws {
        var next = receipts
        let removed = next.resolve(known: commands.map(\.id))
        guard !removed.isEmpty else { return }
        try next.save(to: receiptStorage)
        receipts = next
        removed.forEach { undelivered.remove($0); unsentBodies[$0] = nil }
    }
    private func clearReceipt(_ id: String) throws {
        var next = receipts
        guard next.remove(id) else { return }
        try next.save(to: receiptStorage)
        receipts = next; undelivered.remove(id); unsentBodies[id] = nil
    }
    /// Looks one unresolved command up by ID. No send is in flight in its chat, so absence means the queue never stored it.
    func checkDelivery(_ receipt: RemoteCommand) async {
        let key = MobileChatKey(receipt)
        guard let api, !inFlight.contains(key) else { return }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            if let found = try await api.command(id: receipt.id) {
                if !commands.contains(where: { $0.id == found.id }) { commands.insert(found, at: 0) }
                try resolveDelivery()
            } else { undelivered.insert(receipt.id) }
            chatErrors[key] = nil
        } catch { chatErrors[key] = error.localizedDescription }
    }
    func resendUndelivered(_ receipt: RemoteCommand) async {
        let key = MobileChatKey(receipt)
        guard let api, canResend(receipt), let command = unsentBodies[receipt.id], !inFlight.contains(key) else { return }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do { try await submit(command, using: api) } catch { chatErrors[key] = error.localizedDescription }
    }
    /// Only a receipt the cloud proved absent can be discarded; an unknown one keeps its chat blocked.
    func discardUndelivered(_ receipt: RemoteCommand) {
        let key = MobileChatKey(receipt)
        guard undelivered.contains(receipt.id), !inFlight.contains(key) else { return }
        do { try clearReceipt(receipt.id); chatErrors[key] = nil } catch { chatErrors[key] = error.localizedDescription }
    }

    // MARK: Commands

    func refresh() async {
        guard active else { return }
        startConnection()
        needsFullSync = true; requestUpdates()
    }
    /// Sends a chat command: `send`, `stop`, `allow`/`deny` of an approval, `queue`, or `interrupt` of the observed turn.
    func send(device: RemoteDevice, chat: RemoteChat, kind: String, text: String = "", approval: String? = nil, photos: [RemotePhoto] = []) async -> Bool {
        if !photos.isEmpty, chat.supportsPhotos != true {
            chatErrors[MobileChatKey(device: device.id, chat: chat.id)] = RemoteFailure.photoSetup.localizedDescription; return false
        }
        return await perform(device: device, chat: chat) { owner in
            switch kind {
            case "queue": .queue(owner: owner, device: device.id, project: chat.project, chat: chat.id, text: text, photos: photos)
            case "interrupt": .interruptAndSend(owner: owner, device: device.id, project: chat.project, chat: chat.id, turn: chat.turn ?? "", text: text, photos: photos)
            default: RemoteCommand(owner: owner, device: device.id, project: chat.project, chat: chat.id, kind: kind, text: text, approval: approval, turn: chat.turn, photos: photos)
            }
        }
    }
    /// Answers a pending question or form by its request handle. `answers` must pass `RemoteInteraction.validate(answers:)`.
    func answer(device: RemoteDevice, chat: RemoteChat, interaction: RemoteInteraction, answers: [String: String]) async -> Bool {
        do { try interaction.validate(answers: answers) }
        catch { chatErrors[MobileChatKey(device: device.id, chat: chat.id)] = error.localizedDescription; return false }
        return await perform(device: device, chat: chat) { owner in
            .answer(owner: owner, device: device.id, project: chat.project, chat: chat.id, interaction: interaction.id, answers: answers)
        }
    }
    /// The desktop's Decline of a form, link or unsupported request.
    func decline(device: RemoteDevice, chat: RemoteChat, interaction: RemoteInteraction) async -> Bool {
        guard interaction.canDecline else { return false }
        return await perform(device: device, chat: chat) { owner in
            .decline(owner: owner, device: device.id, project: chat.project, chat: chat.id, interaction: interaction.id)
        }
    }
    /// Builds, checks (`RemoteAPI.preflight`) and submits one command of a chat; its receipt blocks the chat until resolved.
    private func perform(device: RemoteDevice, chat: RemoteChat, make: (String) -> RemoteCommand) async -> Bool {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        guard let api, !isBlocked(key) else { return false }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            let command = make(try await api.owner())
            try await api.preflight(command)
            try await submit(command, using: api)
            chatErrors[key] = nil
            return true
        } catch { chatErrors[key] = error.localizedDescription; return false }
    }
    func createChat(device: RemoteDevice, project: RemoteProject, text: String, options: RemoteChatOptions? = nil) async -> RemoteCommand? {
        let key = Self.creationKey(device: device.id, project: project.id)
        guard let api, !inFlight.contains(key), creationReceipt(device: device.id, project: project.id) == nil, project.canCreateChat == true else { return nil }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            let command = RemoteCommand.newChat(owner: try await api.owner(), device: device.id, project: project.id, text: text, options: options)
            try await api.preflight(command)
            try await submit(command, using: api)
            chatErrors[key] = nil
            return command
        } catch { chatErrors[key] = error.localizedDescription; return nil }
    }
    func configureChat(device: RemoteDevice, chat: RemoteChat, options: RemoteChatOptions, expected: RemoteChatSettings) async -> RemoteCommand? {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        guard let api, !isBlocked(key), expected.canEdit else { return nil }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            let command = RemoteCommand.configure(owner: try await api.owner(), device: device.id, project: chat.project, chat: chat.id, options: options, expected: expected)
            try await api.preflight(command)
            try await submit(command, using: api)
            chatErrors[key] = nil
            return command
        } catch { chatErrors[key] = error.localizedDescription; return nil }
    }
    func pendingSettings(device: String, chat: String) -> Bool {
        commands.contains { $0.device == device && $0.chat == chat && $0.kind == "configure" && ["pending", "claimed", "uncertain"].contains($0.status) }
    }
    private func submit(_ command: RemoteCommand, using api: RemoteAPI) async throws {
        // Save the stable ID before networking. Never resubmit after a transport failure.
        var next = receipts; next.record(command)
        try next.save(to: receiptStorage)
        receipts = next; unsentBodies[command.id] = command; undelivered.remove(command.id)
        do { try await api.submit(command) }
        catch let failure as RemoteNotStored {
            // The server proved it stored nothing, so the receipt must not block later sends.
            try clearReceipt(command.id); throw failure.cause
        }
        try clearReceipt(command.id)
        var receipt = command; receipt.photos = nil
        if !commands.contains(where: { $0.id == receipt.id }) { commands.insert(receipt, at: 0) }
        if self.api === api, active { dirtyCommands.insert(command.id); requestUpdates() }
    }
    /// File reads are idempotent and never reach an agent, so they skip the delivery receipt;
    /// after a failure the user may simply ask again (a new command).
    func requestFile(device: RemoteDevice, chat: RemoteChat, path: String) async throws -> String {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") {
            var done = RemoteCommand.file(owner: device.owner, device: device.id, project: chat.project, chat: chat.id, path: path)
            try done.validate()
            done.status = "submitted"; commands.insert(done, at: 0)
            previewFiles[done.id] = Self.previewFile(path)
            return done.id
        }
        #endif
        guard let api else { throw RemoteFailure.signedOut }
        let command = RemoteCommand.file(owner: try await api.owner(), device: device.id, project: chat.project, chat: chat.id, path: path)
        try command.validate()
        try await api.submit(command)
        if !commands.contains(where: { $0.id == command.id }) { commands.insert(command, at: 0) }
        if self.api === api, active { dirtyCommands.insert(command.id); requestUpdates() }
        return command.id
    }
    func takeFile(_ command: String) async throws -> RemoteFile? {
        #if targetEnvironment(simulator)
        if let file = previewFiles[command] { return file }
        #endif
        guard let api else { throw RemoteFailure.signedOut }
        return try await api.takeFile(command: command)
    }
    /// Messages this phone queued (or sent with Interrupt and send) that the chat's published queue does not show yet.
    func unlistedQueueCommands(device: String, chat: RemoteChat) -> [RemoteCommand] {
        let listed = Set((chat.queue ?? []).compactMap { $0.command?.lowercased() })
        return commands.filter { command in
            command.device == device && command.chat == chat.id && ["queue", "interrupt"].contains(command.kind)
                && ["pending", "claimed"].contains(command.status) && !listed.contains(command.id.lowercased())
        }.reversed()
    }
    /// The reply to an approval or a question (answer or decline): both carry the request handle.
    func approvalCommand(device: String, chat: String, approval: String) -> RemoteCommand? {
        commands.first { $0.device == device && $0.chat == chat && $0.approval.flatMap(UUID.init(uuidString:)) == UUID(uuidString: approval) }
    }
    func signOut() async {
        lifecycle = UUID(); realtime?.stop(); realtime = nil; updates.cancel()
        dirtyDevices = []; dirtyCommands = []; onlineMacs = []
        do { try await api?.signOut(); api = nil; signedIn = false; devices = []; commands = []; drafts = [:]; photoDrafts = [:]; chatErrors = [:] }
        catch { status = error.localizedDescription }
    }

    #if targetEnvironment(simulator)
    /// Fixtures only: shows an unconfirmed receipt without touching the Keychain.
    func previewReceipt(_ command: RemoteCommand, undelivered: Bool) {
        receipts.record(command)
        unsentBodies[command.id] = command
        if undelivered { self.undelivered.insert(command.id) }
    }
    #endif
}
