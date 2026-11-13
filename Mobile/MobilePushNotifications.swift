import Foundation
import UIKit
@preconcurrency import UserNotifications

/// The payload is data. Only the shared, bounded marker parser can select a destination.
@MainActor final class MobilePushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: MobileModel? {
        didSet {
            if let pendingRoute { model?.routePush(pendingRoute); self.pendingRoute = nil }
            if let pendingToken { model?.pushTokenChanged(pendingToken); self.pendingToken = nil }
        }
    }
    private var pendingToken: String?
    private var pendingRoute: PushMarker?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let value = RemotePushDevice.hex(token)
        if let model { model.pushTokenChanged(value) } else { pendingToken = value }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model?.pushState = .failed
    }
    // Use the Objective-C callback API explicitly. The async bridge can invoke UIKit's
    // completion on a cooperative executor, where its state-restoration snapshot asserts.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let marker = PushMarker(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            guard let marker, marker.kind != .withdraw else { completionHandler([]); return }
            if let chat = marker.chat, self.model?.openPushChat == MobileChatKey(device: marker.device, chat: chat) {
                completionHandler([])
            } else { completionHandler([.banner, .list, .sound]) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                             withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let marker = PushMarker(userInfo: response.notification.request.content.userInfo)
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            // Always acknowledge, including malformed payloads, dismissals and test notifications.
            defer { completionHandler() }
            if tapped, let marker, marker.kind != .withdraw {
                if let model = self.model { model.routePush(marker) } else { self.pendingRoute = marker }
            }
        }
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let marker = PushMarker(userInfo: userInfo), marker.kind == .withdraw else { completion(.noData); return }
        Task { @MainActor in
            await MobilePushNotifications.withdraw(marker)
            completion(.newData)
        }
    }
}

enum MobilePushState: Equatable {
    case notAsked, disabled, denied, registering, registered, schema, signedOut, failed, provisioning
    var text: String {
        switch self {
        case .notAsked: L10n.text("Разрешение ещё не запрошено", "Permission has not been requested")
        case .disabled: L10n.text("Уведомления выключены", "Notifications are off")
        case .denied: L10n.text("Разреши уведомления в настройках iOS", "Allow notifications in iOS Settings")
        case .registering: L10n.text("Подключаем уведомления…", "Connecting notifications…")
        case .registered: L10n.text("Уведомления подключены", "Notifications connected")
        case .schema: L10n.text("Обнови схему Supabase и приложение на Mac", "Update the Supabase schema and Mac app")
        case .signedOut: L10n.text("Войди в аккаунт для подключения уведомлений", "Sign in to connect notifications")
        case .failed: L10n.text("Не удалось подключить уведомления. Повторим при открытии приложения.", "Could not connect notifications. We will retry when the app opens.")
        case .provisioning: L10n.text("В подписи приложения нет окружения APNs", "The app signature has no APNs environment")
        }
    }
}

@MainActor enum MobilePushNotifications {
    static var preview: Bool { ProcessInfo.processInfo.arguments.contains("-mobile-preview") }
    static func remove(where matches: (PushMarker) -> Bool) async {
        guard !preview else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered.compactMap { notification -> String? in
            guard let marker = PushMarker(userInfo: notification.request.content.userInfo), matches(marker) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    static func withdraw(_ marker: PushMarker) async {
        await remove { $0.isWithdrawn(by: marker) }
        if !preview, let badge = marker.badge { try? await UNUserNotificationCenter.current().setBadgeCount(badge) }
    }
    static var environment: String? {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
           start.lowerBound < end.upperBound,
           let profile = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
           let entitlements = profile["Entitlements"] as? [String: Any],
           let value = entitlements["aps-environment"] as? String,
           RemotePushDevice.environments.contains(value) { return value }
        #if DEBUG
        return "development"
        #else
        return nil
        #endif
    }
}

extension MobileModel {
    func setPushEnabled(_ value: Bool) async {
        guard !pushChanging else { return }
        pushChanging = true
        defer { pushChanging = false }
        if MobilePushNotifications.preview { pushEnabled = value; pushState = value ? .registered : .disabled; return }
        pushEnabled = value
        UserDefaults.standard.set(value, forKey: "mobilePushEnabled")
        if !value {
            pushRemovalPending = true
            UserDefaults.standard.set(true, forKey: "mobilePushRemovalPending")
            UIApplication.shared.unregisterForRemoteNotifications()
            await MobilePushNotifications.remove { _ in true }
            await pushWork?.value
            await removePushRegistration()
        } else {
            pushRemovalPending = false
            UserDefaults.standard.set(false, forKey: "mobilePushRemovalPending")
            await preparePush(requestPermission: true)
        }
    }
    func removePushRegistration() async {
        guard let api, signedIn else { pushState = .disabled; return }
        do {
            if try await api.supportsPush() { try await api.unregisterPush(id: pushInstallation) }
            pushRemovalPending = false
            UserDefaults.standard.set(false, forKey: "mobilePushRemovalPending")
            pushState = .disabled
        } catch { pushState = .failed }
    }
    func preparePush(requestPermission: Bool = false) async {
        guard !MobilePushNotifications.preview, !pushSigningOut else { return }
        guard pushEnabled else {
            if pushRemovalPending { await removePushRegistration() } else { pushState = .disabled }
            return
        }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard requestPermission else { pushState = .notAsked; return }
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            settings = await center.notificationSettings()
        }
        guard pushEnabled else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral else {
            pushState = .denied
            try? await api?.unregisterPush(id: pushInstallation)
            return
        }
        guard signedIn else { pushState = .signedOut; return }
        pushState = .registering
        UIApplication.shared.registerForRemoteNotifications()
        if pushToken != nil { uploadPush() }
    }
    func pushTokenChanged(_ token: String) {
        pushToken = token
        uploadPush()
    }
    func uploadPush() {
        guard !MobilePushNotifications.preview, !pushSigningOut, pushEnabled, signedIn, let api, let token = pushToken else { return }
        let previous = pushWork
        pushWork = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.pushSigningOut, self.pushEnabled, self.signedIn, self.api === api else { return }
            do {
                guard try await api.supportsPush() else { self.pushState = .schema; return }
                guard let environment = MobilePushNotifications.environment else { self.pushState = .provisioning; return }
                let row = RemotePushDevice(id: self.pushInstallation, token: token, environment: environment,
                                           topic: Bundle.main.bundleIdentifier ?? "com.contextdesk.mobile", locale: L10n.language.rawValue)
                guard !self.pushSigningOut, self.pushEnabled, self.signedIn, self.api === api else { return }
                try await api.registerPush(row)
                self.pushState = .registered
            } catch { self.pushState = .failed }
        }
    }
    func routePush(_ marker: PushMarker) {
        guard let chat = marker.chat, marker.kind != .withdraw else { return }
        pendingPushRoute = MobileChatKey(device: marker.device, chat: chat)
        // An existing snapshot may predate this notification. Unknown chats wait for the next synchronization.
        if devices.contains(where: { $0.id.lowercased() == marker.device && $0.snapshot.chats.contains(where: { $0.id == chat }) }) {
            resolvePushRoute()
        }
    }
    func resolvePushRoute() {
        guard let target = pendingPushRoute, hasPushSnapshot else { return }
        pendingPushRoute = nil
        pushRoute = devices.contains { $0.id.lowercased() == target.device && $0.snapshot.chats.contains { $0.id == target.chat } } ? target : nil
        pushRouteRevision += 1
    }
    func setOpenPushChat(_ target: MobileChatKey?) {
        openPushChat = target
        guard let target else { return }
        Task { await MobilePushNotifications.remove { $0.device == target.device && $0.chat == target.chat } }
    }
    func reconcilePushNotifications() {
        hasPushSnapshot = true
        resolvePushRoute()
        let snapshots = devices
        Task {
            await MobilePushNotifications.remove { marker in
                guard marker.kind == .action, let event = marker.event else { return false }
                guard let device = snapshots.first(where: { $0.id.lowercased() == marker.device }) else { return true }
                return !device.snapshot.chats.contains { chat in
                    chat.approvals.contains { $0.id.lowercased() == event.lowercased() }
                        || (chat.interactions ?? []).contains { $0.id.lowercased() == event.lowercased() }
                }
            }
            await updatePushBadge()
        }
    }
    func updatePushBadge() async {
        guard !MobilePushNotifications.preview else { return }
        let count = devices.reduce(0) { total, device in total + device.snapshot.chats.reduce(0) { $0 + $1.approvals.count + ($1.interactions?.count ?? 0) } }
        try? await UNUserNotificationCenter.current().setBadgeCount(min(count, PushMarker.maximumBadge))
    }
}
