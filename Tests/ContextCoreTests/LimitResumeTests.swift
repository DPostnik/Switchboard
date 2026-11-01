@_spi(NativeProtocol) @testable import CodexAdapter
@testable import ClaudeAdapter
import AgentContract
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

private func completion(_ raw: JSONValue) throws -> AgentTurnCompletion {
    guard case .completed(let value) = try #require(CodexEventDecoder.notification(raw)).payload else { throw ClientFailure("not a completion") }
    return value
}

/// Codex 0.160.0 `turn/completed` with a `TurnError` (schema from `codex app-server generate-json-schema`).
private func codexTurn(status: String, error: String) -> String {
    #"{"method":"turn/completed","params":{"threadId":"a","turn":{"id":"v1","items":[],"status":"\#(status)","error":\#(error),"startedAt":1793550000,"completedAt":1793550042,"durationMs":42000}}}"#
}
private let codexLimitError = #"{"message":"You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:45 PM.","codexErrorInfo":"usageLimitExceeded","additionalDetails":null}"#

@Test func codexUsageLimitStopIsReadFromTheTurnErrorCode() throws {
    let stopped = try completion(try json(codexTurn(status: "failed", error: codexLimitError)))
    #expect(stopped.status == .failed && stopped.hasError)
    // The error has no machine-readable reset; the account limits supply it.
    #expect(stopped.usageLimit == AgentUsageLimitStop(resetsAt: nil))
    // Throttling, other errors, interruptions and clean turns are not an exhausted plan.
    let throttled = #"{"message":"Rate limit reached","codexErrorInfo":"rateLimitExceeded","additionalDetails":null}"#
    let connection = #"{"message":"stream error","codexErrorInfo":{"responseStreamDisconnected":{"httpStatusCode":429}},"additionalDetails":null}"#
    #expect(try completion(try json(codexTurn(status: "failed", error: throttled))).usageLimit == nil)
    #expect(try completion(try json(codexTurn(status: "failed", error: connection))).usageLimit == nil)
    #expect(try completion(try json(codexTurn(status: "interrupted", error: codexLimitError))).usageLimit == nil)
    #expect(try completion(try json(codexTurn(status: "completed", error: "null"))).usageLimit == nil)
}

@Test func accountLimitsSupplyTheLatestResetOfExhaustedWindows() throws {
    let now = Date(timeIntervalSince1970: 1_793_550_000)
    // `account/rateLimits/read` (Codex 0.160.0): the five-hour window is spent, the weekly one is not.
    let limits = CodexDecoding.accountLimits(response: try json(#"""
    {"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1793561400},
      "secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1794000000},"credits":null,"planType":"plus","rateLimitReachedType":"rate_limit_reached"}}
    """#), date: now)
    #expect(LimitResume.exhaustedReset(limits, now: now) == Date(timeIntervalSince1970: 1_793_561_400))
    // Several exhausted windows: the latest reset counts; a reset already past means the snapshot is stale.
    let both = AccountLimits(buckets: [.init(id: "all", name: "All", windows: [
        .init(id: "five_hour", remainingPercent: 0, durationMinutes: 300, resetsAt: now.addingTimeInterval(600)),
        .init(id: "seven_day", remainingPercent: 0, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86_400)),
        .init(id: "old", remainingPercent: 0, durationMinutes: 300, resetsAt: now.addingTimeInterval(-60))])], ordinaryUsageAllowed: nil, fetchedAt: now)
    #expect(LimitResume.exhaustedReset(both, now: now) == now.addingTimeInterval(86_400))
    let open = AccountLimits(buckets: [.init(id: "all", name: "All", windows: [
        .init(id: "five_hour", remainingPercent: 3, durationMinutes: 300, resetsAt: now.addingTimeInterval(600))])], ordinaryUsageAllowed: nil, fetchedAt: now)
    #expect(LimitResume.exhaustedReset(open, now: now) == nil && LimitResume.exhaustedReset(nil, now: now) == nil)
    // The stop's own reset wins over the account limits.
    #expect(LimitResume(resetsAt: now.addingTimeInterval(5)).reset(limits: both, now: now) == now.addingTimeInterval(5))
    #expect(LimitResume(resetsAt: nil).reset(limits: both, now: now) == now.addingTimeInterval(86_400))
}

@Test func claudeLimitStopUsesTheRejectedRateLimitEvent() throws {
    // Shapes from Claude Code 2.1.292: the "allowed" event is copied from a real session; "rejected" follows its schema.
    let allowed = try json(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1791630000,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.03,"resetsAt":1791630000},"seven_day":{"utilization":0.16,"resetsAt":1791975600}}},"uuid":"71d3bfb6-ed16-41f3-ac55-d16a9","session_id":"s"}"#)
    let rejected = try json(#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791630000,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"uuid":"u2","session_id":"s"}"#)
    let apiError = try json(#"{"type":"assistant","message":{"id":"m","role":"assistant","content":[{"type":"text","text":"You've hit your limit · resets 3pm (Europe/Moscow)"}]},"parent_tool_use_id":null,"error":"rate_limit","uuid":"u3","session_id":"s"}"#)
    var stop = ClaudeLimitStop()
    stop.observe(allowed)
    #expect(stop.stop(outcome: .failed) == nil)
    stop.observe(rejected); stop.observe(apiError)
    #expect(stop.stop(outcome: .failed) == AgentUsageLimitStop(resetsAt: Date(timeIntervalSince1970: 1_791_630_000)))
    // Only a failed turn stopped on the limit.
    #expect(stop.stop(outcome: .completed) == nil && stop.stop(outcome: .cancelled) == nil && stop.stop(outcome: .uncertain) == nil)
    // The API-error message alone marks the stop without a time; a sub-agent's error does not.
    var message = ClaudeLimitStop()
    message.observe(try json(#"{"type":"assistant","message":{"id":"m","content":[]},"parent_tool_use_id":"call1","error":"rate_limit","session_id":"s"}"#))
    #expect(message.stop(outcome: .failed) == nil)
    message.observe(apiError)
    #expect(message.stop(outcome: .failed) == AgentUsageLimitStop(resetsAt: nil))
    // Other API errors are not a usage limit.
    var other = ClaudeLimitStop()
    other.observe(try json(#"{"type":"assistant","message":{"id":"m","content":[]},"parent_tool_use_id":null,"error":"overloaded","session_id":"s"}"#))
    #expect(other.stop(outcome: .failed) == nil)
}

@Test func limitResumeStepsFollowTheWallClockAndCancelConditions() {
    let now = Date(timeIntervalSince1970: 1_793_550_000)
    let reset = now.addingTimeInterval(3_600)
    let offered = LimitResume(resetsAt: reset)
    let armed = offered.armed(reset: reset, now: now)
    #expect(armed.continueAt == reset.addingTimeInterval(LimitResume.margin) && armed.resetsAt == reset)
    // A reset already past continues at once.
    #expect(offered.armed(reset: now.addingTimeInterval(-600), now: now).continueAt == now)
    let idle = LimitResume.Situation(exists: true, archived: false, ready: true, busy: false)
    #expect(LimitResume.step(nil, situation: idle, now: now) == .none)
    #expect(LimitResume.step(offered, situation: idle, now: now.addingTimeInterval(9_999)) == .none)
    // Before the time: look again within the recheck interval, so sleep and wake are caught by the wall clock.
    #expect(LimitResume.step(armed, situation: idle, now: now) == .wait(until: now.addingTimeInterval(LimitResume.recheck)))
    let due = armed.continueAt!
    #expect(LimitResume.step(armed, situation: idle, now: due.addingTimeInterval(-10)) == .wait(until: due))
    #expect(LimitResume.step(armed, situation: idle, now: due) == .send)
    // Hours late (the app was closed or the Mac slept): still one send, but only to an idle chat.
    #expect(LimitResume.step(armed, situation: idle, now: due.addingTimeInterval(36_000)) == .send)
    var busy = idle; busy.busy = true
    #expect(LimitResume.step(armed, situation: busy, now: due) == .disarm)
    var offline = idle; offline.ready = false
    #expect(LimitResume.step(armed, situation: offline, now: due) == .wait(until: due.addingTimeInterval(LimitResume.recheck)))
    var archived = idle; archived.archived = true
    #expect(LimitResume.step(armed, situation: archived, now: now) == .drop)
    #expect(LimitResume.step(armed, situation: .init(exists: false, archived: false, ready: false, busy: false), now: due) == .drop)
}

@Test func limitResumeTextInBothLanguages() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Moscow"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 11)))
    let reset = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 14, minute: 30)))
    #expect(LimitResume.offerText(reset: reset, now: now, language: .russian, calendar: calendar) == "Лимит исчерпан. Сброс в 14:30.")
    let english = LimitResume.offerText(reset: reset, now: now, language: .english, calendar: calendar)
    #expect(english.hasPrefix("Usage limit reached. Resets at 2:30") && english.hasSuffix("PM."))
    #expect(LimitResume.armedText(reset.addingTimeInterval(60), now: now, language: .russian, calendar: calendar) == "Продолжу в 14:31")
    #expect(LimitResume.armedText(reset.addingTimeInterval(60), now: now, language: .english, calendar: calendar).hasPrefix("Will continue at 2:31"))
    #expect(LimitResume.offerText(reset: nil, now: now, language: .russian) == "Лимит исчерпан. Время сброса неизвестно.")
    #expect(LimitResume.offerText(reset: nil, now: now, language: .english) == "Usage limit reached. Reset time unknown.")
    // Another day shows the date too.
    let tomorrow = reset.addingTimeInterval(86_400)
    #expect(LimitResume.timeText(tomorrow, now: now, language: .russian, calendar: calendar) != "14:30")
    #expect(LimitResume.message(language: .russian) == "Продолжай с того места, где остановился.")
    #expect(LimitResume.message(language: .english) == "Continue where you left off.")
}

@Test func limitResumeRecordRoundTripsWithTheChat() throws {
    var chat = Chat(id: "a", projectID: UUID(), title: "A", model: "")
    chat.limitResume = LimitResume(resetsAt: Date(timeIntervalSince1970: 1_793_561_400), continueAt: Date(timeIntervalSince1970: 1_793_561_460))
    let decoded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
    #expect(decoded.limitResume == chat.limitResume && decoded.limitResume?.isArmed == true)
    // Records saved before the feature decode without it.
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
    legacy.removeValue(forKey: "limitResume")
    #expect(try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: legacy)).limitResume == nil)
}

@MainActor private func limitModel(_ folder: URL) async throws -> (DeskModel, CodexConnection, AppStore) {
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import sys, json
    requests = []
    turns = 0
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method = m['method']
        result = {'userAgent': 'codex/0.158.0-alpha.2.1 fixture'}
        if method == 'turn/start':
            turns += 1
            result = {'turn': {'id': 'n' + str(turns)}}
        if method == 'account/rateLimits/read':
            result = {'rateLimits': {'limitId': 'codex', 'primary': {'usedPercent': 100, 'windowDurationMins': 300, 'resetsAt': 4102444800},
                      'secondary': {'usedPercent': 41, 'windowDurationMins': 10080, 'resetsAt': 4103000000}, 'planType': 'plus'}}
        if method == 'test/requests': result = requests
        else: requests.append(m)
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: store, summaryExecutable: executable, summaryHome: folder)
    model.state.defaultRoute = .direct
    let project = Project(path: folder.path)
    model.state.projects = [project]
    model.state.chats = [Chat(id: "a", projectID: project.id, title: "A", model: ""), Chat(id: "b", projectID: project.id, title: "B", model: "")]
    model.connected = true; model.authenticated = true
    return (model, connection, store)
}

private func startedTexts(_ connection: CodexConnection) async throws -> [String] {
    try await connection.request("test/requests").array.filter { $0["method"].string == "turn/start" }
        .map { $0["params"]["input"].array.compactMap { $0["text"].string }.joined() }
}

@Test @MainActor func limitStopOffersArmsAndQueuesOneContinuation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (model, connection, store) = try await limitModel(folder)
    // The stop records an offer; the reset comes from the refreshed account limits.
    await model.receive(.init(session: .init(connection: .originalCodex, nativeID: "a"), payload: .completed(try completion(try json(codexTurn(status: "failed", error: codexLimitError))))))
    #expect(model.state.chats[0].limitResume == LimitResume(resetsAt: nil))
    for _ in 0..<300 where model.accountLimits == nil { try await Task.sleep(for: .milliseconds(10)) }
    let reset = Date(timeIntervalSince1970: 4_102_444_800)
    #expect(model.limitResumeReset(model.state.chats[0]) == reset)
    // The offer alone never sends.
    #expect(model.checkLimitResumes(now: reset.addingTimeInterval(3_600)) == nil && model.queuedMessages.isEmpty)

    let now = reset.addingTimeInterval(-600)
    model.armLimitResume("a", now: now)
    let due = reset.addingTimeInterval(LimitResume.margin)
    #expect(model.state.chats[0].limitResume?.continueAt == due)
    // An armed chat does not wait for the user.
    model.state.chats[0].unreadCompletionID = "turn:a:v1"; model.state.chats[0].lastTurnFailed = true
    #expect(!model.attentionChats.contains { $0.chat.id == "a" })
    #expect(model.checkLimitResumes(now: now) == now.addingTimeInterval(LimitResume.recheck))
    #expect(model.queuedMessages.isEmpty)

    // At the time: the record goes and exactly one continuation is queued and sent.
    #expect(model.checkLimitResumes(now: due) == nil)
    #expect(model.state.chats[0].limitResume == nil)
    var sent: [String] = []
    for _ in 0..<300 {
        sent = try await startedTexts(connection)
        if sent.count == 1 && model.queuedMessages.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sent == [LimitResume.message()])
    #expect(model.checkLimitResumes(now: due.addingTimeInterval(600)) == nil)
    await model.flushPersist()
    #expect(try await store.load().chats.first { $0.id == "a" }?.limitResume == nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await startedTexts(connection).count == 1)
}

@Test @MainActor func limitResumeCancelsOnUserSendBusyChatAndArchive() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (model, connection, _) = try await limitModel(folder)
    // Far in the future: arming starts the app's own wall-clock loop, which must not fire during the test.
    let now = Date(timeIntervalSince1970: 4_102_000_000), reset = now.addingTimeInterval(600)
    let due = reset.addingTimeInterval(LimitResume.margin)
    model.state.chats[0].limitResume = LimitResume(resetsAt: reset)
    model.state.chats[1].limitResume = LimitResume(resetsAt: reset)
    model.armLimitResume("a", now: now); model.armLimitResume("b", now: now)

    // A message of the user's own in the chat replaces the planned continuation.
    model.projectID = model.state.projects[0].id; model.chatID = "a"
    model.draft = "My own follow-up"
    await model.send()
    #expect(model.state.chats[0].limitResume == nil)

    // Busy at the time (a queued message waits): no blind queuing, the offer comes back.
    model.state.queuedMessages = [QueuedMessage(id: "q", threadID: "b", projectID: model.state.projects[0].id, text: "Waiting", model: "", effort: "medium")]
    #expect(model.checkLimitResumes(now: due) == nil)
    #expect(model.state.chats[1].limitResume == LimitResume(resetsAt: reset))
    #expect(model.queuedMessages.map(\.id) == ["q"])
    model.state.queuedMessages = []

    // Archived before the time: forgotten.
    model.armLimitResume("b", now: now)
    model.state.chats[1].archived = true
    #expect(model.checkLimitResumes(now: now) == nil)
    #expect(model.state.chats[1].limitResume == nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await startedTexts(connection) == ["My own follow-up"])
}

@Test @MainActor func armedContinuationAfterRestartWaitsForTheAgentAndSendsOnce() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (model, connection, store) = try await limitModel(folder)
    let past = Date().addingTimeInterval(-7_200)
    model.state.chats[0].limitResume = LimitResume(resetsAt: past, continueAt: past.addingTimeInterval(LimitResume.margin))
    try await store.save(model.state)
    // A relaunch reads the armed record; while the agent is not connected nothing is sent.
    model.state = try await store.load()
    model.connected = false
    #expect(model.checkLimitResumes() != nil)
    #expect(model.queuedMessages.isEmpty && model.state.chats[0].limitResume?.isArmed == true)
    model.connected = true
    #expect(model.checkLimitResumes() == nil)
    var sent: [String] = []
    for _ in 0..<300 {
        sent = try await startedTexts(connection)
        if sent.count == 1 && model.queuedMessages.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sent == [LimitResume.message()])
    // The saved state has no record left, so a further launch cannot send it again.
    #expect(try await store.load().chats.first { $0.id == "a" }?.limitResume == nil)
}
