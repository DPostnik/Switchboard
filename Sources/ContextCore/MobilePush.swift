import Foundation

// Shared push contract of the Mac and the iPhone app (compiled by both targets: Foundation only, no AppKit or CryptoKit).
// The cloud stores device tokens only; notification text travels through APNs and is never stored in Supabase.

/// One registered app installation (`public.remote_push_devices`). Values mirror the database checks.
public struct RemotePushDevice: Codable, Sendable, Equatable, Identifiable {
    public static let environments = ["development", "production"]
    /// App installation ID kept by the phone (UUID, lowercase in the cloud).
    public var id: String
    /// APNs device token as lowercase hexadecimal.
    public var token: String
    /// `development` (sandbox host) or `production`.
    public var environment: String
    /// The app's bundle ID, sent as `apns-topic`.
    public var topic: String
    /// Notification language of this device: `ru` or `en`.
    public var locale: String
    public init(id: String, token: String, environment: String, topic: String, locale: String) {
        self.id = id; self.token = token; self.environment = environment; self.topic = topic; self.locale = locale
    }
    /// The device's notification language (`en` for an unknown value; `validate()` rejects those).
    public var language: AppLanguage { AppLanguage(rawValue: locale) ?? .english }
    /// Throws `RemoteFailure.invalidCommand` unless every field passes the same checks as the database.
    public func validate() throws {
        let hex = Set("0123456789abcdef")
        let topicCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard UUID(uuidString: id) != nil,
              (64...400).contains(token.count), token.allSatisfy({ hex.contains($0) }),
              Self.environments.contains(environment),
              (1...155).contains(topic.count), topic.allSatisfy({ topicCharacters.contains($0) }),
              AppLanguage(rawValue: locale) != nil else { throw RemoteFailure.invalidCommand }
    }
    /// Lowercase hexadecimal of an APNs device token as delivered by `didRegisterForRemoteNotificationsWithDeviceToken`.
    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""; result.reserveCapacity(data.count * 2)
        for byte in data { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 0x0f)]) }
        return result
    }
}

/// The `sb` object of a push payload: identifiers only, never text. The single parser of these keys on both sides;
/// the phone treats the payload as untrusted data and `init?(userInfo:)` validates every field.
public struct PushMarker: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case action, turn, attention, test, withdraw
    }
    public static let key = "sb"
    /// Upper bound of `w` and `wc` entries in one withdrawal.
    public static let maximumWithdrawn = 64
    /// Upper bound of one identifier in UTF-8 bytes (chat IDs and event IDs).
    public static let maximumIdentifierBytes = 512
    public static let maximumBadge = 9999

    public var kind: Kind
    /// Sending Mac's device ID (lowercase UUID).
    public var device: String
    public var chat: String?
    /// Event ID: action UUID, proposal notice ID, `turn:<chat>:<turn>` or `attention:<UUID>`.
    public var event: String?
    /// `w`: withdrawn event IDs.
    public var withdrawn: [String]
    /// `wc`: chats whose turn notifications are withdrawn.
    public var withdrawnChats: [String]
    /// `n`: badge for a withdrawal (a background push cannot carry `aps.badge`).
    public var badge: Int?

    public init(kind: Kind, device: String, chat: String? = nil, event: String? = nil,
                withdrawn: [String] = [], withdrawnChats: [String] = [], badge: Int? = nil) {
        self.kind = kind; self.device = device.lowercased(); self.chat = chat; self.event = event
        self.withdrawn = withdrawn; self.withdrawnChats = withdrawnChats; self.badge = badge
    }

    /// The JSON object written under `sb` (keys `k d c i w wc n`; empty values are omitted).
    public var dictionary: [String: Any] {
        var value: [String: Any] = ["k": kind.rawValue, "d": device]
        if let chat { value["c"] = chat }
        if let event { value["i"] = event }
        if !withdrawn.isEmpty { value["w"] = withdrawn }
        if !withdrawnChats.isEmpty { value["wc"] = withdrawnChats }
        if let badge { value["n"] = badge }
        return value
    }

    /// Reads `userInfo["sb"]`. Nil for anything malformed: unknown kind, a device that is not a UUID, wrong types,
    /// empty or oversized identifiers, control characters, more than `maximumWithdrawn` entries, a badge out of range,
    /// a non-withdrawal without chat and event (except `test`), or a withdrawal that withdraws nothing.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo[Self.key] as? [String: Any],
              let kindText = value["k"] as? String, let kind = Kind(rawValue: kindText),
              let deviceText = value["d"] as? String, deviceText.count == 36, let device = UUID(uuidString: deviceText) else { return nil }
        func identifier(_ key: String) -> String?? {
            guard let raw = value[key] else { return .some(nil) }
            guard let text = raw as? String, Self.validIdentifier(text) else { return nil }
            return .some(text)
        }
        func identifiers(_ key: String) -> [String]? {
            guard let raw = value[key] else { return [] }
            guard let items = raw as? [Any], items.count <= Self.maximumWithdrawn else { return nil }
            var result: [String] = []
            for item in items {
                guard let text = item as? String, Self.validIdentifier(text) else { return nil }
                result.append(text)
            }
            return result
        }
        guard let chat = identifier("c"), let event = identifier("i"),
              let withdrawn = identifiers("w"), let withdrawnChats = identifiers("wc") else { return nil }
        var badge: Int?
        if let raw = value["n"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue,
                  (0...Double(Self.maximumBadge)).contains(number.doubleValue) else { return nil }
            badge = number.intValue
        }
        switch kind {
        case .withdraw:
            guard !withdrawn.isEmpty || !withdrawnChats.isEmpty else { return nil }
        case .test:
            guard withdrawn.isEmpty, withdrawnChats.isEmpty else { return nil }
        case .action, .turn, .attention:
            guard chat != nil, event != nil, withdrawn.isEmpty, withdrawnChats.isEmpty else { return nil }
        }
        self.init(kind: kind, device: device.uuidString, chat: chat, event: event,
                  withdrawn: withdrawn, withdrawnChats: withdrawnChats, badge: badge)
    }

    static func validIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumIdentifierBytes
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    /// True when `withdrawal` (kind `withdraw`, same Mac) names this notification's event, or this turn notification's chat.
    public func isWithdrawn(by withdrawal: PushMarker) -> Bool {
        guard withdrawal.kind == .withdraw, kind != .withdraw, withdrawal.device == device else { return false }
        if let event, withdrawal.withdrawn.contains(event) { return true }
        if kind == .turn, let chat, withdrawal.withdrawnChats.contains(chat) { return true }
        return false
    }
}

extension RemoteAPI {
    /// False when the cloud schema predates push notifications (`remote_push_version` missing or not 1).
    public func supportsPush() async throws -> Bool {
        do {
            return try JSONDecoder().decode(Int.self, from: await request("rest/v1/rpc/remote_push_version", method: "POST", body: Data("{}".utf8))) == 1
        } catch RemoteFailure.request(404) { return false }
    }
    /// Phone side: registers or refreshes this installation. The cloud moves the token to this installation and keeps
    /// at most 8 installations per owner. Idempotent.
    public func registerPush(_ device: RemotePushDevice) async throws {
        struct Body: Encodable { let device_id, device_token, apns_environment, apns_topic, language: String }
        try device.validate()
        _ = try await request("rest/v1/rpc/register_remote_push", method: "POST", body: JSONEncoder().encode(Body(
            device_id: device.id.lowercased(), device_token: device.token, apns_environment: device.environment,
            apns_topic: device.topic, language: device.locale)))
    }
    /// Phone side: removes this installation's row (notifications off, sign-out).
    public func unregisterPush(id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw RemoteFailure.invalidCommand }
        _ = try await request("rest/v1/remote_push_devices?id=eq.\(id.lowercased())", method: "DELETE")
    }
    /// Mac side: the owner's registered installations, newest first. Rows that fail validation are skipped.
    public func pushDevices() async throws -> [RemotePushDevice] {
        try JSONDecoder().decode([RemotePushDevice].self, from: await request(
            "rest/v1/remote_push_devices?select=id,token,environment,topic,locale&order=updated.desc&limit=16"))
            .filter { (try? $0.validate()) != nil }
    }
    /// Mac side, after APNs reported the token gone: deletes the row only if it still has this token and was last
    /// registered before `invalidSince` (APNs' timestamp). The comparison runs in the database.
    public func removePushDevice(_ device: RemotePushDevice, invalidSince: Date) async throws {
        try device.validate()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        _ = try await request("rest/v1/remote_push_devices?id=eq.\(device.id.lowercased())&token=eq.\(device.token)&updated=lt.\(formatter.string(from: invalidSince))",
                              method: "DELETE")
    }
}
