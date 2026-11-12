import Foundation
import Darwin
import AgentContract

/// Quota suspension cleanup is separate from the scheduler's durable wait state.
/// It never creates a browser, adopts a legacy environment, or retries a close.
public enum ScheduledBrowserCleanup {
    public enum Outcome: Equatable, Sendable {
        case notNeeded
        case closed
        case failed(String)
    }

    public static func close(session: AgentSessionReference, runtime: URL,
                             root: URL = BrowserEnvironmentStore.directory) -> Outcome {
        do {
            // Keep ownership stable until chrome_host has checked the captured lease
            // under operation.lock and confirmed the recorded Chrome's exit.
            // The catalog lock is nonblocking; a busy browser is a cleanup error.
            guard FileManager.default.fileExists(atPath: root.path) else { return .notNeeded }
            let catalog = try BrowserProfileFileLock(directory: root, name: "profiles.lock")
            defer { catalog.release() }
            let store = BrowserProfileStore(root: root)
            guard let profile = try store.current(session: session) else { return .notNeeded }
            guard store.owns(profile, session: session), profile.state == .active else {
                // Human-owned and released profiles must never receive control requests.
                return .notNeeded
            }
            let grant = try store.ownedGrant(session: session)
            let environment = store.environment(grant.environment)
            guard FileManager.default.fileExists(atPath: environment.path) else { return .notNeeded }
            guard environment.resolvingSymlinksInPath().path == environment.path else {
                throw BrowserProfileError.storage
            }
            guard !FileManager.default.fileExists(atPath: environment.appendingPathComponent("executor-in-flight.json").path) else {
                throw BrowserProfileError.uncertain
            }
            let result = try run(environment: environment, runtime: runtime, grant: grant)
            guard result.running == false, result.error == nil else { throw BrowserProfileError.closeFirst }
            return .closed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func run(environment: URL, runtime: URL, grant: BrowserProfileGrant) throws -> BrowserProfileControl.Result {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", runtime.appendingPathComponent("chrome_host.py").path,
                             "--root", environment.path, "--language", L10n.language.rawValue,
                             "--profile-lease", grant.generation.uuidString.lowercased(), "--close"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Chrome's graceful close already has an eight-second confirmation window.
        // This outer bound also covers a stuck helper. Terminating that helper never
        // signals Chrome; its persisted close intent prevents an uncertain retry.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
            throw ClientFailure(L10n.text(
                "Завершение браузера не подтверждено вовремя. Автоматического повтора нет.",
                "Browser exit was not confirmed before the deadline. It will not be retried."))
        }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        guard bytes.count <= 32_768,
              let result = try? JSONDecoder().decode(BrowserProfileControl.Result.self, from: bytes) else {
            throw BrowserProfileError.storage
        }
        if let error = result.error { throw ClientFailure(error) }
        guard process.terminationStatus == 0 else { throw BrowserProfileError.storage }
        return result
    }
}
