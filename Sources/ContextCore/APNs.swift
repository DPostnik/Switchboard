import CryptoKit
import Foundation

// Mac-side APNs provider (token-based, HTTP/2 through URLSession). Contract: docs/mobile-push-plan.md 1.3 and 4.1-4.7.
// Never log or expose the PEM, the JWT or device tokens.

/// APNs host per build environment. A connection never mixes environments.
public enum APNsEnvironment: String, Codable, Sendable, CaseIterable {
    case development, production
    public var host: String { self == .development ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
}

/// The team-scoped signing key (.p8) with its Key ID and Team ID. Descriptions never include key material.
public struct APNsCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Invalid: Error, Equatable, Sendable {
        case keyID, teamID, key
        public func message(language: AppLanguage = L10n.language) -> String {
            switch self {
            case .keyID: L10n.text("Key ID должен состоять из 10 латинских букв или цифр.", "The Key ID must be 10 Latin letters or digits.", language: language)
            case .teamID: L10n.text("Team ID должен состоять из 10 латинских букв или цифр.", "The Team ID must be 10 Latin letters or digits.", language: language)
            case .key: L10n.text("Файл не похож на ключ APNs (.p8, P-256).", "The file is not an APNs key (.p8, P-256).", language: language)
            }
        }
    }
    public let keyID: String
    public let teamID: String
    let keyData: Data
    /// Parses the PEM (`-----BEGIN PRIVATE KEY-----`, PKCS #8, P-256). Throws `Invalid`.
    public init(keyID: String, teamID: String, pem: String) throws {
        guard Self.validIdentifier(keyID) else { throw Invalid.keyID }
        guard Self.validIdentifier(teamID) else { throw Invalid.teamID }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { throw Invalid.key }
        self.keyID = keyID; self.teamID = teamID; keyData = key.rawRepresentation
    }
    init(keyID: String, teamID: String, key: P256.Signing.PrivateKey) {
        self.keyID = keyID; self.teamID = teamID; keyData = key.rawRepresentation
    }
    /// 10 ASCII letters or digits.
    public static func validIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
    /// The Key ID in Apple's download name `AuthKey_<KEYID>.p8`, or nil.
    public static func keyID(fileName: String) -> String? {
        guard fileName.hasPrefix("AuthKey_"), fileName.lowercased().hasSuffix(".p8") else { return nil }
        let value = String(fileName.dropFirst("AuthKey_".count).dropLast(3))
        return validIdentifier(value) ? value : nil
    }
    var key: P256.Signing.PrivateKey { get throws { try P256.Signing.PrivateKey(rawRepresentation: keyData) } }
    public var description: String { "APNsCredentials(keyID: \(keyID), teamID: \(teamID))" }
    public var debugDescription: String { description }
}

/// One cached provider token (ES256 JWT) per key. Renewed after 50 minutes; `renewIfStale()` refuses before 20 minutes
/// (APNs: refresh no more than once every 20 and no less than once every 60 minutes).
public actor APNsTokenSource {
    public static let renewalAge: TimeInterval = 50 * 60
    public static let minimumAge: TimeInterval = 20 * 60
    private let credentials: APNsCredentials
    private let clock: @Sendable () -> Date
    private var cached: (token: String, issued: Date)?
    public init(credentials: APNsCredentials, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.clock = clock
    }
    /// When the cached token was issued; nil before the first `token()`.
    public var issued: Date? { cached?.issued }
    /// Age of the cached token by the injected clock; nil before the first `token()`.
    public func age() -> TimeInterval? { cached.map { clock().timeIntervalSince($0.issued) } }
    /// The cached token, or a new one when none exists, it is 50 minutes old, or the clock moved back over 5 minutes.
    public func token() throws -> String {
        let now = clock()
        if let cached {
            let age = now.timeIntervalSince(cached.issued)
            if age < Self.renewalAge && age > -300 { return cached.token }
        }
        return try issue(now: now)
    }
    /// After `ExpiredProviderToken`: issues a new token only if the cached one is at least 20 minutes old.
    /// Returns false (and keeps the token) otherwise.
    public func renewIfStale() throws -> Bool {
        let now = clock()
        if let cached, now.timeIntervalSince(cached.issued) < Self.minimumAge { return false }
        _ = try issue(now: now)
        return true
    }
    private func issue(now: Date) throws -> String {
        let value = try Self.jwt(credentials: credentials, issued: now)
        cached = (value, now)
        return value
    }
    /// `base64url(header).base64url(claims).base64url(signature)`; the signature is the 64-byte raw ES256 form.
    static func jwt(credentials: APNsCredentials, issued: Date) throws -> String {
        // Both identifiers are validated alphanumerics, so the JSON needs no escaping.
        let header = #"{"alg":"ES256","kid":"\#(credentials.keyID)"}"#
        let claims = #"{"iss":"\#(credentials.teamID)","iat":\#(Int(issued.timeIntervalSince1970))}"#
        let input = base64URL(Data(header.utf8)) + "." + base64URL(Data(claims.utf8))
        let signature = try credentials.key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What a notification is about. Text is produced per device language from the subject, never from Mac-localized titles.
public enum PushSubject: Sendable, Hashable {
    case approval, question, accessRequest
    case turnReady, turnStopped, turnFailed
    case blocker(job: String), taskProblem(job: String), quotaWait(job: String)
    case test
    public var kind: PushMarker.Kind {
        switch self {
        case .approval, .question, .accessRequest: .action
        case .turnReady, .turnStopped, .turnFailed: .turn
        case .blocker, .taskProblem, .quotaWait: .attention
        case .test: .test
        }
    }
    /// Notification title in `language`. A job name is cut to 60 characters and kept on one line.
    public func title(language: AppLanguage) -> String {
        func name(_ job: String) -> String {
            let line = job.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
        return switch self {
        case .approval: L10n.text("Нужно разрешение", "Approval needed", language: language)
        case .question: L10n.text("Нужен ваш ответ", "Your answer is needed", language: language)
        case .accessRequest: L10n.text("Запрос доступа к проекту", "Project access request", language: language)
        case .turnReady: L10n.text("Ответ готов", "Reply ready", language: language)
        case .turnStopped: L10n.text("Ход остановлен", "Turn stopped", language: language)
        case .turnFailed: L10n.text("Ход завершился ошибкой", "Turn failed", language: language)
        case .blocker(let job): L10n.text("Задача «\(name(job))» заблокирована", "Task “\(name(job))” is blocked", language: language)
        case .taskProblem(let job): L10n.text("Проблема в задаче «\(name(job))»", "Problem in task “\(name(job))”", language: language)
        case .quotaWait(let job): L10n.text("Задача «\(name(job))» ждёт лимита", "Task “\(name(job))” is waiting for usage limits", language: language)
        case .test: L10n.text("Тестовое уведомление Switchboard", "Switchboard test notification", language: language)
        }
    }
}

/// One notification-worthy event on the Mac. `chatTitle` and `text` are used only with the "include chat title and
/// text" setting; the default payload has title = subject and body = project name.
public struct PushEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var subject: PushSubject
    /// Chat ID; nil only for `test`.
    public var chat: String?
    public var project: String
    public var chatTitle: String?
    public var text: String?
    public var created: Date
    public init(id: String, subject: PushSubject, chat: String?, project: String, chatTitle: String? = nil, text: String? = nil, created: Date) {
        self.id = id; self.subject = subject; self.chat = chat; self.project = project
        self.chatTitle = chatTitle; self.text = text; self.created = created
    }
    public var kind: PushMarker.Kind { subject.kind }
    /// `apns-expiration` lifetime: actions 1 hour, turns and attention 15 minutes, test 0 (one attempt, not stored).
    public var lifetime: TimeInterval {
        switch kind { case .action: 3600; case .turn, .attention: 900; case .test, .withdraw: 0 }
    }
    public static func turnID(chat: String, turn: String) -> String { "turn:\(chat):\(turn)" }
    public static func attentionID(_ id: UUID) -> String { "attention:\(id.uuidString.lowercased())" }
}

/// One APNs POST: headers per plan 4.1, JSON body per 4.7 (at most 4096 bytes).
public struct APNsRequest: Sendable, Equatable {
    public static let payloadLimit = 4096
    public static let detailLimit = 300
    public enum PushType: String, Sendable { case alert, background }
    public var id: UUID
    public var pushType: PushType
    public var priority: Int
    /// Epoch seconds; 0 = one delivery attempt, not stored by APNs.
    public var expiration: Int
    public var collapseID: String?
    public var topic: String
    public var body: Data

    /// A visible notification of `event` for `device`, text in the device's language. `mac` is the sending Mac's device
    /// ID. With `detail`, subtitle = `project · chat title`, body = the event text cut to 300 characters; otherwise
    /// title = subject and body = project name. Text is shortened further until the JSON fits 4096 bytes.
    public static func alert(event: PushEvent, device: RemotePushDevice, mac: String, badge: Int?, detail: Bool, now: Date) -> APNsRequest {
        let language = device.language
        var title = clip(event.subject.title(language: language), 200)
        var subtitle: String?
        var body = clip(event.project, 200)
        if detail {
            if let chatTitle = event.chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !chatTitle.isEmpty {
                subtitle = clip(event.project, 100) + " · " + clip(chatTitle, 200)
            }
            if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { body = clip(text, detailLimit) }
        }
        let interruption = event.kind == .action ? "time-sensitive" : "active"
        let marker = PushMarker(kind: event.kind, device: mac, chat: event.chat, event: event.id)
        func encode() -> Data {
            var alert: [String: Any] = ["title": title, "body": body]
            if let subtitle { alert["subtitle"] = subtitle }
            var aps: [String: Any] = ["alert": alert, "sound": "default", "interruption-level": interruption,
                                      "thread-id": threadID(mac: mac, chat: event.chat)]
            if let badge { aps["badge"] = max(0, badge) }
            return json(["aps": aps, PushMarker.key: marker.dictionary])
        }
        var data = encode()
        // Each removed character removes at least one byte; the ellipsis adds three.
        while data.count > payloadLimit {
            let excess = data.count - payloadLimit + 3
            if body.count > 1 { body = shorten(body, by: excess) }
            else if let value = subtitle, value.count > 1 { subtitle = shorten(value, by: excess) }
            else if title.count > 1 { title = shorten(title, by: excess) }
            else { break }
            data = encode()
        }
        let collapse: String? = switch event.kind {
        case .turn: event.chat.map { collapseID(for: "turn:\($0)") }
        case .action, .attention: collapseID(for: event.id)
        case .test, .withdraw: nil
        }
        return APNsRequest(id: UUID(), pushType: .alert, priority: event.kind == .attention ? 5 : 10,
                           expiration: event.lifetime > 0 ? Int(event.created.addingTimeInterval(event.lifetime).timeIntervalSince1970) : 0,
                           collapseID: collapse, topic: device.topic, body: data)
    }

    /// A background push that withdraws delivered notifications: `{"aps":{"content-available":1},"sb":{…}}`,
    /// priority 5, not stored (expiration 0), no collapse ID.
    public static func withdrawal(marker: PushMarker, topic: String) -> APNsRequest {
        APNsRequest(id: UUID(), pushType: .background, priority: 5, expiration: 0, collapseID: nil, topic: topic,
                    body: json(["aps": ["content-available": 1], PushMarker.key: marker.dictionary]))
    }

    /// The value itself when it fits APNs' 64-byte limit, otherwise its SHA-256 as 64 hexadecimal characters.
    public static func collapseID(for value: String) -> String {
        value.utf8.count <= 64 ? value : SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// `<mac>:<16 hex characters of the chat's SHA-256>` groups one chat's notifications without exposing its ID.
    static func threadID(mac: String, chat: String?) -> String {
        guard let chat else { return "\(mac.lowercased()):test" }
        return "\(mac.lowercased()):" + SHA256.hash(data: Data(chat.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func json(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
    static func clip(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit - 1)) + "…" : text }
    static func shorten(_ text: String, by count: Int) -> String {
        let keep = max(0, text.count - count - 1)
        return keep == 0 ? "…" : String(text.prefix(keep)) + "…"
    }

    /// The HTTP request for `token` (lowercase hex) with the provider token `jwt`.
    public func urlRequest(environment: APNsEnvironment, token: String, jwt: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(environment.host)/3/device/\(token)")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 20
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bearer " + jwt, forHTTPHeaderField: "authorization")
        return request
    }
    /// APNs headers except `authorization`.
    public var headers: [String: String] {
        var value = ["apns-topic": topic, "apns-push-type": pushType.rawValue, "apns-priority": String(priority),
                     "apns-expiration": String(expiration), "apns-id": id.uuidString.lowercased(),
                     "content-type": "application/json"]
        if let collapseID { value["apns-collapse-id"] = collapseID }
        return value
    }
}

/// The result of one send, mapped from APNs' status and `reason` (plan 1.3, 4.4).
public enum APNsOutcome: Sendable, Equatable {
    case delivered
    /// 410, `BadDeviceToken`, `DeviceTokenNotForTopic`: delete the row if registered before `since` (nil = now).
    case tokenGone(since: Date?)
    /// `ExpiredProviderToken`. `APNsClient.send` handles it and never returns it.
    case tokenExpired
    /// Other 403 (`InvalidProviderToken`, `BadEnvironmentKeyIdInToken`, …) or an unusable key: stop until the key changes.
    case credentials(String)
    /// 429 (60 seconds) and 5xx (15 minutes).
    case retry(after: TimeInterval)
    /// Other 4xx: a bug or an invalid request. Drop, no retry.
    case rejected(String)
    /// Transport failure: no HTTP answer.
    case unreachable

    public static func classify(status: Int, body: Data) -> APNsOutcome {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let raw = object?["reason"] as? String ?? ""
        // Reasons are short ASCII words; anything else is replaced so logs never carry response text.
        let reason = !raw.isEmpty && raw.count <= 64 && raw.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) ? raw : "HTTP \(status)"
        switch (status, reason) {
        case (200, _): return .delivered
        case (400, "BadDeviceToken"), (400, "DeviceTokenNotForTopic"): return .tokenGone(since: nil)
        case (410, _):
            let milliseconds = (object?["timestamp"] as? NSNumber)?.doubleValue
            return .tokenGone(since: milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) })
        case (403, "ExpiredProviderToken"): return .tokenExpired
        case (403, _): return .credentials(reason)
        case (429, _): return .retry(after: 60)
        case (500...599, _): return .retry(after: 15 * 60)
        default: return .rejected(reason)
        }
    }
}

/// HTTP transport for `APNsClient`, injectable for tests.
public protocol APNsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral URLSession transport, one session per APNs host (a connection never mixes environments).
public struct APNsSessionTransport: APNsTransport {
    private let sessions: [String: URLSession]
    public init() {
        var sessions: [String: URLSession] = [:]
        for environment in APNsEnvironment.allCases {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            sessions[environment.host] = URLSession(configuration: configuration)
        }
        self.sessions = sessions
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let host = request.url?.host, let session = sessions[host] else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

/// Sends requests to APNs with the cached provider token. Never logs; outcomes carry reasons only.
public actor APNsClient {
    private let tokens: APNsTokenSource
    private let transport: any APNsTransport
    public init(tokens: APNsTokenSource, transport: any APNsTransport = APNsSessionTransport()) {
        self.tokens = tokens; self.transport = transport
    }
    public init(credentials: APNsCredentials, clock: @escaping @Sendable () -> Date = { Date() }, transport: any APNsTransport = APNsSessionTransport()) {
        self.init(tokens: APNsTokenSource(credentials: credentials, clock: clock), transport: transport)
    }
    /// One delivery to one device. `ExpiredProviderToken` renews the token (only if it is 20 minutes old) and retries
    /// once; a younger token yields `retry(after:)` until renewal is allowed. Invalid device rows give `rejected`.
    public func send(_ request: APNsRequest, device: RemotePushDevice) async -> APNsOutcome {
        guard (try? device.validate()) != nil, let environment = APNsEnvironment(rawValue: device.environment) else {
            return .rejected("InvalidDevice")
        }
        let outcome = await attempt(request, environment: environment, token: device.token)
        guard outcome == .tokenExpired else { return outcome }
        do {
            guard try await tokens.renewIfStale() else {
                return .retry(after: max(60, APNsTokenSource.minimumAge - (await tokens.age() ?? 0)))
            }
        } catch { return .credentials("SigningFailed") }
        let second = await attempt(request, environment: environment, token: device.token)
        return second == .tokenExpired ? .credentials("ExpiredProviderToken") : second
    }
    private func attempt(_ request: APNsRequest, environment: APNsEnvironment, token: String) async -> APNsOutcome {
        let jwt: String
        do { jwt = try await tokens.token() } catch { return .credentials("SigningFailed") }
        do {
            let (data, response) = try await transport.send(request.urlRequest(environment: environment, token: token, jwt: jwt))
            return .classify(status: response.statusCode, body: data)
        } catch { return .unreachable }
    }
}
