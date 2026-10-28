import Foundation

/// The user's own Telegram notifier (`telegram-agent-notifier/notifier.py`): a local outbox that a launchd worker
/// sends to the user's private bot chat, and an inbox of the user's Reply answers. Switchboard only calls its
/// command line; it never sees the bot token. Questions carry `sb-` keys, so only Switchboard claims their replies.
public struct TelegramNotifier: Sendable {
    public static let keyPrefix = "sb-"
    public static let defaultScript = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Public/self-projects/telegram-agent-notifier/notifier.py").path
    public static let questionLimit = 2400

    public var script: String
    public var python: String

    public init(script: String = Self.defaultScript, python: String = "/opt/homebrew/bin/python3") {
        self.script = script; self.python = python
    }

    public struct Reply: Decodable, Equatable, Sendable {
        public let id: Int
        public let key: String
        public let thread: String
        public let text: String
        enum CodingKeys: String, CodingKey { case id = "update_id", key = "event_key", thread, text }
        public init(id: Int, key: String, thread: String, text: String) { self.id = id; self.key = key; self.thread = thread; self.text = text }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    public func isConfigured() async -> Bool {
        guard let output = try? await run(["status"]),
              let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return false }
        return object["configured"] as? Bool == true
    }

    /// Records a question once per key; the worker sends it. Repeating a key does nothing.
    public func enqueue(key: String, job: String, thread: String, question: String) async throws {
        _ = try await run(["enqueue", "--key", key, "--job", String(job.prefix(200)), "--thread", thread],
                          input: String(question.prefix(Self.questionLimit)))
    }

    /// Cancels a question that is no longer waiting; an unsent one is never delivered.
    public func resolve(key: String) async throws { _ = try await run(["resolve", "--key", key]) }

    /// Takes one reply to a Switchboard question; it stays claimed until acknowledged.
    public func claimReply() async throws -> Reply? {
        let output = try await run(["claim-reply", "--key-prefix", Self.keyPrefix]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output != "null" else { return nil }
        return try JSONDecoder().decode(Reply.self, from: Data(output.utf8))
    }

    /// `forwarded` after the reply is safely in the chat; otherwise `uncertain`, which stops any repeat.
    public func acknowledge(_ id: Int, forwarded: Bool) async throws {
        _ = try await run(["ack-reply", "--id", String(id), "--result", forwarded ? "forwarded" : "uncertain"])
    }

    func run(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 20) async throws -> String {
        guard FileManager.default.isReadableFile(atPath: script), FileManager.default.isExecutableFile(atPath: python) else {
            throw Failure(errorDescription: L10n.text("Уведомитель Telegram не найден: \(script)", "Telegram notifier not found: \(script)"))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-telegram-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputFile = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output"), errors = folder.appendingPathComponent("errors")
        try Data((input ?? "").utf8).write(to: inputFile)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        // `-I` keeps the notifier's folder and the environment out of Python's import path.
        child.arguments = ["-I", script] + arguments
        child.currentDirectoryURL = URL(fileURLWithPath: script).deletingLastPathComponent()
        let stdin = try FileHandle(forReadingFrom: inputFile), stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning {
            if Date() > deadline {
                child.terminate()
                throw Failure(errorDescription: L10n.text("Уведомитель Telegram не ответил вовремя; результат не подтверждён.", "The Telegram notifier did not answer in time; the outcome is unconfirmed."))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        guard child.terminationStatus == 0 else {
            let reason = ((try? String(contentsOf: errors, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init) ?? ""
            throw Failure(errorDescription: L10n.text("Уведомитель Telegram завершился с ошибкой: \(reason)", "The Telegram notifier failed: \(reason)"))
        }
        return text
    }
}

/// Which waiting chats go to Telegram and which sent questions are withdrawn. A wait is sent once it lasted
/// `delay` (the user may still be at the Mac); a sent one is resolved as soon as it stops waiting.
public enum TelegramAlerts {
    public struct Waiting: Equatable, Sendable {
        public let key: String
        public let chatID: String
        public let job: String
        public let question: String
        public init(key: String, chatID: String, job: String, question: String) {
            self.key = key; self.chatID = chatID; self.job = job; self.question = question
        }
    }

    public static func plan(waiting: [Waiting], firstSeen: [String: Date], sent: Set<String>, now: Date, delay: TimeInterval)
        -> (send: [Waiting], resolve: [String]) {
        let current = Set(waiting.map(\.key))
        let send = waiting.filter { !sent.contains($0.key) && now.timeIntervalSince(firstSeen[$0.key] ?? now) >= delay }
        return (send, sent.subtracting(current).sorted())
    }

    /// A notifier key: `sb-`, the chat and the wait, limited to the characters and length it accepts.
    public static func key(chatID: String, wait: String) -> String {
        let raw = TelegramNotifier.keyPrefix + chatID + "-" + wait
        return String(String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" ? Character($0) : "-" }).prefix(200))
    }
}
