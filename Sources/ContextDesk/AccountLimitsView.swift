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

    private var selected: AgentConnectionID { agent ?? (model.currentAgent == .appClaude ? .appClaude : .originalCodex) }
    private var claude: Bool { selected == .appClaude }
    private var limits: AccountLimits? { claude ? model.claudeLimits : model.accountLimits }
    private var issue: String? { claude ? model.claudeLimitsError : model.limitsError }
    private var refreshing: Bool { claude ? model.refreshingClaudeLimits : model.refreshingLimits }
    private var connected: Bool { claude ? model.claudeConnected : model.connected }
    private var authenticated: Bool { claude ? model.claudeAuthenticated : model.authenticated }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.text("Доступный usage", "Available usage"), systemImage: "chart.bar").font(.ui(.title2).bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Закрыть", "Close")).keyboardShortcut(.cancelAction)
            }
            Picker(L10n.text("Провайдер", "Provider"), selection: Binding(get: { selected }, set: { agent = $0 })) {
                Text("Codex").tag(AgentConnectionID.originalCodex)
                Text("Claude Code").tag(AgentConnectionID.appClaude)
            }.pickerStyle(.segmented).labelsHidden().pointingHandCursor()
            Text(claude
                 ? L10n.text("Лимиты подписки Claude общие для аккаунта: Claude Code, claude.ai и другие приложения. Контекст отдельного чата показан рядом с полем сообщения.", "Claude subscription limits are shared across your account: Claude Code, claude.ai and other apps. Each chat’s context usage is shown next to the message field.")
                 : L10n.text("Лимиты Codex общие для аккаунта во всех приложениях. Контекст отдельного чата показан рядом с полем сообщения.", "Codex limits are shared across all apps on your account. Each chat’s context usage is shown next to the message field."))
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
        if claude && !model.claudeConnected && model.claudeConnecting {
            ProgressView(L10n.text("Подключаю Claude Code…", "Connecting Claude Code…")).padding(.vertical)
        } else if !authenticated {
            Text(claude
                 ? L10n.text("Войди в Claude в настройках приложения, чтобы увидеть лимиты.", "Sign in to Claude in the app’s settings to see your limits.")
                 : L10n.text("Войди в ChatGPT в настройках приложения, чтобы увидеть лимиты.", "Sign in with ChatGPT in the app’s settings to see your limits."))
        } else {
            if !connected { Label(L10n.text("Нет подключения. Данные могут быть устаревшими.", "Disconnected. Data may be out of date."), systemImage: "wifi.slash") }
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.ui(.callout)).foregroundStyle(.orange)
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
                            }.padding(16).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
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
        guard claude else { await model.refreshLimits(); return }
        // The usage probe needs the app-owned Claude profile; connecting only checks the CLI and account.
        if !model.claudeConnected { await model.connectClaude() }
        await model.refreshClaudeLimits()
    }

    private func windowRow(_ window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.title)
                Spacer()
                Text(window.remainingPercent.map { L10n.text("\($0)% осталось", "\($0)% remaining") } ?? L10n.text("Нет данных", "No data")).monospacedDigit()
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: Double(remaining), total: 100).tint(remaining <= 10 ? .orange : .blue)
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
