import Foundation
import AgentContract
import Darwin

public enum JobEngine: String, Codable, CaseIterable, Sendable {
    case codex, claude
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Deliberately bounded RRULE support. Unsupported fields are rejected, never ignored.
public struct JobSchedule: Codable, Equatable, Sendable {
    public var rule: String
    public var timeZone: String
    public var once: Date?
    public init(rule: String = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timeZone: String = TimeZone.current.identifier, once: Date? = nil) {
        self.rule = rule; self.timeZone = timeZone; self.once = once
    }
    public func next(after date: Date) throws -> Date? {
        guard let zone = TimeZone(identifier: timeZone) else { throw Self.invalid }
        if let once { return once > date ? once : nil }
        if rule.isEmpty { return nil }
        let raw = rule.hasPrefix("RRULE:") ? String(rule.dropFirst(6)) : rule
        var fields: [String: String] = [:]
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, fields[String(pair[0])] == nil else { throw Self.invalid }
            fields[String(pair[0])] = String(pair[1])
        }
        let interval = Int(fields["INTERVAL"] ?? "1") ?? 0
        guard (1...525600).contains(interval) else { throw Self.invalid }
        if fields["FREQ"] == "MINUTELY" || fields["FREQ"] == "HOURLY" {
            guard Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL"]) else { throw Self.invalid }
            return date.addingTimeInterval(Double(interval) * (fields["FREQ"] == "HOURLY" ? 3600 : 60))
        }
        guard ["DAILY", "WEEKLY"].contains(fields["FREQ"] ?? ""), interval == 1,
              Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYSECOND", "BYDAY"]),
              fields["BYSECOND"] == nil || fields["BYSECOND"] == "0" else { throw Self.invalid }
        func numbers(_ key: String, range: ClosedRange<Int>) throws -> [Int] {
            guard let value = fields[key] else { throw Self.invalid }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Int($0) }
            guard !values.isEmpty, values.count == parts.count, values.allSatisfy(range.contains) else { throw Self.invalid }
            return Array(Set(values)).sorted()
        }
        let hours = try numbers("BYHOUR", range: 0...23), minutes = try numbers("BYMINUTE", range: 0...59)
        let weekdayMap = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let days = fields["BYDAY"]?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
        guard days.allSatisfy({ weekdayMap[$0] != nil }), fields["FREQ"] != "WEEKLY" || !days.isEmpty else { throw Self.invalid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var candidates: [Date] = []
        for hour in hours { for minute in minutes {
            for day in days.isEmpty ? [nil] : days.map({ weekdayMap[$0] }) {
                var components = DateComponents(); components.hour = hour; components.minute = minute; components.second = 0; components.weekday = day
                if let next = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first) { candidates.append(next) }
            }
        } }
        return candidates.min()
    }
    public static var invalid: ClientFailure {
        ClientFailure(L10n.text("Неподдерживаемое расписание или часовой пояс. Используй минуты/часы с INTERVAL либо DAILY/WEEKLY с BYHOUR, BYMINUTE и BYDAY.", "Unsupported schedule or time zone. Use minutes/hours with INTERVAL, or DAILY/WEEKLY with BYHOUR, BYMINUTE and BYDAY."))
    }
}

public struct ManagedJob: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var prompt = ""
    public var engine = JobEngine.codex
    public var projectID: UUID?
    public var model = ""
    public var effort = ""
    public var route = RequestRoute.direct
    public var schedule = JobSchedule()
    public var enabled = false
    public var nextRun: Date?
    public var source: String?
    public var sourceDisabled = false
    /// Missing on legacy jobs: never infer consent from a project access mode.
    public var acceptsExternalPolicy: Bool?
    /// Role for this job's runs; nil uses the project's job default. Never above it (`ScheduleControl` cannot set it).
    public var roleID: String?
    /// Explicit per-task permission, propagated to each fresh browser environment.
    public var browserSessionImport: ChromeSessionImportPolicy?
    /// A frozen revision: editing the library never silently changes scheduled work.
    public var routine: RoutineInvocation?
    /// Command that decides whether a run starts; only the app's job editor sets it.
    public var precondition: JobPrecondition?
    public init() {}
    public func validate() throws {
        try validateBrowserSessionImport()
        if let routine, try routine.prompt() != prompt {
            throw ClientFailure(L10n.text("Инструкции не соответствуют сохранённой версии рутины. Выбери рутину заново.", "Instructions do not match the saved routine revision. Select the routine again."))
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, projectID != nil else {
            throw ClientFailure(L10n.text("Укажи название, задание и проект.", "Enter a name, instructions and project."))
        }
        _ = try schedule.next(after: Date())
        guard !enabled || source == nil || sourceDisabled else {
            throw ClientFailure(L10n.text("Сначала отключи исходное расписание и подтверди это в редакторе.", "Disable the original schedule first and confirm this in the editor."))
        }
    }
}
public enum JobRunStatus: String, Codable, Sendable {
    case starting, running, completed, failed, interrupted, uncertain, blocked, skipped
    public var active: Bool { self == .starting || self == .running }
    public var title: String {
        switch self {
        case .starting: return L10n.text("Запускается", "Starting")
        case .running: return L10n.text("Выполняется", "Running")
        case .completed: return L10n.text("Завершено", "Completed")
        case .failed: return L10n.text("Ошибка", "Failed")
        case .interrupted: return L10n.text("Остановлено", "Stopped")
        case .uncertain: return L10n.text("Результат не подтверждён", "Outcome unconfirmed")
        case .blocked: return L10n.text("Нужны разрешения", "Permissions needed")
        case .skipped: return L10n.text("Пропущено: нового нет", "Skipped: nothing new")
        }
    }
}
public struct JobRun: Identifiable, Codable, Sendable {
    /// Kept under the legacy JSON key so migration cannot break cross-file links.
    public var conversationID: ConversationID? { threadID.map { ConversationID($0) } }
    public var id = UUID()
    public var jobID: UUID
    public var engine: JobEngine
    public var name: String
    public var started: Date
    public var finished: Date?
    public var status: JobRunStatus = .starting
    public var threadID: String?
    public var turnID: String?
    public var output = ""
    public var routine: RoutineInvocation?
}
extension JobRun {
    /// Longest a scheduled run may stay active before the watchdog stops it. The longest observed run took
    /// 113 minutes (2026-10-19), so this only catches hung runs.
    public static let deadline: TimeInterval = 3 * 3600
    public func isOverdue(now: Date) -> Bool { status.active && now.timeIntervalSince(started) > Self.deadline }
}
public struct JobLedger: Codable, Sendable {
    public var version = 1
    public var jobs: [ManagedJob] = []
    public var runs: [JobRun] = []
    public init() {}
}

/// Single process owner plus write-before-dispatch ledger. A failed write never authorizes execution.
public actor JobStore {
    public nonisolated let file: URL
    private var lock: Int32 = -1
    private var ledger: JobLedger?
    public init(file: URL) { self.file = file }
    deinit { Self.unlock(lock) }
    private static func unlock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        // A child/duplicate may still hold the open file description. close alone
        // does not release flock until every copy closes (including pre-exec children).
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    public func load() throws -> JobLedger {
        if let ledger { return ledger }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClientFailure(L10n.text("Не удалось открыть расписания", "Could not open schedules")) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw ClientFailure(L10n.text("Расписания уже обслуживает другое окно приложения.", "Another app instance already owns the schedules."))
        }
        lock = fd
        do {
            var value = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(JobLedger.self, from: Data(contentsOf: file)) : JobLedger()
            guard value.version == 1 else { throw JobSchedule.invalid }
            for index in value.runs.indices where value.runs[index].status.active {
                value.runs[index].status = .uncertain; value.runs[index].finished = Date()
                // The occurrence was consumed before dispatch. Keep the user's schedule
                // and its next occurrence; recovering this run must not replay it.
            }
            try commit(value)
            return value
        } catch { Self.unlock(lock); lock = -1; throw error }
    }
    private func commit(_ value: JobLedger) throws {
        let data = try JSONEncoder().encode(value)
        // No data-protection class: scheduled runs read this file while the Mac is locked; 0600 keeps it private.
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        ledger = value
    }
    public func save(_ job: ManagedJob, now: Date = Date(), expected: ManagedJob? = nil) throws -> JobLedger {
        try job.validate()
        var value = try load()
        if let expected {
            guard expected.id == job.id, value.jobs.first(where: { $0.id == job.id }) == expected else { throw ScheduleControl.changed }
        }
        guard !value.runs.contains(where: { $0.jobID == job.id && $0.status.active }) else { throw Self.busy }
        var job = job
        job.nextRun = job.enabled ? try job.schedule.next(after: now) : nil
        if job.enabled && job.nextRun == nil { job.enabled = false }
        if let index = value.jobs.firstIndex(where: { $0.id == job.id }) { value.jobs[index] = job } else { value.jobs.append(job) }
        do { try commit(value) }
        catch {
            if expected != nil { throw ScheduleControlUncertain() }
            throw error
        }
        return value
    }
    public func insertImported(_ job: ManagedJob) throws -> JobLedger {
        try job.validate()
        var value = try load()
        guard !job.enabled, !job.sourceDisabled, job.nextRun == nil, let source = job.source,
              !value.jobs.contains(where: { $0.id == job.id || $0.source == source }) else {
            throw ClientFailure(L10n.text("Это расписание уже импортировано или копия не выключена.", "This schedule is already imported or the copy is not disabled."))
        }
        value.jobs.append(job)
        do { try commit(value) } catch { throw ScheduleControlUncertain() }
        return value
    }
    /// Add a task authored through the control channel. A lost acknowledgement is uncertain, never a retry.
    public func insertCreated(_ job: ManagedJob, now: Date = Date()) throws -> JobLedger {
        try job.validate()
        var value = try load()
        guard job.source == nil, !job.sourceDisabled, job.routine == nil, job.roleID == nil,
              !value.jobs.contains(where: { $0.id == job.id }) else { throw ScheduleControl.invalid }
        var job = job
        job.nextRun = job.enabled ? try job.schedule.next(after: now) : nil
        if job.enabled && job.nextRun == nil { job.enabled = false }
        value.jobs.append(job)
        do { try commit(value) } catch { throw ScheduleControlUncertain() }
        return value
    }
    public func remove(_ id: UUID) throws -> JobLedger {
        var value = try load()
        guard !value.runs.contains(where: { $0.jobID == id && $0.status.active }) else { throw Self.busy }
        value.jobs.removeAll { $0.id == id }; value.runs.removeAll { $0.jobID == id }
        try commit(value); return value
    }
    public func claim(_ id: UUID, manual: Bool, now: Date = Date()) throws -> (ManagedJob, JobRun)? {
        var value = try load()
        guard let index = value.jobs.firstIndex(where: { $0.id == id }),
              value.runs.filter({ $0.status.active }).count < 3,
              !value.runs.contains(where: { $0.jobID == id && $0.status.active }) else { return nil }
        let job = value.jobs[index]
        guard manual || (job.enabled && job.nextRun.map { $0 <= now } == true) else { return nil }
        try job.validate()
        var run = JobRun(jobID: id, engine: job.engine, name: job.name, started: now)
        run.routine = job.routine
        value.runs.insert(run, at: 0)
        // No backlog after sleep. Manual runs leave the scheduled occurrence intact.
        if !manual {
            value.jobs[index].nextRun = try job.schedule.next(after: now)
            if value.jobs[index].nextRun == nil { value.jobs[index].enabled = false }
        }
        try commit(value); return (job, run)
    }
    public func attach(_ id: UUID, thread: String? = nil, turn: String? = nil) throws -> JobLedger {
        var value = try load()
        if let i = value.runs.firstIndex(where: { $0.id == id && $0.status.active }) {
            value.runs[i].threadID = thread; value.runs[i].turnID = turn; value.runs[i].status = .running
        }
        try commit(value); return value
    }
    public func finish(_ id: UUID, status: JobRunStatus, output: String = "") throws -> JobLedger {
        var value = try load()
        if let i = value.runs.firstIndex(where: { $0.id == id && $0.status.active }) {
            value.runs[i].status = status; value.runs[i].output = output; value.runs[i].finished = Date()
            // A run's outcome does not change the user's recurring schedule.
        }
        try commit(value); return value
    }
    public func release() { ledger = nil; Self.unlock(lock); lock = -1 }
    public static var busy: ClientFailure { ClientFailure(L10n.text("Дождись завершения задания или останови его.", "Wait for the task to finish or stop it.")) }
}
