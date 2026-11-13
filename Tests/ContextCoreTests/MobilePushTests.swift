import Foundation
import Testing
@testable import ContextCore

private let pushMac = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
private func pushDevice(token: String = String(repeating: "ab", count: 32), environment: String = "development",
                        topic: String = "com.contextdesk.mobile", locale: String = "ru") -> RemotePushDevice {
    RemotePushDevice(id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", token: token, environment: environment, topic: topic, locale: locale)
}

@Test func pushDeviceValidationMirrorsTheDatabase() throws {
    try pushDevice().validate()
    try pushDevice(token: String(repeating: "0", count: 400), environment: "production", topic: "a", locale: "en").validate()
    for bad in [pushDevice(token: String(repeating: "a", count: 63)), pushDevice(token: String(repeating: "a", count: 401)),
                pushDevice(token: String(repeating: "A", count: 64)), pushDevice(token: String(repeating: "g", count: 64)),
                pushDevice(environment: "sandbox"), pushDevice(topic: ""), pushDevice(topic: "com/evil"),
                pushDevice(topic: String(repeating: "a", count: 156)), pushDevice(topic: "com.app\n"), pushDevice(locale: "de"),
                RemotePushDevice(id: "not-a-uuid", token: String(repeating: "a", count: 64), environment: "development", topic: "t", locale: "en")] {
        #expect(throws: RemoteFailure.self) { try bad.validate() }
    }
    #expect(pushDevice(locale: "en").language == .english && pushDevice().language == .russian)
    #expect(RemotePushDevice.hex(Data([0x00, 0x0f, 0xa5, 0xff])) == "000fa5ff")
    #expect(RemotePushDevice.hex(Data()) == "")
}

@Test func pushMarkerRoundTripsThroughJSON() throws {
    let markers = [
        PushMarker(kind: .action, device: pushMac.uppercased(), chat: "chat-1", event: "11111111-2222-3333-4444-555555555555"),
        PushMarker(kind: .turn, device: pushMac, chat: "чат", event: "turn:чат:t1"),
        PushMarker(kind: .attention, device: pushMac, chat: "c", event: "attention:x"),
        PushMarker(kind: .test, device: pushMac),
        PushMarker(kind: .withdraw, device: pushMac, withdrawn: ["a", "b"], withdrawnChats: ["c"], badge: 3),
    ]
    for marker in markers {
        #expect(marker.device == pushMac)
        // As delivered on the phone: JSON parsed by the system into Foundation objects.
        let data = try JSONSerialization.data(withJSONObject: [PushMarker.key: marker.dictionary, "aps": ["alert": "x"]])
        let userInfo = try #require(try JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
        #expect(PushMarker(userInfo: userInfo) == marker)
        #expect(PushMarker(userInfo: [PushMarker.key: marker.dictionary]) == marker)
    }
    #expect(PushMarker(kind: .test, device: pushMac).dictionary.keys.sorted() == ["d", "k"])
}

@Test func pushMarkerRejectsHostileInput() throws {
    let valid: [String: Any] = ["k": "action", "d": pushMac, "c": "chat", "i": "event"]
    #expect(PushMarker(userInfo: ["sb": valid]) != nil)
    func with(_ changes: [String: Any?]) -> [AnyHashable: Any] {
        var value = valid
        for (key, item) in changes { value[key] = item }
        return ["sb": value]
    }
    let long = String(repeating: "я", count: 257)
    let hostile: [[AnyHashable: Any]] = [
        [:], ["sb": "text"], ["sb": [valid]], ["sb": NSNull()], ["other": valid],
        with(["k": "delete"]), with(["k": nil]), with(["k": 1]),
        with(["d": nil]), with(["d": "mac"]), with(["d": 5]), with(["d": "{" + pushMac + "}"]), with(["d": pushMac + "0"]),
        with(["c": 7]), with(["c": ""]), with(["c": "a\nb"]), with(["c": "a\u{0}b"]), with(["c": long]), with(["c": nil]),
        with(["i": ["x"]]), with(["i": nil]), with(["i": "a\u{2028}b"]),
        with(["w": ["x"]]), with(["wc": ["x"]]),
        with(["n": true]), with(["n": -1]), with(["n": 1.5]), with(["n": "2"]), with(["n": 10_000]),
        ["sb": ["k": "withdraw", "d": pushMac]],
        ["sb": ["k": "withdraw", "d": pushMac, "w": []]],
        ["sb": ["k": "withdraw", "d": pushMac, "w": "x"]],
        ["sb": ["k": "withdraw", "d": pushMac, "w": ["x", 1]]],
        ["sb": ["k": "withdraw", "d": pushMac, "w": Array(repeating: "x", count: 65)]],
        ["sb": ["k": "withdraw", "d": pushMac, "wc": [""]]],
        ["sb": ["k": "test", "d": pushMac, "w": ["x"]]],
    ]
    for userInfo in hostile { #expect(PushMarker(userInfo: userInfo) == nil, "\(userInfo)") }
    // Bounds hold exactly at the limits.
    #expect(PushMarker(userInfo: ["sb": ["k": "withdraw", "d": pushMac, "w": Array(repeating: "x", count: 64), "n": 9999]])?.badge == 9999)
    #expect(PushMarker(userInfo: with(["c": String(repeating: "я", count: 256)])) != nil)
    #expect(PushMarker(userInfo: with(["n": 0]))?.badge == 0)
}

@Test func pushMarkerWithdrawalMatchesEventsAndTurnChats() {
    let action = PushMarker(kind: .action, device: pushMac, chat: "c1", event: "e1")
    let turn = PushMarker(kind: .turn, device: pushMac, chat: "c1", event: "turn:c1:t")
    let byEvent = PushMarker(kind: .withdraw, device: pushMac, withdrawn: ["e1"])
    let byChat = PushMarker(kind: .withdraw, device: pushMac, withdrawnChats: ["c1"])
    #expect(action.isWithdrawn(by: byEvent))
    #expect(!turn.isWithdrawn(by: byEvent))
    #expect(turn.isWithdrawn(by: byChat))
    #expect(!action.isWithdrawn(by: byChat))
    #expect(!action.isWithdrawn(by: PushMarker(kind: .withdraw, device: "cccccccc-cccc-cccc-cccc-cccccccccccc", withdrawn: ["e1"])))
    #expect(!action.isWithdrawn(by: action))
    #expect(!byEvent.isWithdrawn(by: byEvent))
}

// MARK: - RemoteAPI push calls

private final class PushRecorder: @unchecked Sendable {
    let lock = NSLock()
    var requests: [(method: String, url: String, body: Data?)] = []
    var status = 200
    var response = Data("[]".utf8)
}
private final class PushRecorderRegistry: @unchecked Sendable {
    let lock = NSLock()
    var entries: [String: PushRecorder] = [:]
    func get(_ host: String) -> PushRecorder? { lock.withLock { entries[host] } }
    func set(_ host: String, _ value: PushRecorder?) { lock.withLock { entries[host] = value } }
}
private final class PushURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = PushRecorderRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.get(request.url!.host!) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let recorder = Self.registry.get(request.url!.host!) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            body = data
        }
        let (status, data) = recorder.lock.withLock {
            recorder.requests.append((request.httpMethod ?? "", request.url!.absoluteString, body))
            return (recorder.status, recorder.response)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func pushAPI(_ recorder: PushRecorder, host: String) throws -> RemoteAPI {
    PushURLProtocol.registry.set(host, recorder)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PushURLProtocol.self]
    let session = try JSONSerialization.data(withJSONObject: ["access_token": "a", "refresh_token": "r",
        "expires_at": Date().timeIntervalSince1970 + 3600, "user": ["id": "11111111-1111-1111-1111-111111111111"]])
    return try RemoteAPI(url: "https://" + host, key: "sb_publishable_fixture", transport: URLSession(configuration: configuration),
                         storage: RemoteSessionStorage(read: { _ in session }, write: { _, _ in }))
}

@Test func remoteAPIPushCallsUseTheMigrationContract() async throws {
    let recorder = PushRecorder(); let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try pushAPI(recorder, host: host)
    defer { PushURLProtocol.registry.set(host, nil) }
    let device = pushDevice()
    try await api.registerPush(device)
    try await api.unregisterPush(id: device.id.uppercased())
    try await api.removePushDevice(device, invalidSince: Date(timeIntervalSince1970: 1_800_000_000.25))
    recorder.lock.withLock { recorder.response = try! JSONSerialization.data(withJSONObject: [
        ["id": device.id, "token": device.token, "environment": "development", "topic": "com.contextdesk.mobile", "locale": "en"],
        ["id": device.id, "token": "bad", "environment": "development", "topic": "com.contextdesk.mobile", "locale": "en"]]) }
    let devices = try await api.pushDevices()
    #expect(devices.count == 1 && devices.first?.locale == "en")
    let requests = recorder.lock.withLock { recorder.requests }
    #expect(requests.count == 4)
    #expect(requests[0].method == "POST" && requests[0].url.hasSuffix("/rest/v1/rpc/register_remote_push"))
    let body = try #require(try JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: String])
    #expect(body == ["device_id": device.id, "device_token": device.token, "apns_environment": "development",
                     "apns_topic": "com.contextdesk.mobile", "language": "ru"])
    #expect(requests[1].method == "DELETE" && requests[1].url.hasSuffix("/rest/v1/remote_push_devices?id=eq.\(device.id)"))
    #expect(requests[2].method == "DELETE")
    #expect(requests[2].url.hasSuffix("remote_push_devices?id=eq.\(device.id)&token=eq.\(device.token)&updated=lt.2027-01-15T08:00:00.250Z"))
    #expect(requests[3].method == "GET" && requests[3].url.contains("remote_push_devices?select=id,token,environment,topic,locale"))
    // Invalid input never reaches the network.
    await #expect(throws: RemoteFailure.self) { try await api.registerPush(pushDevice(locale: "de")) }
    await #expect(throws: RemoteFailure.self) { try await api.unregisterPush(id: "x&id=neq.0") }
    #expect(recorder.lock.withLock { recorder.requests.count } == 4)
}

@Test func remoteAPIPushVersionGate() async throws {
    let recorder = PushRecorder(); let host = UUID().uuidString.lowercased() + ".invalid"
    let api = try pushAPI(recorder, host: host)
    defer { PushURLProtocol.registry.set(host, nil) }
    recorder.lock.withLock { recorder.status = 404 }
    #expect(try await api.supportsPush() == false)
    recorder.lock.withLock { recorder.status = 200; recorder.response = Data("1".utf8) }
    #expect(try await api.supportsPush())
    recorder.lock.withLock { recorder.response = Data("2".utf8) }
    #expect(try await api.supportsPush() == false)
    recorder.lock.withLock { recorder.status = 500 }
    await #expect(throws: RemoteFailure.self) { try await api.supportsPush() }
}
