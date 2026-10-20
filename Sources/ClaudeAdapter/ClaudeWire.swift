import Foundation
import Darwin
import ContextCore

/// Ordered, bounded JSONL transport. A dropped/invalid frame closes the stream; no request is replayed.
actor ClaudeWire {
    nonisolated let frames: AsyncStream<JSONValue>
    private let sink: AsyncStream<JSONValue>.Continuation
    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var ended = false
    /// Chat label of the launched process; its leftovers are swept when the stream closes.
    private var chatLabel: String?
    init() { let stream = AsyncStream<JSONValue>.makeStream(); frames = stream.stream; sink = stream.continuation }
    func start(executable: URL, arguments: [String], environment: [String: String], cwd: URL) throws {
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        child.currentDirectoryURL = cwd; child.standardInput = input; child.standardOutput = output; child.standardError = errors
        let chunks = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { chunks.continuation.finish() } else { chunks.continuation.yield(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let label = environment[ProcessLabels.chatKey]
        if let label { ProcessSweeper.shared.begin(chat: label) }
        do { try child.run() } catch {
            if let label { ProcessSweeper.shared.end(chat: label) }
            output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil; throw error
        }
        chatLabel = label
        process = child; stdin = input; stdout = output; stderr = errors
        reader = Task { [weak self] in
            for await data in chunks.stream { await self?.ingest(data) }
            await self?.closed()
        }
    }
    func send(_ value: JSONValue) throws {
        guard !ended, process?.isRunning == true, let input = stdin else { throw Self.closedError }
        var bytes = try JSONEncoder().encode(value); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func control(_ request: JSONValue) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.object(["type": .string("control_request"), "request_id": .string(id), "request": request]))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15)); await self?.timeout(id)
                }
            } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }
    private func timeout(_ id: String) { if pending[id] != nil { close() } }
    private func ingest(_ data: Data) {
        guard !ended else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard line.count <= 4 * 1024 * 1024 else { close(); return }
            if line.isEmpty { continue }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else { close(); return }
            if value["type"].string == "control_response", let id = value["response"]["request_id"].string,
               let continuation = pending.removeValue(forKey: id) {
                if value["response"]["subtype"].string == "success" { continuation.resume(returning: value["response"]["response"]) }
                else { continuation.resume(throwing: Self.closedError) }
            } else { sink.yield(value) }
        }
        if buffer.count > 4 * 1024 * 1024 { close() }
    }
    func close() {
        if let process, process.isRunning {
            process.terminate()
            Task { try? await Task.sleep(for: .seconds(1)); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        closed()
    }
    private func closed() {
        guard !ended else { return }; ended = true
        for continuation in pending.values { continuation.resume(throwing: Self.closedError) }; pending.removeAll()
        stdout?.fileHandleForReading.readabilityHandler = nil; stderr?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.fileHandleForWriting.close()
        sink.yield(.object(["type": .string("transport_closed")])); sink.finish()
        if let chatLabel { ProcessSweeper.shared.end(chat: chatLabel); self.chatLabel = nil }
    }
    private static var closedError: ClientFailure {
        ClientFailure(L10n.text("Соединение Claude закрыто. Запрос не повторён.", "Claude connection closed. The request was not retried."))
    }
}

enum ClaudeProfile {
    static func environment(home: URL) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] { result[key] = ProcessInfo.processInfo.environment[key] }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        result["CLAUDE_CONFIG_DIR"] = home.path; result["DISABLE_AUTOUPDATER"] = "1"
        // Instance label for the orphan sweeper; chat launches add the chat label on top.
        result.merge(ProcessLabels.environment()) { _, new in new }
        return result
    }
    /// The profile's CLAUDE.md with the user's global rules (often a symlink to ~/.claude/CLAUDE.md).
    static func instructions(home: URL, language: AppLanguage = L10n.language) -> String? {
        let file = home.appendingPathComponent("CLAUDE.md").resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 64 * 1024, let data = try? Data(contentsOf: file) else { return nil }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return L10n.text("Глобальные инструкции пользователя (CLAUDE.md):", "User's global instructions (CLAUDE.md):", language: language)
            + "\n\n" + body
    }
    /// The `attribution` object of the profile's settings.json (e.g. empty strings to drop Co-Authored-By).
    static func attribution(home: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("settings.json")), data.count <= 1_048_576,
              let settings = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let attribution) = settings["attribution"] else { return nil }
        let kept = attribution.filter { ["commit", "pr"].contains($0.key) && $0.value.string != nil }
        return kept.isEmpty ? nil : .object(kept)
    }
    static func command(executable: URL, home: URL, arguments: [String]) async throws -> (Int32, Data) {
        let folder = home.appendingPathComponent("probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        child.environment = environment(home: home); child.currentDirectoryURL = home
        child.standardInput = FileHandle.nullDevice; child.standardOutput = handle; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); kill(child.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(15)
        while child.isRunning {
            if Task.isCancelled || Date() > deadline || ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_048_576 {
                child.terminate(); try? await Task.sleep(for: .milliseconds(200))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }; throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return (child.terminationStatus, try Data(contentsOf: output))
    }
}
