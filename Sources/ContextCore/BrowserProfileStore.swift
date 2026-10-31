import Foundation
import CryptoKit
import Darwin
import AgentContract

public struct BrowserProfileGrant: Codable, Equatable, Sendable {
    public let environment: UUID
    public let generation: UUID
}

public struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, configuring, active, human, available }
    public let id: UUID
    public var name: String?
    public let project: String
    public let connection: AgentConnectionID
    public var owner: String?
    public var generation: UUID
    public var state: State
    public var grant: BrowserProfileGrant { .init(environment: id, generation: generation) }
}

public enum BrowserProfileError: Error, LocalizedError, CaseIterable, Equatable {
    case storage, busy, scope, released, uncertain, closeFirst, invalidName
    public var errorDescription: String? { message(language: L10n.language) }
    public func message(language: AppLanguage) -> String {
        switch self {
        case .storage: return L10n.text("Каталог профилей браузера недоступен или повреждён. Действие не подтверждено.", "The browser profile catalog is unavailable or damaged. The operation was not confirmed.", language: language)
        case .busy: return L10n.text("Профиль занят. Сначала освободи его в чате-владельце.", "The profile is in use. Release it in its owning chat first.", language: language)
        case .scope: return L10n.text("Этот профиль недоступен текущему проекту или подключению.", "This profile is unavailable to the current project or connection.", language: language)
        case .released: return L10n.text("Управление профилем передано. Выбери доступный профиль в меню браузера.", "Profile control was released. Select an available profile in the Browser menu.", language: language)
        case .uncertain: return L10n.text("Подключение профиля не подтверждено. Повтора нет. Закрой его Chrome и явно выбери профиль заново.", "Profile activation was not confirmed. It was not retried. Close its Chrome and explicitly select the profile again.", language: language)
        case .closeFirst: return L10n.text("Сначала закрой браузер через меню «Браузер». Для передачи профиля необходимо подтвердить завершение Chrome.", "Close the browser from the Browser menu first. Profile handoff requires confirmed Chrome exit.", language: language)
        case .invalidName: return L10n.text("Укажи название профиля от 1 до 80 символов.", "Enter a profile name from 1 to 80 characters.", language: language)
        }
    }
}

/// One atomic catalog is the routing authority. No cookies or website tokens are
/// stored here. Changes serialize with the executor's operation.lock; readers see
/// either complete revision. A lease is a routing boundary, not an OS sandbox.
public struct BrowserProfileStore: Sendable {
    public let root: URL
    public init(root: URL = BrowserEnvironmentStore.directory) { self.root = root.standardizedFileURL }
    private struct Catalog: Codable, Sendable {
        var schema = 1
        var profiles: [String: BrowserProfile] = [:]
        var bindings: [String: BrowserProfileGrant] = [:]
    }
    /// The browser monitor and every profile view re-read `profiles.json` (hundreds of KB). The parsed catalog is
    /// reused while the file's mtime and size are unchanged; `save` drops the entry, external writers change the stamp.
    private struct CatalogStamp: Equatable { var seconds: Int; var nanoseconds: Int; var size: Int }
    private static let catalogLock = NSLock()
    nonisolated(unsafe) private static var catalogCache: [String: (stamp: CatalogStamp, catalog: Catalog)] = [:]
    private static func stamp(_ info: stat) -> CatalogStamp {
        CatalogStamp(seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec), size: Int(info.st_size))
    }
    /// Views and the browser monitor hash every chat's session; memoizing keeps that off the hot render path.
    private static let keyLock = NSLock()
    nonisolated(unsafe) private static var keyCache: [[String]: String] = [:]
    public static func key(_ session: AgentSessionReference) -> String {
        let value = [session.connection.agent.rawValue, session.connection.id.uuidString.lowercased(), session.nativeID]
        if let cached = keyLock.withLock({ keyCache[value] }) { return cached }
        let data = try! JSONEncoder().encode(value)
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        keyLock.withLock { keyCache[value] = key }
        return key
    }
    public func environment(_ id: UUID) -> URL { root.appendingPathComponent("environments/" + id.uuidString.lowercased()) }
    private func canonical(_ project: String) throws -> String {
        guard project.hasPrefix("/"), !project.contains("\0") else { throw BrowserProfileError.scope }
        return URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private func read() throws -> Catalog {
        let path = root.appendingPathComponent("profiles.json")
        guard path.resolvingSymlinksInPath().path == path.path else { throw BrowserProfileError.storage }
        var info = stat()
        guard stat(path.path, &info) == 0 else {
            guard errno == ENOENT,
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles-required").path) else { throw BrowserProfileError.storage }
            return Catalog()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw BrowserProfileError.storage }
        let stamp = Self.stamp(info)
        if let cached = Self.catalogLock.withLock({ Self.catalogCache[path.path] }), cached.stamp == stamp { return cached.catalog }
        guard path.resolvingSymlinksInPath().path == path.path,
              let bytes = try? Data(contentsOf: path), bytes.count <= 8 * 1024 * 1024,
              let value = try? JSONDecoder().decode(Catalog.self, from: bytes), value.schema == 1,
              value.profiles.allSatisfy({ $0.key == $0.value.id.uuidString.lowercased() }),
              value.bindings.allSatisfy({ value.profiles[$0.value.environment.uuidString.lowercased()] != nil }) else { throw BrowserProfileError.storage }
        Self.catalogLock.withLock { Self.catalogCache[path.path] = (stamp, value) }
        return value
    }
    private func save(_ value: Catalog) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 8 * 1024 * 1024 else { throw BrowserProfileError.storage }
        let path = root.appendingPathComponent("profiles.json")
        let marker = root.appendingPathComponent("profiles-required")
        if !FileManager.default.fileExists(atPath: marker.path) { try Data("1\n".utf8).write(to: marker, options: .atomic) }
        Self.catalogLock.withLock { _ = Self.catalogCache.removeValue(forKey: path.path) }
        try bytes.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserProfileError.storage }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw BrowserProfileError.storage }
        let directory = open(root.path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw BrowserProfileError.storage }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw BrowserProfileError.storage }
    }
    private func change<T>(_ body: (inout Catalog, inout [BrowserProfileFileLock]) throws -> T) throws -> T {
        let lock = try BrowserProfileFileLock(directory: root, name: "profiles.lock")
        var held: [BrowserProfileFileLock] = []
        defer { held.forEach { $0.release() }; lock.release() }
        var catalog = try read()
        let result = try body(&catalog, &held)
        try save(catalog)
        return result
    }
    private func locks(_ ids: [UUID]) throws -> [BrowserProfileFileLock] {
        try Set(ids).sorted { $0.uuidString < $1.uuidString }.map {
            try BrowserProfileFileLock(directory: environment($0), name: "operation.lock")
        }
    }
    public func current(session: AgentSessionReference) throws -> BrowserProfile? {
        let catalog = try read()
        guard let binding = catalog.bindings[Self.key(session)] else { return nil }
        return catalog.profiles[binding.environment.uuidString.lowercased()]
    }
    public func profiles(project: String, connection: AgentConnectionID) throws -> [BrowserProfile] {
        let path = try canonical(project)
        return try read().profiles.values.filter { $0.name != nil && $0.project == path && $0.connection == connection }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }
    /// Session keys whose bound profile has a live Chrome for Testing, with that Chrome's PID.
    /// Read-only status for the UI: never launches, adopts or signals a process.
    public func runningBrowsers(executablePath: (Int32) -> String? = BrowserProfileStore.executablePath) -> [String: Int32] {
        guard let catalog = try? read() else { return [:] }
        let chromeRoot = root.appendingPathComponent("chrome-for-testing").path + "/"
        var result: [String: Int32] = [:]
        for (key, binding) in catalog.bindings {
            let record = environment(binding.environment).appendingPathComponent("testing-chrome-owner.json")
            // Most bound profiles have no live Chrome: one stat decides before any file is opened or an error is built.
            var info = stat()
            guard stat(record.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536,
                  let bytes = try? Data(contentsOf: record), bytes.count <= 65_536,
                  let owner = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let pid = (owner["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let executable = owner["executable"] as? String,
                  executable.hasPrefix(chromeRoot), executable.hasSuffix("/Contents/MacOS/Google Chrome for Testing"),
                  executablePath(pid) == executable else { continue }
            result[key] = pid
        }
        return result
    }
    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
    public func owns(_ profile: BrowserProfile, session: AgentSessionReference) -> Bool { profile.owner == Self.key(session) }

    /// Reserve before thread/start; no browser tool may dispatch before native acknowledgement.
    public func prepareNew(project: String, connection: AgentConnectionID, selection: AgentBrowserProfile? = nil,
                           verifyClosed: (URL) throws -> Void = { _ in throw BrowserProfileError.closeFirst }) throws -> BrowserProfileGrant {
        let path = try canonical(project)
        return try change { catalog, held in
            if let selection {
                let id = selection.id.uuidString.lowercased()
                guard var p = catalog.profiles[id], p.project == path, p.connection == connection, p.name != nil else { throw BrowserProfileError.scope }
                guard p.owner == nil, p.state == .available else { throw BrowserProfileError.busy }
                held += try locks([p.id])
                try verifyClosed(environment(p.id))
                p.generation = UUID(); p.state = .configuring
                catalog.profiles[id] = p
                return p.grant
            }
            let p = BrowserProfile(id: UUID(), project: path, connection: connection, owner: nil,
                                   generation: UUID(), state: .configuring)
            catalog.profiles[p.id.uuidString.lowercased()] = p
            return p.grant
        }
    }

    /// Only the original Codex connection can migrate the old native-ID namespace.
    /// A lost reconfiguration acknowledgement remains configuring and is never retried.
    public func prepare(session: AgentSessionReference, project: String) throws -> BrowserProfileGrant {
        let path = try canonical(project), key = Self.key(session)
        return try change { catalog, held in
            if let binding = catalog.bindings[key], var p = catalog.profiles[binding.environment.uuidString.lowercased()] {
                guard p.project == path, p.connection == session.connection else { throw BrowserProfileError.scope }
                guard p.owner == key, p.generation == binding.generation else { throw BrowserProfileError.released }
                guard p.state == .active || p.state == .pending else { throw p.state == .configuring ? BrowserProfileError.uncertain : BrowserProfileError.released }
                held += try locks([p.id])
                if p.state == .pending { p.state = .configuring; catalog.profiles[p.id.uuidString.lowercased()] = p }
                return p.grant
            }
            let legacy = session.connection == .originalCodex
                ? try BrowserEnvironmentStore.legacyEnvironment(session: session.nativeID, root: root) : nil
            let id = legacy ?? UUID()
            guard catalog.profiles[id.uuidString.lowercased()] == nil else { throw BrowserProfileError.storage }
            held += try locks([id])
            let p = BrowserProfile(id: id, project: path, connection: session.connection, owner: key,
                                   generation: UUID(), state: .configuring)
            catalog.profiles[id.uuidString.lowercased()] = p; catalog.bindings[key] = p.grant
            return p.grant
        }
    }
    public func acknowledge(_ grant: BrowserProfileGrant, session: AgentSessionReference) throws {
        try change { catalog, held in
            let id = grant.environment.uuidString.lowercased(), key = Self.key(session)
            guard var p = catalog.profiles[id], p.grant == grant, p.connection == session.connection,
                  p.state == .configuring || p.state == .active,
                  p.owner == nil || p.owner == key,
                  catalog.bindings[key] == nil || catalog.bindings[key] == grant else { throw BrowserProfileError.uncertain }
            held += try locks([p.id])
            p.owner = key; p.state = .active
            catalog.profiles[id] = p; catalog.bindings[key] = grant
        }
    }
    public func ownedGrant(session: AgentSessionReference, allowHuman: Bool = false) throws -> BrowserProfileGrant {
        let c = try read(), key = Self.key(session)
        guard let b = c.bindings[key], let p = c.profiles[b.environment.uuidString.lowercased()],
              p.owner == key, p.grant == b else { throw BrowserProfileError.released }
        guard p.state == .active || (allowHuman && p.state == .human) else { throw BrowserProfileError.released }
        return b
    }
    /// Called under operation.lock immediately before native control or cookie import.
    public func validate(_ grant: BrowserProfileGrant?, environment id: UUID, allowHuman: Bool = false) throws {
        guard let p = try read().profiles[id.uuidString.lowercased()] else {
            guard grant == nil else { throw BrowserProfileError.released }; return
        }
        guard p.grant == grant, p.state == .active || (allowHuman && p.state == .human) else { throw BrowserProfileError.released }
    }
    public func rename(session: AgentSessionReference, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BrowserProfileError.invalidName }
        try change { c, held in
            let key = Self.key(session)
            guard let b = c.bindings[key], var p = c.profiles[b.environment.uuidString.lowercased()], p.owner == key else { throw BrowserProfileError.released }
            p.name = name; c.profiles[p.id.uuidString.lowercased()] = p
        }
    }
    /// Transfer only closed profiles. Existing data stays in place; old clients
    /// retain obsolete generations and cannot use their still-connected MCP process.
    public func select(_ target: UUID?, session: AgentSessionReference, project: String,
                       verifyClosed: (URL) throws -> Void) throws {
        let path = try canonical(project), key = Self.key(session)
        try change { c, held in
            let old = c.bindings[key].flatMap { c.profiles[$0.environment.uuidString.lowercased()] }
            var next: BrowserProfile
            if let target {
                guard let p = c.profiles[target.uuidString.lowercased()], p.project == path,
                      p.connection == session.connection, p.name != nil else { throw BrowserProfileError.scope }
                guard p.owner == nil || p.owner == key else { throw BrowserProfileError.busy }
                next = p
            } else {
                next = BrowserProfile(id: UUID(), project: path, connection: session.connection, owner: nil,
                                      generation: UUID(), state: .available)
            }
            held += try locks([next.id] + (old.map { [$0.id] } ?? []))
            if let old, old.owner == key { try verifyClosed(environment(old.id)) }
            try verifyClosed(environment(next.id))
            if var old, old.owner == key, old.id != next.id {
                old.owner = nil; old.generation = UUID(); old.state = .available
                c.profiles[old.id.uuidString.lowercased()] = old
            }
            next.owner = key; next.generation = UUID(); next.state = .pending
            c.profiles[next.id.uuidString.lowercased()] = next; c.bindings[key] = next.grant
        }
    }
    public func release(session: AgentSessionReference, verifyClosed: (URL) throws -> Void) throws {
        try change { c, held in
            let key = Self.key(session)
            guard let b = c.bindings[key], var p = c.profiles[b.environment.uuidString.lowercased()], p.owner == key else { throw BrowserProfileError.released }
            held += try locks([p.id])
            try verifyClosed(environment(p.id))
            p.owner = nil; p.generation = UUID(); p.state = .available
            c.profiles[p.id.uuidString.lowercased()] = p
        }
    }
    public func humanControl(session: AgentSessionReference, take: Bool) throws {
        try change { c, held in
            let key = Self.key(session)
            guard let b = c.bindings[key], var p = c.profiles[b.environment.uuidString.lowercased()], p.owner == key,
                  p.grant == b, p.state == (take ? .active : .human) else { throw BrowserProfileError.released }
            held += try locks([p.id])
            guard !FileManager.default.fileExists(atPath: environment(p.id).appendingPathComponent("executor-in-flight.json").path) else { throw BrowserProfileError.uncertain }
            p.generation = UUID(); p.state = take ? .human : .pending
            c.profiles[p.id.uuidString.lowercased()] = p; c.bindings[key] = p.grant
        }
    }
}

/// Nonblocking, no-follow locks, shared with Python. Never replace a lock inode.
final class BrowserProfileFileLock {
    private var descriptor: Int32 = -1
    init(directory: URL, name: String) throws {
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw BrowserProfileError.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BrowserProfileError.storage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { release(); throw BrowserProfileError.busy }
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
