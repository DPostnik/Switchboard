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
    #expect(model.resolvedDefaultModel(.originalCodex, project: project) == "gpt-6.2-sol")
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
    #expect(decoded.model == "gpt-6.2-sol")
}

@Test func codexModelDiscoveryPrefersSolAndKeepsValidExplicitChoices() {
    let engine = AgentModelInfo(id: "engine-default", displayName: "Engine", isDefault: true)
    let sol = AgentModelInfo(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol")
    #expect(SavedState().model == sol.id)
    #expect(CodexModelDefaults.resolve("", available: [engine, sol]) == sol.id)
    #expect(CodexModelDefaults.resolve("removed", available: [engine, sol]) == sol.id)
    #expect(CodexModelDefaults.resolve(engine.id, available: [engine, sol]) == engine.id)
    #expect(CodexModelDefaults.resolve(sol.id, available: [engine]) == engine.id)
    #expect(CodexModelDefaults.resolve(sol.id, available: []) == sol.id)
}

@Test func codexSol62MigrationMovesOnlyGPT61SolDefaultsOnce() throws {
    var state = SavedState()
    state.model = "gpt-6.1-sol"
    var sol = Project(path: "/tmp/sol61"), astra = Project(path: "/tmp/astra"), claude = Project(path: "/tmp/claude")
    sol.setChatModel(ModelChoice(model: "gpt-6.1-sol", effort: "high"), agent: "codex")
    astra.setChatModel(ModelChoice(model: "gpt-6-astra"), agent: "codex")
    claude.setChatModel(ModelChoice(model: "gpt-6.1-sol"), agent: "claude")
    state.projects = [sol, astra, claude]
    state.chats = [Chat(id: "old", projectID: sol.id, title: "Old", model: "gpt-6.1-sol")]
    let moved = state.applyCodexSol62Default()
    #expect(moved)
    #expect(state.model == "gpt-6.2-sol")
    #expect(state.projects[0].chatModels?["codex"] == ModelChoice(model: "gpt-6.2-sol", effort: "high"))
    #expect(state.projects[1].chatModels?["codex"]?.model == "gpt-6-astra")
    #expect(state.projects[2].chatModels?["claude"]?.model == "gpt-6.1-sol")
    #expect(state.chats[0].model == "gpt-6.1-sol")
    // A later explicit choice of GPT-6.1 Sol survives persistence.
    state.model = "gpt-6.1-sol"
    var restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    let repeated = restored.applyCodexSol62Default()
    #expect(!repeated)
    #expect(restored.model == "gpt-6.1-sol")
    var other = SavedState(); other.model = "gpt-6-astra"
    let otherApplied = other.applyCodexSol62Default()
    #expect(otherApplied)
    #expect(other.model == "gpt-6-astra")
}

@Test func codexSol62JobMigrationRunsOnceAndKeepsHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("scheduled-jobs.json")
    var ledger = JobLedger()
    var codex = ManagedJob(); codex.model = "gpt-6.1-sol"
    var astra = ManagedJob(); astra.model = "gpt-6-astra"
    var claude = ManagedJob(); claude.engine = JobEngine(rawValue: "claude"); claude.model = "gpt-6.1-sol"
    ledger.jobs = [codex, astra, claude]
    try JSONEncoder().encode(ledger).write(to: file)
    let store = JobStore(file: file)
    let loaded = try await store.load()
    #expect(loaded.jobs.map(\.model) == ["gpt-6.2-sol", "gpt-6-astra", "gpt-6.1-sol"])
    #expect(loaded.codexSol62Migrated == true)
    await store.release()
    // A later explicit GPT-6.1 Sol choice is not migrated again.
    var saved = try JSONDecoder().decode(JobLedger.self, from: Data(contentsOf: file))
    saved.jobs[0].model = "gpt-6.1-sol"
    try JSONEncoder().encode(saved).write(to: file)
    let again = JobStore(file: file)
    #expect(try await again.load().jobs[0].model == "gpt-6.1-sol")
    await again.release()
}
