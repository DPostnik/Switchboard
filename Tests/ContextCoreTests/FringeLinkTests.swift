import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ContextDesk
import FringeProtocol

private func action(_ kind: AgentInteraction.Kind, details: String = "ls", turnOption: Bool = false) -> PendingAction {
    PendingAction(interaction: AgentInteraction(id: UUID(), session: AgentSessionReference(connection: .originalCodex, nativeID: "n"),
                                                turn: nil, kind: kind, reason: "Run a command", details: details, canAllowTurn: turnOption), threadID: "chat")
}

@Test func fringeRequestsKeepOnlyWhatThePanelNeeds() {
    let approval = action(.approval(canAllow: true), details: String(repeating: "x", count: 5_000))
    let request = FringeLinkMapping.request(approval)
    #expect(request.id == approval.id)
    #expect(request.chatID == "chat")
    #expect(request.kind == .approval)
    #expect(request.canAllow)
    #expect(!request.canAllowTurn)
    #expect(FringeLinkMapping.request(action(.approval(canAllow: true), turnOption: true)).canAllowTurn)
    #expect(!FringeLinkMapping.request(action(.approval(canAllow: false), turnOption: true)).canAllowTurn)
    #expect(request.reason == "Run a command")
    #expect(request.details.count == FringeLinkMapping.detailsLimit)
    #expect(FringeLinkMapping.request(action(.questions([]))).kind == .question)
    #expect(FringeLinkMapping.request(action(.unsupported(message: "?"))).kind == .other)
}

@Test func fringeAnswersOnlyApprovalsTheAgentAllows() {
    let allowed = action(.approval(canAllow: true))
    let denyOnly = action(.approval(canAllow: false))
    let question = action(.questions([]))
    #expect(FringeLinkMapping.response(for: .allowOnce, to: allowed).map { "\($0)" } == "allowOnce")
    #expect(FringeLinkMapping.response(for: .deny, to: denyOnly).map { "\($0)" } == "deny")
    #expect(FringeLinkMapping.response(for: .allowOnce, to: denyOnly) == nil)
    #expect(FringeLinkMapping.response(for: .deny, to: question) == nil)
    // "For this turn" needs the agent to offer it; Codex interactions never do.
    #expect(FringeLinkMapping.response(for: .allowTurn, to: allowed) == nil)
    #expect(FringeLinkMapping.response(for: .allowTurn, to: action(.approval(canAllow: true), turnOption: true)).map { "\($0)" } == "allowTurn")
    #expect(FringeLinkMapping.response(for: .allowTurn, to: action(.approval(canAllow: false), turnOption: true)) == nil)
}

private func subagent(_ id: String, _ status: AgentSubagent.Status, background: Bool = false, started: TimeInterval, ended: TimeInterval? = nil) -> AgentSubagent {
    AgentSubagent(id: id, title: "Task \(id)", type: "Explore", prompt: "p", background: background, depth: 1, status: status,
                  activity: status == .running ? "Reading" : nil, startedAt: Date(timeIntervalSince1970: started),
                  endedAt: ended.map { Date(timeIntervalSince1970: $0) })
}

@Test func fringeSubagentsFollowTheirChatRunningFirst() {
    let agents = [subagent("old", .completed, started: 10, ended: 20), subagent("bg", .running, background: true, started: 40),
                  subagent("new", .failed, started: 30, ended: 50), subagent("fg", .running, started: 35)]
    let sent = FringeLinkMapping.subagents(agents, chatID: "chat")
    #expect(sent.map(\.id) == ["fg", "bg", "new", "old"])
    #expect(sent.allSatisfy { $0.chatID == "chat" })
    #expect(sent.map(\.status) == [.running, .running, .failed, .completed])
    #expect(sent.map(\.background) == [false, true, false, false])
    #expect(sent[0].activity == "Reading" && sent[0].type == "Explore" && sent[0].ended == nil)
    #expect(sent[3].ended == Date(timeIntervalSince1970: 20))
    #expect(FringeLinkMapping.subagents(agents, chatID: "chat", limit: 2).map(\.id) == ["fg", "bg"])
    // Only sub-agents of the chats the panel shows travel with the snapshot.
    let now = Date()
    let chat = NotchChat(id: "chat", title: "T", project: "P", phase: .working, updated: now)
    let hidden = NotchChat(id: "hidden", title: "H", project: "P", phase: .working, updated: now)
    let snapshot = NotchIslandController.Snapshot(chats: [chat, hidden], ordered: [chat], actions: [], working: ["chat"], waitingChats: [],
                                                  subagents: ["chat": [agents[1]], "hidden": [agents[3]]])
    #expect(FringeLinkMapping.snapshot(snapshot).subagents.map(\.id) == ["bg"])
}

@Test func fringeChatsMapEveryPhase() {
    let now = Date()
    let chats = [NotchChat.Phase.waiting, .working, .finished].map {
        FringeLinkMapping.chat(NotchChat(id: "c", title: "T", project: "P", phase: $0, activity: "a", since: now, updated: now)).phase
    }
    #expect(chats == [.waiting, .working, .finished])
}
