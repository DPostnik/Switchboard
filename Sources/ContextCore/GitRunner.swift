import Foundation

/// Runs read-mostly `git` commands for the app's own features (branch status, checkpoints, turn diffs).
/// Never prompts: no terminal, no askpass, no optional index locks, so it cannot block or race an agent's git.
/// Each call runs once; a timeout or launch failure is reported, never retried.
public struct GitRunner: Sendable {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: Data
        public var errors: String

        public var succeeded: Bool { status == 0 }
        public var text: String { String(decoding: output, as: UTF8.self) }
    }

    public enum Failure: Error, Equatable, Sendable {
        case launch(String)
        case timedOut
    }

    public var executable: String
    public var timeout: TimeInterval
    /// Extra environment, for example `GIT_INDEX_FILE` for a private index.
    public var environment: [String: String]

    public init(executable: String = "/usr/bin/git", timeout: TimeInterval = 10, environment: [String: String] = [:]) {
        self.executable = executable; self.timeout = timeout; self.environment = environment
    }

    /// `git -C directory arguments...`; `input` is written to stdin.
    public func run(_ arguments: [String], in directory: String, input: Data? = nil) async throws(Failure) -> Result {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["LC_ALL"] = "C"
        environment.merge(self.environment) { _, new in new }
        child.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        child.standardOutput = stdout; child.standardError = stderr
        child.standardInput = input == nil ? FileHandle.nullDevice : stdin
        // Both pipes drain concurrently so a large diff cannot fill one and stall git.
        let outputs = PipeCollector(stdout.fileHandleForReading), errors = PipeCollector(stderr.fileHandleForReading)
        do { try child.run() } catch { throw Failure.launch(error.localizedDescription) }
        if let input {
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global().async { try? writer.write(contentsOf: input); try? writer.close() }
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0.5))
        var expired = false
        while child.isRunning {
            if Date() > deadline || Task.isCancelled {
                expired = true; child.terminate()
                try? await Task.sleep(for: .milliseconds(200))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                break
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        // Not `waitUntilExit()`: on the main thread it waits for a run-loop callback that never comes while the
        // main queue is busy, and hung forever after the process had already exited.
        while child.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        if expired { throw Failure.timedOut }
        let data = await outputs.finish(), message = await errors.finish()
        return Result(status: child.terminationStatus, output: data,
                      errors: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var waiter: CheckedContinuation<Data, Never>?
    private var done = false

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            let all = handle.readDataToEndOfFile()
            lock.lock(); data = all; done = true
            let waiting = waiter; waiter = nil
            lock.unlock()
            waiting?.resume(returning: all)
        }
    }

    func finish() async -> Data {
        await withCheckedContinuation { continuation in
            lock.lock()
            if done { lock.unlock(); continuation.resume(returning: data) } else { waiter = continuation; lock.unlock() }
        }
    }
}
