import Foundation
import AgentContract
@testable import ContextCore
@testable import ContextDesk

// Test-only names for the two registered agents' connection state. The app reaches every connection through the
// registry (`agentStates`, `client(_:)`, `receive(_:from:)`); tests written for the two-agent model keep reading
// and setting the Codex and Claude state under their old names.
@MainActor extension DeskModel {
    private func set(_ id: AgentConnectionID, _ change: (inout AgentConnectionState) -> Void) {
        var value = agentState(id); change(&value); agentStates[id] = value
    }
    var connected: Bool {
        get { agentState(.originalCodex).connected } set { set(.originalCodex) { $0.connected = newValue } }
    }
    var authenticated: Bool {
        get { agentState(.originalCodex).authenticated } set { set(.originalCodex) { $0.authenticated = newValue } }
    }
    var claudeConnected: Bool {
        get { agentState(.appClaude).connected } set { set(.appClaude) { $0.connected = newValue } }
    }
    var claudeAuthenticated: Bool {
        get { agentState(.appClaude).authenticated } set { set(.appClaude) { $0.authenticated = newValue } }
    }
    var accountLabel: String {
        get { agentState(.originalCodex).accountLabel } set { set(.originalCodex) { $0.accountLabel = newValue } }
    }
    var codexModels: [AgentModelInfo] {
        get { agentState(.originalCodex).models } set { set(.originalCodex) { $0.models = newValue } }
    }
    var accountLimits: AccountLimits? { agentState(.originalCodex).limits }
    var claudeLimits: AccountLimits? { agentState(.appClaude).limits }
    var claudeLimitsError: String? { agentState(.appClaude).limitsError }
    var connection: AgentClient { client(.originalCodex)! }
    var claudeConnection: AgentClient { client(.appClaude)! }
    var summaryRunner: AgentGenerationRunner { generationRunner(connection: .originalCodex)! }
    var claudeSummaryRunner: AgentGenerationRunner { generationRunner(connection: .appClaude)! }
    var claudeHome: URL { registration(.appClaude)!.generationHome }
    func refreshAccount() async { await refreshAccount(.originalCodex) }
    func refreshModels() async { await refreshModels(.originalCodex) }
    func refreshLimits() async { await refreshLimits(.originalCodex) }
    func connect() async { await connect(.originalCodex) }
    func connectClaude() async { await connect(.appClaude) }
    func receive(_ event: AgentEvent) async { await receive(event, from: .originalCodex) }
    func receiveClaude(_ event: AgentEvent) async { await receive(event, from: .appClaude) }
}
