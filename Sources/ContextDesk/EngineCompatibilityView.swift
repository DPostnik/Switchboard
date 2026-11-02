import SwiftUI
import AgentContract
import ContextCore
import ContextTranscript

/// Settings → Accounts: protocol drift the agent's adapter counted since launch (names only).
struct EngineCompatibilityRows: View {
    let agent: AgentID
    @State private var entries: [CompatibilityDrift.Entry] = []

    var body: some View {
        Group {
            if let summary = CompatibilityDrift.summary(entries) {
                Label {
                    Text(summary).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DeskPalette.attention)
                }
                .font(.ui(.caption)).foregroundStyle(.secondary)
                .help(L10n.text("Движок прислал события или поля, которых адаптер не знает. Они пропущены, как и раньше; подробности в системном журнале (категория compatibility).",
                                "The engine sent events or fields this adapter does not know. They are skipped as before; details are in the system log (category compatibility)."))
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CompatibilityDrift.changed).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() { entries = CompatibilityDrift.shared.snapshot(agent: agent) }
}
