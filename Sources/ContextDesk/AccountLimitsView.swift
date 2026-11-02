import ContextTranscript
import SwiftUI
import ContextCore

struct AccountLimitsView: View {
    @ObservedObject var model: DeskModel
    var maxListHeight: CGFloat = 340
    @Environment(\.dismiss) private var dismiss

    @State private var agent: AgentConnectionID?
    /// Room under the bucket list for the "Checked" line.
    static let checkedLineHeight: CGFloat = 40

    private var selected: AgentConnectionID {
        agent ?? (model.isRegistered(model.currentAgent) ? model.currentAgent : model.agentIDs.first ?? .unregistered)
    }
    private var state: AgentConnectionState { model.agentState(selected) }
    private var profile: AgentProfile? { model.profile(selected) }
    /// A per-chat engine connects only to check the CLI and account, so the popover connects it to read limits.
    private var connectsOnDemand: Bool { !model.traits(selected).contains(.sharedEngine) }
    private var limits: AccountLimits? { state.limits }
    private var issue: String? { state.limitsError }
    private var refreshing: Bool { state.refreshingLimits }
    private var connected: Bool { state.connected }
    private var authenticated: Bool { state.authenticated }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.text("Доступный usage", "Available usage"), systemImage: "chart.bar").font(.ui(.title2).bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Закрыть", "Close")).keyboardShortcut(.cancelAction)
            }
            Picker(L10n.text("Провайдер", "Provider"), selection: Binding(get: { selected }, set: { agent = $0 })) {
                ForEach(model.agentIDs, id: \.self) { id in Text(model.profile(id)?.productName ?? model.agentName(id)).tag(id) }
            }.pickerStyle(.segmented).labelsHidden().pointingHandCursor()
            Text(profile?.accountCopy.limitsScope() ?? "")
                .font(.ui(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // A fixed height from the first frame: AppKit places the popover only when it is shown,
            // so late data, a provider switch or a loading state must not resize it afterwards.
            VStack(alignment: .leading, spacing: 18) { status }
                .frame(height: maxListHeight + Self.checkedLineHeight, alignment: .top)
            HStack {
                Text(L10n.text("Время: \(TimeZone.current.identifier)", "Time zone: \(TimeZone.current.identifier)")).font(.ui(.caption)).foregroundStyle(.secondary)
                Spacer()
                if refreshing && limits != nil { ProgressView().uiSmallSpinner() }
                Button(L10n.text("Обновить", "Refresh")) { Task { await refresh() } }
                    .disabled(refreshing || !connected || !authenticated)
            }
        }.padding(24).frame(width: 480)
            .buttonStyle(PointerButtonStyle(base: .automatic))
            .task(id: selected) { await refresh() }
    }

    @ViewBuilder private var status: some View {
        if connectsOnDemand && !connected && state.connecting {
            let name = profile?.productName ?? model.agentName(selected)
            ProgressView(L10n.text("Подключаю \(name)…", "Connecting \(name)…")).padding(.vertical)
        } else if !authenticated {
            Text(profile?.accountCopy.limitsSignIn() ?? "")
        } else {
            if !connected { Label(L10n.text("Нет подключения. Данные могут быть устаревшими.", "Disconnected. Data may be out of date."), systemImage: "wifi.slash") }
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.ui(.callout)).foregroundStyle(DeskPalette.problem)
            }
            if let snapshot = limits {
                if snapshot.ordinaryUsageAllowed == false {
                    Text(L10n.text("Сервис сообщает, что обычное использование сейчас недоступно.", "The service reports that ordinary usage is currently unavailable.")).font(.ui(.callout))
                }
                if snapshot.buckets.isEmpty { Text(L10n.text("Сервис пока не передал данные о лимитах.", "The service has not provided limit data yet.")).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(bucket.name).font(.ui(.headline))
                                if bucket.windows.isEmpty { Text(L10n.text("Данные о периодах лимита не переданы.", "No limit window data provided.")).foregroundStyle(.secondary) }
                                ForEach(bucket.windows) { window in windowRow(window) }
                            }.padding(16).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
                Text(L10n.text("Проверено: \(localDate(snapshot.fetchedAt))", "Checked: \(localDate(snapshot.fetchedAt))"))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            } else if refreshing {
                ProgressView(L10n.text("Проверяю лимиты…", "Checking limits…")).padding(.vertical)
            } else if issue == nil {
                Text(L10n.text("Данные о лимитах пока не получены.", "Limit data has not been received yet.")).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        let id = selected
        // The usage probe of a per-chat engine needs its app-owned profile; connecting only checks the CLI and account.
        if connectsOnDemand && !model.agentState(id).connected { await model.connect(id) }
        await model.refreshLimits(id)
    }

    private func windowRow(_ window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.title)
                Spacer()
                Text(window.remainingPercent.map { L10n.text("\($0)% осталось", "\($0)% remaining") } ?? L10n.text("Нет данных", "No data")).monospacedDigit()
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: Double(remaining), total: 100).tint(remaining <= 10 ? DeskPalette.attention : DeskPalette.accent)
                    .accessibilityLabel(L10n.text("\(window.title): осталось \(remaining)%", "\(window.title): \(remaining)% remaining"))
            }
            if let reset = window.resetsAt {
                Text(L10n.text("Обновление: \(localDate(reset))", "Resets: \(localDate(reset))"))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Время обновления неизвестно", "Reset time unknown")).font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private func localDate(_ date: Date) -> String {
        L10n.date(date)
    }
}
