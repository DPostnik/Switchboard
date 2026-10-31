import Darwin
import Foundation
import Security

/// Checks who is on the other end of a connected Unix socket: the peer's code signature must
/// carry the expected bundle id and the same Team ID as this process.
public enum FringePeer {
    /// Designated-requirement text for `bundleID` signed by `teamID`.
    public static func requirement(bundleID: String, teamID: String) -> String {
        #"identifier "\#(bundleID)" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    /// The Team ID of the running process; nil for ad-hoc or unsigned builds, which then accept no peer.
    /// Read once: after the app's bundle on disk is replaced by a new build, `SecCodeCopySelf` no longer
    /// identifies the running process, and a fresh read would reject every peer until relaunch.
    public static func currentTeamID() -> String? { cachedTeamID }
    private static let cachedTeamID: String? = readCurrentTeamID()
    private static func readCurrentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True only if the process connected on `socket` is validly signed as `bundleID` by our team.
    public static func isTrusted(socket: Int32, bundleID: String) -> Bool {
        guard let teamID = currentTeamID() else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement(bundleID: bundleID, teamID: teamID) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
