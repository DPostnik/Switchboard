import CryptoKit
import Foundation
import Testing
@testable import ContextCore

private let apnsMac = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
private func apnsDevice(locale: String = "en", environment: String = "development") -> RemotePushDevice {
    RemotePushDevice(id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", token: String(repeating: "0a", count: 32),
                     environment: environment, topic: "com.contextdesk.mobile", locale: locale)
}
private func apnsCredentials(_ key: P256.Signing.PrivateKey = .init()) throws -> APNsCredentials {
    try APNsCredentials(keyID: "ABCDE12345", teamID: "4M74WJDNSW", pem: key.pemRepresentation)
}
private final class TestClock: @unchecked Sendable {
    let lock = NSLock(); var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
private func base64URLDecode(_ text: Substring) -> Data? {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    return Data(base64Encoded: value)
}
private func payload(_ request: APNsRequest) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
}

@Test func apnsCredentialsValidateIdentifiersAndKey() throws {
    let key = P256.Signing.PrivateKey()
    let credentials = try apnsCredentials(key)
    #expect(credentials.keyID == "ABCDE12345")
    #expect(!credentials.description.contains("PRIVATE") && !String(reflecting: credentials).contains(key.pemRepresentation))
    #expect(throws: APNsCredentials.Invalid.keyID) { try APNsCredentials(keyID: "ABC", teamID: "4M74WJDNSW", pem: key.pemRepresentation) }
    #expect(throws: APNsCredentials.Invalid.keyID) { try APNsCredentials(keyID: "ABCDE1234Я", teamID: "4M74WJDNSW", pem: key.pemRepresentation) }
    #expect(throws: APNsCredentials.Invalid.teamID) { try APNsCredentials(keyID: "ABCDE12345", teamID: "4M74WJDNS!", pem: key.pemRepresentation) }
    #expect(throws: APNsCredentials.Invalid.key) { try APNsCredentials(keyID: "ABCDE12345", teamID: "4M74WJDNSW", pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----") }
    #expect(throws: APNsCredentials.Invalid.key) { try APNsCredentials(keyID: "ABCDE12345", teamID: "4M74WJDNSW", pem: P384.Signing.PrivateKey().pemRepresentation) }
    #expect(APNsCredentials.keyID(fileName: "AuthKey_ABCDE12345.p8") == "ABCDE12345")
    #expect(APNsCredentials.keyID(fileName: "AuthKey_ABC.p8") == nil && APNsCredentials.keyID(fileName: "key.p8") == nil)
    for language in AppLanguage.allCases {
        #expect(!APNsCredentials.Invalid.key.message(language: language).isEmpty)
    }
    #expect(APNsEnvironment.development.host == "api.sandbox.push.apple.com" && APNsEnvironment.production.host == "api.push.apple.com")
}

@Test func apnsTokenIsAVerifiableES256JWT() async throws {
    let key = P256.Signing.PrivateKey()
    let clock = TestClock()
    let source = APNsTokenSource(credentials: try apnsCredentials(key), clock: { clock.now })
    let token = try await source.token()
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 3 && !token.contains("=") && !token.contains("+") && !token.contains("/"))
    let headerData = try #require(base64URLDecode(parts[0])), claimsData = try #require(base64URLDecode(parts[1]))
    let header = try #require(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
    let claims = try #require(try JSONSerialization.jsonObject(with: claimsData) as? [String: Any])
    #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "ABCDE12345" && header.count == 2)
    #expect(claims["iss"] as? String == "4M74WJDNSW" && claims["iat"] as? Int == 1_800_000_000 && claims.count == 2)
    let signature = try #require(base64URLDecode(parts[2]))
    #expect(signature.count == 64)
    let verified = try P256.Signing.ECDSASignature(rawRepresentation: signature)
    #expect(key.publicKey.isValidSignature(verified, for: Data((parts[0] + "." + parts[1]).utf8)))
    #expect(!P256.Signing.PrivateKey().publicKey.isValidSignature(verified, for: Data((parts[0] + "." + parts[1]).utf8)))
}

@Test func apnsTokenRenewalWindows() async throws {
    let clock = TestClock()
    let source = APNsTokenSource(credentials: try apnsCredentials(), clock: { clock.now })
    let first = try await source.token()
    clock.advance(49 * 60)
    #expect(try await source.token() == first)
    // ExpiredProviderToken before 20 minutes: no renewal (TooManyProviderTokenUpdates).
    let fresh = APNsTokenSource(credentials: try apnsCredentials(), clock: { clock.now })
    let early = try await fresh.token()
    clock.advance(19 * 60)
    #expect(try await fresh.renewIfStale() == false)
    #expect(try await fresh.token() == early)
    clock.advance(60)
    #expect(try await fresh.renewIfStale())
    #expect(try await fresh.token() != early)
    #expect(await fresh.age() == 0)
    // The first source reaches 50 minutes: renewed on the next use.
    clock.advance(60)
    let renewed = try await source.token()
    #expect(renewed != first)
    #expect(await source.issued == clock.now)
    // A clock that moved back far renews instead of sending a token from the future.
    clock.advance(-600)
    #expect(try await source.token() != renewed)
}

@Test func apnsCollapseIDsAreHashedOver64Bytes() {
    #expect(APNsRequest.collapseID(for: "turn:chat") == "turn:chat")
    let exact = String(repeating: "a", count: 64)
    #expect(APNsRequest.collapseID(for: exact) == exact)
    let long = "turn:" + String(repeating: "я", count: 30)
    let hashed = APNsRequest.collapseID(for: long)
    #expect(hashed.count == 64 && hashed.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(hashed == SHA256.hash(data: Data(long.utf8)).map { String(format: "%02x", $0) }.joined())
    #expect(APNsRequest.collapseID(for: long + "x") != hashed)
}

@Test func apnsAlertHeadersPerKind() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func request(_ subject: PushSubject, id: String = "event-1", chat: String? = "chat-1") -> APNsRequest {
        APNsRequest.alert(event: PushEvent(id: id, subject: subject, chat: chat, project: "Project", created: now),
                          device: apnsDevice(), mac: apnsMac, badge: 2, detail: false, now: now)
    }
    let action = request(.approval)
    #expect(action.pushType == .alert && action.priority == 10 && action.expiration == 1_800_003_600 && action.collapseID == "event-1")
    #expect((try payload(action)["aps"] as? [String: Any])?["interruption-level"] as? String == "time-sensitive")
    let turn = request(.turnReady, id: PushEvent.turnID(chat: "chat-1", turn: "t9"))
    #expect(turn.priority == 10 && turn.expiration == 1_800_000_900 && turn.collapseID == "turn:chat-1")
    #expect((try payload(turn)["aps"] as? [String: Any])?["interruption-level"] as? String == "active")
    let attentionID = PushEvent.attentionID(UUID())
    let attention = request(.blocker(job: "Nightly"), id: attentionID)
    #expect(attention.priority == 5 && attention.expiration == 1_800_000_900 && attention.collapseID == attentionID)
    let test = request(.test, id: "test-1", chat: nil)
    #expect(test.priority == 10 && test.expiration == 0 && test.collapseID == nil)
    let longChat = String(repeating: "c", count: 100)
    #expect(request(.turnFailed, id: "t", chat: longChat).collapseID?.count == 64)
    let http = action.urlRequest(environment: .development, token: apnsDevice().token, jwt: "jwt")
    func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
    #expect(header("apns-topic") == "com.contextdesk.mobile" && header("apns-push-type") == "alert" && header("apns-priority") == "10")
    #expect(header("apns-expiration") == "1800003600" && header("apns-collapse-id") == "event-1" && header("authorization") == "bearer jwt")
    #expect(header("apns-id") == action.id.uuidString.lowercased())
    let url = action.urlRequest(environment: .production, token: apnsDevice().token, jwt: "jwt")
    #expect(url.url?.absoluteString == "https://api.push.apple.com/3/device/" + apnsDevice().token && url.httpMethod == "POST")
    // Withdrawal: background, priority 5, not stored, no alert and no badge in aps.
    let marker = PushMarker(kind: .withdraw, device: apnsMac, withdrawn: ["event-1"], withdrawnChats: ["chat-1"], badge: 1)
    let withdrawal = APNsRequest.withdrawal(marker: marker, topic: "com.contextdesk.mobile")
    #expect(withdrawal.pushType == .background && withdrawal.priority == 5 && withdrawal.expiration == 0 && withdrawal.collapseID == nil)
    let body = try payload(withdrawal)
    #expect((body["aps"] as? [String: Any])?.keys.sorted() == ["content-available"])
    #expect(PushMarker(userInfo: body) == marker)
    #expect(withdrawal.headers["apns-push-type"] == "background")
}

@Test func apnsAlertTextFollowsDeviceLanguageAndPrivacy() throws {
    let now = Date()
    let event = PushEvent(id: "e", subject: .approval, chat: "chat-1", project: "Switchboard",
                          chatTitle: "Секретный чат", text: "rm -rf build", created: now)
    for (locale, title) in [("ru", "Нужно разрешение"), ("en", "Approval needed")] {
        let plain = try payload(APNsRequest.alert(event: event, device: apnsDevice(locale: locale), mac: apnsMac, badge: 4, detail: false, now: now))
        let aps = try #require(plain["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == title && alert["body"] as? String == "Switchboard" && alert["subtitle"] == nil)
        #expect(aps["badge"] as? Int == 4 && aps["sound"] as? String == "default")
        #expect((aps["thread-id"] as? String)?.hasPrefix(apnsMac + ":") == true && !(aps["thread-id"] as! String).contains("chat-1"))
        #expect(PushMarker(userInfo: plain) == PushMarker(kind: .action, device: apnsMac, chat: "chat-1", event: "e"))
    }
    let detailed = try payload(APNsRequest.alert(event: event, device: apnsDevice(), mac: apnsMac, badge: nil, detail: true, now: now))
    let alert = try #require((detailed["aps"] as? [String: Any])?["alert"] as? [String: Any])
    #expect(alert["subtitle"] as? String == "Switchboard · Секретный чат" && alert["body"] as? String == "rm -rf build")
    #expect((detailed["aps"] as? [String: Any])?["badge"] == nil)
    let long = PushEvent(id: "e", subject: .turnReady, chat: "c", project: "P", text: String(repeating: "x", count: 1000), created: now)
    let cut = try payload(APNsRequest.alert(event: long, device: apnsDevice(), mac: apnsMac, badge: nil, detail: true, now: now))
    #expect(((cut["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String == String(repeating: "x", count: 299) + "…")
    // Every subject has text in both languages, and they differ.
    let subjects: [PushSubject] = [.approval, .question, .accessRequest, .turnReady, .turnStopped, .turnFailed,
                                   .blocker(job: "J"), .taskProblem(job: "J"), .quotaWait(job: "J"), .test]
    for subject in subjects {
        let ru = subject.title(language: .russian), en = subject.title(language: .english)
        #expect(!ru.isEmpty && !en.isEmpty && ru != en)
    }
    let job = PushSubject.blocker(job: String(repeating: "j", count: 100) + "\nsecond").title(language: .english)
    #expect(!job.contains("\n") && job.count < 100)
}

@Test func apnsPayloadFitsLimitWithLongCyrillic() throws {
    let now = Date()
    // Multi-scalar graphemes (25 bytes each) and control characters (escaped to 6 bytes) force the shrinking loop.
    let huge = String(repeating: "Щ\u{301}ука 👨‍👩‍👧‍👦\u{1}", count: 4000)
    let event = PushEvent(id: String(repeating: "и", count: 256), subject: .taskProblem(job: huge), chat: String(repeating: "ч", count: 256),
                          project: huge, chatTitle: huge, text: huge, created: now)
    for detail in [false, true] {
        let request = APNsRequest.alert(event: event, device: apnsDevice(locale: "ru"), mac: apnsMac, badge: 99, detail: detail, now: now)
        #expect(request.body.count <= APNsRequest.payloadLimit)
        let body = try payload(request)
        #expect(PushMarker(userInfo: body)?.event == event.id)
        let alert = try #require((body["aps"] as? [String: Any])?["alert"] as? [String: Any])
        #expect((alert["body"] as? String)?.hasSuffix("…") == true)
        #expect((alert["title"] as? String)?.hasPrefix("Проблема в задаче") == true)
    }
    // The 300-character detail limit leaves room; the encoded body of a cut Cyrillic text is still valid JSON.
    let text = String(repeating: "ж", count: 5000)
    let request = APNsRequest.alert(event: PushEvent(id: "e", subject: .turnReady, chat: "c", project: "П", text: text, created: now),
                                    device: apnsDevice(locale: "ru"), mac: apnsMac, badge: nil, detail: true, now: now)
    #expect(request.body.count <= APNsRequest.payloadLimit)
}

@Test func apnsClassificationTable() {
    func body(_ reason: String, timestamp: Double? = nil) -> Data {
        var value: [String: Any] = ["reason": reason]
        if let timestamp { value["timestamp"] = timestamp }
        return try! JSONSerialization.data(withJSONObject: value)
    }
    #expect(APNsOutcome.classify(status: 200, body: Data()) == .delivered)
    #expect(APNsOutcome.classify(status: 400, body: body("BadDeviceToken")) == .tokenGone(since: nil))
    #expect(APNsOutcome.classify(status: 400, body: body("DeviceTokenNotForTopic")) == .tokenGone(since: nil))
    #expect(APNsOutcome.classify(status: 410, body: body("Unregistered", timestamp: 1_800_000_000_500)) == .tokenGone(since: Date(timeIntervalSince1970: 1_800_000_000.5)))
    #expect(APNsOutcome.classify(status: 410, body: body("ExpiredToken")) == .tokenGone(since: nil))
    #expect(APNsOutcome.classify(status: 403, body: body("ExpiredProviderToken")) == .tokenExpired)
    #expect(APNsOutcome.classify(status: 403, body: body("InvalidProviderToken")) == .credentials("InvalidProviderToken"))
    #expect(APNsOutcome.classify(status: 403, body: body("BadEnvironmentKeyIdInToken")) == .credentials("BadEnvironmentKeyIdInToken"))
    #expect(APNsOutcome.classify(status: 403, body: body("Forbidden")) == .credentials("Forbidden"))
    #expect(APNsOutcome.classify(status: 413, body: body("PayloadTooLarge")) == .rejected("PayloadTooLarge"))
    #expect(APNsOutcome.classify(status: 400, body: body("BadCollapseId")) == .rejected("BadCollapseId"))
    #expect(APNsOutcome.classify(status: 400, body: body("TopicDisallowed")) == .rejected("TopicDisallowed"))
    #expect(APNsOutcome.classify(status: 429, body: body("TooManyRequests")) == .retry(after: 60))
    #expect(APNsOutcome.classify(status: 429, body: body("TooManyProviderTokenUpdates")) == .retry(after: 60))
    #expect(APNsOutcome.classify(status: 500, body: body("InternalServerError")) == .retry(after: 900))
    #expect(APNsOutcome.classify(status: 503, body: body("ServiceUnavailable")) == .retry(after: 900))
    // Unknown or hostile reason text never passes through.
    #expect(APNsOutcome.classify(status: 400, body: body("token 0a0a0a\nsecret")) == .rejected("HTTP 400"))
    #expect(APNsOutcome.classify(status: 403, body: Data("not json".utf8)) == .credentials("HTTP 403"))
    #expect(APNsOutcome.classify(status: 302, body: Data()) == .rejected("HTTP 302"))
}

private final class FakeAPNsTransport: APNsTransport, @unchecked Sendable {
    let lock = NSLock()
    var answers: [(Int, String)] = []
    var requests: [URLRequest] = []
    var fail = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock {
            requests.append(request)
            if fail { throw URLError(.networkConnectionLost) }
            let (status, reason) = answers.isEmpty ? (200, "") : answers.removeFirst()
            let data = reason.isEmpty ? Data() : Data(#"{"reason":"\#(reason)"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!)
        }
    }
}

@Test func apnsClientSendsAndRenewsExpiredProviderTokensOnce() async throws {
    let clock = TestClock(); let transport = FakeAPNsTransport()
    let client = APNsClient(credentials: try apnsCredentials(), clock: { clock.now }, transport: transport)
    let event = PushEvent(id: "e", subject: .approval, chat: "c", project: "P", created: clock.now)
    let request = APNsRequest.alert(event: event, device: apnsDevice(), mac: apnsMac, badge: nil, detail: false, now: clock.now)
    #expect(await client.send(request, device: apnsDevice()) == .delivered)
    let first = transport.lock.withLock { transport.requests[0] }
    #expect(first.url?.host == "api.sandbox.push.apple.com" && first.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)
    // Expired provider token on a young token: no renewal, retry when renewal is allowed.
    transport.lock.withLock { transport.answers = [(403, "ExpiredProviderToken")] }
    clock.advance(5 * 60)
    #expect(await client.send(request, device: apnsDevice()) == .retry(after: 15 * 60))
    #expect(transport.lock.withLock { transport.requests.count } == 2)
    // Old enough: renewed once and retried with a new token.
    clock.advance(20 * 60)
    transport.lock.withLock { transport.answers = [(403, "ExpiredProviderToken"), (200, "")] }
    #expect(await client.send(request, device: apnsDevice()) == .delivered)
    let tokens = transport.lock.withLock { transport.requests.suffix(2).map { $0.value(forHTTPHeaderField: "authorization") } }
    #expect(tokens.count == 2 && tokens[0] != tokens[1])
    // Expired again right after renewal: a credentials problem, no loop.
    clock.advance(21 * 60)
    transport.lock.withLock { transport.answers = [(403, "ExpiredProviderToken"), (403, "ExpiredProviderToken")] }
    #expect(await client.send(request, device: apnsDevice()) == .credentials("ExpiredProviderToken"))
    transport.lock.withLock { transport.fail = true }
    #expect(await client.send(request, device: apnsDevice()) == .unreachable)
    let count = transport.lock.withLock { transport.requests.count }
    #expect(await client.send(request, device: apnsDevice(environment: "staging")) == .rejected("InvalidDevice"))
    #expect(transport.lock.withLock { transport.requests.count } == count)
    transport.lock.withLock { transport.fail = false; transport.answers = [(410, "Unregistered")] }
    #expect(await client.send(request, device: apnsDevice(environment: "production")) == .tokenGone(since: nil))
    #expect(transport.lock.withLock { transport.requests.last?.url?.host } == "api.push.apple.com")
}

@Test func apnsRetryKeepsTheOriginalExpiration() {
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let event = PushEvent(id: "held", subject: .approval, chat: "c", project: "P", created: created)
    let device = RemotePushDevice(id: UUID().uuidString, token: String(repeating: "a", count: 64),
                                  environment: "development", topic: "com.contextdesk.mobile", locale: "en")
    let request = APNsRequest.alert(event: event, device: device, mac: UUID().uuidString,
                                    badge: 1, detail: false, now: created.addingTimeInterval(1800))
    #expect(request.expiration == 1_800_003_600)
}
