import CryptoKit
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

private actor PushCenterTransport: APNsTransport {
    var requests: [URLRequest] = []
    let status: Int
    let body: String
    init(status: Int = 200, body: String = "{}") { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: [:])!)
    }
    var count: Int { requests.count }
}

@MainActor private func pushCenterFixture(_ transport: PushCenterTransport) throws -> (MobilePushCenter, RemoteAPI, RemotePushDevice) {
    let center = MobilePushCenter()
    let pem = P256.Signing.PrivateKey().pemRepresentation
    center.readKey = { Data(pem.utf8) }
    center.supportsPush = { _ in true }
    center.makeSender = { APNsClient(credentials: $0, transport: transport) }
    let row = RemotePushDevice(id: UUID().uuidString, token: String(repeating: "ab", count: 32),
        environment: "development", topic: "com.contextdesk.mobile", locale: "en")
    center.fetchDevices = { _ in [row] }
    center.away = { true }
    let api = try RemoteAPI(url: "https://push.invalid", key: "sb_publishable_fixture",
                           storage: .init(read: { _ in nil }, write: { _, _ in }))
    return (center, api, row)
}
private func pushCenterEvent() -> PushEvent {
    PushEvent(id: UUID().uuidString, subject: .approval, chat: "chat", project: "project", created: Date())
}

@Test @MainActor func pushCenterDisabledAndFilteredEventsNeverReachTransport() async throws {
    let transport = PushCenterTransport()
    let (center, api, _) = try pushCenterFixture(transport)
    center.valid = { _ in true }
    center.post(pushCenterEvent())
    #expect(await transport.count == 0)
    await center.enable(api: api, mac: UUID().uuidString, keyID: "ABCDEFGHIJ", teamID: "ABCDEFGHIJ")
    center.valid = { _ in false }
    center.post(pushCenterEvent())
    await center.waitForCurrentDelivery()
    #expect(await transport.count == 0)
    center.reset()
}

@Test @MainActor func pushCenterDeletesGoneTokenWithTimestampGuard() async throws {
    let transport = PushCenterTransport(status: 410, body: #"{"reason":"Unregistered","timestamp":1000000}"#)
    let (center, api, row) = try pushCenterFixture(transport)
    var removed: (RemotePushDevice, Date)?
    center.deleteDevice = { _, device, since in removed = (device, since) }
    center.valid = { _ in true }
    await center.enable(api: api, mac: UUID().uuidString, keyID: "ABCDEFGHIJ", teamID: "ABCDEFGHIJ")
    center.post(pushCenterEvent()); await center.waitForCurrentDelivery()
    #expect(removed?.0 == row)
    #expect(removed?.1 == Date(timeIntervalSince1970: 1000))
    center.reset()
}

@Test @MainActor func pushCenterCredentialErrorStopsFurtherSends() async throws {
    let transport = PushCenterTransport(status: 403, body: #"{"reason":"InvalidProviderToken"}"#)
    let (center, api, _) = try pushCenterFixture(transport)
    center.valid = { _ in true }
    await center.enable(api: api, mac: UUID().uuidString, keyID: "ABCDEFGHIJ", teamID: "ABCDEFGHIJ")
    center.post(pushCenterEvent()); await center.waitForCurrentDelivery()
    #expect(center.status.contains("InvalidProviderToken"))
    // Toggling access with the same rejected key must not resume sends.
    await center.enable(api: api, mac: UUID().uuidString, keyID: "ABCDEFGHIJ", teamID: "ABCDEFGHIJ")
    center.post(pushCenterEvent()); await center.waitForCurrentDelivery()
    #expect(await transport.count == 1)
    center.reset()
}
