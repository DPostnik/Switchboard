import Foundation
import Darwin

/// Local, same-user command channel. Only the running scheduler may execute requests.
/// Claim files are permanent receipts: an interrupted command is never replayed.
public struct ScheduleControlRequest: Codable, Sendable {
    public var version: Int
    public var id: UUID
    public var expires: Date
    public var operation: String
    public var importRequest: ScheduleImport?
    /// A new app-owned recurring task; the owner fixes route, role, source and consent.
    public var createRequest: ScheduleCreate?
    public var expected: ManagedJob?
    public var model: String?
    public var effort: String?
    public var prompt: String?
    /// A replacement recurring schedule; one-time runs stay in the editor.
    public var schedule: JobSchedule?
    public var enabled: Bool?
    public var confirmSourceDisabled: Bool?
    /// Explicit user-authorized per-task consent for an external CLI engine (Claude only).
    public var acceptExternalPolicy: Bool?
    public var browserSessionImport: ChromeSessionImportPolicy?
    public var clearBrowserSessionImport: Bool?
}

public struct ScheduleControlReply: Codable, Sendable {
    public var version = 1
    public var id: UUID
    public var status: String
    public var jobs: [ManagedJob]?
    public var message: String?
    public var catalog: ScheduleCatalog?
    public init(id: UUID, status: String, jobs: [ManagedJob]? = nil, message: String? = nil) {
        self.id = id; self.status = status; self.jobs = jobs; self.message = message
    }
}

public struct ScheduleControlUncertain: LocalizedError, Sendable {
    public var errorDescription: String? {
        L10n.text("Не удалось подтвердить сохранение задания. Проверь состояние; не повторяй изменение автоматически.", "Could not confirm the task was saved. Check its state; do not automatically repeat the edit.")
    }
    public init() {}
}

public enum ScheduleControl {
    public static var invalid: ClientFailure {
        ClientFailure(L10n.text("Некорректный или просроченный запрос управления расписанием.", "Invalid or expired schedule control request."))
    }
    public static var changed: ClientFailure {
        ClientFailure(L10n.text("Задание изменилось. Прочитай его заново перед изменением.", "The task changed. Read it again before editing."))
    }
    public static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// Build a new task from an agent request. The agent chooses only name, instructions, engine,
    /// recurring schedule, model/effort, project and enablement; everything else stays at the owner's defaults.
    public static func created(_ input: ScheduleCreate, project: ScheduleProject, now: Date = Date()) throws -> ManagedJob {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.projectID == project.id, TimeZone(identifier: input.schedule.timeZone) != nil,
              !input.model.isEmpty, input.model.count <= 128,
              input.model == input.model.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              efforts.contains(input.effort) else { throw invalid }
        guard input.schedule.once == nil, !input.schedule.rule.isEmpty,
              try input.schedule.next(after: now) != nil else { throw JobSchedule.invalid }
        var job = ManagedJob()
        job.name = name; job.prompt = input.prompt; job.engine = input.engine
        job.projectID = project.id; job.model = input.model; job.effort = input.effort
        job.schedule = JobSchedule(rule: input.schedule.rule, timeZone: input.schedule.timeZone)
        job.enabled = input.enabled ?? false
        try job.validate()
        return job
    }
    public static func updated(_ request: ScheduleControlRequest, originalPaused: Bool) throws -> ManagedJob {
        guard ["update", "browser-import"].contains(request.operation), var job = request.expected else { throw invalid }
        guard (request.model == nil) == (request.effort == nil) else { throw invalid }
        if let model = request.model, let effort = request.effort {
            guard !model.isEmpty, model.count <= 128,
                  model == model.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  efforts.contains(effort) else { throw invalid }
            job.model = model; job.effort = effort
        }
        if request.operation == "browser-import" {
            guard (request.browserSessionImport != nil) != (request.clearBrowserSessionImport == true),
                  request.prompt == nil, request.enabled == nil, request.confirmSourceDisabled == nil else { throw invalid }
            if let policy = request.browserSessionImport {
                job.browserSessionImport = try ChromeSessionImportPolicy(profile: policy.profile, site: policy.site)
            } else { job.browserSessionImport = nil }
        } else if request.browserSessionImport != nil || request.clearBrowserSessionImport != nil { throw invalid }
        if let accepted = request.acceptExternalPolicy {
            guard request.operation == "update", job.engine == .claude else { throw invalid }
            job.acceptsExternalPolicy = accepted
        }
        if let schedule = request.schedule {
            guard request.operation == "update", schedule.once == nil, !schedule.rule.isEmpty,
                  try schedule.next(after: Date()) != nil else { throw JobSchedule.invalid }
            job.schedule = schedule
        }
        if let prompt = request.prompt { job.prompt = prompt }
        if let enabled = request.enabled { job.enabled = enabled }
        if request.confirmSourceDisabled == true {
            guard job.source != nil, originalPaused else {
                throw ClientFailure(L10n.text("Пауза исходного расписания не подтверждена.", "The original schedule is not confirmed paused."))
            }
            job.sourceDisabled = true
        }
        // An enabled task whose pause was already confirmed keeps that confirmation for edits that do
        // not change enablement; a missing source definition must not freeze its instructions/settings.
        let confirmedRunning = request.enabled == nil && request.confirmSourceDisabled == nil
            && request.expected?.enabled == true && request.expected?.sourceDisabled == true
        if job.enabled && job.source != nil && !originalPaused && !confirmedRunning {
            throw ClientFailure(L10n.text("Исходное расписание должно оставаться на паузе.", "The original schedule must remain paused."))
        }
        try job.validate()
        return job
    }

    /// Transport consumes bounded JSON, never commands or executable text.
    @MainActor public static func drain(directory: URL, now: Date = Date(),
        catalog: () throws -> ScheduleCatalog = { ScheduleCatalog() },
        handle: (ScheduleControlRequest) async throws -> [ManagedJob]) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folderAttributes = try fm.attributesOfItem(atPath: directory.path)
        guard folderAttributes[.type] as? FileAttributeType == .typeDirectory,
              (folderAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((folderAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw invalid }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".request.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files.prefix(8) {
            let stem = String(file.lastPathComponent.dropLast(".request.json".count))
            guard let id = UUID(uuidString: stem), id.uuidString == stem else { continue }
            let claim = directory.appendingPathComponent(stem + ".claimed.json")
            let response = directory.appendingPathComponent(stem + ".response.json")
            guard !fm.fileExists(atPath: claim.path), !fm.fileExists(atPath: response.path) else { continue }
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else { continue }
            // Rename precedes all mutations. A crash after rename requires manual reconciliation.
            try fm.moveItem(at: file, to: claim)
            let reply: ScheduleControlReply
            do {
                let data = try Data(contentsOf: claim)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys).isSubset(of: ["version", "id", "expires", "operation", "browserSessionImport", "clearBrowserSessionImport", "expected", "prompt", "schedule", "enabled", "confirmSourceDisabled", "acceptExternalPolicy", "importRequest", "createRequest", "model", "effort"]) else { throw invalid }
                let request = try JSONDecoder().decode(ScheduleControlRequest.self, from: data)
                guard request.version == 1, request.id == id, request.expires > now,
                      request.expires.timeIntervalSince(now) <= 600,
                      ["list", "update", "catalog", "import", "create", "browser-import"].contains(request.operation) else { throw invalid }
                if request.operation == "create" {
                    guard Set(object.keys) == Set(["version", "id", "expires", "operation", "createRequest"]),
                          let created = object["createRequest"] as? [String: Any],
                          Set(created.keys).isSubset(of: ["name", "prompt", "engine", "projectID", "schedule", "model", "effort", "enabled"]),
                          let schedule = created["schedule"] as? [String: Any], Set(schedule.keys) == Set(["rule", "timeZone"]),
                          request.createRequest != nil else { throw invalid }
                } else if request.createRequest != nil { throw invalid }
                if request.operation == "browser-import", !Set(object.keys).isSubset(of: ["version", "id", "expires", "operation", "expected", "browserSessionImport", "clearBrowserSessionImport"]) { throw invalid }
                if request.operation != "browser-import", request.browserSessionImport != nil || request.clearBrowserSessionImport != nil { throw invalid }
                if let policy = object["browserSessionImport"] as? [String: Any], Set(policy.keys) != Set(["profile", "site"]) { throw invalid }
                if object["schedule"] != nil, request.operation != "create" {
                    guard request.operation == "update", let schedule = object["schedule"] as? [String: Any],
                          Set(schedule.keys) == Set(["rule", "timeZone"]) else { throw invalid }
                }
                if request.operation == "list" || request.operation == "catalog" {
                    guard request.expected == nil, request.prompt == nil, request.schedule == nil, request.enabled == nil,
                          request.confirmSourceDisabled == nil, request.importRequest == nil,
                          request.acceptExternalPolicy == nil, request.model == nil, request.effort == nil else { throw invalid }
                }
                if request.operation == "import" {
                    guard let imported = object["importRequest"] as? [String: Any],
                          Set(imported.keys).isSubset(of: ["sourceID", "sourceDigest", "projectID", "timeZone", "model", "effort", "recurring", "prompt"]),
                          request.importRequest != nil, request.expected == nil, request.prompt == nil, request.schedule == nil,
                          request.enabled == nil, request.confirmSourceDisabled == nil,
                          request.acceptExternalPolicy == nil, request.model == nil, request.effort == nil else { throw invalid }
                } else if request.importRequest != nil { throw invalid }
                var completed = ScheduleControlReply(id: id, status: "completed", jobs: try await handle(request))
                if request.operation == "catalog" { completed.catalog = try catalog() }
                reply = completed
            } catch {
                reply = ScheduleControlReply(id: id, status: error is ScheduleControlUncertain ? "uncertain" : "rejected", message: error.localizedDescription)
            }
            try JSONEncoder().encode(reply).write(to: response, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: response.path)
        }
    }
}
