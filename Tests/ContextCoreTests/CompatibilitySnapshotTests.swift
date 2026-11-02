@testable import CodexAdapter
@testable import ClaudeAdapter
import ContextCore
import Foundation
import Testing

/// Condensed protocol indexes written by `scripts/compat-snapshot.py` (by hand, when a version is verified).
private let snapshots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/compat")

private func load(_ name: String) throws -> [String: Any]? {
    let url = snapshots.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
}

/// Walks field paths through the snapshot's type graph: property -> referenced types, `|` aliases, `+` open objects.
private struct CodexSnapshot {
    typealias Properties = [String: [String]]
    let clientRequests: [String: [String: String]]
    let serverRequests: [String: [String: String]]
    let notifications: [String: String]
    let itemTypes: [String: Properties]
    let types: [String: Properties]

    init(_ json: [String: Any]) {
        // Requests without params carry JSON null, so read entries field by field.
        func requests(_ key: String) -> [String: [String: String]] {
            (json[key] as? [String: [String: Any]] ?? [:]).mapValues { $0.compactMapValues { $0 as? String } }
        }
        clientRequests = requests("clientRequests")
        serverRequests = requests("serverRequests")
        notifications = json["notifications"] as? [String: String] ?? [:]
        itemTypes = json["itemTypes"] as? [String: Properties] ?? [:]
        types = json["types"] as? [String: Properties] ?? [:]
    }

    /// A type's own properties plus those of its aliases (union variants).
    private func expand(_ properties: Properties, seen: inout Set<String>) -> [Properties] {
        [properties] + (properties["|"] ?? []).flatMap { alias -> [Properties] in
            guard seen.insert(alias).inserted, let next = types[alias] else { return [] }
            return expand(next, seen: &seen)
        }
    }
    private func expand(type: String) -> [Properties] {
        var seen: Set<String> = [type]
        return types[type].map { expand($0, seen: &seen) } ?? []
    }

    func root(_ root: String) -> [Properties]? {
        let parts = root.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var seen = Set<String>()
        switch parts[0] {
        case "response": return clientRequests[parts[1]]?["response"].map(expand(type:))
        case "notification": return notifications[parts[1]].map(expand(type:))
        case "serverRequest": return serverRequests[parts[1]]?["params"].map(expand(type:))
        case "item": return itemTypes[parts[1]].map { expand($0, seen: &seen) }
        default: return nil
        }
    }

    func resolves(_ path: String, from start: [Properties]) -> Bool {
        var current = start
        for step in path.split(separator: ".").map(String.init) where step != "*" {
            var next: [Properties] = [], found = false
            for properties in current {
                if let references = properties[step] {
                    found = true
                    next += references.flatMap(expand(type:))
                } else if properties["+"] != nil { return true }
            }
            guard found else { return false }
            current = next
        }
        return true
    }

    /// Everything in the declared surface that this snapshot lacks.
    func missing() -> [String] {
        var missing = CodexProtocolSurface.requests.filter { clientRequests[$0] == nil }.map { "request " + $0 }
        for (root, paths) in CodexProtocolSurface.reads {
            guard let start = self.root(root) else { missing.append("root " + root); continue }
            missing += paths.filter { !resolves($0, from: start) }.map { root + " " + $0 }
        }
        return missing.sorted()
    }
}

@Test func codexSurfaceIsContainedInTheSnapshotOfEverySupportedVersion() throws {
    #expect(!CodexProtocolSurface.versionsWithoutSnapshot.contains(CodexProtocolCompatibility.currentVersion))
    #expect(CodexProtocolSurface.versionsWithoutSnapshot.isSubset(of: Set(CodexProtocolCompatibility.supportedVersions)))
    var checked: [String] = []
    for version in CodexProtocolCompatibility.supportedVersions where !CodexProtocolSurface.versionsWithoutSnapshot.contains(version) {
        let json = try #require(try load("codex-\(version).json"), "No snapshot for supported Codex \(version); run scripts/compat-snapshot.py codex")
        #expect(json["version"] as? String == version)
        let snapshot = CodexSnapshot(json)
        #expect(snapshot.missing() == [], "Codex \(version)")
        checked.append(version)
    }
    #expect(checked.contains(CodexProtocolCompatibility.currentVersion))
}

@Test func codexKnownProtocolMatchesTheCurrentSnapshot() throws {
    let snapshot = CodexSnapshot(try #require(try load("codex-\(CodexProtocolCompatibility.currentVersion).json")))
    #expect(Set(snapshot.notifications.keys) == CodexProtocolSurface.notifications)
    #expect(Set(snapshot.serverRequests.keys) == CodexProtocolSurface.serverRequests)
    #expect(Set(snapshot.itemTypes.keys) == CodexProtocolSurface.itemTypes)
    #expect(CodexProtocolSurface.syntheticNotifications.isDisjoint(with: CodexProtocolSurface.notifications))
}

/// Guards the walker itself, so the containment test cannot pass vacuously.
@Test func codexSnapshotWalkerRejectsUnknownRootsAndFields() throws {
    let snapshot = CodexSnapshot(try #require(try load("codex-\(CodexProtocolCompatibility.currentVersion).json")))
    let turn = try #require(snapshot.root("notification:turn/completed"))
    #expect(snapshot.resolves("turn.error.message", from: turn))
    #expect(!snapshot.resolves("turn.error.messages", from: turn))
    #expect(!snapshot.resolves("turn.id.value", from: turn))
    #expect(snapshot.root("notification:turn/teleported") == nil)
    #expect(snapshot.root("item:hologram") == nil)
    let command = try #require(snapshot.root("item:commandExecution"))
    #expect(!snapshot.resolves("aggregated_output", from: command))
}

@Test func claudeSurfaceMatchesThePinnedSnapshot() throws {
    let json = try #require(try load("claude-\(ClaudeRuntime.pinnedVersion).json"), "No snapshot for Claude Code \(ClaudeRuntime.pinnedVersion); run scripts/compat-snapshot.py claude")
    #expect(json["version"] as? String == ClaudeRuntime.pinnedVersion)
    func list(_ key: String) -> Set<String> { Set(json[key] as? [String] ?? []) }
    #expect(list("frameTypes") == ClaudeProtocolSurface.frameTypes)
    #expect(list("systemSubtypes") == ClaudeProtocolSurface.systemSubtypes)
    #expect(ClaudeProtocolSurface.readFrameTypes.subtracting(ClaudeProtocolSurface.undocumentedFrameTypes).isSubset(of: list("frameTypes")))
    #expect(ClaudeProtocolSurface.readSystemSubtypes.isSubset(of: list("systemSubtypes")))
    #expect(ClaudeProtocolSurface.readResultSubtypes.isSubset(of: list("resultSubtypes")))
    #expect(ClaudeProtocolSurface.answeredControlRequests.isSubset(of: list("controlRequestSubtypes")))
    #expect(ClaudeProtocolSurface.sentControlRequests.isSubset(of: list("controlRequestSubtypes")))
    // Undocumented names stay separate, so a snapshot that starts declaring them shows up here.
    #expect(ClaudeProtocolSurface.undocumentedFrameTypes.isDisjoint(with: list("frameTypes")))
    #expect(ClaudeProtocolSurface.undocumentedSystemSubtypes.isDisjoint(with: list("systemSubtypes")))
}
