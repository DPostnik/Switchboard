import Foundation
import Testing
@testable import ContextCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
private func event(_ id: String, _ subject: PushSubject = .approval, chat: String = "chat-1") -> PushEvent {
    PushEvent(id: id, subject: subject, chat: subject == .test ? nil : chat, project: "P", created: start)
}

@Test func outboxHoldsWhilePresentAndReleasesWhenAway() {
    var outbox = PushOutbox()
    let r1 = outbox.post(event("a1"), now: start)
    #expect(r1)
    let r2 = outbox.post(event("t1", .turnReady), now: start)
    #expect(r2)
    let r3 = outbox.due(now: at(5), away: false)
    #expect(r3.isEmpty)
    #expect(outbox.isHolding)
    let r4 = outbox.due(now: at(30), away: true)
    #expect(r4.map(\.id) == ["a1", "t1"])
    // Handed out once: not repeated while the send is in flight.
    let r5 = outbox.due(now: at(31), away: true)
    #expect(r5.isEmpty)
    outbox.delivered("a1"); outbox.delivered("t1")
    #expect(!outbox.isHolding)
    // Setting off: due at once; a test event always ignores the away rule.
    var open = PushOutbox(onlyWhileAway: false)
    open.post(event("a2"), now: start)
    let r6 = open.due(now: start, away: false)
    #expect(r6.map(\.id) == ["a2"])
    var test = PushOutbox()
    test.post(event("test-1", .test), now: start)
    let r7 = test.due(now: start, away: false)
    #expect(r7.map(\.id) == ["test-1"])
}

@Test func outboxDropsTurnsAfterTenMinutesButKeepsPendingActions() {
    var outbox = PushOutbox()
    outbox.post(event("a1"), now: start)
    outbox.post(event("t1", .turnStopped), now: start)
    outbox.post(event("x1", .quotaWait(job: "J"), chat: "chat-2"), now: start)
    let r8 = outbox.due(now: at(599), away: false)
    #expect(r8.isEmpty)
    #expect(outbox.held.count == 3)
    let r9 = outbox.due(now: at(600), away: false)
    #expect(r9.isEmpty)
    #expect(outbox.held.map(\.event.id) == ["a1"])
    // Away within the hour: the action still goes out.
    let r10 = outbox.due(now: at(3000), away: true)
    #expect(r10.map(\.id) == ["a1"])
    // An action held for its whole lifetime (1 hour) expires.
    var late = PushOutbox()
    late.post(event("a2"), now: start)
    let r11 = late.due(now: at(3600), away: true)
    #expect(r11.isEmpty && !late.isHolding)
    // A turn released when the user leaves within 10 minutes.
    var turn = PushOutbox()
    turn.post(event("t2", .turnFailed), now: start)
    let r12 = turn.due(now: at(540), away: true)
    #expect(r12.map(\.id) == ["t2"])
}

@Test func outboxReplacesHeldTurnOfTheSameChatAndDeduplicates() {
    var outbox = PushOutbox()
    let r13 = outbox.post(event("turn:c:1", .turnReady, chat: "c"), now: start)
    #expect(r13)
    let r14 = outbox.post(event("turn:d:1", .turnReady, chat: "d"), now: start)
    #expect(r14)
    let r15 = outbox.post(event("turn:c:2", .turnFailed, chat: "c"), now: at(1))
    #expect(r15)
    #expect(outbox.held.map(\.event.id) == ["turn:d:1", "turn:c:2"])
    let r16 = outbox.post(event("turn:c:2", .turnFailed, chat: "c"), now: at(2))
    #expect(!r16)
    let r17 = outbox.due(now: at(3), away: true)
    #expect(r17.count == 2)
    outbox.delivered("turn:c:2")
    let r18 = outbox.post(event("turn:c:2", .turnFailed, chat: "c"), now: at(4))
    #expect(!r18)
    // Sent IDs stay bounded.
    var many = PushOutbox(onlyWhileAway: false)
    for index in 0..<(PushOutbox.sentLimit + 10) {
        many.post(event("e\(index)"), now: start)
        _ = many.due(now: start, away: true)
        many.delivered("e\(index)")
    }
    #expect(many.sent.count == PushOutbox.sentLimit)
    let r19 = many.post(event("e0"), now: start)
    #expect(r19)
}

@Test func outboxWithdrawalBeforeAndAfterSending() {
    var outbox = PushOutbox()
    outbox.post(event("a1"), now: start)
    outbox.post(event("t1", .turnReady, chat: "c"), now: start)
    // Resolved before sending: removed, nothing to withdraw on the phone.
    let r20 = outbox.withdraw(events: ["a1"], chats: ["c"])
    #expect(r20.isEmpty)
    #expect(!outbox.isHolding)
    outbox.post(event("a2"), now: start)
    outbox.post(event("a3", .question, chat: "c"), now: start)
    outbox.post(event("t2", .turnReady, chat: "c"), now: start)
    let r21 = outbox.due(now: at(1), away: true)
    #expect(r21.count == 3)
    outbox.delivered("a2"); outbox.delivered("t2")
    // a3 is in flight: withdrawn too, since it may already be on the phone.
    let withdrawal = outbox.withdraw(events: ["a2", "a3", "unknown"], chats: ["c"])
    #expect(withdrawal.events.sorted() == ["a2", "a3"] && withdrawal.chats == ["c"])
    let r22 = outbox.withdraw(events: ["a2", "a3"], chats: ["c"])
    #expect(r22.isEmpty)
    // A late result for a withdrawn event changes nothing.
    outbox.delivered("a3")
    let r23 = outbox.withdraw(events: ["a3"], chats: [])
    #expect(r23.isEmpty)
    // A chat withdraws turns only; its sent actions need their IDs.
    outbox.post(event("a4", .approval, chat: "c"), now: start)
    _ = outbox.due(now: at(2), away: true); outbox.delivered("a4")
    let r24 = outbox.withdraw(events: [], chats: ["c"])
    #expect(r24.isEmpty)
    let r25 = outbox.withdraw(events: ["a4"], chats: [])
    #expect(r25.events == ["a4"])
}

@Test func outboxRetryScheduleAndAttemptLimit() {
    var outbox = PushOutbox()
    outbox.post(event("a1"), now: start)
    let r26 = outbox.due(now: start, away: true)
    #expect(r26.map(\.id) == ["a1"])
    outbox.failed("a1", retryAfter: nil, now: start)
    #expect(outbox.nextRetry == at(30))
    let r27 = outbox.due(now: at(29), away: true)
    #expect(r27.isEmpty)
    // A retry of a released event does not wait for the away state again.
    let r28 = outbox.due(now: at(30), away: false)
    #expect(r28.map(\.id) == ["a1"])
    outbox.failed("a1", retryAfter: nil, now: at(30))
    #expect(outbox.nextRetry == at(150))
    let r29 = outbox.due(now: at(150), away: true)
    #expect(r29.map(\.id) == ["a1"])
    outbox.failed("a1", retryAfter: nil, now: at(150))
    #expect(!outbox.isHolding && outbox.nextRetry == nil)
    // APNs delays: 429 after 60 seconds, 5xx after 15 minutes; never past the event's lifetime.
    var server = PushOutbox()
    server.post(event("t1", .turnReady), now: start)
    _ = server.due(now: start, away: true)
    server.failed("t1", retryAfter: 60, now: start)
    #expect(server.nextRetry == at(60))
    _ = server.due(now: at(60), away: true)
    server.failed("t1", retryAfter: 900, now: at(60))
    let r30 = server.due(now: at(960), away: true)
    #expect(r30.isEmpty && !server.isHolding)
    // Drop and reset.
    var other = PushOutbox()
    other.post(event("a1"), now: start); other.post(event("a2"), now: start)
    other.drop("a1")
    #expect(other.held.map(\.event.id) == ["a2"])
    _ = other.due(now: start, away: true); other.delivered("a2")
    other.reset()
    #expect(!other.isHolding && other.sent.isEmpty)
    let r31 = other.post(event("a2"), now: start)
    #expect(r31)
}
