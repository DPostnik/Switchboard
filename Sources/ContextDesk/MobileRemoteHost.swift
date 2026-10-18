import Foundation
import SwiftUI
import ContextCore
import ContextTranscript
import AgentContract
import Combine
import IOKit.pwr_mgt
import IOKit.ps

@MainActor final class MobileRemoteHost: ObservableObject {
    @Published var url = ""
    @Published var key = ""
    @Published var email = ""
    @Published var password = ""
    @Published var projects: Set<String> = []
    @Published var autoEnable = true { didSet { if autoEnable != oldValue { saveConfig() } } }
    @Published private(set) var enabled = false
    @Published private(set) var transitioning = false
    @Published private(set) var status = ""
    @Published private(set) var connectionState: RemoteConnectionState = .stopped
    private var realtime: RemoteRealtime?
    private let publication = RemoteEventWork()
    private let commandWork = RemoteEventWork()
    private var modelChanges: AnyCancellable?
    private weak var model: DeskModel?
    private var lastPublished: RemoteSnapshot?
    private var liveMessages: [String: [RemoteMessage]] = [:]
    /// Thread ID -> readable current tool call of its running turn.
    private var liveActivity: [String: String] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var sleeping = false
    /// The cloud schema has the short-lived file table; checked on every subscription.
    private var filesReady = false
    private var api: RemoteAPI?
    private var apiURL = ""
    private var apiKey = ""
    private let makeClient: (String, String) throws -> RemoteAPI
    private var assertion: IOPMAssertionID = 0
    private let configFile = Locations.root.appendingPathComponent("mobile-remote.json")
    private let setupFile: URL
    private let journal = RemoteJournal(file: Locations.root.appendingPathComponent("mobile-remote-journal.json"))
    private var device = UUID().uuidString.lowercased()
    /// Whether access should come back on the next launch: set by enabling, cleared only when the user turns it off.
    private var active = false
    private struct Config: Codable {
        var url: String; var key: String; var device: String; var projects: Set<String>
        var autoEnable: Bool?; var active: Bool?
    }
    init(setupFile: URL = Locations.root.appendingPathComponent("mobile-setup.json"),
         makeClient: @escaping (String, String) throws -> RemoteAPI = { try RemoteAPI(url: $0, key: $1) }) {
        self.setupFile = setupFile
        self.makeClient = makeClient
        if let data = try? Data(contentsOf: configFile), let config = try? JSONDecoder().decode(Config.self, from: data) {
            url = config.url; key = config.key; device = config.device; projects = config.projects
            autoEnable = config.autoEnable ?? true; active = config.active ?? true
        }
    }
    private func saveConfig() {
        do {
            try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Config(url: url, key: key, device: device, projects: projects, autoEnable: autoEnable, active: active))
                .write(to: configFile, options: .atomic)
        } catch { status = error.localizedDescription }
    }
    // Called once from app boot, so tests and background model instances never connect.
    func restoreOnLaunch(model: DeskModel) async {
        guard autoEnable, active, !url.isEmpty, !key.isEmpty, !projects.isEmpty else { return }
        await enable(model: model)
    }
    // Disabling access stops transport, not authentication. Reuse the actor so
    // re-enabling does not reread Keychain or race a second token refresh.
    func connectionClient() throws -> RemoteAPI {
        if let api, apiURL == url, apiKey == key { return api }
        api = nil
        let client = try makeClient(url, key)
        api = client; apiURL = url; apiKey = key
        return client
    }
    // Model construction also happens in tests and background contexts. Only the
    // settings UI consumes the installer handoff.
    func prepareConnection() {
        guard !enabled, !transitioning else { return }
        do {
            if let setup = try RemoteSetup.consume(setupFile) {
                url = setup.url; key = setup.key; email = setup.email; password = setup.password
                status = L10n.text("Подключение подготовлено. Выберите проекты и включите доступ.", "Connection prepared. Select projects and enable access.")
            }
        } catch { status = error.localizedDescription }
    }
    func enable(model: DeskModel) async {
        guard !enabled, !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        do {
            let client = try connectionClient()
            if !password.isEmpty { try await client.signIn(email: email, password: password); password = "" }
            _ = try await client.owner()
            active = true
            try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Config(url: url, key: key, device: device, projects: projects, autoEnable: autoEnable, active: active))
                .write(to: configFile, options: .atomic)
            api = client; self.model = model; enabled = true; lastPublished = nil
            let channel = RemoteRealtime(role: "mac", device: device, credentials: { try await client.realtimeCredentials() }) { [weak self] in
                try await client.checkRealtimeSchema()
                guard let self, self.enabled, !self.sleeping else { throw CancellationError() }
                self.lastPublished = nil // A new subscription always reconciles current local state.
                self.filesReady = (try? await client.supportsFiles()) ?? false
                try await self.publishCurrent()
            }
            realtime = channel
            channel.onState = { [weak self] value in
                guard let self else { return }
                connectionState = value; status = value.text
                if value == .connecting { publication.cancel() }
                if value == .connected { requestPublication(); requestCommands() }
            }
            channel.onError = { [weak self] error in self?.status = error.localizedDescription }
            channel.onChange = { [weak self] event in
                guard let self, event.device.lowercased() == device.lowercased(), event.entity == "command" else { return }
                // Finishing/rejecting an earlier command can unblock a queued send.
                requestCommands()
            }
            channel.onPresence = { [weak self] peers in
                if !peers.phones.isEmpty { self?.requestPublication() }
            }
            modelChanges = model.objectWillChange.merge(with: model.transcript.objectWillChange).sink { [weak self] _ in self?.requestPublication() }
            observePowerAndSleep()
            updateSleepAssertion()
            channel.start()
        } catch { password = ""; status = error.localizedDescription }
    }
    private func publishCurrent() async throws {
        guard enabled, !sleeping, let model, let api else { throw CancellationError() }
        var snapshot = await model.remoteSnapshot(projects: projects)
        try Task.checkCancellation()
        for index in snapshot.chats.indices {
            let chat = snapshot.chats[index].id
            // Off-screen streaming events are not in the selected desktop transcript.
            if chat != model.chatID, let live = liveMessages[chat] {
                var messages = snapshot.chats[index].messages
                for item in live {
                    if let i = messages.firstIndex(where: { $0.id == item.id }) { messages[i] = item }
                    else { messages.append(item) }
                }
                snapshot.chats[index].messages = Array(messages.suffix(20))
            }
        }
        for index in snapshot.projects.indices { snapshot.projects[index].canReadFiles = filesReady ? true : nil }
        for index in snapshot.chats.indices where snapshot.chats[index].running {
            if let action = liveActivity[snapshot.chats[index].id] { snapshot.chats[index].activity = action }
        }
        liveMessages = liveMessages.filter { key, _ in snapshot.chats.contains { $0.id == key } }
        liveActivity = liveActivity.filter { key, _ in snapshot.chats.contains { $0.id == key && $0.running } }
        guard snapshot != lastPublished else { return }
        try await api.publishChanges(RemoteDevice(id: device, owner: api.owner(), snapshot: snapshot), previous: lastPublished)
        try Task.checkCancellation()
        lastPublished = snapshot
    }
    func requestPublication() {
        guard enabled, !sleeping, connectionState == .connected else { return }
        publication.enqueue(delay: .milliseconds(350), operation: { [weak self] in
            try await self?.publishCurrent()
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    func observe(_ event: AgentEvent, thread: String?) {
        guard enabled, let thread, let model,
              let chat = model.state.chats.first(where: { $0.id == thread }), projects.contains(chat.projectID.uuidString) else { return }
        switch event.payload {
        case .item(let item) where item.kind == "activity":
            // Same one-line headline as the desktop working row.
            liveActivity[thread] = String(TranscriptScrollView.activityHeadline(item.text).prefix(RemoteChat.activityLimit))
        case .started:
            liveActivity[thread] = nil
        case .item(let item) where ["user", "assistant"].contains(item.kind):
            if item.kind == "assistant" { liveActivity[thread] = nil }
            let message = RemoteMessage(id: item.id, role: item.kind, fullText: item.text)
            var entries = liveMessages[thread] ?? []
            if let i = entries.firstIndex(where: { $0.id == item.id }) { entries[i] = message } else { entries.append(message) }
            liveMessages[thread] = Array(entries.suffix(20))
        case .delta(_, let id, let text):
            var entries = liveMessages[thread] ?? []
            liveActivity[thread] = nil
            if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].append(text) }
            else {
                var message = lastPublished?.chats.first(where: { $0.id == thread })?.messages.first(where: { $0.id == id })
                    ?? RemoteMessage(id: id, role: "assistant", text: "")
                message.append(text)
                entries.append(message)
            }
            liveMessages[thread] = Array(entries.suffix(20))
        default: break
        }
        requestPublication()
    }
    private func requestCommands() {
        guard enabled, !sleeping, connectionState == .connected else { return }
        commandWork.enqueue(operation: { [weak self] in
            guard let self, let api, let model else { return }
            while enabled, !sleeping {
                try Task.checkCancellation()
                let commands = try await api.claim(device: device)
                guard !commands.isEmpty else { return }
                for command in commands {
                    // Once claimed, an uncertain command is never requeued or redispatched.
                    try Task.checkCancellation()
                    var result = "rejected"
                    do {
                        guard projects.contains(command.project), command.device.lowercased() == device.lowercased(),
                              command.owner == (try await api.owner()) else { throw RemoteFailure.invalidCommand }
                        try await journal.begin(command)
                        if command.kind == "file" { result = try await answerFile(command, model: model, api: api) }
                        else { result = try await model.executeRemote(command) }
                    } catch RemoteFailure.invalidCommand { result = "rejected" }
                    catch { result = "uncertain" }
                    try await api.finish(id: command.id, status: result)
                    requestPublication()
                }
            }
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    /// Reads only from the chat's own project folder and answers once; the agent is not involved.
    private func answerFile(_ command: RemoteCommand, model: DeskModel, api: RemoteAPI) async throws -> String {
        guard filesReady,
              let project = model.state.projects.first(where: { $0.id.uuidString == command.project }),
              model.state.chats.contains(where: { $0.id == command.chat && $0.projectID == project.id }) else { throw RemoteFailure.invalidCommand }
        let path = command.text, root = project.path
        let file = await Task.detached(priority: .userInitiated) { RemoteFileReader.read(path, root: root) }.value
        try await api.publishFile(file, command: command.id)
        return "submitted"
    }
    /// User-initiated off: unlike quitting, it also stops access from returning on the next launch.
    func turnOff() async {
        active = false; saveConfig()
        await disable()
    }
    func disable() async {
        enabled = false; sleeping = false
        realtime?.stop(); realtime = nil
        publication.cancel(); commandWork.cancel(); modelChanges = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil; liveMessages = [:]; liveActivity = [:]; lastPublished = nil
        releaseSleepAssertion()
        status = L10n.text("Удалённый доступ выключен. Очередь в облаке сохранена.", "Remote access disabled. Cloud queue retained.")
    }
    private func observePowerAndSleep() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true; self.publication.cancel(); self.commandWork.cancel(); self.realtime?.stop(); self.releaseSleepAssertion()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.sleeping = false; self.updateSleepAssertion(); self.realtime?.start()
            }
        })
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let host = Unmanaged<MobileRemoteHost>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak host] in
                guard let host, host.enabled, !host.sleeping else { return }
                host.updateSleepAssertion()
            }
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }
    func forgetCloudCopy() async {
        await turnOff()
        do {
            let client = try connectionClient()
            try await client.deleteDevice(device)
            try await client.signOut()
            status = L10n.text("Облачная копия и очередь удалены", "Cloud copy and queue deleted")
        } catch { status = error.localizedDescription }
    }
    private func updateSleepAssertion() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let onAC = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPSACPowerValue
        if onAC && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Switchboard Remote Access" as CFString, &assertion)
        } else if !onAC { releaseSleepAssertion() }
    }
    private func releaseSleepAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}

struct MobileRemoteSettings: View {
    @ObservedObject var host: MobileRemoteHost
    @ObservedObject var model: DeskModel
    var body: some View {
        Section(L10n.text("Мобильный доступ · Supabase", "Mobile access · Supabase")) {
            Group {
            TextField("Supabase URL", text: $host.url)
            SecureField(L10n.text("Публичный ключ", "Public key"), text: $host.key)
            TextField(L10n.text("Почта Supabase", "Supabase email"), text: $host.email)
            SecureField(L10n.text("Пароль Supabase", "Supabase password"), text: $host.password)
            }.disabled(host.enabled || host.transitioning)
            Text(L10n.text("Если Связка ключей на Mac запрашивает доступ для Switchboard, выберите «Разрешать всегда», чтобы сохранить разрешение. После обновления приложения macOS может запросить его снова.", "If Keychain on your Mac asks to allow Switchboard access, choose Always Allow to save permission. macOS may ask again after an app update."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            Text(L10n.text("Выбранные проекты: названия, последние сообщения и запросы подтверждения передаются в Supabase. Фото с телефона удаляются из облака примерно через час после обработки команды, а с Mac — через час после окончания работы чата. Очистка на Mac выполняется, пока приложение открыто. Вложения из истории Mac и учётные данные агентов не передаются. Облачная копия хранится до удаления ниже.", "Selected projects: names, recent messages and approval requests are sent to Supabase. Phone photos are removed from the cloud about an hour after the command is processed, and from your Mac an hour after the chat becomes idle. Mac cleanup runs while the app is open. Attachments from Mac history and agent credentials are excluded. The cloud copy remains until deleted below."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            ForEach(model.state.projects) { project in
                Toggle(project.name, isOn: Binding(get: { host.projects.contains(project.id.uuidString) }, set: {
                    if $0 { host.projects.insert(project.id.uuidString) } else { host.projects.remove(project.id.uuidString) }
                })).disabled(host.enabled)
            }
            Text(L10n.text("На питании от сети Mac не засыпает автоматически. Закрытая крышка, принудительный сон и Cmd+Q могут прервать доступ.", "On external power, the Mac stays awake during idle time. Closing the lid, forced sleep and Cmd+Q can interrupt access."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            Toggle(L10n.text("Включать доступ при запуске приложения", "Enable access when the app launches"), isOn: $host.autoEnable)
            Text(L10n.text("Если доступ был включён, он восстановится после запуска или перезапуска приложения, и сохранённые команды будут обработаны. Кнопка «Выключить доступ» отменяет это до следующего ручного включения.", "If access was on, it comes back after the app launches or restarts, and saved commands are processed. Disable access keeps it off until you enable it again."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
            if host.enabled {
                Button(L10n.text("Выключить доступ", "Disable access")) { Task { await host.turnOff() } }
            } else {
                Button(L10n.text("Включить и обработать очередь", "Enable and process queue")) { Task { await host.enable(model: model) } }.disabled(host.projects.isEmpty || host.transitioning)
            }
            Button(L10n.text("Удалить облачную копию и очередь", "Delete cloud copy and queue"), role: .destructive) { Task { await host.forgetCloudCopy() } }
            if !host.status.isEmpty { Text(host.status).font(.ui(.caption)).textSelection(.enabled) }
        }
        .task { host.prepareConnection() }
    }
}
