@testable import ACPAdapter
import ContextCore
import Foundation
import Testing

/// The pinned ACP schema index written by `scripts/compat-snapshot.py acp` (by hand, when a schema release is adopted).
private let snapshotURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/compat/acp-v1-\(ACPProtocolSurface.schemaVersion).json")

/// Walks field paths through the snapshot's type graph: property -> referenced types, `|` aliases, `+` open objects.
private struct ACPSnapshot {
    typealias Properties = [String: [String]]
    let json: [String: Any]
    let agentMethods: [String: [String: Any]]
    let clientMethods: [String: [String: Any]]
    let protocolMethods: [String: [String: Any]]
    let sessionUpdates: [String: String]
    let types: [String: Properties]

    init() throws {
        json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
        agentMethods = json["agentMethods"] as? [String: [String: Any]] ?? [:]
        clientMethods = json["clientMethods"] as? [String: [String: Any]] ?? [:]
        protocolMethods = json["protocolMethods"] as? [String: [String: Any]] ?? [:]
        sessionUpdates = json["sessionUpdates"] as? [String: String] ?? [:]
        types = json["types"] as? [String: Properties] ?? [:]
    }

    private func expand(type: String) -> [Properties] {
        var seen: Set<String> = [type], result: [Properties] = [], queue = [type]
        while let next = queue.popLast() {
            guard let properties = types[next] else { continue }
            result.append(properties)
            for alias in properties["|"] ?? [] where seen.insert(alias).inserted { queue.append(alias) }
        }
        return result
    }

    func root(_ root: String) -> [Properties]? {
        let parts = root.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let type: String?
        switch parts[0] {
        case "response": type = (agentMethods[parts[1]] ?? clientMethods[parts[1]])?["response"] as? String
        case "params": type = agentMethods[parts[1]]?["params"] as? String
        case "request": type = clientMethods[parts[1]].flatMap { $0["notification"] == nil ? $0["params"] as? String : nil }
        case "notification": type = (clientMethods[parts[1]] ?? protocolMethods[parts[1]])?["params"] as? String
        case "update": type = sessionUpdates[parts[1]]
        default: type = nil
        }
        return type.map(expand(type:))
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

    func missing(_ surface: [String: [String]]) -> [String] {
        var missing: [String] = []
        for (root, paths) in surface {
            guard let start = self.root(root) else { missing.append("root " + root); continue }
            missing += paths.filter { !resolves($0, from: start) }.map { root + " " + $0 }
        }
        return missing.sorted()
    }
}

@Test func acpSurfaceIsContainedInThePinnedSchemaSnapshot() throws {
    let snapshot = try ACPSnapshot()
    #expect(snapshot.json["version"] as? String == ACPProtocolSurface.schemaVersion)
    #expect(snapshot.json["protocolVersion"] as? Int == ACPProtocolSurface.protocolVersion)
    #expect(snapshot.missing(ACPProtocolSurface.reads) == [])
    #expect(snapshot.missing(ACPProtocolSurface.writes) == [])
    #expect(ACPProtocolSurface.sentRequests.subtracting(snapshot.agentMethods.keys) == [])
    #expect(ACPProtocolSurface.sentNotifications.allSatisfy { snapshot.agentMethods[$0]?["notification"] as? Bool == true })
    #expect(ACPProtocolSurface.answeredRequests.subtracting(snapshot.clientMethods.keys) == [])
    #expect(ACPProtocolSurface.surfacedUpdates.isSubset(of: ACPProtocolSurface.sessionUpdates))
}

@Test func acpKnownProtocolMatchesThePinnedSchemaSnapshot() throws {
    let snapshot = try ACPSnapshot()
    #expect(Set(snapshot.agentMethods.keys) == ACPProtocolSurface.agentMethods)
    #expect(Set(snapshot.clientMethods.keys) == ACPProtocolSurface.clientMethods)
    #expect(Set(snapshot.protocolMethods.keys) == ACPProtocolSurface.protocolMethods)
    #expect(Set(snapshot.sessionUpdates.keys) == ACPProtocolSurface.sessionUpdates)
    // Every known agent request is either answered or refused; none falls through.
    let requests = Set(snapshot.clientMethods.filter { $0.value["notification"] == nil }.keys)
    #expect(requests == ACPProtocolSurface.answeredRequests.union(ACPProtocolSurface.refusedRequests))
}

/// Guards the walker itself, so the containment test cannot pass vacuously.
@Test func acpSnapshotWalkerRejectsUnknownRootsAndFields() throws {
    let snapshot = try ACPSnapshot()
    let call = try #require(snapshot.root("update:tool_call_update"))
    #expect(snapshot.resolves("content.*.newText", from: call))
    #expect(!snapshot.resolves("content.*.newTexts", from: call))
    #expect(!snapshot.resolves("toolCallId.value", from: call))
    #expect(snapshot.root("update:hologram") == nil)
    #expect(snapshot.root("request:session/update") == nil)
    let initialize = try #require(snapshot.root("response:initialize"))
    #expect(snapshot.resolves("authMethods.*.type", from: initialize))
    #expect(!snapshot.resolves("agentCapabilities.sessionCapabilities.teleport", from: initialize))
}

@Test func acpDriftIsCountedByNameOnly() {
    func names(_ message: JSONValue) -> [String] { ACPProtocolSurface.drift(message).map { "\($0.0.rawValue) \($0.1)" } }
    let update: (String) -> JSONValue = { kind in
        .object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                 "params": .object(["sessionId": .string("s"), "update": .object(["sessionUpdate": .string(kind), "content": .object(["type": .string("text")])])])])
    }
    #expect(names(update("agent_message_chunk")) == [])
    #expect(names(update("hologram_update")) == ["itemType hologram_update"])
    #expect(names(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("_vendor/x")])) == ["serverRequest _vendor/x"])
    #expect(names(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("fs/read_text_file")])) == [])
    #expect(names(.object(["method": .string("_vendor/note")])) == ["missingField _vendor/note:jsonrpc", "notification _vendor/note"])
    #expect(names(.object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object([
        "sessionId": .string("s"), "update": .object(["sessionUpdate": .string("tool_call")])])])) == ["missingField session/update:tool_call.toolCallId"])
}
