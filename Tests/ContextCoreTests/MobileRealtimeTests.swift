import Foundation
import Testing
@testable import ContextCore

@MainActor private final class ScriptedRemoteSocket: RemoteSocket {
    var sent: [[String: Any]] = []
    var incoming: [String] = []
    var receiver: CheckedContinuation<String, Error>?
    var closed = false
    var acknowledgeJoin = true
    var acknowledgeHeartbeat = true
    var topic = ""
    var join = ""
    func send(_ text: String) async throws {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        sent.append(value)
        if value["event"] as? String == "phx_join" {
            topic = value["topic"] as! String; join = value["ref"] as! String
            if acknowledgeJoin {
                try push(event: "phx_reply", payload: ["status": "ok"], reference: join)
                try push(event: "system", payload: ["status":"ok","extension":"system"])
            }
        }
        if value["event"] as? String == "heartbeat", acknowledgeHeartbeat {
            try push(event: "phx_reply", payload: ["status": "ok"], reference: value["ref"] as? String, topic: "phoenix")
        }
    }
    func receive() async throws -> String {
        if closed { throw URLError(.networkConnectionLost) }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() {
        closed = true
        let waiting = receiver; receiver = nil
        waiting?.resume(throwing: URLError(.networkConnectionLost))
    }
    func push(event: String, payload: [String: Any], reference: String? = nil, topic: String? = nil) throws {
        var value: [String: Any] = ["topic": topic ?? self.topic, "event": event, "payload": payload]
        if let reference { value["ref"] = reference }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        if let receiver { self.receiver = nil; receiver.resume(returning: text) }
        else { incoming.append(text) }
    }
}

@MainActor private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate())
}
private let remoteTestOwner = "11111111-1111-1111-1111-111111111111"
private let remoteTestDevice = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
@MainActor private func credentials() -> RemoteRealtimeCredentials {
    RemoteRealtimeCredentials(url: URL(string: "wss://example.invalid")!, owner: remoteTestOwner, token: "test-token")
}

@Test @MainActor func realtimeSubscribesBeforeSyncAndHasNoIdleReads() async throws {
    let socket = ScriptedRemoteSocket()
    var reads = 0; var events: [RemoteInvalidation] = []
    let client = RemoteRealtime(role: "phone", device: "phone", credentials: { credentials() }, ready: {
        #expect(socket.sent.contains { $0["event"] as? String == "phx_join" })
        reads += 1
    }, factory: { _ in socket }, heartbeatInterval: .milliseconds(15), deadline: .milliseconds(8), monitorNetwork: false)
    client.onChange = { events.append($0) }
    client.start(); client.start()
    try await eventually { client.state == .connected }
    try socket.push(event: "broadcast", payload: ["event": "changed", "payload": ["entity":"command","device":remoteTestDevice,"id":"cmd"]])
    try await eventually { events.count == 1 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(reads == 1)
    #expect(socket.sent.filter { $0["event"] as? String == "phx_join" }.count == 1)
    #expect(socket.sent.contains { $0["event"] as? String == "heartbeat" })
    let config = socket.sent[0]["payload"] as! [String: Any]
    #expect((config["config"] as? [String: Any])?["private"] as? Bool == true)
    client.stop()
    let sent = socket.sent.count
    try await Task.sleep(for: .milliseconds(50))
    #expect(socket.sent.count == sent && client.state == .stopped)
}

@Test @MainActor func realtimePresenceTracksSessionsAndClearsOnDisconnect() async throws {
    let socket = ScriptedRemoteSocket()
    let client = RemoteRealtime(role: "phone", device: "phone", credentials: { credentials() }, ready: {}, factory: { _ in socket }, monitorNetwork: false)
    client.start(); defer { client.stop() }
    try await eventually { client.state == .connected }
    try socket.push(event: "presence_state", payload: ["mac":["metas":[["role":"mac","device":remoteTestDevice,"phx_ref":"one"]]]])
    try await eventually { client.presence.macs.contains(remoteTestDevice) }
    try socket.push(event: "presence_diff", payload: ["joins":["mac":["metas":[["role":"mac","device":remoteTestDevice,"phx_ref":"two"]]]],"leaves":["mac":["metas":[["phx_ref":"one"]]]]])
    try await Task.sleep(for: .milliseconds(20))
    #expect(client.presence.macs.contains(remoteTestDevice))
    socket.close()
    try await eventually { client.state == .retrying }
    #expect(client.presence.macs.isEmpty)
}

@Test @MainActor func realtimeSilentSocketAndMissingSubscriptionCannotLookConnected() async throws {
    for join in [true, false] {
        let socket = ScriptedRemoteSocket(); socket.acknowledgeJoin = join; socket.acknowledgeHeartbeat = false
        var reads = 0
        let client = RemoteRealtime(role: "phone", device: "phone", credentials: { credentials() }, ready: { reads += 1 },
            factory: { _ in socket }, heartbeatInterval: .milliseconds(15), deadline: .milliseconds(8), monitorNetwork: false)
        client.start()
        try await eventually { client.state == .retrying }
        #expect(reads == (join ? 1 : 0))
        client.stop()
    }
}

@Test @MainActor func realtimeReconnectReconcilesAndNeverSendsCommands() async throws {
    var sockets: [ScriptedRemoteSocket] = []; var reads = 0
    let client = RemoteRealtime(role: "mac", device: remoteTestDevice, credentials: { credentials() }, ready: { reads += 1 },
        factory: { _ in let socket = ScriptedRemoteSocket(); sockets.append(socket); return socket }, monitorNetwork: false)
    client.start(); defer { client.stop() }
    try await eventually { reads == 1 }
    sockets[0].close()
    for _ in 0..<300 {
        if reads == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reads == 2 && sockets.count == 2)
    #expect(sockets.flatMap(\.sent).allSatisfy { ["phx_join", "presence"].contains($0["event"] as? String ?? "") })
}

@Test @MainActor func realtimeLateOldConnectionCannotCloseNewOne() async throws {
    var suspended: CheckedContinuation<Void, Never>?
    var reads = 0; var sockets: [ScriptedRemoteSocket] = []
    let client = RemoteRealtime(role: "phone", device: "phone", credentials: { credentials() }, ready: {
        reads += 1
        if reads == 1 { await withCheckedContinuation { suspended = $0 } }
    }, factory: { _ in let socket = ScriptedRemoteSocket(); sockets.append(socket); return socket }, monitorNetwork: false)
    client.start(); defer { client.stop() }
    try await eventually { suspended != nil }
    client.stop(); client.start()
    try await eventually { reads == 2 && client.state == .connected }
    suspended?.resume(); suspended = nil
    try await Task.sleep(for: .milliseconds(30))
    #expect(client.state == .connected && !sockets[1].closed)
}

@Test @MainActor func realtimeWiFiCellularHandoffReconcilesWithoutCommandReplay() async throws {
    var sockets: [ScriptedRemoteSocket] = []; var reads = 0
    let client = RemoteRealtime(role: "phone", device: "phone", credentials: { credentials() }, ready: { reads += 1 },
        factory: { _ in let socket = ScriptedRemoteSocket(); sockets.append(socket); return socket }, monitorNetwork: false)
    client.start(); defer { client.stop() }
    client.networkChanged(available: true, route: "wifi:en0")
    try await eventually { client.state == .connected }
    try sockets[0].push(event: "presence_state", payload: ["mac":["metas":[["role":"mac","device":remoteTestDevice,"phx_ref":"one"]]]])
    try await eventually { !client.presence.macs.isEmpty }
    client.networkChanged(available: true, route: "cellular:pdp_ip0")
    #expect(sockets[0].closed && client.presence.macs.isEmpty)
    try await eventually { reads == 2 && client.state == .connected }
    client.networkChanged(available: true, route: "cellular:pdp_ip0")
    try await Task.sleep(for: .milliseconds(30))
    #expect(sockets.count == 2 && !sockets[1].closed)
    client.networkChanged(available: true, route: "wifi:en0")
    try await eventually { reads == 3 && client.state == .connected }
    #expect(sockets.flatMap(\.sent).allSatisfy { ["phx_join", "presence"].contains($0["event"] as? String ?? "") })
    client.stop()
    client.networkChanged(available: true, route: "cellular:pdp_ip0")
    #expect(client.state == .stopped && sockets.count == 3)
}

@Test @MainActor func realtimeNetworkReturnWakesBackoff() async throws {
    var sockets: [ScriptedRemoteSocket] = []; var reads = 0
    let client = RemoteRealtime(role: "phone", device: "phone", credentials: { credentials() }, ready: { reads += 1 },
        factory: { _ in let socket = ScriptedRemoteSocket(); sockets.append(socket); return socket }, monitorNetwork: false)
    client.start(); defer { client.stop() }
    client.networkChanged(available: true, route: "wifi:en0")
    try await eventually { client.state == .connected }
    client.networkChanged(available: false, route: "")
    try await Task.sleep(for: .milliseconds(30))
    #expect(client.state == .offline && sockets.count == 1)
    client.networkChanged(available: true, route: "cellular:pdp_ip0")
    try await eventually { reads == 2 && client.state == .connected }
}

@Test @MainActor func realtimeAuthenticationFailureStopsInsteadOfRetrying() async throws {
    var attempts = 0
    let client = RemoteRealtime(role: "phone", device: "phone", credentials: {
        attempts += 1; throw RemoteFailure.signedOut
    }, ready: {}, monitorNetwork: false)
    client.start(); defer { client.stop() }
    try await eventually { client.state == .authenticationRequired }
    try await Task.sleep(for: .milliseconds(30))
    #expect(attempts == 1)
    #expect(RemoteRealtime.terminalState(for: RemoteFailure.realtimeSetup) == .failed)
    #expect(RemoteRealtime.terminalState(for: RemoteFailure.request(503)) == nil)
    for attempt in 0...100 { #expect((0.8...30).contains(RemoteRealtime.retryDelay(attempt: attempt))) }
}

@Test @MainActor func eventWorkRetainsChangesArrivingDuringReadAndStopsWhenClean() async throws {
    let work = RemoteEventWork()
    var runs = 0; var continuation: CheckedContinuation<Void, Never>?
    let operation: @MainActor () async throws -> Void = {
        runs += 1
        if runs == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    let failure: @MainActor (Error) -> Void = { _ in Issue.record("Unexpected work failure") }
    work.enqueue(operation: operation, failure: failure)
    try await eventually { continuation != nil }
    for _ in 0..<20 { work.enqueue(operation: operation, failure: failure) }
    continuation?.resume(); continuation = nil
    try await eventually { runs == 2 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(runs == 2)
    work.enqueue(delay: .seconds(1), operation: operation, failure: failure)
    work.cancel()
    try await Task.sleep(for: .milliseconds(30))
    #expect(runs == 2)
}

@Test @MainActor func eventWorkCoalescesRequestsForTheDelayAndASoonerRequestCutsTheWaitShort() async throws {
    let work = RemoteEventWork()
    var runs = 0
    let operation: @MainActor () async throws -> Void = { runs += 1 }
    let failure: @MainActor (Error) -> Void = { _ in Issue.record("Unexpected work failure") }
    let clock = ContinuousClock(), start = clock.now
    for _ in 0..<5 {
        work.enqueue(delay: .seconds(1), operation: operation, failure: failure)
        try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(500))
    #expect(runs == 0)
    for _ in 0..<120 where runs == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runs == 1)
    #expect(clock.now - start >= .seconds(1))
    try await Task.sleep(for: .milliseconds(50))
    #expect(runs == 1)

    work.enqueue(delay: .seconds(1), operation: operation, failure: failure)
    try await Task.sleep(for: .milliseconds(50))
    #expect(runs == 1)
    let urgent = clock.now
    work.enqueue(delay: .zero, operation: operation, failure: failure)
    for _ in 0..<120 where runs == 1 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(runs == 2)
    #expect(clock.now - urgent < .milliseconds(700))
    try await Task.sleep(for: .milliseconds(30))
    #expect(runs == 2)
}

@Test func snapshotPatchAndDeltaPreserveUnchangedChatsAndRejectStaleRevisions() throws {
    let a = RemoteChat(id: "a", project: "p", title: "A", running: false, messages: [], approvals: [])
    let b = RemoteChat(id: "b", project: "p", title: "B", running: false, messages: [], approvals: [])
    let baseline = RemoteSnapshot(projects: [], chats: [a,b])
    var device = RemoteDevice(id: remoteTestDevice, owner: remoteTestOwner, snapshot: baseline)
    device.revision = 2
    var next = device; next.snapshot.chats[0].title = "Changed"; next.revision = 3
    let patch = RemoteSnapshotPatch(device: next, previous: baseline)
    #expect(patch.changed_chats.count == 1 && patch.changed_chats[0].id == "a")
    let metadata = RemoteDevice(id: remoteTestDevice, owner: remoteTestOwner, snapshot: RemoteSnapshot(projects: [], chats: []))
    var delta = RemoteSnapshotDelta(device: metadata, chats: [next.snapshot.chats[0]], order: ["b","a"])
    delta.device.revision = 3
    let applied = delta.applying(to: device)
    #expect(applied.snapshot.chats == [b,next.snapshot.chats[0]])
    delta.order = ["a"]; delta.device.revision = 4
    #expect(delta.applying(to: applied).snapshot.chats == [next.snapshot.chats[0]])
    delta.device.revision = 1
    #expect(delta.applying(to: applied).revision == 3)
}
