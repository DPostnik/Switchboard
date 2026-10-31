import AgentContract
import Combine
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@MainActor private func publicationModel(_ root: URL, store: AppStore) -> DeskModel {
    DeskModel(store: store, pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil,
              jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
}

/// Records every coalesced write; `blockNext` holds the next write open until `release()`.
@MainActor private final class WriteLog {
    var snapshots: [SavedState] = []
    var blockNext = false
    private var gate: CheckedContinuation<Void, Never>?
    func record(_ snapshot: SavedState) async {
        snapshots.append(snapshot)
        guard blockNext else { return }
        blockNext = false
        await withCheckedContinuation { gate = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor func persistCoalescesCallsAndQueuesOneFollowUpDuringARunningWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("state.sqlite"))
    let model = publicationModel(root, store: store)
    let log = WriteLog()
    model.persistWriter = { await log.record($0) }
    // Several calls within the delay: one write of the latest state.
    model.state.model = "one"; model.saveAgentChoice()
    model.state.model = "two"; model.saveAgentChoice()
    model.state.model = "three"; model.saveAgentChoice()
    #expect(model.persistWrites == 0)
    // Under parallel test load the delayed task may run late; wait for it instead of assuming the delay.
    for _ in 0..<500 where model.persistWrites == 0 { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: DeskModel.persistDelay * 2)
    #expect(model.persistWrites == 1)
    #expect(log.snapshots.map(\.model) == ["three"])
    // Calls while a write runs: exactly one follow-up, carrying the state as it is at write time.
    log.blockNext = true
    model.state.model = "four"; model.saveAgentChoice()
    for _ in 0..<500 where log.snapshots.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(log.snapshots.map(\.model) == ["three", "four"])
    model.state.model = "five"; model.saveAgentChoice()
    model.state.model = "six"; model.saveAgentChoice()
    log.release()
    await model.flushPersist()
    #expect(model.persistWrites == 3)
    #expect(log.snapshots.map(\.model) == ["three", "four", "six"])
    try await Task.sleep(for: DeskModel.persistDelay * 2)
    #expect(model.persistWrites == 3)
    // The quit path writes at once through the store, without waiting for the delay.
    model.persistWriter = nil
    model.state.model = "flushed"; model.saveAgentChoice()
    await model.flushPersist()
    #expect(model.persistWrites == 4)
    #expect(try await store.load().model == "flushed")
    await model.flushPersist()
    #expect(model.persistWrites == 4)
}

@Test @MainActor func identicalRunStatusUsageAndWaitsDoNotPublish() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = publicationModel(root, store: AppStore(file: root.appendingPathComponent("state.sqlite")))
    let chat = Chat(id: "run", projectID: UUID(), title: "Chat", model: "fixture")
    model.state.chats = [chat]
    let source = try #require(chat.nativeSession)
    var changes = 0
    let observer = model.objectWillChange.sink { changes += 1 }
    defer { observer.cancel() }
    await model.receive(.init(session: source, payload: .started(turn: "turn")))
    #expect(model.isBusy(threadID: chat.id))
    #expect(changes == 1)
    await model.receive(.init(session: source, payload: .started(turn: "turn")))
    #expect(changes == 1)
    await model.receive(.init(session: source, payload: .status(turn: "turn", text: "Thinking")))
    #expect(model.runActivity(threadID: chat.id).status == "Thinking")
    #expect(changes == 2)
    await model.receive(.init(session: source, payload: .status(turn: "turn", text: "Thinking")))
    #expect(changes == 2)
    await model.receive(.init(session: source, payload: .status(turn: "turn", text: "Reading")))
    #expect(model.runActivity(threadID: chat.id).status == "Reading")
    #expect(changes == 3)
    let usage = UsageSnapshot(measuredAt: Date(timeIntervalSince1970: 10))
    await model.receive(.init(session: source, payload: .usage(turn: nil, total: nil, snapshot: usage)))
    #expect(model.usage[chat.id] == usage)
    #expect(changes == 4)
    await model.receive(.init(session: source, payload: .usage(turn: nil, total: nil, snapshot: usage)))
    #expect(changes == 4)
    await model.receive(.init(session: source, payload: .background(tasks: 0)))
    await model.receive(.init(session: source, payload: .subagents([])))
    #expect(changes == 4)
    await model.receive(.init(session: source, payload: .background(tasks: 2)))
    #expect(model.backgroundWaits[chat.id] == 2)
    #expect(changes == 5)
    await model.receive(.init(session: source, payload: .background(tasks: 2)))
    #expect(changes == 5)
    let agent = AgentSubagent(id: "sub", title: "Explore", type: nil, prompt: "Find the files", background: false, depth: 1,
                              startedAt: Date(timeIntervalSince1970: 20))
    await model.receive(.init(session: source, payload: .subagents([agent])))
    #expect(model.subagents[chat.id] == [agent])
    #expect(changes == 6)
    await model.receive(.init(session: source, payload: .subagents([agent])))
    #expect(changes == 6)
}

@Test func nativeSessionMapAnswersLikeTheChatFilter() {
    let foreign = AgentConnectionID(agent: AgentID(rawValue: "uninstalled"), id: UUID())
    let project = UUID()
    let shared = AgentSessionReference(connection: .originalCodex, nativeID: "shared")
    var first = Chat(id: "first-shared", projectID: project, title: "D1", model: ""); first.nativeSession = shared
    var second = Chat(id: "second-shared", projectID: project, title: "D2", model: ""); second.nativeSession = shared
    var detached = Chat(id: "detached", projectID: project, title: "N", model: ""); detached.nativeSession = nil
    let chats = [Chat(id: "a", projectID: project, title: "A", model: ""),
                 Chat(session: AgentSessionReference(connection: .appClaude, nativeID: "claude-1"), projectID: project, title: "B", model: ""),
                 Chat(session: AgentSessionReference(connection: foreign, nativeID: "a"), projectID: project, title: "C", model: ""),
                 first, second, detached]
    var state = SavedState(); state.chats = chats
    let map = NativeSessionMap(chats: chats)
    let queries: [(String, AgentConnectionID)] = [("a", .originalCodex), ("a", foreign), ("a", .appClaude), ("claude-1", .appClaude),
                                                  ("claude-1", .originalCodex), ("shared", .originalCodex), ("detached", .originalCodex),
                                                  ("missing", .originalCodex)]
    for (nativeID, connection) in queries {
        #expect(map.appID(for: nativeID, connection: connection) == ConversationIdentity.appID(for: nativeID, in: state, connection: connection),
                "\(nativeID) on \(connection)")
    }
    #expect(map.appID(for: "a") == "a")
    #expect(map.appID(for: "a", connection: foreign) == chats[2].id)
    #expect(map.appID(for: "shared") == nil)
    #expect(NativeSessionMap(chats: []).appID(for: "a") == nil)
}

@Test @MainActor func eventsResolveChatsThroughTheMapAfterChatsAreAddedAndRemoved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = publicationModel(root, store: AppStore(file: root.appendingPathComponent("state.sqlite")))
    let a = Chat(id: "a", projectID: UUID(), title: "A", model: "fixture")
    let b = Chat(id: "b", projectID: a.projectID, title: "B", model: "fixture")
    let sessionA = try #require(a.nativeSession), sessionB = try #require(b.nativeSession)
    model.state.chats = [a]
    await model.receive(.init(session: sessionA, payload: .started(turn: "t")))
    await model.receive(.init(session: sessionB, payload: .started(turn: "t")))
    #expect(model.isBusy(threadID: "a") && !model.isBusy(threadID: "b"))
    model.state.chats.append(b)
    await model.receive(.init(session: sessionB, payload: .started(turn: "t")))
    #expect(model.isBusy(threadID: "b"))
    await model.receive(.init(session: sessionA, payload: .status(turn: "t", text: "one")))
    #expect(model.runActivity(threadID: "a").status == "one")
    model.state.chats.removeAll { $0.id == "a" }
    await model.receive(.init(session: sessionA, payload: .status(turn: "t", text: "two")))
    #expect(model.runActivity(threadID: "a").status == "one")
    // A native session two chats claim resolves to no chat, like the filter did.
    var twin = Chat(id: "twin", projectID: a.projectID, title: "Twin", model: "fixture"); twin.nativeSession = sessionB
    model.state.chats.append(twin)
    await model.receive(.init(session: sessionB, payload: .status(turn: "t", text: "ambiguous")))
    #expect(model.runActivity(threadID: "b").status == nil)
    model.state.chats.removeAll { $0.id == "twin" }
    await model.receive(.init(session: sessionB, payload: .status(turn: "t", text: "clear")))
    #expect(model.runActivity(threadID: "b").status == "clear")
    // Re-keying a chat's native session is a state change too.
    model.state.chats[0].nativeSession = AgentSessionReference(connection: .originalCodex, nativeID: "renamed")
    await model.receive(.init(session: sessionB, payload: .status(turn: "t", text: "stale")))
    #expect(model.runActivity(threadID: "b").status == "clear")
    await model.receive(.init(session: .init(connection: .originalCodex, nativeID: "renamed"), payload: .status(turn: "t", text: "fresh")))
    #expect(model.runActivity(threadID: "b").status == "fresh")
}

@Test @MainActor func remoteTimestampFormatterKeepsTheDefaultISO8601Format() {
    for seconds in [0.0, 1_700_000_000.5, Date().timeIntervalSince1970] {
        let date = Date(timeIntervalSince1970: seconds)
        #expect(DeskModel.remoteTimestampFormatter.string(from: date) == ISO8601DateFormatter().string(from: date))
    }
}
