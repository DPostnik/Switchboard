import Foundation
import ContextCore
import AgentContract

/// Launches only the bounded extension adapter with authority issued by the native app.
enum UserChromeConfiguration {
    static let server = "switchboard_user_chrome"

    static func allowed(enabled: Bool, permissions: AgentPermissionProfile, scheduled: Bool,
                        grant: AgentUserChromeGrant?) -> Bool {
        enabled && permissions.effective.browser == .appAndUserChrome && !scheduled && grant != nil
    }

    static func configuration(enabled: Bool, permissions: AgentPermissionProfile, scheduled: Bool,
                              resources: URL?, grant: AgentUserChromeGrant?) throws -> JSONValue {
        var entry: [String: JSONValue] = ["command": .string("/usr/bin/false"), "args": .array([]),
                                         "enabled": .bool(false), "required": .bool(false)]
        if allowed(enabled: enabled, permissions: permissions, scheduled: scheduled, grant: grant), let grant {
            guard let resources,
                  FileManager.default.fileExists(atPath: resources.appendingPathComponent("UserChromeRuntime/server.py").path) else {
                throw ClientFailure(L10n.text("Компонент расширения Chrome отсутствует в сборке приложения.",
                                             "The Chrome extension component is missing from this app build."))
            }
            guard !grant.chatID.isEmpty, UUID(uuidString: grant.profileID) != nil,
                  grant.stateDirectory.isFileURL, grant.capabilityFile.isFileURL,
                  grant.capabilityFile.standardizedFileURL.path.hasPrefix(grant.stateDirectory.standardizedFileURL.path + "/") else {
                throw ClientFailure(L10n.text("Разрешение расширения Chrome недействительно. Подключи профиль заново.",
                                             "The Chrome extension grant is invalid. Connect the profile again."))
            }
            entry["command"] = .string("/usr/bin/python3")
            entry["args"] = .array(["-I", resources.appendingPathComponent("UserChromeRuntime/server.py").path,
                                    "mcp", "--state-dir", grant.stateDirectory.path, "--chat-id", grant.chatID,
                                    "--profile-id", grant.profileID, "--capability-file", grant.capabilityFile.path].map(JSONValue.string))
            entry["enabled"] = .bool(true)
            entry["required"] = .bool(true)
            entry["startup_timeout_sec"] = .number(30)
            entry["tool_timeout_sec"] = .number(90)
        }
        return .object(["mcp_servers.\(server)": .object(entry)])
    }

    static let instructions = """
    The switchboard_user_chrome tools control the user's regular Google Chrome through the paired Switchboard extension, with its current tabs and site sign-ins.
    When asked to use the user's Chrome, use these tools. Otherwise start with switchboard_browser and switch to the user's Chrome if sign-in import fails or the site blocks the isolated browser.
    Chrome must be running and the Switchboard extension must be connected to the paired profile. Report the specific setup or connection blocker. Do not restart Chrome, change its profile, copy credentials, or retry actions with uncertain outcomes.
    List tabs first. Create a new tab for your task unless the user requested an existing tab. Close only tabs you created; never close the browser or unrelated tabs. Browser access does not authorize sending messages, purchases, or other external commitments.
    """
}
