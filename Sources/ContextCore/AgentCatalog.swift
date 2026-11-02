import Foundation

/// The ACP agent registry (`cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, format in the registry's
/// `FORMAT.md` and `agent.schema.json`): agents with an `npx` package or per-platform `binary` archives.
///
/// The registry is third-party data. Parsing is lenient: unknown fields and distribution types are ignored and counted
/// by name; an entry that fails validation is skipped and counted, never the whole catalog. Values that end up in paths
/// or commands (`id`, `version`, `cmd`, the npm package) are validated here so the installer never sees unsafe ones.
public struct AgentCatalog: Codable, Hashable, Sendable {
    /// The document's own `version` (format version, "1.0.0").
    public var formatVersion: String?
    public var entries: [AgentCatalogEntry]
    /// Entries dropped because a required field was missing or unsafe.
    public var skippedEntries: Int
    /// Unknown fields and distribution types by name (`agent.<field>`, `distribution.<type>`, `binary.<field>`), with counts.
    public var unknownFields: [String: Int]

    public init(formatVersion: String? = nil, entries: [AgentCatalogEntry], skippedEntries: Int = 0, unknownFields: [String: Int] = [:]) {
        self.formatVersion = formatVersion; self.entries = entries; self.skippedEntries = skippedEntries; self.unknownFields = unknownFields
    }

    public func entry(_ id: String) -> AgentCatalogEntry? { entries.first { $0.id == id } }

    /// The registry's platform key for this Mac (`darwin-aarch64` or `darwin-x86_64`).
    public static var currentPlatform: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #else
        return "darwin-x86_64"
        #endif
    }
}

public struct AgentCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var icon: String?
    public var repository: String?
    public var website: String?
    public var license: String?
    public var distribution: AgentCatalogDistribution

    public init(id: String, name: String, version: String, description: String? = nil, icon: String? = nil, repository: String? = nil,
                website: String? = nil, license: String? = nil, distribution: AgentCatalogDistribution) {
        self.id = id; self.name = name; self.version = version; self.description = description; self.icon = icon
        self.repository = repository; self.website = website; self.license = license; self.distribution = distribution
    }

    /// The distribution this client installs on this Mac: a binary for the current platform first (no Node needed), else npx.
    public var installable: AgentCatalogInstallSource? {
        if let binary = distribution.binary[AgentCatalog.currentPlatform] { return .binary(binary) }
        if let npx = distribution.npx { return .npx(npx) }
        return nil
    }
}

public enum AgentCatalogInstallSource: Hashable, Sendable {
    case npx(AgentCatalogPackage)
    case binary(AgentCatalogBinary)
}

public struct AgentCatalogDistribution: Codable, Hashable, Sendable {
    public var npx: AgentCatalogPackage?
    /// Platform key (`darwin-aarch64`, ...) -> archive.
    public var binary: [String: AgentCatalogBinary]
    /// Distribution types this client does not install (`uvx` and unknown ones), by name.
    public var unsupported: [String]

    public init(npx: AgentCatalogPackage? = nil, binary: [String: AgentCatalogBinary] = [:], unsupported: [String] = []) {
        self.npx = npx; self.binary = binary; self.unsupported = unsupported
    }
}

/// An npm package: `package` is the name alone; `version` is the version the registry spec pins (`@google/gemini-cli@0.66.0`).
public struct AgentCatalogPackage: Codable, Hashable, Sendable {
    public var package: String
    public var version: String?
    public var args: [String]
    public var env: [String: String]

    public init(package: String, version: String? = nil, args: [String] = [], env: [String: String] = [:]) {
        self.package = package; self.version = version; self.args = args; self.env = env
    }

    /// Splits `name@version` (a scoped name keeps its leading `@`); nil when the name or version is not safe to pass to npm.
    public static func split(_ spec: String) -> (name: String, version: String?)? {
        var name = spec, version: String?
        if let at = spec.lastIndex(of: "@"), at != spec.startIndex {
            name = String(spec[..<at]); version = String(spec[spec.index(after: at)...])
        }
        guard isPackageName(name) else { return nil }
        if let version, !AgentCatalogParser.isSafeVersion(version) { return nil }
        return (name, version)
    }

    /// npm names: optional `@scope/`, then lowercase letters, digits and `-._~`; never an option, a path or a URL.
    static func isPackageName(_ name: String) -> Bool {
        let parts = name.hasPrefix("@") ? name.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init) : [name]
        guard (1...2).contains(parts.count), name.hasPrefix("@") == (parts.count == 2), name.count <= 214 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first != ".", first != "_", first != "-" else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-._~".contains($0)) }
        }
    }
}

public struct AgentCatalogBinary: Codable, Hashable, Sendable {
    public var archive: URL
    /// Lowercase hex SHA-256 of the archive; nil when the registry gives none (installed as "unverified checksum").
    public var sha256: String?
    /// Executable relative to the extracted archive (`./goose`).
    public var cmd: String
    public var args: [String]
    public var env: [String: String]

    public init(archive: URL, sha256: String? = nil, cmd: String, args: [String] = [], env: [String: String] = [:]) {
        self.archive = archive; self.sha256 = sha256; self.cmd = cmd; self.args = args; self.env = env
    }
}

public enum AgentCatalogParser {
    public enum Failure: Error, Equatable { case notACatalog }

    static let documentFields: Set<String> = ["version", "agents", "extensions"]
    static let entryFields: Set<String> = ["id", "name", "version", "description", "repository", "website", "authors", "license",
                                           "license_url", "icon", "distribution"]
    static let packageFields: Set<String> = ["package", "args", "env"]
    static let binaryFields: Set<String> = ["archive", "sha256", "cmd", "args", "env"]
    /// Known types this client does not install.
    static let knownUnsupported: Set<String> = ["uvx"]

    /// Throws only when the document is not a JSON object with an `agents` array.
    public static func parse(_ data: Data) throws -> AgentCatalog {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let agents = object["agents"] as? [Any] else {
            throw Failure.notACatalog
        }
        var unknown: [String: Int] = [:]
        for key in object.keys where !documentFields.contains(key) { unknown["document.\(key)", default: 0] += 1 }
        var entries: [AgentCatalogEntry] = [], skipped = 0, seen = Set<String>()
        for item in agents {
            guard let raw = item as? [String: Any], let entry = parseEntry(raw, unknown: &unknown), seen.insert(entry.id).inserted else {
                skipped += 1; continue
            }
            entries.append(entry)
        }
        return AgentCatalog(formatVersion: object["version"] as? String, entries: entries, skippedEntries: skipped, unknownFields: unknown)
    }

    static func parseEntry(_ raw: [String: Any], unknown: inout [String: Int]) -> AgentCatalogEntry? {
        guard let id = raw["id"] as? String, isSafeID(id), let version = raw["version"] as? String, isSafeVersion(version),
              let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let distribution = raw["distribution"] as? [String: Any] else { return nil }
        var local: [String: Int] = [:]
        for key in raw.keys where !entryFields.contains(key) { local["agent.\(key)", default: 0] += 1 }
        var result = AgentCatalogDistribution()
        for (type, value) in distribution.sorted(by: { $0.key < $1.key }) {
            switch type {
            case "npx":
                guard let package = parsePackage(value, unknown: &local) else { return nil }
                result.npx = package
            case "binary":
                guard let targets = value as? [String: Any] else { return nil }
                for (platform, target) in targets {
                    // A malformed target for another platform does not cost the entry its usable ones.
                    if let binary = parseBinary(target, unknown: &local) { result.binary[platform] = binary }
                    else { local["binary.invalid", default: 0] += 1 }
                }
            default:
                result.unsupported.append(type)
                if !knownUnsupported.contains(type) { local["distribution.\(type)", default: 0] += 1 }
            }
        }
        guard result.npx != nil || !result.binary.isEmpty || !result.unsupported.isEmpty else { return nil }
        unknown.merge(local, uniquingKeysWith: +)
        return AgentCatalogEntry(id: id, name: name, version: version, description: raw["description"] as? String,
                                 icon: (raw["icon"] as? String).flatMap(httpsURL)?.absoluteString,
                                 repository: (raw["repository"] as? String).flatMap(httpsURL)?.absoluteString,
                                 website: (raw["website"] as? String).flatMap(httpsURL)?.absoluteString,
                                 license: raw["license"] as? String, distribution: result)
    }

    static func parsePackage(_ value: Any, unknown: inout [String: Int]) -> AgentCatalogPackage? {
        guard let raw = value as? [String: Any], let spec = raw["package"] as? String, let parts = AgentCatalogPackage.split(spec) else { return nil }
        for key in raw.keys where !packageFields.contains(key) { unknown["npx.\(key)", default: 0] += 1 }
        return AgentCatalogPackage(package: parts.name, version: parts.version, args: strings(raw["args"]), env: environment(raw["env"]))
    }

    static func parseBinary(_ value: Any, unknown: inout [String: Int]) -> AgentCatalogBinary? {
        guard let raw = value as? [String: Any], let archive = (raw["archive"] as? String).flatMap(httpsURL),
              let cmd = raw["cmd"] as? String, isSafeRelativePath(cmd) else { return nil }
        var digest: String?
        if let sha = raw["sha256"] {
            // A digest that is present but malformed is not "absent": the target is unusable.
            guard let text = sha as? String, text.count == 64, text.allSatisfy(\.isHexDigit) else { return nil }
            digest = text.lowercased()
        }
        for key in raw.keys where !binaryFields.contains(key) { unknown["binary.\(key)", default: 0] += 1 }
        return AgentCatalogBinary(archive: archive, sha256: digest, cmd: cmd, args: strings(raw["args"]), env: environment(raw["env"]))
    }

    static func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
    /// Environment from the registry; names must be plain identifiers.
    static func environment(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        return raw.reduce(into: [:]) { result, item in
            guard let text = item.value as? String, let first = item.key.first, first.isLetter || first == "_",
                  item.key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return }
            result[item.key] = text
        }
    }
    static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Registry ids become folder names: lowercase letters, digits, `-`, `_`, `.`; no leading dot.
    public static func isSafeID(_ id: String) -> Bool {
        guard let first = id.first, first.isASCII, first.isLowercase || first.isNumber, id.count <= 64 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-_.".contains($0)) }
    }
    /// Versions become folder names and npm specs: letters, digits, `.`, `-`, `+`; starts with a digit.
    public static func isSafeVersion(_ version: String) -> Bool {
        guard let first = version.first, first.isASCII, first.isNumber, version.count <= 64, !version.contains("..") else { return false }
        return version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) }
    }
    /// A path inside the extracted archive: relative, no `..` components, no empty name.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.isEmpty && !parts.contains("..") && parts.contains { $0 != "." }
    }
}

/// Version order for update checks: numeric `major.minor.patch` (missing parts count as 0), a prerelease ranks below
/// its release. Versions that are not numeric compare as different but never as newer.
public enum AgentCatalogVersion {
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let a = parts(candidate), let b = parts(installed) else { return false }
        if a.numbers != b.numbers {
            for (x, y) in zip(a.numbers, b.numbers) where x != y { return x > y }
            return false
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, .some): return true
        case let (.some(x), .some(y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }
    static func parts(_ version: String) -> (numbers: [Int], prerelease: String?)? {
        let core = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
        let split = core.split(separator: "-", maxSplits: 1).map(String.init)
        guard let head = split.first else { return nil }
        var numbers = head.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        while numbers.count < 3 { numbers.append(0) }
        return (numbers.compactMap { $0 }, split.count > 1 ? split[1] : nil)
    }
}
