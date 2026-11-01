import Foundation
import ContextCore

/// Holds the one wall-clock check loop for armed "continue after limit reset" requests.
@MainActor final class LimitResumeClock {
    var task: Task<Void, Never>?
}

/// "Continue after reset": a turn that stopped on an exhausted usage limit offers one click that queues a short
/// continuation at the reset time plus a margin. The decision logic is `LimitResume.step`; this extension applies it.
@MainActor extension DeskModel {
    /// The reset the chat waits for: the stop's own, else the account limits of the chat's agent.
    func limitResumeReset(_ chat: Chat, now: Date = Date()) -> Date? {
        chat.limitResume?.reset(limits: chat.nativeSession?.connection == .appClaude ? claudeLimits : accountLimits, now: now)
    }

    /// Records (or clears) the offer when a turn completes. Any other completion makes an earlier offer obsolete.
    func noteLimitStop(threadID: String, completion: AgentTurnCompletion) {
        guard let index = state.chats.firstIndex(where: { $0.id == threadID }), !state.chats[index].isScheduledRecord else { return }
        guard let stop = completion.usageLimit else {
            if state.chats[index].limitResume != nil { state.chats[index].limitResume = nil; persist() }
            return
        }
        state.chats[index].limitResume = LimitResume(resetsAt: stop.resetsAt)
        persist()
        AppLog.delivery.notice("Chat \(threadID, privacy: .public) stopped on the usage limit; reset \(stop.resetsAt == nil ? "from account limits" : "reported", privacy: .public)")
        // Fresh account limits supply the reset when the stop carried none.
        guard stop.resetsAt == nil else { return }
        let claude = state.chats[index].nativeSession?.connection == .appClaude
        Task { [weak self] in
            if claude { await self?.refreshClaudeLimits() } else { await self?.refreshLimits() }
        }
    }

    func armLimitResume(_ id: String, now: Date = Date()) {
        guard let index = state.chats.firstIndex(where: { $0.id == id }), !state.chats[index].isArchived,
              let resume = state.chats[index].limitResume, !resume.isArmed,
              let reset = limitResumeReset(state.chats[index], now: now) else { return }
        state.chats[index].limitResume = resume.armed(reset: reset, now: now)
        // The user has seen the stop and asked for the continuation; the finished turn no longer waits for them.
        notices.removeAll { $0.threadID == id && $0.completionID != nil }
        persist()
        AppLog.delivery.notice("Chat \(id, privacy: .public): continuation after the limit reset armed")
        startLimitResumeClock()
    }

    /// Cancels the planned continuation and shows the offer again.
    func cancelLimitResume(_ id: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == id }), state.chats[index].limitResume?.isArmed == true else { return }
        state.chats[index].limitResume?.continueAt = nil
        persist()
    }

    /// Forgets the offer and any planned continuation (the user wrote, dismissed it, or the chat left).
    func dropLimitResume(_ id: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == id }), state.chats[index].limitResume != nil else { return }
        state.chats[index].limitResume = nil
        persist()
    }

    func limitResumeSituation(_ id: String) -> LimitResume.Situation {
        guard let chat = state.chats.first(where: { $0.id == id }) else { return .init(exists: false, archived: false, ready: false, busy: false) }
        let ready = !shuttingDown && !chat.isScheduledRecord && chatConnected(id) && chatAuthenticated(id)
        let busy = isBusy(threadID: id) || isSending(threadID: id) || isChangingChat(id) || pending.contains { $0.threadID == id }
            || queuedMessages.contains { $0.threadID == id } || backgroundWaits[id] != nil
        return .init(exists: true, archived: chat.isArchived, ready: ready, busy: busy)
    }

    /// One wall-clock pass over armed chats. Returns when to look again; nil when nothing is armed.
    @discardableResult
    func checkLimitResumes(now: Date = Date()) -> Date? {
        var next: Date?
        for chat in state.chats where chat.limitResume?.isArmed == true {
            switch LimitResume.step(chat.limitResume, situation: limitResumeSituation(chat.id), now: now) {
            case .none: break
            case .wait(let until): next = min(next ?? until, until)
            case .send:
                // The record goes in the same state change that queues the message: it is queued once and never retried.
                if queueContinuation(chat.id, text: LimitResume.message(), localID: LimitResume.messageIDPrefix + UUID().uuidString,
                                     removingLimitResume: true) {
                    AppLog.delivery.notice("Chat \(chat.id, privacy: .public): continuation after the limit reset queued")
                } else { dropLimitResume(chat.id) }
            case .disarm:
                cancelLimitResume(chat.id)
                AppLog.delivery.notice("Chat \(chat.id, privacy: .public) was busy at the limit reset; continuation not sent, offer shown again")
            case .drop: dropLimitResume(chat.id)
            }
        }
        return next
    }

    /// Checks at the due time but at least every `LimitResume.recheck` seconds, comparing wall-clock dates,
    /// so sleep and wake are caught on the next pass. Ends when nothing is armed; arming starts it again.
    func startLimitResumeClock() {
        guard limitResumeClock.task == nil else { return }
        limitResumeClock.task = Task { [weak self] in
            while true {
                guard let next = self?.checkLimitResumes() else { self?.limitResumeClock.task = nil; return }
                do { try await Task.sleep(for: .seconds(min(max(next.timeIntervalSinceNow, 1), LimitResume.recheck))) }
                catch { self?.limitResumeClock.task = nil; return }
            }
        }
    }
}
