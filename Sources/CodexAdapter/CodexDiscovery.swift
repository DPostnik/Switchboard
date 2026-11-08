import Foundation
import ContextCore

extension Locations {
    public static func codexExecutable() throws -> URL {
        try codexExecutable(
            applicationDirectories: ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path],
            path: ProcessInfo.processInfo.environment["PATH"] ?? "",
            managedExecutable: agentsHome.appendingPathComponent("codex/bin/codex").path
        )
    }

    static func codexExecutable(applicationDirectories: [String], path: String,
                                cliDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"], managedExecutable: String? = nil) throws -> URL {
        // Desktop releases may embed the CLI as a nested app instead of a loose binary.
        let candidates = [managedExecutable].compactMap { $0 } + applicationDirectories.flatMap { directory in
            ["ChatGPT.app", "Codex.app"].flatMap { app in
                ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex"].map {
                    "\(directory)/\(app)/Contents/Resources/\($0)"
                }
            }
        } + cliDirectories.map { "\($0)/codex" } + path.split(separator: ":").filter {
            $0.hasPrefix("/") // Never resolve an executable relative to the working directory.
        }.map { "\($0)/codex" }
        guard let executable = candidates.first(where: {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw ClientFailure(L10n.text("Codex не найден. Установи официальный Codex CLI или приложение ChatGPT/Codex.", "Codex was not found. Install the official Codex CLI or the ChatGPT/Codex app."))
        }
        return URL(fileURLWithPath: executable)
    }
}
