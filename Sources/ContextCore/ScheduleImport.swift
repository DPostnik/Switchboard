import Foundation
import CryptoKit

public struct ScheduleImport: Codable, Sendable {
    public var sourceID: String
    public var sourceDigest: String
    public var projectID: UUID
    public var timeZone: String
    public var model: String
    public var effort: String
    public var recurring: Bool
    public var prompt: String?
}

/// Agent-authored new task. Fields the owner always decides (route, role, source, consent) are absent by design.
public struct ScheduleCreate: Codable, Sendable {
    public var name: String
    public var prompt: String
    public var engine: JobEngine
    public var projectID: UUID
    public var schedule: JobSchedule
    public var model: String
    public var effort: String
    public var enabled: Bool?
    public init(name: String, prompt: String, engine: JobEngine, projectID: UUID, schedule: JobSchedule,
                model: String, effort: String, enabled: Bool? = nil) {
        self.name = name; self.prompt = prompt; self.engine = engine; self.projectID = projectID
        self.schedule = schedule; self.model = model; self.effort = effort; self.enabled = enabled
    }
}

public struct ScheduleSource: Codable, Sendable {
    public var definition: ScheduledJob
    public var digest: String
}

public struct ScheduleProject: Codable, Sendable {
    public var id: UUID
    public var path: String
    public init(id: UUID, path: String) { self.id = id; self.path = path }
}

public struct ScheduleCatalog: Codable, Sendable {
    public var sources: [ScheduleSource]
    public var projects: [ScheduleProject]
    public init(sources: [ScheduleSource] = [], projects: [ScheduleProject] = []) {
        self.sources = sources; self.projects = projects
    }
}

public enum ScheduleImports {
    /// Read only known, same-user, nonsymlink source definitions. Never write external state.
    public static func source(_ id: String, directory: URL) throws -> ScheduleSource {
        guard !id.isEmpty, id != ".", id != "..",
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else { throw ScheduleControl.invalid }
        let folder = directory.appendingPathComponent(id)
        let file = folder.appendingPathComponent("automation.toml")
        for url in [directory, folder, file] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == (url == file ? .typeRegular : .typeDirectory),
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ScheduleControl.invalid }
        }
        let bytes = try Data(contentsOf: file)
        guard bytes.count < 2_000_000 else { throw ScheduleControl.invalid }
        let definition = try ScheduledJobs.decode(bytes, id: id)
        guard definition.issue == nil, ["ACTIVE", "PAUSED"].contains(definition.status) else { throw ScheduleControl.invalid }
        return ScheduleSource(definition: definition, digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    public static func catalog(directory: URL, projects: [ScheduleProject]) throws -> ScheduleCatalog {
        // Failure to read the directory must not look like an empty source list.
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let sources = folders.compactMap { try? source($0.lastPathComponent, directory: directory) }
        return ScheduleCatalog(sources: sources.sorted { $0.definition.id < $1.definition.id }, projects: projects)
    }

    public static func prepare(_ input: ScheduleImport, directory: URL, project: ScheduleProject) throws -> ManagedJob {
        let snapshot = try source(input.sourceID, directory: directory)
        guard snapshot.digest == input.sourceDigest else { throw ScheduleControl.changed }
        let source = snapshot.definition
        guard input.recurring, input.projectID == project.id,
              source.paths.isEmpty || source.paths.contains(project.path),
              !source.rawRule.isEmpty, TimeZone(identifier: input.timeZone) != nil,
              !input.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.model.isEmpty || source.model == input.model,
              source.effort.isEmpty || source.effort == input.effort else { throw ScheduleControl.invalid }
        var job = ManagedJob()
        job.name = source.name; job.prompt = input.prompt ?? source.prompt
        job.projectID = project.id; job.model = input.model; job.effort = input.effort
        job.source = "codex:" + source.id
        job.schedule = JobSchedule(rule: source.rawRule, timeZone: input.timeZone)
        // The bounded parser rejects COUNT, UNTIL and yearly/one-time rules.
        guard try job.schedule.next(after: Date()) != nil else { throw JobSchedule.invalid }
        try job.validate()
        return job
    }
}
