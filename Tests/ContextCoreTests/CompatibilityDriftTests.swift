@_spi(NativeProtocol) @testable import CodexAdapter
@testable import ClaudeAdapter
import AgentContract
import Foundation
import Testing
@testable import ContextCore

private func names(_ found: [(CompatibilityDrift.Category, String)]) -> [String] { found.map { "\($0.0.rawValue) \($0.1)" } }

@Test func driftStoreLogsFirstOccurrenceOnlyAndCountsTheRest() {
    let drift = CompatibilityDrift(logging: false)
    #expect(drift.record(.codex, version: "0.160.0", .notification, "thread/future"))
    #expect(!drift.record(.codex, version: "0.160.0", .notification, "thread/future"))
    #expect(!drift.record(.codex, version: "0.160.0", .notification, "thread/future"))
    // Another version, category or agent is a separate record.
    #expect(drift.record(.codex, version: "0.160.1", .notification, "thread/future"))
    #expect(drift.record(.codex, version: "0.160.0", .itemType, "thread/future"))
    #expect(drift.record(.claudeCode, version: nil, .frameType, "future"))
    let codex = drift.snapshot(agent: .codex)
    #expect(codex.count == 3)
    #expect(codex.first?.count == 3 && codex.first?.key.name == "thread/future" && codex.first?.key.version == "0.160.0")
    #expect(drift.snapshot(agent: .claudeCode).first?.key.version == "unknown")
    #expect(drift.snapshot().count == 4)
}

@Test func driftStoreKeepsOnlyShortPrintableIdentifiersAndCapsRecords() throws {
    let drift = CompatibilityDrift(logging: false)
    drift.record(.codex, version: "0.160.0 (evil\nline)", .notification, "secret text with spaces\nand newline " + String(repeating: "x", count: 500))
    let entry = try #require(drift.snapshot().first)
    #expect(!entry.key.name.contains(" ") && !entry.key.name.contains("\n"))
    #expect(entry.key.name.count == CompatibilityDrift.nameLimit)
    #expect(!entry.key.version.contains("\n"))
    drift.record(.codex, version: "1", .notification, "")
    #expect(drift.snapshot().contains { $0.key.name == "(none)" })
    for index in 0..<(CompatibilityDrift.keyLimit + 50) { drift.record(.codex, version: "1", .notification, "n\(index)") }
    let all = drift.snapshot()
    #expect(all.count == CompatibilityDrift.keyLimit + 1)
    #expect(all.first { $0.key.name == CompatibilityDrift.overflowName }?.count ?? 0 >= 50)
}

@Test func driftSummaryIsCompactAndBilingual() throws {
    let drift = CompatibilityDrift(logging: false)
    #expect(CompatibilityDrift.summary(drift.snapshot()) == nil)
    for _ in 0..<3 { drift.record(.codex, version: "0.160.0", .notification, "thread/future") }
    drift.record(.codex, version: "0.160.0", .missingField, "turn/started:turn.id")
    let summary = try #require(CompatibilityDrift.summary(drift.snapshot(), limit: 1))
    #expect(summary.contains("thread/future ×3"))
    #expect(!summary.contains("turn.id"))
    for category in CompatibilityDrift.Category.allCases { #expect(!category.title.isEmpty) }
}

@Test func codexDriftNamesUnknownNotificationsItemsRequestsAndMissingFields() {
    func message(_ method: String, _ params: [String: JSONValue] = [:], id: JSONValue = .null) -> JSONValue {
        var value: [String: JSONValue] = ["method": .string(method), "params": .object(params)]
        if id != .null { value["id"] = id }
        return .object(value)
    }
    let usage: JSONValue = .object(["total": .object(["inputTokens": .number(10), "cachedInputTokens": .number(2), "outputTokens": .number(3)])])
    // Known and complete: nothing recorded, including deliberately ignored and synthetic notifications.
    for raw in [message("thread/tokenUsage/updated", ["threadId": .string("t"), "turnId": .string("u"), "tokenUsage": usage]),
                message("turn/started", ["threadId": .string("t"), "turn": .object(["id": .string("u")])]),
                message("item/completed", ["threadId": .string("t"), "item": .object(["id": .string("i"), "type": .string("webSearch")])]),
                message("thread/status/changed"), message("client/disconnected"),
                message("item/commandExecution/requestApproval", ["threadId": .string("t")], id: .number(1))] {
        #expect(CodexProtocolSurface.drift(raw).isEmpty)
    }
    #expect(names(CodexProtocolSurface.drift(message("thread/futureThing"))) == ["notification thread/futureThing"])
    #expect(names(CodexProtocolSurface.drift(message("item/future/request", id: .string("r")))) == ["serverRequest item/future/request"])
    #expect(names(CodexProtocolSurface.drift(message("item/started", ["threadId": .string("t"), "item": .object(["id": .string("i"), "type": .string("hologram")])])))
            == ["itemType hologram"])
    #expect(names(CodexProtocolSurface.drift(message("item/completed", ["item": .object([:])])))
            == ["missingField item/completed:threadId", "missingField item/completed:item.id", "missingField item/completed:item.type"])
    #expect(names(CodexProtocolSurface.drift(message("thread/tokenUsage/updated", ["threadId": .string("t"), "tokenUsage": .object(["total": .object(["input_tokens": .number(1)])])])))
            == ["missingField thread/tokenUsage/updated:tokenUsage.total.inputTokens", "missingField thread/tokenUsage/updated:tokenUsage.total.cachedInputTokens",
                "missingField thread/tokenUsage/updated:tokenUsage.total.outputTokens"])
    #expect(names(CodexProtocolSurface.drift(message("turn/completed", ["threadId": .string("t"), "turn": .object(["id": .string("u")])])))
            == ["missingField turn/completed:turn.status"])
    #expect(names(CodexProtocolSurface.drift(message("item/agentMessage/delta", ["threadId": .string("t")]))) == ["missingField item/agentMessage/delta:itemId"])
}

@Test func codexDriftUsesTheEngineVersionAndLeavesDecodingUnchanged() {
    let drift = CompatibilityDrift(logging: false)
    let raw: JSONValue = .object(["method": .string("thread/futureThing"), "params": .object(["threadId": .string("t")])])
    CodexProtocolSurface.record(raw, userAgent: "codex/0.160.3 (Mac OS; arm64)", into: drift)
    CodexProtocolSurface.record(raw, userAgent: nil, into: drift)
    #expect(Set(drift.snapshot().map(\.key.version)) == ["0.160.3", "unknown"])
    // The decoder still drops it exactly as before.
    #expect(CodexEventDecoder.notification(raw) == nil)
    #expect(CodexDecoding.transcriptItem(.object(["id": .string("i"), "type": .string("hologram")])) == nil)
}

/// End to end through the real transport: unknown notifications are counted, the event stream is untouched.
@Test func codexConnectionCountsDriftWithoutChangingDelivery() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = "test/drift-" + UUID().uuidString.prefix(8).lowercased()
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!\#(fixturePython)
    import json, sys
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("method") == "initialize":
            print(json.dumps({"id": m["id"], "result": {"userAgent": "codex/0.158.0-alpha.2.1 fixture"}}), flush=True)
        elif m.get("method") == "initialized":
            for _ in range(3): print(json.dumps({"method": "MARKER", "params": {"secret": "do not record"}}), flush=True)
    """#.replacingOccurrences(of: "MARKER", with: marker).utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    let connection = CodexConnection()
    let events = connection.events
    try await connection.start(executable: executable, home: folder.appendingPathComponent("home"))
    let reader = Task {
        var delivered = 0
        for await event in events where event["method"].string == marker {
            delivered += 1
            if delivered == 3 { break }
        }
        return delivered
    }
    let watchdog = Task { try await Task.sleep(for: .seconds(10)); reader.cancel() }
    let delivered = await reader.value
    watchdog.cancel()
    await connection.stop()
    #expect(delivered == 3)
    let entry = try #require(CompatibilityDrift.shared.snapshot(agent: .codex).first { $0.key.name == marker })
    #expect(entry.count == 3 && entry.key.category == .notification && entry.key.version == "0.158.0-alpha.2.1")
}

@Test func claudeDriftNamesUnknownFramesSubtypesEventsAndMissingFields() {
    func frame(_ value: [String: JSONValue]) -> JSONValue { .object(value) }
    let usage: JSONValue = .object(["input_tokens": .number(1)])
    for raw in [frame(["type": .string("system"), "subtype": .string("init")]),
                frame(["type": .string("system"), "subtype": .string("ui_invalidate")]),
                frame(["type": .string("command_lifecycle")]), frame(["type": .string("transport_closed")]),
                frame(["type": .string("keep_alive")]), frame(["type": .string("rate_limit_event")]),
                frame(["type": .string("assistant"), "message": .object(["id": .string("m")])]),
                // A sub-agent's assistant message is not read for the chat's own reply.
                frame(["type": .string("assistant"), "parent_tool_use_id": .string("t"), "message": .object([:])]),
                frame(["type": .string("stream_event"), "event": .object(["type": .string("message_start"), "message": .object(["id": .string("m"), "usage": usage])])]),
                frame(["type": .string("result"), "is_error": .bool(false), "usage": usage]),
                frame(["type": .string("control_request"), "request": .object(["subtype": .string("can_use_tool")])])] {
        #expect(ClaudeProtocolSurface.drift(raw).isEmpty)
    }
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("hologram")]))) == ["frameType hologram"])
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("system"), "subtype": .string("future")]))) == ["systemSubtype future"])
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("stream_event"), "event": .object(["type": .string("ping")])]))) == ["streamEvent ping"])
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("stream_event"), "event": .object(["type": .string("message_start"), "message": .object([:])])])))
            == ["missingField message_start:message.id", "missingField message_start:message.usage.input_tokens"])
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("result")]))) == ["missingField result:is_error", "missingField result:usage.input_tokens"])
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("control_request"), "request": .object(["subtype": .string("elicitation")])])))
            == ["controlRequest elicitation"])
    #expect(names(ClaudeProtocolSurface.drift(frame(["type": .string("system"), "subtype": .string("compact_boundary")])))
            == ["missingField compact_boundary:compact_metadata.pre_tokens"])
}

@Test func claudeVersionOutputParsesOnlyTheCLIShape() {
    #expect(ClaudeProtocolSurface.version(fromVersionOutput: "2.1.292 (Claude Code)\n") == "2.1.292")
    #expect(ClaudeProtocolSurface.version(fromVersionOutput: "2.1.292") == nil)
    #expect(ClaudeProtocolSurface.version(fromVersionOutput: " (Claude Code)") == nil)
    #expect(ClaudeProtocolSurface.version(fromVersionOutput: "2.1.292 beta (Claude Code)") == nil)
}
