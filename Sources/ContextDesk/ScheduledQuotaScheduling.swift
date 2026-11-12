import Foundation
import ContextCore

/// One admission read per connection, shared by all due routines. Never starts a model turn.
@MainActor final class ScheduledQuotaState {
    struct Snapshot: Sendable {
        let accountID: String?
        let limits: AccountLimits?
        let context: AgentContext?
        let fetchedAt: Date
    }
    var closeBrowser: @Sendable (AgentSessionReference, URL) -> ScheduledBrowserCleanup.Outcome = {
        ScheduledBrowserCleanup.close(session: $0, runtime: $1)
    }
    var cached: [AgentConnectionID: Snapshot] = [:]
    var requests: [AgentConnectionID: Task<Snapshot, Never>] = [:]
    var checking: Set<UUID> = []
    var launching: Set<UUID> = []
    var cleanup: Set<UUID> = []
    var cleanupTasks: [String: Task<Void, Never>] = [:]
}

@MainActor extension DeskModel {
    func scheduledQuotaSnapshot(_ connection: AgentConnectionID?, fresh: Bool = false) async -> ScheduledQuotaState.Snapshot {
        guard let agent = connection else { return .init(accountID: nil, limits: nil, context: nil, fetchedAt: Date()) }
        let context = agentState(agent).descriptor?.context
        if let pending = scheduledQuota.requests[agent] { return await pending.value }
        if !fresh, let value = scheduledQuota.cached[agent], value.context == context,
           Date().timeIntervalSince(value.fetchedAt) < 60 { return value }
        let task = Task { @MainActor [weak self] in
            guard let self, let client = self.client(agent) else {
                return ScheduledQuotaState.Snapshot(accountID: nil, limits: nil, context: context, fetchedAt: Date())
            }
            do {
                let account = try await client.account()
                let limits = try await client.limits()
                guard account.authenticated, self.agentState(agent).descriptor?.context == context else {
                    return ScheduledQuotaState.Snapshot(accountID: nil, limits: nil, context: context, fetchedAt: Date())
                }
                return ScheduledQuotaState.Snapshot(accountID: account.identityFingerprint, limits: limits, context: context, fetchedAt: Date())
            } catch {
                return ScheduledQuotaState.Snapshot(accountID: nil, limits: nil, context: context, fetchedAt: Date())
            }
        }
        scheduledQuota.requests[agent] = task
        let value = await task.value
        scheduledQuota.requests[agent] = nil
        scheduledQuota.cached[agent] = value
        return value
    }

    func scheduledQuotaDecision(_ job: ManagedJob, snapshot: ScheduledQuotaState.Snapshot, now: Date) -> ScheduledLimitPolicy.Decision {
        guard snapshot.accountID != nil else { return .unknown }
        guard let provider = AgentIntegrationFactory.quotaProvider(job.engine) else { return .unknown }
        return ScheduledLimitPolicy.evaluate(snapshot.limits, provider: provider, model: modelCatalog(connection(for: job.engine))?.resolveModel(job.model) ?? job.model, now: now)
    }

    func quotaNextCheck(reset: Date?, count: Int = 0, now: Date) -> Date {
        if let reset, reset > now { return reset.addingTimeInterval(LimitResume.margin) }
        return now.addingTimeInterval(min(3600, 300 * pow(2, Double(min(count, 4)))))
    }

    func quotaWaitingText(reset: Date?) -> String {
        if let reset {
            return L10n.text("Лимит исчерпан. Проверка после ", "Quota exhausted. Check after ") + LimitResume.timeText(reset.addingTimeInterval(LimitResume.margin), now: Date())
        }
        return L10n.text("Доступный лимит не подтверждён. Проверка будет повторена без запуска агента.",
                         "Available quota is not confirmed. The check will repeat without starting the agent.")
    }

    /// A quota stop is definitive. Persist the wait before releasing browser resources.
    func suspendScheduledQuota(threadID: String, completion: AgentTurnCompletion) async -> Bool {
        guard let stop = completion.usageLimit,
              let run = jobLedger.runs.first(where: { $0.threadID == threadID && $0.status.occupiesSlot && ($0.turnID == nil || $0.turnID == completion.id) }),
              let job = jobLedger.jobs.first(where: { $0.id == run.jobID }) else { return false }
        let now = Date()
        if let agent = connection(for: job.engine) { scheduledQuota.cached[agent] = nil }
        do {
            jobLedger = try await jobStore.suspendForQuota(run.id, resetAt: stop.resetsAt,
                nextCheckAt: quotaNextCheck(reset: stop.resetsAt, now: now), model: job.model,
                accountID: run.executionAccountID, now: now, suspendedTurnID: completion.id)
            guard jobLedger.runs.contains(where: { $0.id == run.id && $0.status == .waitingForQuota }) else { return false }
            jobExecutors.removeValue(forKey: run.id)
            jobLedger = try await jobStore.updateQuotaWait(run.id, resetAt: stop.resetsAt,
                nextCheckAt: quotaNextCheck(reset: stop.resetsAt, now: now), output: quotaWaitingText(reset: stop.resetsAt), countCheck: false)
            guard jobLedger.runs.contains(where: { $0.id == run.id && $0.status == .waitingForQuota }) else { return true }
            await reconcileQuotaAttention()
            dropLimitResume(threadID)
            if let session = state.chats.first(where: { $0.id == threadID })?.nativeSession,
               let resources = Bundle.main.resourceURL {
                scheduledQuota.cleanup.insert(run.id)
                let closeBrowser = scheduledQuota.closeBrowser
                scheduledQuota.cleanupTasks[threadID] = Task { [weak self] in
                    let result = await Task.detached {
                        closeBrowser(session, resources.appendingPathComponent("BrowserRuntime"))
                    }.value
                    guard let self else { return }
                    defer { self.scheduledQuota.cleanup.remove(run.id); self.scheduledQuota.cleanupTasks[threadID] = nil }
                    guard !self.schedulerStopping, self.schedulerReady, let current = self.jobLedger.runs.first(where: { $0.id == run.id }),
                          current.status == .waitingForQuota, let wait = current.quotaWait else { return }
                    let note: String
                    switch result {
                    case .notNeeded: note = L10n.text("Автоматическое закрытие браузера не требовалось или профиль не принадлежит агенту.", "Automatic browser closure was not needed or the profile is not agent-owned.")
                    case .closed: note = L10n.text("Агентный браузер закрыт; профиль сохранён.", "Agent browser closed; profile preserved.")
                    case .failed(let reason): note = L10n.text("Браузер не освобождён: ", "Browser resources were not released: ") + reason
                    }
                    do {
                        self.jobLedger = try await self.jobStore.updateQuotaWait(run.id, resetAt: wait.resetAt,
                            nextCheckAt: wait.nextCheckAt, output: current.output + "\n" + note, countCheck: false)
                    } catch { self.schedulerReady = false; self.error = error.localizedDescription }
                }
            }
            return true
        } catch {
            schedulerReady = false; self.error = error.localizedDescription
            return false
        }
    }

    func checkScheduledQuotaWaits(now: Date = Date()) async {
        for run in jobLedger.runs where run.status == .waitingForQuota && run.quotaWait.map({ $0.nextCheckAt <= now }) == true {
            await checkScheduledQuotaWait(run.id, now: now)
        }
    }

    func checkScheduledQuotaWait(_ id: UUID, now: Date = Date(), manual: Bool = false) async {
        guard schedulerReady, !schedulerStopping, !scheduledQuota.cleanup.contains(id),
              scheduledQuota.checking.insert(id).inserted else { return }
        defer { scheduledQuota.checking.remove(id) }
        guard let run = jobLedger.runs.first(where: { $0.id == id && $0.status == .waitingForQuota }), let wait = run.quotaWait else { return }
        guard let agent = connection(for: run.engine) else { return }
        guard scheduledAgentReady(agent) else { return }
        let snapshot = await scheduledQuotaSnapshot(agent, fresh: manual)
        guard schedulerReady, !schedulerStopping,
              jobLedger.runs.contains(where: { $0.id == id && $0.status == .waitingForQuota }) else { return }
        if let original = wait.accountID, let current = snapshot.accountID, original != current {
            await finishJob(id, status: .interrupted, output: L10n.text("Аккаунт изменился. Автоматическое продолжение отменено.", "The account changed. Automatic continuation was cancelled.")); return
        }
        if let thread = run.threadID {
            guard let chat = state.chats.first(where: { $0.id == thread }), !chat.isArchived,
                  dispatchModel(chat) == wait.model, chat.route == wait.job.route, chat.effort == wait.job.effort else {
                await finishJob(id, status: .interrupted, output: L10n.text("Чат или его настройки изменились. Продолжение отменено.", "The chat or its settings changed. Continuation was cancelled.")); return
            }
            guard !isBusy(threadID: thread), !isSending(threadID: thread), !isChangingChat(thread),
                  !queuedMessages.contains(where: { $0.threadID == thread }), !pending.contains(where: { $0.threadID == thread }), backgroundWaits[thread] == nil else { return }
            // An old run without a stable binding cannot adopt whichever account is now signed in.
            guard wait.accountID != nil else {
                await finishJob(id, status: .interrupted, output: L10n.text("Не удалось подтвердить исходный аккаунт. Продолжи чат вручную.", "The original account could not be confirmed. Continue the chat manually.")); return
            }
        }
        guard snapshot.context == agentState(agent).descriptor?.context else { return }
        let decision = scheduledQuotaDecision(wait.job, snapshot: snapshot, now: Date())
        do {
            switch decision {
            case .unknown, .wait:
                let reset: Date?
                if case .wait(let value) = decision { reset = value } else { reset = nil }
                jobLedger = try await jobStore.updateQuotaWait(id, resetAt: reset,
                    nextCheckAt: quotaNextCheck(reset: reset, count: wait.checkCount ?? 0, now: Date()))
            case .allowed:
                guard let project = state.projects.first(where: { $0.id == wait.job.projectID }),
                      FileManager.default.fileExists(atPath: project.path) else {
                    await finishJob(id, status: .failed, output: L10n.text("Проект недоступен.", "Project unavailable.")); return
                }
                if let original = run.executionPermissions,
                   original != wait.job.role(project: project, catalog: roleCatalog).profile(for: project, sharedRoots: sharedRoots) {
                    await finishJob(id, status: .interrupted, output: L10n.text("Разрешения проекта изменились. Автоматическое продолжение отменено; проверь настройки перед новым запуском.", "Project permissions changed. Automatic continuation was cancelled; review settings before starting again.")); return
                }
                // Manual checks may run before the previous due date; admission still needs an atomic claim.
                if manual { jobLedger = try await jobStore.updateQuotaWait(id, resetAt: nil, nextCheckAt: now, countCheck: false) }
                guard let (job, claimed) = try await jobStore.claimQuotaResume(id, now: Date(), accountID: snapshot.accountID) else { return }
                jobLedger = try await jobStore.load()
                await reconcileQuotaAttention()
                if let thread = claimed.threadID {
                    guard !isBusy(threadID: thread), !isSending(threadID: thread),
                          !queuedMessages.contains(where: { $0.threadID == thread }) else {
                        await finishJob(id, status: .interrupted, output: L10n.text("Чат занят. Автоматическое продолжение отменено.", "The chat is busy. Automatic continuation was cancelled.")); return
                    }
                    let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.deliver(text: L10n.text(
                        "Продолжай текущий запуск рутины с места остановки. Не повторяй уже выполненные действия. Проверь результат действий с неизвестным исходом. Если нужен браузер, открой новую браузерную сессию с сохранённым профилем; прежние идентификаторы вкладок недействительны.",
                        "Continue this routine run where it stopped. Do not repeat completed actions. Check actions with unknown outcomes before proceeding. If a browser is needed, open a new browser session with the saved profile; previous tab identifiers are invalid."),
                        project: project, threadID: thread, localID: "local-user:quota:" + UUID().uuidString,
                        selectedModel: wait.model, selectedEffort: job.effort, scheduledRun: claimed.id,
                        scheduledRoute: job.route, scheduledAgent: agent, scheduledRole: job.role(project: project, catalog: self.roleCatalog))
                    }
                    jobTasks[id] = task
                    await task.value
                    jobTasks[id] = nil
                } else { await executeClaimedJob(job, run: claimed) }
            }
        } catch { schedulerReady = false; self.error = error.localizedDescription }
    }

    func cancelScheduledQuota(in thread: String) async {
        for run in jobLedger.runs where run.threadID == thread && run.status == .waitingForQuota {
            await finishJob(run.id, status: .interrupted, output: L10n.text("Автоматическое продолжение отменено действием пользователя.", "Automatic continuation was cancelled by user activity."))
        }
    }
}
