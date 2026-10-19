import Foundation
import ContextCore

@MainActor extension DeskModel {
    func startScheduler() async {
        guard schedulerTask == nil, !schedulerStopping else { return }
        do {
            jobLedger = try await jobStore.load(); schedulerReady = true
            if let resources = Bundle.main.resourceURL {
                let source = resources.appendingPathComponent("Skills/schedule-control")
                let destination = Locations.root.appendingPathComponent("workflows/schedule-control")
                if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.copyItem(at: source, to: destination)
                    if connected { try await connection.registerWorkflows(at: summarySkillsDirectory) }
                }
            }
        }
        catch { schedulerReady = false; self.error = error.localizedDescription; return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.watchScheduler()
                await self?.tickJobs()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    /// Watchdog for unattended work (roles plan, Phase 3b). It never replays anything: an overdue run is stopped and
    /// recorded as uncertain, and a scheduler that stopped after a storage error retries taking the schedules.
    func watchScheduler(now: Date = Date()) async {
        guard !schedulerStopping else { return }
        if !schedulerReady {
            guard now >= schedulerRecoveryAfter else { return }
            schedulerRecoveryAfter = now.addingTimeInterval(300)
            do {
                jobLedger = try await jobStore.load(); schedulerReady = true
                AppLog.lifecycle.notice("Scheduler recovered after an error")
            } catch {
                AppLog.lifecycle.error("Scheduler recovery failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        await stopOverdueRuns(now: now)
    }
    func stopOverdueRuns(now: Date = Date()) async {
        for run in jobLedger.runs where run.isOverdue(now: now) {
            AppLog.lifecycle.error("Scheduled run \(run.id.uuidString, privacy: .public) passed its deadline; stopping it")
            // Record first, so the later cancellation outcome cannot replace the reason; finishing drops the executor.
            let executor = jobExecutors[run.id], task = jobTasks[run.id]
            await finishJob(run.id, status: .uncertain, output: L10n.text(
                "Запуск шёл дольше 3 часов, и сторож остановил его. Повтора не было; проверь результат в чате запуска.",
                "The run took longer than 3 hours and the watchdog stopped it. Nothing was retried; check the result in the run's chat."))
            task?.cancel()
            await executor?.stop()
        }
    }
    func tickJobs(now: Date = Date(), controlDirectory: URL = Locations.root.appendingPathComponent("schedule-control")) async {
        guard schedulerReady, !schedulerStopping else { return }
        await processScheduleControl(directory: controlDirectory)
        guard schedulerReady, !schedulerStopping else { return }
        for job in jobLedger.jobs where job.enabled && job.nextRun.map({ $0 <= now }) == true {
            // Offline Codex work remains due; no network call has been made and no run is claimed.
            guard AgentIntegrationFactory.scheduledReadiness[job.engine]?(self) == true else { continue }
            await launchJob(job.id, manual: false, now: now)
        }
    }
    func saveJob(_ job: ManagedJob) async -> Bool {
        if job.enabled, let issue = routineIssue(job) { error = issue; return false }
        do { jobLedger = try await jobStore.save(job); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func routineIssue(_ job: ManagedJob) -> String? {
        guard let invocation = job.routine else { return nil }
        let capabilities: Set<AgentCapability>
        if job.engine == .claude { capabilities = [.scheduledExecution, .interruption] }
        else if let descriptor = agentDescriptor { capabilities = descriptor.capabilities }
        else { return L10n.text("Подключи агента для проверки возможностей рутины.", "Connect the agent to check routine capabilities.") }
        return invocation.definition.mappingIssue(capabilities: capabilities, agent: job.engine.agentID)
    }
    func deleteJob(_ id: UUID) async {
        do { jobLedger = try await jobStore.remove(id) } catch { self.error = error.localizedDescription }
    }
    func toggleJob(_ job: ManagedJob) async {
        var updated = job; updated.enabled.toggle(); _ = await saveJob(updated)
    }
    func launchJob(_ id: UUID, manual: Bool = true, now: Date = Date()) async {
        guard schedulerReady, !schedulerStopping else { return }
        do {
            guard let (job, run) = try await jobStore.claim(id, manual: manual, now: now) else { return }
            jobLedger = try await jobStore.load()
            guard let project = state.projects.first(where: { $0.id == job.projectID }),
                  FileManager.default.fileExists(atPath: project.path) else {
                await finishJob(run.id, status: .failed, output: L10n.text("Проект недоступен. Проверь папку задания.", "Project unavailable. Check the task folder.")); return
            }
            guard let makeExecutor = jobExecutorFactories[job.engine] else {
                await finishJob(run.id, status: .blocked, output: L10n.text("Исполнитель недоступен", "The agent is unavailable")); return
            }
            guard !schedulerStopping else { await finishJob(run.id, status: .interrupted); return }
            let executor = makeExecutor(self, job, run, project)
            jobExecutors[run.id] = executor
            jobTasks[run.id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    jobTasks.removeValue(forKey: run.id)
                    if jobLedger.runs.first(where: { $0.id == run.id })?.status.active != true {
                        jobExecutors.removeValue(forKey: run.id)
                    }
                }
                do {
                    let descriptor = try await executor.descriptor().value()
                    if let routine = job.routine {
                        do {
                            try routine.validate(descriptor: descriptor)
                            guard try routine.prompt() == job.prompt else { throw ConversationIdentity.invalidStorage }
                        } catch {
                            await finishJob(run.id, status: .blocked, output: error.localizedDescription); return
                        }
                    }
                    let request = job.executionRequest(runID: run.id, project: project, descriptor: descriptor)
                    let result = try await executor.execute(request) { [weak self] in
                        guard let self else { throw CancellationError() }
                        // A print run (installed CLI) has no engine session; its chat is a local read-only record.
                        if descriptor.identityMode == .externalCLI {
                            try await self.attachScheduledRecord(run, job: job, prompt: request.prompt, project: project)
                        } else { try await self.attachScheduledRun(run.id) }
                    }.value()
                    if case .finished(let outcome, let output) = result {
                        await finishJob(run.id, status: JobRunStatus(outcome), output: output)
                    }
                } catch {
                    let status: JobRunStatus
                    if let failure = error as? AgentOperationFailure {
                        status = failure.uncertain ? .uncertain : failure.rejection != nil ? .blocked : .failed
                    } else { status = error is CancellationError ? .interrupted : .failed }
                    await finishJob(run.id, status: status, output: error.localizedDescription)
                }
            }
        } catch { self.error = error.localizedDescription; schedulerReady = false }
    }
    func attachScheduledRun(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !schedulerStopping else { throw CancellationError() }
        jobLedger = try await jobStore.attach(id)
    }
    func finishJob(_ id: UUID, status: JobRunStatus, output: String = "") async {
        let wasActive = jobLedger.runs.first { $0.id == id }?.status.active == true
        do { jobLedger = try await jobStore.finish(id, status: status, output: output); jobExecutors.removeValue(forKey: id) }
        catch { schedulerReady = false; self.error = error.localizedDescription }
        if wasActive {
            await finishScheduledRecord(id, status: status, output: output)
            if let run = jobLedger.runs.first(where: { $0.id == id }) { await recordAttention(run, status: status, output: output) }
        }
    }
    func stopJob(_ run: JobRun) async {
        jobTasks[run.id]?.cancel()
        await jobExecutors[run.id]?.stop()
    }

    func stopScheduler() async {
        schedulerStopping = true; schedulerReady = false
        schedulerTask?.cancel(); schedulerTask = nil
        for task in jobTasks.values { task.cancel() }
        for executor in Array(jobExecutors.values) { await executor.stop() }
        for task in Array(jobTasks.values) { await task.value }
        for run in jobLedger.runs where run.status.active { await finishJob(run.id, status: .uncertain) }
        await jobStore.release()
    }
    func importedJob(_ source: ScheduledJob) -> ManagedJob {
        var job = ManagedJob(); job.name = source.name; job.prompt = source.prompt; job.engine = source.engine
        job.model = source.model; job.effort = source.effort; job.source = source.engine.rawValue + ":" + source.id
        job.projectID = state.projects.first(where: { source.paths.contains($0.path) })?.id
        // A source thread belongs to the other app. Only its explicit prompt can be transferred.
        job.schedule = JobSchedule(rule: source.rawRule)
        return job
    }
}

@MainActor extension DeskModel {
    func processScheduleControl(directory: URL = Locations.root.appendingPathComponent("schedule-control"), originals: URL = Locations.automations) async {
        do {
            try await ScheduleControl.drain(directory: directory, catalog: {
                try ScheduleImports.catalog(directory: originals, projects: self.state.projects.map { ScheduleProject(id: $0.id, path: $0.path) })
            }) { request in
                guard self.schedulerReady, !self.schedulerStopping else { throw ScheduleControl.invalid }
                if request.operation == "list" || request.operation == "catalog" { return try await self.jobStore.load().jobs }
                if request.operation == "import" {
                    guard let input = request.importRequest,
                          let project = self.state.projects.first(where: { $0.id == input.projectID }),
                          FileManager.default.fileExists(atPath: project.path) else { throw ScheduleControl.invalid }
                    let job = try ScheduleImports.prepare(input, directory: originals, project: ScheduleProject(id: project.id, path: project.path))
                    do { self.jobLedger = try await self.jobStore.insertImported(job) }
                    catch {
                        if error is ScheduleControlUncertain { self.schedulerReady = false }
                        throw error
                    }
                    return self.jobLedger.jobs
                }
                if request.operation == "create" {
                    guard let input = request.createRequest,
                          let project = self.state.projects.first(where: { $0.id == input.projectID }),
                          FileManager.default.fileExists(atPath: project.path) else { throw ScheduleControl.invalid }
                    let job = try ScheduleControl.created(input, project: ScheduleProject(id: project.id, path: project.path))
                    do { self.jobLedger = try await self.jobStore.insertCreated(job) }
                    catch {
                        if error is ScheduleControlUncertain { self.schedulerReady = false }
                        throw error
                    }
                    return self.jobLedger.jobs
                }
                let source = request.expected?.source
                let paused = source.map { source in
                    guard source.hasPrefix("codex:"),
                          let snapshot = try? ScheduleImports.source(String(source.dropFirst(6)), directory: originals) else { return false }
                    return snapshot.definition.status == "PAUSED"
                } ?? false
                let job = try ScheduleControl.updated(request, originalPaused: paused)
                guard let project = self.state.projects.first(where: { $0.id == job.projectID }),
                      FileManager.default.fileExists(atPath: project.path) else { throw ScheduleControl.invalid }
                if job.enabled, let issue = self.routineIssue(job) { throw ClientFailure(issue) }
                do { self.jobLedger = try await self.jobStore.save(job, expected: request.expected) }
                catch {
                    if error is ScheduleControlUncertain { self.schedulerReady = false }
                    throw error
                }
                return self.jobLedger.jobs
            }
        } catch { self.error = error.localizedDescription }
    }
}
