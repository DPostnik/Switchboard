import Foundation
import AgentContract

/// Native control uses a captured lease, checked under the runtime operation lock.
public enum BrowserProfileControl {
    public struct Result: Decodable, Sendable {
        public let running: Bool?
        public let pid: Int32?
        /// Set by `--close-if-idle` when a tab with an address kept Chrome running.
        public let kept: Bool?
        public let error: String?
    }
    public static func status(environment: URL, runtime: URL, grant: BrowserProfileGrant?, close: Bool = false) throws -> Result {
        try run(environment: environment, runtime: runtime,
                arguments: (close ? ["--close"] : []) + (grant.map { ["--profile-lease", $0.generation.uuidString.lowercased()] } ?? []))
    }
    /// Caller holds the catalog and operation locks. This performs no mutation.
    public static func verifyClosed(environment: URL, runtime: URL) throws {
        let result = try run(environment: environment, runtime: runtime, arguments: ["--profile-idle"])
        guard result.running == false, result.error == nil else { throw BrowserProfileError.closeFirst }
    }
    private static func run(environment: URL, runtime: URL, arguments: [String]) throws -> Result {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", runtime.appendingPathComponent("chrome_host.py").path, "--root", environment.path,
                             "--language", L10n.language.rawValue] + arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard bytes.count <= 32_768, let result = try? JSONDecoder().decode(Result.self, from: bytes) else { throw BrowserProfileError.storage }
        if let error = result.error { throw ClientFailure(error) }
        guard process.terminationStatus == 0 else { throw BrowserProfileError.storage }
        return result
    }
}
