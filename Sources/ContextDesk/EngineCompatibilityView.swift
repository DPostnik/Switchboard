import SwiftUI
import AgentContract
import ContextCore
import ContextTranscript

/// Copy for an engine connected under the version policy (user decision 2026-11-02).
enum EngineCompatibility {
    /// Nil for a verified engine.
    static func warning(name: String, engine: AgentEngineVersion?) -> String? {
        guard let engine, !engine.verified else { return nil }
        let nearest = engine.nearestVerified ?? "?"
        return L10n.text("\(name) \(engine.version) не проверен с этим приложением (проверена \(nearest)). Подключение работает, диагностика расхождений протокола включена; если что-то сломается, обнови Switchboard или верни проверенную версию.",
                         "\(name) \(engine.version) is not verified with this app (verified: \(nearest)). It is connected with protocol drift diagnostics on; if something breaks, update Switchboard or go back to the verified version.")
    }
}

/// Settings → Accounts: the engine version and protocol drift the agent's adapter counted since launch (names only).
struct EngineCompatibilityRows: View {
    let agent: AgentID
    let name: String
    let engine: AgentEngineVersion?
    @State private var entries: [CompatibilityDrift.Entry] = []

    var body: some View {
        Group {
            if let engine, let warning = EngineCompatibility.warning(name: name, engine: engine) {
                Label {
                    Text(warning).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DeskPalette.attention)
                }
                .font(.ui(.callout)).foregroundStyle(DeskPalette.attentionInk)
            } else if let engine {
                LabeledContent(L10n.text("Версия", "Version"), value: L10n.text("\(name) \(engine.version) · проверена", "\(name) \(engine.version) · verified"))
            }
            if let summary = CompatibilityDrift.summary(entries) {
                Label {
                    Text(summary).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DeskPalette.attention)
                }
                .font(.ui(.caption)).foregroundStyle(.secondary)
                .help(L10n.text("Движок прислал события или поля, которых адаптер не знает. Они пропущены, как и раньше; подробности в системном журнале (категория compatibility).",
                                "The engine sent events or fields this adapter does not know. They are skipped as before; details are in the system log (category compatibility)."))
            } else if engine?.verified == false {
                Text(L10n.text("С запуска незнакомых данных протокола не было.", "No unrecognized protocol data since launch."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CompatibilityDrift.changed).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() { entries = CompatibilityDrift.shared.snapshot(agent: agent) }
}
