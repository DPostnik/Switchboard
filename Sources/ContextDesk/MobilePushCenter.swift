import AppKit
import Combine
import ContextCore
import Foundation

/// App-owned APNs sender. Tokens and signing material never enter logs or project access settings.
@MainActor final class MobilePushCenter: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var hasKey = false
    static let keyService = "Switchboard.APNs.v1"
    // App operations are injectable so tests never touch the real Keychain or cloud.
    var readKey: () throws -> Data? = { try RemoteVault.readChecked("auth-key", service: keyService) }
    var supportsPush: @MainActor (RemoteAPI) async throws -> Bool = { try await $0.supportsPush() }
    var fetchDevices: @MainActor (RemoteAPI) async throws -> [RemotePushDevice] = { try await $0.pushDevices() }
    var deleteDevice: @MainActor (RemoteAPI, RemotePushDevice, Date) async throws -> Void = { try await $0.removePushDevice($1, invalidSince: $2) }
    var makeSender: (APNsCredentials) -> APNsClient = { APNsClient(credentials: $0) }
    private var api: RemoteAPI?
    private var client: APNsClient?
    private var activeCredentials: APNsCredentials?
    private var blockedCredentials: APNsCredentials?
    private var mac = ""
    private var generation = UUID()
    private var outbox = PushOutbox()
    private var cache: [RemotePushDevice] = []
    private var cachedAt = Date.distantPast
    private var drain: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var withdrawalTask: Task<Void, Never>?
    private var withdrawals = PushOutbox.Withdrawal()
    var detail = false
    var onlyAway = true { didSet { outbox.onlyWhileAway = onlyAway } }
    var valid: (PushEvent) -> Bool = { _ in false }
    var badge: () -> Int = { 0 }
    var away: () -> Bool = {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return locked || CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) >= 120
    }
    func enable(api: RemoteAPI, mac: String, keyID: String, teamID: String) async {
        guard !Task.isCancelled else { return }
        reset()
        let epoch = generation
        do {
            guard let data = try readKey(),
                  let pem = String(data: data, encoding: .utf8) else {
                hasKey = false; status = L10n.text("Выберите ключ APNs.", "Choose an APNs key."); return
            }
            let credentials = try APNsCredentials(keyID: keyID, teamID: teamID, pem: pem)
            hasKey = true
            guard credentials != blockedCredentials else { return }
            activeCredentials = credentials
            guard try await supportsPush(api) else {
                guard epoch == generation else { return }
                status = L10n.text("Обновите схему Supabase для уведомлений.", "Update the Supabase schema for notifications."); return
            }
            guard epoch == generation else { return }
            self.api = api; self.mac = mac; client = makeSender(credentials)
            status = L10n.text("Уведомления готовы к отправке.", "Notifications are ready to send.")
        } catch { if epoch == generation { report(error) } }
    }
    func reset() {
        generation = UUID(); drain?.cancel(); drain = nil; timer?.cancel(); timer = nil
        withdrawalTask?.cancel(); withdrawalTask = nil; withdrawals = .init()
        outbox.reset(); cache = []; cachedAt = .distantPast; api = nil; client = nil; activeCredentials = nil
    }
    func importKey(_ url: URL, keyID: String, teamID: String) throws {
        guard url.pathExtension.lowercased() == "p8" else { throw APNsCredentials.Invalid.key }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096, let pem = String(data: data, encoding: .utf8) else { throw APNsCredentials.Invalid.key }
        _ = try APNsCredentials(keyID: keyID, teamID: teamID, pem: pem)
        try RemoteVault.save(data, account: "auth-key", service: Self.keyService)
        hasKey = true; status = L10n.text("Ключ сохранён в Связке ключей.", "Key saved in Keychain.")
    }
    func removeKey() {
        do {
            try RemoteVault.save(nil, account: "auth-key", service: Self.keyService)
            reset(); hasKey = false; status = L10n.text("Ключ удалён.", "Key removed.")
        } catch { report(error) }
    }
    func report(_ error: Error) {
        // Only app-owned messages: file URLs, key bytes and network response bodies are never displayed here.
        status = (error as? APNsCredentials.Invalid)?.message()
            ?? L10n.text("Не удалось настроить уведомления. Проверьте ключ и подключение.", "Could not configure notifications. Check the key and connection.")
    }
    func post(_ event: PushEvent) {
        guard client != nil, event.kind == .test || valid(event) else { return }
        outbox.post(event, now: Date()); pump()
    }
    func test() {
        guard client != nil else { return }
        post(PushEvent(id: UUID().uuidString, subject: .test, chat: nil, project: "Switchboard", created: Date()))
    }
    private func devices(_ api: RemoteAPI) async -> [RemotePushDevice] {
        if Date().timeIntervalSince(cachedAt) < 30 { return cache }
        let epoch = generation
        if let rows = try? await fetchDevices(api), epoch == generation {
            cache = rows.filter { (try? $0.validate()) != nil }; cachedAt = Date()
        }
        guard epoch == generation else { return [] }
        return cache
    }
    private func pump() {
        guard drain == nil, let api, let client else { return }
        let epoch = generation
        drain = Task { [weak self] in
            guard let self else { return }
            let events = outbox.due(now: Date(), away: away())
            for event in events {
                guard epoch == generation, !Task.isCancelled else { return }
                guard event.kind == .test || valid(event) else { outbox.drop(event.id); continue }
                let rows = await devices(api)
                guard epoch == generation else { return }
                if rows.isEmpty {
                    outbox.drop(event.id)
                    status = L10n.text("Нет зарегистрированных iPhone.", "No registered iPhones."); continue
                }
                var accepted = false, retry: TimeInterval?, transient = false
                for row in rows {
                    let request = APNsRequest.alert(event: event, device: row, mac: mac, badge: badge(), detail: detail, now: event.created)
                    let outcome = await client.send(request, device: row)
                    guard epoch == generation, !Task.isCancelled else { return }
                    // No tokens or notification text, including in an error description.
                    switch outcome {
                    case .delivered: accepted = true
                    case .tokenGone(let since):
                        try? await deleteDevice(api, row, since ?? Date())
                        guard epoch == generation else { return }
                        cache.removeAll { $0.id == row.id }
                    case .credentials(let reason):
                        blockedCredentials = activeCredentials
                        status = L10n.text("Ошибка ключа APNs: ", "APNs key error: ") + reason
                        reset(); return
                    case .retry(let delay): transient = true; retry = max(retry ?? 0, delay)
                    case .unreachable: transient = true
                    case .rejected(let reason):
                        AppLog.remote.error("Push rejected: \(reason, privacy: .public)")
                    case .tokenExpired: break
                    }
                }
                guard epoch == generation else { return }
                if accepted {
                    outbox.delivered(event.id)
                    status = L10n.text("APNs принял уведомление.", "APNs accepted the notification.")
                    AppLog.remote.notice("Push accepted: \(event.id, privacy: .public), \(event.kind.rawValue, privacy: .public)")
                } else if transient {
                    outbox.failed(event.id, retryAfter: retry, now: Date())
                    status = L10n.text("Отправка отложена после ошибки связи.", "Send deferred after a connection error.")
                } else {
                    outbox.drop(event.id)
                    status = L10n.text("APNs отклонил уведомление.", "APNs rejected the notification.")
                }
            }
            drain = nil
            if outbox.isHolding { schedule() }
        }
    }
    func waitForCurrentDelivery() async { await drain?.value }
    private func schedule() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            timer = nil; pump()
        }
    }
    func withdraw(events: Set<String> = [], chats: Set<String> = []) {
        let removed = outbox.withdraw(events: events, chats: chats)
        withdrawals.events += removed.events; withdrawals.chats += removed.chats
        guard !withdrawals.isEmpty, withdrawalTask == nil, let api, let client else { return }
        let epoch = generation
        withdrawalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            // A resolution during a send must withdraw after that alert, not before it.
            await drain?.value
            guard epoch == generation else { return }
            let pending = withdrawals; withdrawals = .init()
            let rows = await devices(api)
            guard epoch == generation else { return }
            for row in rows {
                var marker = PushMarker(kind: .withdraw, device: mac, badge: badge())
                func request(_ value: PushMarker) -> APNsRequest { .withdrawal(marker: value, topic: row.topic) }
                for (ids, isChat) in [(pending.events, false), (pending.chats, true)] {
                    for id in Set(ids) {
                        var candidate = marker
                        if isChat { candidate.withdrawnChats.append(id) } else { candidate.withdrawn.append(id) }
                        if request(candidate).body.count > APNsRequest.payloadLimit
                            || candidate.withdrawn.count > PushMarker.maximumWithdrawn
                            || candidate.withdrawnChats.count > PushMarker.maximumWithdrawn {
                            _ = await client.send(request(marker), device: row)
                            guard epoch == generation else { return }
                            marker = PushMarker(kind: .withdraw, device: mac, badge: badge())
                            if isChat { marker.withdrawnChats = [id] } else { marker.withdrawn = [id] }
                        } else { marker = candidate }
                    }
                }
                if !marker.withdrawn.isEmpty || !marker.withdrawnChats.isEmpty {
                    _ = await client.send(request(marker), device: row)
                    guard epoch == generation else { return }
                }
            }
            withdrawalTask = nil
            // Any resolutions received during I/O are collected by a new batch.
            if !withdrawals.isEmpty { withdraw() }
        }
    }
}
