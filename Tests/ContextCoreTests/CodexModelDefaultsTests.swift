import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ContextDesk

@Test @MainActor func codexSolDefaultMigratesOnceAndPreservesChatProjectAndClaudeChoices() throws {
    let model = DeskModel(summaryResources: nil)
    let project = model.state.addProject(path: "/tmp/codex-default")
    let override = model.state.addProject(path: "/tmp/codex-override")
    model.state.projects[1].setChatModel(ModelChoice(model: "project-model", effort: "high"), agent: "codex")
    model.state.model = "gpt-6-astra"
    model.state.claudeModel = "claude-sonnet-5-5"
    model.state.chats = [Chat(id: "existing", projectID: project, title: "Existing", model: "existing-model")]
    let adopted = model.state.applyCodexSolDefault()
    #expect(adopted)
    #expect(model.resolvedDefaultModel(.originalCodex, project: project) == "gpt-6.1-sol")
    #expect(model.resolvedDefaultModel(.originalCodex, project: override) == "project-model")
    #expect(model.state.chats[0].model == "existing-model")
    #expect(model.state.claudeModel == "claude-sonnet-5-5")
    // A later explicit app default survives persistence and subsequent launches.
    model.state.model = "later-choice"
    var restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(model.state))
    let reapplied = restored.applyCodexSolDefault()
    #expect(!reapplied)
    #expect(restored.model == "later-choice")
    // Older stores omit the migration key.
    var legacy = try JSONEncoder().encode(SavedState())
    var json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    json.removeValue(forKey: "codexSolDefaultApplied")
    json["model"] = "old-default"
    legacy = try JSONSerialization.data(withJSONObject: json)
    var decoded = try JSONDecoder().decode(SavedState.self, from: legacy)
    let migrated = decoded.applyCodexSolDefault()
    #expect(migrated)
    #expect(decoded.model == "gpt-6.1-sol")
}

@Test func codexModelDiscoveryPrefersSolAndKeepsValidExplicitChoices() {
    let engine = AgentModelInfo(id: "engine-default", displayName: "Engine", isDefault: true)
    let sol = AgentModelInfo(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol")
    #expect(SavedState().model == sol.id)
    #expect(CodexModelDefaults.resolve("", available: [engine, sol]) == sol.id)
    #expect(CodexModelDefaults.resolve("removed", available: [engine, sol]) == sol.id)
    #expect(CodexModelDefaults.resolve(engine.id, available: [engine, sol]) == engine.id)
    #expect(CodexModelDefaults.resolve(sol.id, available: [engine]) == engine.id)
    #expect(CodexModelDefaults.resolve(sol.id, available: []) == sol.id)
}
