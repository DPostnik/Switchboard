import Foundation
import CryptoKit

/// What the installer wrote for one agent, `<agents>/<id>/installed.json`.
public struct AgentInstallRecord: Codable, Hashable, Sendable {
    public enum Distribution: String, Codable, Sendable { case npx, binary }
    public enum Checksum: String, Codable, Sendable {
        /// The archive matched the registry's sha256.
        case verified
        /// The registry gave no sha256 for the archive.
        case unverified
        /// npm package (npm checks its own integrity data).
        case notApplicable
    }

    public var id: String
    public var name: String
    public var version: String
    public var distribution: Distribution
    /// npm spec (`@google/gemini-cli@0.66.0`) or archive URL.
    public var source: String
    /// Absolute path of the agent's executable inside `<agents>/<id>/<version>/`.
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var checksum: Checksum
    public var installedAt: Date
    /// `--version` printed the installed version (some agents print something else; the check only needs exit 0).
    public var versionConfirmed: Bool
}

/// Typed install failures; none of them is retried automatically.
public enum AgentInstallFailure: LocalizedError, Equatable, Sendable {
    case nodeNotFound
    case notInstallable(String)
    case versionUnavailable(String)
    case busy(String)
    case notInstalled(String)
    case download(String)
    case tooLarge
    case checksumMismatch
    case unsafeArchive(String)
    case extraction(String)
    case npm(String)
    case commandMissing(String)
    case versionCheck(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            L10n.text("Node.js не найден: нужен npm (/opt/homebrew/bin/npm или в PATH). Установи Node, например brew install node, и повтори.",
                      "Node.js was not found: npm is needed (/opt/homebrew/bin/npm or on PATH). Install Node, for example brew install node, and try again.")
        case .notInstallable(let name):
            L10n.text("\(name) нельзя установить на этот Mac из каталога.", "\(name) cannot be installed on this Mac from the catalog.")
        case .versionUnavailable(let version):
            L10n.text("Версия \(version) недоступна в каталоге.", "Version \(version) is not available in the catalog.")
        case .busy(let id): L10n.text("Установка \(id) уже идёт.", "\(id) is already being installed.")
        case .notInstalled(let id): L10n.text("\(id) не установлен из каталога.", "\(id) is not installed from the catalog.")
        case .download(let reason): L10n.text("Загрузка не удалась: \(reason)", "Download failed: \(reason)")
        case .tooLarge: L10n.text("Архив слишком большой.", "The archive is too large.")
        case .checksumMismatch:
            L10n.text("Контрольная сумма архива не совпала с каталогом; установка отменена.", "The archive's checksum does not match the catalog; installation refused.")
        case .unsafeArchive(let reason): L10n.text("Небезопасный архив: \(reason)", "Unsafe archive: \(reason)")
        case .extraction(let reason): L10n.text("Не удалось распаковать архив: \(reason)", "Could not extract the archive: \(reason)")
        case .npm(let reason): L10n.text("npm install не удался: \(reason)", "npm install failed: \(reason)")
        case .commandMissing(let path): L10n.text("После установки не найдена команда \(path).", "The command \(path) is missing after installation.")
        case .versionCheck(let reason):
            L10n.text("Новая версия не прошла проверку --version (\(reason)); прежняя оставлена.", "The new version failed its --version check (\(reason)); the previous one is kept.")
        case .storage(let reason): L10n.text("Не удалось записать установку: \(reason)", "Could not write the installation: \(reason)")
        }
    }
}

/// An installed agent whose catalog entry has a newer version.
public struct AgentCatalogUpdate: Hashable, Sendable {
    public let id: String
    public let installed: String
    public let available: String
}

/// Installs catalog agents into `<agents>/<id>/<version>/` only on the user's request.
///
/// `binary`: the current platform's archive is downloaded (size cap), its sha256 checked when the registry gives one
/// (a mismatch refuses the install; none is recorded as unverified), listed and extracted with the system `bsdtar`
/// (no absolute paths, no `..`, per-file size limit), then walked: symlinks must stay inside, no special files, total
/// size cap. `npx`: `npm install --ignore-scripts --no-audit --no-fund --prefix <staging> <package>@<version>` with the
/// app's own npm cache, never global. Everything is staged next to the final folder and renamed into place only after
/// `<command> --version` exits 0 (with a throwaway HOME); the previous version is kept until then and removed after the
/// record is written. A failure removes the staging and is reported once; nothing is retried.
public actor AgentCatalogInstaller {
    public static let recordName = "installed.json"
    public let directory: URL
    let session: URLSession
    let npmCandidates: [String]
    let inheritedEnvironment: [String: String]
    let limits: Limits
    let now: @Sendable () -> Date
    private var busy = Set<String>()

    public struct Limits: Sendable {
        public var download: Int64 = 1 << 30
        public var extracted: Int64 = 2 << 30
        public var files = 200_000
        public var npmTimeout: TimeInterval = 600
        public var versionTimeout: TimeInterval = 60
        public init() {}
    }

    public init(directory: URL = Locations.agentsHome, configuration: URLSessionConfiguration = .ephemeral, npmCandidates: [String]? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment, limits: Limits = Limits(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        self.npmCandidates = npmCandidates ?? (["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
            + (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/npm" })
        self.inheritedEnvironment = environment; self.limits = limits; self.now = now
    }

    // MARK: Records

    nonisolated public static func record(id: String, directory: URL) -> AgentInstallRecord? {
        guard AgentCatalogParser.isSafeID(id),
              let data = try? Data(contentsOf: directory.appendingPathComponent(id).appendingPathComponent(recordName)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentInstallRecord.self, from: data)
    }

    /// The installed executable of `id` when its record exists and points at an executable file inside its version
    /// folder (file checks only). Used by launch profiles to find catalog installs.
    nonisolated public static func installedCommand(id: String, directory: URL) -> URL? {
        guard let record = record(id: id, directory: directory) else { return nil }
        let versionFolder = directory.appendingPathComponent(id).appendingPathComponent(record.version).standardizedFileURL.path + "/"
        let command = URL(fileURLWithPath: record.command).standardizedFileURL
        guard command.path.hasPrefix(versionFolder), FileManager.default.isExecutableFile(atPath: command.path) else { return nil }
        return command
    }

    public func records() -> [AgentInstallRecord] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return ids.sorted().compactMap { Self.record(id: $0, directory: directory) }
    }

    public func isBusy(_ id: String) -> Bool { busy.contains(id) }

    /// Installed agents whose cached catalog entry is newer (no network).
    public func availableUpdates(catalog: AgentCatalog) -> [AgentCatalogUpdate] {
        records().compactMap { record in
            guard let entry = catalog.entry(record.id), AgentCatalogVersion.isNewer(entry.version, than: record.version) else { return nil }
            return AgentCatalogUpdate(id: record.id, installed: record.version, available: entry.version)
        }
    }

    // MARK: Install, update, remove

    /// Installs `entry` (or an npm `version` of it other than the catalog's), replacing a previous install only after
    /// the new one passes its check. `checkEnvironment` adds variables to the `--version` run.
    @discardableResult
    public func install(_ entry: AgentCatalogEntry, version requested: String? = nil,
                        checkEnvironment: [String: String] = [:]) async throws -> AgentInstallRecord {
        let id = entry.id
        guard AgentCatalogParser.isSafeID(id) else { throw AgentInstallFailure.notInstallable(entry.name) }
        guard let source = entry.installable else { throw AgentInstallFailure.notInstallable(entry.name) }
        let version = requested ?? entry.version
        guard AgentCatalogParser.isSafeVersion(version) else { throw AgentInstallFailure.versionUnavailable(version) }
        guard busy.insert(id).inserted else { throw AgentInstallFailure.busy(id) }
        defer { busy.remove(id) }

        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw AgentInstallFailure.storage(error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: staging) }

        let distribution: AgentInstallRecord.Distribution, spec: String, checksum: AgentInstallRecord.Checksum
        let relativeCommand: String, args: [String], env: [String: String]
        var npmDirectory: URL?
        switch source {
        case .binary(let binary):
            guard version == entry.version else { throw AgentInstallFailure.versionUnavailable(version) }
            checksum = try await installBinary(binary, into: staging, scratch: folder)
            distribution = .binary; spec = binary.archive.absoluteString
            relativeCommand = binary.cmd; args = binary.args; env = binary.env
        case .npx(let package):
            let npm = try findNPM()
            npmDirectory = npm.deletingLastPathComponent()
            spec = "\(package.package)@\(version)"
            try await runNPM(npm, spec: spec, prefix: staging)
            relativeCommand = try npmBinary(package: package.package, prefix: staging)
            distribution = .npx; checksum = .notApplicable; args = package.args; env = package.env
        }
        let stagedCommand = try command(relativeCommand, in: staging)
        let confirmed = try await checkVersion(stagedCommand, version: version, staging: staging, scratch: folder,
                                               extraPath: npmDirectory, environment: checkEnvironment)

        // Commit: the new folder takes the version's name (a same-version reinstall moves the old one aside first).
        let final = folder.appendingPathComponent(version, isDirectory: true)
        let aside = folder.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        let hadFinal = manager.fileExists(atPath: final.path)
        do {
            if hadFinal { try manager.moveItem(at: final, to: aside) }
            try manager.moveItem(at: staging, to: final)
        } catch {
            if hadFinal, !manager.fileExists(atPath: final.path) { try? manager.moveItem(at: aside, to: final) }
            throw AgentInstallFailure.storage(error.localizedDescription)
        }
        let commandPath = final.appendingPathComponent(String(stagedCommand.path.dropFirst(staging.path.count + 1))).path
        let record = AgentInstallRecord(id: id, name: entry.name, version: version, distribution: distribution, source: spec,
                                        command: commandPath, args: args, env: env, checksum: checksum, installedAt: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)),
                                        versionConfirmed: confirmed)
        do { try write(record, folder: folder) }
        catch {
            try? manager.removeItem(at: final)
            if hadFinal { try? manager.moveItem(at: aside, to: final) }
            throw AgentInstallFailure.storage(error.localizedDescription)
        }
        // Only now are older versions and the moved-aside copy removed.
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name != version && name != Self.recordName {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
        return record
    }

    /// Installs the catalog's version of an installed agent.
    @discardableResult
    public func update(_ id: String, catalog: AgentCatalog, checkEnvironment: [String: String] = [:]) async throws -> AgentInstallRecord {
        guard Self.record(id: id, directory: directory) != nil else { throw AgentInstallFailure.notInstalled(id) }
        guard let entry = catalog.entry(id) else { throw AgentInstallFailure.notInstallable(id) }
        return try await install(entry, checkEnvironment: checkEnvironment)
    }

    /// Removes the agent's folder (record first, so a partial removal never leaves a record pointing at missing files).
    public func remove(_ id: String) throws {
        guard AgentCatalogParser.isSafeID(id), Self.record(id: id, directory: directory) != nil else { throw AgentInstallFailure.notInstalled(id) }
        guard !busy.contains(id) else { throw AgentInstallFailure.busy(id) }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(Self.recordName))
            try FileManager.default.removeItem(at: folder)
        } catch { throw AgentInstallFailure.storage(error.localizedDescription) }
    }

    func write(_ record: AgentInstallRecord, folder: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent(Self.recordName), options: .atomic)
    }

    // MARK: Binary

    func installBinary(_ binary: AgentCatalogBinary, into staging: URL, scratch: URL) async throws -> AgentInstallRecord.Checksum {
        let download = scratch.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: download) }
        let digest = try await fetch(binary.archive, to: download)
        if let expected = binary.sha256, expected != digest { throw AgentInstallFailure.checksumMismatch }
        let name = binary.archive.lastPathComponent.lowercased()
        if [".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar"].contains(where: name.hasSuffix) {
            try await extract(download, into: staging)
            try validateTree(staging)
        } else {
            // A raw executable: stored under the command's own name.
            let target = staging.appendingPathComponent((binary.cmd as NSString).lastPathComponent)
            do {
                try FileManager.default.moveItem(at: download, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            } catch { throw AgentInstallFailure.storage(error.localizedDescription) }
        }
        return binary.sha256 == nil ? .unverified : .verified
    }

    /// Streams the archive to `file` with the size cap, returning its lowercase hex SHA-256.
    func fetch(_ url: URL, to file: URL) async throws -> String {
        guard url.scheme?.lowercased() == "https" else { throw AgentInstallFailure.download("not https") }
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(from: url) }
        catch { throw AgentInstallFailure.download(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentInstallFailure.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        if http.expectedContentLength > limits.download { throw AgentInstallFailure.tooLarge }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
            throw AgentInstallFailure.storage(file.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256(), buffer = Data(), total: Int64 = 0
        buffer.reserveCapacity(1 << 16)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    total += Int64(buffer.count)
                    if total > limits.download { throw AgentInstallFailure.tooLarge }
                    hasher.update(data: buffer); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                }
            }
            total += Int64(buffer.count)
            if total > limits.download { throw AgentInstallFailure.tooLarge }
            hasher.update(data: buffer); try handle.write(contentsOf: buffer)
        } catch let failure as AgentInstallFailure { throw failure }
        catch { throw AgentInstallFailure.download(error.localizedDescription) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lists the archive first (every member relative, without `..`), then extracts it with bsdtar, whose defaults also
    /// refuse `..` and absolute paths; `ulimit -f` caps each extracted file.
    func extract(_ archive: URL, into staging: URL) async throws {
        let listing = try await AgentCatalogProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path],
                                                        environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], directory: staging,
                                                        timeout: 120, scratch: staging.deletingLastPathComponent())
        guard listing.status == 0 else { throw AgentInstallFailure.extraction(listing.tail) }
        let members = listing.output.split(whereSeparator: \.isNewline)
        guard members.count <= limits.files else { throw AgentInstallFailure.unsafeArchive("too many files") }
        for member in members {
            let path = String(member)
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") { throw AgentInstallFailure.unsafeArchive(path) }
        }
        let blocks = String(max(limits.extracted / 512, 1))
        let result = try await AgentCatalogProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "ulimit -f \"$1\" && shift && exec /usr/bin/tar \"$@\"", "sh", blocks, "-xf", archive.path, "-C", staging.path, "-o"],
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], directory: staging, timeout: 600, scratch: staging.deletingLastPathComponent())
        guard result.status == 0 else { throw AgentInstallFailure.extraction(result.tail) }
    }

    /// Every entry stays inside `root`: symlinks resolve inside, no devices or pipes, total size and count capped.
    func validateTree(_ root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
            throw AgentInstallFailure.extraction("unreadable")
        }
        var total: Int64 = 0, count = 0
        for case let url as URL in walker {
            count += 1
            if count > limits.files { throw AgentInstallFailure.unsafeArchive("too many files") }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            let relative = String(url.path.dropFirst(root.path.count))
            if values?.isSymbolicLink == true {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path), !destination.hasPrefix("/") else {
                    throw AgentInstallFailure.unsafeArchive("link \(relative)")
                }
                let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination).standardizedFileURL.path
                guard resolved == base || resolved.hasPrefix(base + "/") else { throw AgentInstallFailure.unsafeArchive("link \(relative)") }
                continue
            }
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else { throw AgentInstallFailure.unsafeArchive("special file \(relative)") }
            total += Int64(values?.fileSize ?? 0)
            if total > limits.extracted { throw AgentInstallFailure.tooLarge }
        }
    }

    // MARK: npm

    func findNPM() throws -> URL {
        guard let path = npmCandidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AgentInstallFailure.nodeNotFound
        }
        return URL(fileURLWithPath: path)
    }

    func toolEnvironment(extraPath: URL?) -> [String: String] {
        // Inherited npm settings (a global prefix, `global=true`) are dropped; `~/.npmrc` (registry, proxy) still applies.
        var result = inheritedEnvironment.filter { !$0.key.lowercased().hasPrefix("npm_config_") }
        let path = [extraPath?.path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].compactMap { $0 }
        result["PATH"] = path.joined(separator: ":")
        result["npm_config_cache"] = directory.appendingPathComponent(".npm-cache").path
        result["npm_config_update_notifier"] = "false"
        result["npm_config_yes"] = "false"
        result["NO_COLOR"] = "1"
        return result
    }

    func runNPM(_ npm: URL, spec: String, prefix: URL) async throws {
        let arguments = ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--omit=dev", "--loglevel=error",
                         "--prefix", prefix.path, spec]
        let result: AgentCatalogProcess.Result
        do {
            result = try await AgentCatalogProcess.run(npm, arguments, environment: toolEnvironment(extraPath: npm.deletingLastPathComponent()),
                                                       directory: prefix, timeout: limits.npmTimeout, scratch: prefix.deletingLastPathComponent())
        } catch AgentCatalogProcess.Failure.timedOut { throw AgentInstallFailure.npm("timed out") }
        catch { throw AgentInstallFailure.npm(error.localizedDescription) }
        guard result.status == 0 else {
            if result.output.contains("env: node: No such file or directory") { throw AgentInstallFailure.nodeNotFound }
            throw AgentInstallFailure.npm(result.tail)
        }
    }

    /// `node_modules/.bin/<name>` from the package's `bin`: a string means the package's own name, a map with one entry
    /// that entry, otherwise the entry named like the package.
    func npmBinary(package: String, prefix: URL) throws -> String {
        let manifest = prefix.appendingPathComponent("node_modules").appendingPathComponent(package).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentInstallFailure.commandMissing("node_modules/\(package)/package.json")
        }
        let base = package.split(separator: "/").last.map(String.init) ?? package
        let name: String?
        if object["bin"] is String { name = base }
        else if let bins = object["bin"] as? [String: Any] {
            name = bins.count == 1 ? bins.keys.first : (bins[base] != nil ? base : bins.keys.sorted().first)
        } else { name = nil }
        guard let name, !name.contains("/"), !name.hasPrefix(".") else { throw AgentInstallFailure.commandMissing("bin of \(package)") }
        return "node_modules/.bin/\(name)"
    }

    // MARK: Check

    /// The command inside `root` (also after resolving links), made executable if an archive dropped the mode.
    func command(_ relative: String, in root: URL) throws -> URL {
        guard AgentCatalogParser.isSafeRelativePath(relative) else { throw AgentInstallFailure.commandMissing(relative) }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard resolved.path.hasPrefix(base), FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), !directory.boolValue else {
            throw AgentInstallFailure.commandMissing(relative)
        }
        if !FileManager.default.isExecutableFile(atPath: resolved.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolved.path)
        }
        return url
    }

    /// `<command> --version` in the staging folder with a throwaway HOME; must exit 0. Returns whether it printed `version`.
    func checkVersion(_ command: URL, version: String, staging: URL, scratch: URL, extraPath: URL?,
                      environment extra: [String: String]) async throws -> Bool {
        let home = scratch.appendingPathComponent(".check-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ["PATH": toolEnvironment(extraPath: extraPath)["PATH"] ?? "/usr/bin:/bin", "HOME": home.path,
                           "TMPDIR": home.path, "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
        environment.merge(extra.mapValues { $0.replacingOccurrences(of: "$CHECK_HOME", with: home.path) }) { _, new in new }
        let result: AgentCatalogProcess.Result
        do {
            result = try await AgentCatalogProcess.run(command, ["--version"], environment: environment, directory: staging,
                                                       timeout: limits.versionTimeout, scratch: scratch)
        } catch AgentCatalogProcess.Failure.timedOut { throw AgentInstallFailure.versionCheck("timed out") }
        catch { throw AgentInstallFailure.versionCheck(error.localizedDescription) }
        guard result.status == 0 else { throw AgentInstallFailure.versionCheck("exit \(result.status): \(result.tail)") }
        return result.output.contains(version)
    }
}

/// Runs a short-lived tool with a deadline, its output in a file (no pipe a surviving child could hold open).
enum AgentCatalogProcess {
    enum Failure: Error { case launch(String), timedOut }
    struct Result {
        let status: Int32
        let output: String
        /// The last lines, for error messages.
        var tail: String {
            output.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(400).description
        }
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], directory: URL,
                    timeout: TimeInterval, scratch: URL) async throws -> Result {
        let log = scratch.appendingPathComponent(".log-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: log.path, contents: nil), let handle = try? FileHandle(forWritingTo: log) else {
            throw Failure.launch(log.path)
        }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let child = Process()
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        child.currentDirectoryURL = directory
        child.standardInput = FileHandle.nullDevice; child.standardOutput = handle; child.standardError = handle
        do { try child.run() } catch { throw Failure.launch(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        var expired = false
        while child.isRunning {
            if Date() > deadline || Task.isCancelled {
                expired = true; child.terminate()
                try? await Task.sleep(for: .milliseconds(500))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        while child.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        if expired { throw Failure.timedOut }
        let data = (try? Data(contentsOf: log)) ?? Data()
        return Result(status: child.terminationStatus, output: String(decoding: data.suffix(256 * 1024), as: UTF8.self))
    }
}
