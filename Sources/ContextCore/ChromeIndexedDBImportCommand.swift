import AppKit
import Foundation

/// Native helper for the agent-triggered IndexedDB transfer. The Python executor runs it while holding the
/// environment `operation.lock` and after it has stopped the chat's Chrome, so the destination profile is closed
/// and the whole-origin LevelDB clone is consistent. It does nothing unless the user has granted IndexedDB
/// transfer for this exact site, and it refuses while the source Chrome is running.
public enum ChromeIndexedDBImportCommand {
    @MainActor public static func run(arguments args: [String]) async -> Bool {
        guard args.count == 5, args[1] == "--browser-import-indexeddb" else { return false }
        let language = AppLanguage(rawValue: args[4]) ?? .english
        let environment = URL(fileURLWithPath: args[2])
        let site = args[3]
        let output: JSONValue
        do {
            let root = BrowserEnvironmentStore.directory.standardizedFileURL
            guard environment.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("environments").path,
                  environment.resolvingSymlinksInPath().path == environment.path,
                  UUID(uuidString: environment.lastPathComponent) != nil,
                  let scope = try ChromeIndexedDBConsent.resolve(site: site, environment: environment, browserRoot: root)
            else { throw ChromeCookieError.indexedDBDisabled }
            // A distinct ledger key bounds IndexedDB transfers on their own, apart from cookie imports (audit M7).
            try ChromeImportLedger.admit(environment: environment, site: "indexeddb:" + scope.site)
            guard let result = try ChromeIndexedDBSource.install(
                profile: scope.profile, scheme: "https", host: scope.site, environment: environment,
                sourceIsRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty })
            else { throw ChromeCookieError.indexedDBMissing }
            output = .object(["storeName": .string(result.storeName), "copiedBytes": .number(Double(result.copiedBytes)),
                              "blobCopied": .bool(result.blobCopied), "websiteSignInVerified": .bool(false)])
        } catch {
            let safe = error as? ChromeCookieError ?? .connection
            output = .object(["error": .string(safe.message(language: language)), "outcomeUnknown": .bool(safe == .uncertain)])
        }
        if let data = try? JSONEncoder().encode(output) { FileHandle.standardOutput.write(data) }
        return true
    }
}
