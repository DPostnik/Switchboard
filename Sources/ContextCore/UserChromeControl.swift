import Foundation
import CryptoKit
import AgentContract

/// App-side authority for the regular-Chrome extension. Never exports the control secret to an agent.
public actor UserChromeControl {
    public static let shared = UserChromeControl()
    public static let extensionID = "hbhjeiejjmgpjhmmjifnpkdoeehojkmj"
    public static let hostName = "local.daniil.switchboard.browser"
    public static var directory: URL { Locations.root.appendingPathComponent("user-chrome") }
    public static var extensionDirectory: URL { directory.appendingPathComponent("extension") }
    private var coordinator: Process?

    public struct Profile: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String?
        public let connected: Bool
        public let paired: Bool
    }
    public struct Status: Decodable, Sendable {
        public let profiles: [Profile]
        public let enabled: Bool
        public let selectedProfileId: String?
    }

    public func install(resources: URL) async throws {
        if FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("runtime/server.py").path),
           (try? await command(["status"])) != nil {
            _ = try await command(["shutdown-if-idle"], control: true)
            var stopped = false
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if (try? await command(["status"])) == nil { stopped = true; break }
            }
            guard stopped else { throw failure("Помощник ещё завершает работу. Обновление не выполнено.", "The helper is still stopping. The update was not applied.") }
            coordinator = nil
        }
        let fm = FileManager.default, root = Self.directory
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (source, target) in [("UserChromeRuntime", "runtime"), ("UserChromeExtension", "extension")] {
            let from = resources.appendingPathComponent(source), to = root.appendingPathComponent(target)
            guard fm.fileExists(atPath: from.path) else { throw failure("Компонент расширения отсутствует в сборке.", "The extension component is missing from this build.") }
            let stage = root.appendingPathComponent(target + ".install-" + UUID().uuidString)
            try fm.copyItem(at: from, to: stage)
            if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: stage) }
            else { try fm.moveItem(at: stage, to: to) }
        }
        let token = root.appendingPathComponent("control-token")
        if !fm.fileExists(atPath: token.path) {
            try Data((UUID().uuidString + UUID().uuidString).utf8).write(to: token, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launcher = root.appendingPathComponent("native-host")
        let args = ["/usr/bin/python3", "-B", root.appendingPathComponent("runtime/server.py").path,
                    "native", "--state-dir", root.path, "--extension-id", Self.extensionID]
        try Data(("#!/bin/sh\nexec " + args.map(quoted).joined(separator: " ") + " \"$@\"\n").utf8).write(to: launcher, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let hosts = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": Self.hostName, "description": "Switchboard Browser", "path": launcher.path,
                                       "type": "stdio", "allowed_origins": ["chrome-extension://" + Self.extensionID + "/"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: hosts.appendingPathComponent(Self.hostName + ".json"), options: .atomic)
    }

    public func status() async throws -> Status {
        try await ensureStarted()
        return try JSONDecoder().decode(Status.self, from: await command(["status"]))
    }
    public func selectProfile(_ id: String) async throws {
        try await ensureStarted()
        _ = try await command(["select-profile", "--profile-id", id], control: true)
    }
    public func pair(profile: String, code: String) async throws {
        try await ensureStarted()
        _ = try await command(["pair", "--profile-id", profile, "--code", code], control: true)
    }
    public func setEnabled(_ enabled: Bool) async throws {
        guard FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("control-token").path) else { return }
        try await ensureStarted()
        _ = try await command(["set-enabled", "--enabled", enabled ? "true" : "false"], control: true)
    }
    public func revoke(chat: String) async throws {
        guard FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("control-token").path) else { return }
        try await ensureStarted()
        _ = try await command(["revoke", "--chat-id", chat], control: true)
    }

    public func grant(chat: String, projectRoot: String, allowed: Bool) async throws -> AgentUserChromeGrant? {
        guard FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("control-token").path) else { return nil }
        guard allowed else { try await revoke(chat: chat); return nil }
        let current = try await status()
        guard current.enabled, let profileID = current.selectedProfileId,
              current.profiles.contains(where: { $0.id == profileID && $0.paired }) else { return nil }
        struct Grant: Decodable { let capability: String; let profileId: String; let chatId: String }
        let result = try JSONDecoder().decode(Grant.self, from: await command(
            ["grant", "--chat-id", chat, "--profile-id", profileID, "--project-root", projectRoot, "--ttl", "3600"], control: true))
        guard result.chatId == chat, result.profileId == profileID else { throw failure("Получен неверный доступ к Chrome.", "Invalid Chrome grant received.") }
        let grants = Self.directory.appendingPathComponent("client-grants")
        try FileManager.default.createDirectory(at: grants, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data(result.capability.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = grants.appendingPathComponent(digest + ".token")
        try Data(result.capability.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return AgentUserChromeGrant(chatID: chat, profileID: profileID, stateDirectory: Self.directory, capabilityFile: file)
    }

    private func ensureStarted() async throws {
        let script = Self.directory.appendingPathComponent("runtime/server.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw failure("Сначала установи расширение в настройках браузера.", "Install the extension in browser settings first.") }
        if (try? await command(["status"])) != nil { return }
        if coordinator?.isRunning == true { throw failure("Соединение с расширением ещё не готово.", "The extension connection is not ready yet.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", script.path, "serve", "--state-dir", Self.directory.path, "--extension-id", Self.extensionID]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); coordinator = process
        // Only establish the channel. No browser action is retried.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if (try? await command(["status"])) != nil { return }
            guard process.isRunning else { break }
        }
        throw failure("Не удалось запустить соединение с расширением.", "Could not start the extension connection.")
    }
    private func command(_ arguments: [String], control: Bool = false) async throws -> Data {
        let root = Self.directory
        let args = ["-B", root.appendingPathComponent("runtime/server.py").path] + arguments + ["--state-dir", root.path]
            + (control ? ["--control-token-file", root.appendingPathComponent("control-token").path] : [])
        return try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = args
            let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-chrome-" + UUID().uuidString)
            FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let errors = try FileHandle(forWritingTo: errorFile)
            defer { try? errors.close(); try? FileManager.default.removeItem(at: errorFile) }
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            var bytes = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                bytes.append(chunk)
                if bytes.count > 262_144 { process.terminate(); break }
            }
            process.waitUntilExit(); deadline.cancel()
            guard bytes.count <= 262_144, process.terminationStatus == 0 else {
                let reader = try? FileHandle(forReadingFrom: errorFile)
                let errorBytes = try? reader?.read(upToCount: 8192)
                try? reader?.close()
                let object = errorBytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                let code = object?["error"] ?? ""
                switch code {
                case "pairing_code_mismatch":
                    throw ClientFailure(L10n.text("Код не совпал. Проверь профиль и код в расширении.", "The code did not match. Check the profile and the code in the extension."))
                case "profile_not_paired":
                    throw ClientFailure(L10n.text("Сначала свяжи выбранный профиль.", "Pair the selected profile first."))
                case "coordinator_busy":
                    throw ClientFailure(L10n.text("Расширение занято. Останови управление вкладками перед обновлением.", "The extension is busy. Stop tab control before updating."))
                default:
                    throw ClientFailure(L10n.text("Команда расширения не подтверждена. Проверь подключение в настройках.", "The extension command was not confirmed. Check the connection in settings."))
                }
            }
            return bytes
        }.value
    }
    private func failure(_ ru: String, _ en: String) -> ClientFailure { ClientFailure(L10n.text(ru, en)) }
}
