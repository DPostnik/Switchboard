import AppKit
import Foundation

public enum ChromeSessionImportCommand {
    @MainActor public static func run(arguments args: [String]) async -> Bool {
        guard args.count == 6, args[1] == "--browser-import-session" else {
            return false
        }
        let language = AppLanguage(rawValue: args[5]) ?? .english
        let output: JSONValue
        do {
            guard let endpoint = URL(string: args[4]) else { throw ChromeCookieError.connection }
            let result = try await ChromeCookieImporter.importSession(
                environment: URL(fileURLWithPath: args[2]), site: args[3], endpoint: endpoint,
                sourceIsRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty })
            output = .object(["verified": .number(Double(result.cookies.verified)), "skipped": .number(Double(result.cookies.skipped)),
                              "unverified": .number(Double(result.cookies.unverified)), "websiteSignInVerified": .bool(false),
                              "localStorageVerified": .number(Double(result.localStorage.verified)),
                              "localStorageSkipped": .number(Double(result.localStorage.skipped)),
                              "localStorageUnverified": .number(Double(result.localStorage.unverified))])
        } catch {
            let safe = error as? ChromeCookieError ?? .connection
            output = .object(["error": .string(safe.message(language: language)), "outcomeUnknown": .bool(safe == .uncertain)])
        }
        if let data = try? JSONEncoder().encode(output) { FileHandle.standardOutput.write(data) }
        return true
    }
}
