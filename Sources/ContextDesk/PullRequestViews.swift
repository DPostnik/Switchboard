import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// Colours and glyphs for the PR badge.
enum PullRequestStyle {
    /// A muted purple that sits with the sage palette, for merged PRs.
    static let merged = Color(red: 0x7A / 255, green: 0x5C / 255, blue: 0x99 / 255)

    static func tint(_ state: PullRequestStatus.State) -> Color {
        switch state {
        case .open: DeskPalette.accent
        case .draft: .secondary
        case .merged: merged
        case .closed: DeskPalette.problem
        }
    }

    /// ✓ passing, ✗ failing, • pending; nothing without checks or after the PR is closed.
    static func checksGlyph(_ status: PullRequestStatus) -> (glyph: String, color: Color)? {
        guard status.isOpen else { return nil }
        switch status.checksSummary {
        case .none: return nil
        case .passing: return ("✓", DeskPalette.accent)
        case .failing: return ("✗", DeskPalette.problem)
        case .pending: return ("•", DeskPalette.attention)
        }
    }
}

/// «#123» in the state's colour with the checks glyph; display-only.
struct PullRequestBadge: View {
    let status: PullRequestStatus

    var body: some View {
        HStack(spacing: .ui(2)) {
            Text("#\(status.number)").monospacedDigit().foregroundStyle(PullRequestStyle.tint(status.state))
            if let checks = PullRequestStyle.checksGlyph(status) {
                Text(checks.glyph).fontWeight(.bold).foregroundStyle(checks.color)
            }
            if status.isOpen && status.mergeable == .conflicting {
                Image(systemName: "exclamationmark.triangle.fill").imageScale(.small).foregroundStyle(DeskPalette.problem)
            }
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PullRequestText.summary(status))
    }
}

/// The composer's PR badge beside the branch chip; a click opens the details and the watch toggle.
struct ComposerPullRequestChip: View {
    @ObservedObject var model: DeskModel
    @State private var showing = false
    @State private var placement = CompactPopoverPlacement.fallback
    @State private var anchor = ScreenFrameProbe()

    var body: some View {
        let folder = model.composerPullRequestFolder
        if let status = model.pullRequestStatus(folder: folder) {
            Button {
                if !showing { placement = anchor.compactPlacement }
                showing.toggle()
            } label: { PullRequestBadge(status: status) }
                .buttonStyle(ChipButtonStyle()).fixedSize().pointingHandCursor()
                .help(PullRequestText.summary(status))
                .background(ScreenFrameReader(probe: anchor))
                .popover(isPresented: $showing, arrowEdge: placement.edge) {
                    CappedScroll(maxHeight: placement.maxHeight) {
                        PullRequestPopover(model: model, status: status, chatID: model.chatID).padding(16).frame(width: .ui(320))
                    }
                }
        }
    }
}

struct PullRequestPopover: View {
    @ObservedObject var model: DeskModel
    let status: PullRequestStatus
    let chatID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: .ui(10)) {
            HStack(alignment: .firstTextBaseline, spacing: .ui(6)) {
                Text("#\(status.number)").font(.ui(.headline)).monospacedDigit().foregroundStyle(PullRequestStyle.tint(status.state))
                Text(status.title).font(.ui(.headline)).foregroundStyle(DeskPalette.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: .ui(4)) {
                line(L10n.text("Состояние: ", "State: ") + PullRequestText.state(status.state), systemImage: "smallcircle.filled.circle",
                     color: PullRequestStyle.tint(status.state))
                if !status.headRefName.isEmpty, !status.baseRefName.isEmpty {
                    line(status.headRefName + " → " + status.baseRefName, systemImage: GitBranchText.symbol, color: .secondary)
                }
                line(PullRequestText.checks(status.checksSummary), systemImage: checksSymbol, color: checksColor)
                if let review = PullRequestText.review(status.reviewDecision) {
                    line(review, systemImage: "person.crop.circle.badge.checkmark", color: .secondary)
                }
                if status.isOpen && status.mergeable == .conflicting {
                    line(PullRequestText.conflict(base: status.baseRefName), systemImage: "exclamationmark.triangle.fill", color: DeskPalette.problem)
                }
            }
            .font(.ui(.callout))
            Divider()
            if let chatID, status.isOpen || model.pullRequests.watch(chatID: chatID) != nil {
                Toggle(isOn: Binding(get: { model.pullRequests.watch(chatID: chatID) != nil },
                                     set: { _ in Task { await model.togglePullRequestWatch(chatID: chatID) } })) {
                    Text(L10n.text("Следить за PR", "Watch PR"))
                }
                .toggleStyle(.switch).controlSize(.small)
                .help(L10n.text("Пока PR открыт, Switchboard проверяет его раз в 3 минуты и сообщает этому чату о падении проверок, успешных проверках, новых отзывах, конфликте, слиянии или закрытии. Агенту ничего не отправляется без твоего нажатия.",
                                "While the PR is open, Switchboard checks it every 3 minutes and tells this chat about failing or passing checks, new reviews, a conflict, a merge or a close. Nothing is sent to the agent unless you click."))
            }
            HStack {
                Spacer()
                if let url = URL(string: status.url), !status.url.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label(L10n.text("Открыть на GitHub", "Open on GitHub"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(DeskButtonStyle())
                }
            }
        }
    }

    private var checksSymbol: String {
        switch status.checksSummary {
        case .none: "circle.dashed"
        case .passing: "checkmark.circle.fill"
        case .pending: "clock"
        case .failing: "xmark.circle.fill"
        }
    }

    private var checksColor: Color {
        switch status.checksSummary {
        case .none: .secondary
        case .passing: DeskPalette.accent
        case .pending: DeskPalette.attention
        case .failing: DeskPalette.problem
        }
    }

    private func line(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: .ui(6)) {
            Image(systemName: systemImage).foregroundStyle(color).frame(width: .ui(16))
            Text(text).foregroundStyle(DeskPalette.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Explicit occasions for a PR lookup: the selected project or chat changes, the app becomes active. Git
/// changes (commits, pushes) arrive through `GitStatusStore.didRead`; turn ends through `refreshGitStatus`.
struct PullRequestTracking: ViewModifier {
    @ObservedObject var model: DeskModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.projectID) { _, _ in model.refreshPullRequest(folder: model.selectedProject?.path) }
            .onChange(of: model.chatID) { _, _ in model.refreshPullRequest(folder: model.composerPullRequestFolder) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Only the folder in view: the other projects' badges follow their git changes.
                model.refreshPullRequest(folder: model.composerPullRequestFolder)
            }
    }
}

/// The "Needs you" section for watched PRs: one card per open alert, with "Send to agent" for failing checks
/// and new reviews.
struct PullRequestAlertsSection: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        let alerts = model.pullRequests.openAlerts
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(L10n.text("Пул-реквесты", "Pull requests")).font(.ui(.headline)).foregroundStyle(DeskPalette.ink)
                    Text("\(alerts.count)").font(.ui(.callout)).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(alerts) { alert in card(alert) }
            }
        }
    }

    private func card(_ alert: PullRequestAlert) -> some View {
        let problem = alert.kind == .checksFailed || alert.kind == .conflict
        let tint = problem ? DeskPalette.problem : alert.kind == .merged ? PullRequestStyle.merged : DeskPalette.accent
        let chat = model.state.chats.first { $0.id == alert.chatID }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(alert.kind)).font(.ui(.title3)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("#\(alert.number) \(alert.title)").font(.ui(.caption).weight(.semibold)).foregroundStyle(tint).lineLimit(1)
                Text(PullRequestText.alert(alert)).font(.ui(.body).weight(.medium)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detail(alert) {
                    Text(detail).font(.ui(.callout)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text([chat?.title, L10n.date(alert.lastSeen)].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if alert.canSendToAgent {
                        Button { Task { await model.sendPullRequestAlertToAgent(alert) } } label: {
                            if model.pullRequests.sending.contains(alert.id) { ProgressView().uiSmallSpinner() }
                            else { Label(L10n.text("Отправить агенту", "Send to agent"), systemImage: "paperplane") }
                        }
                        .buttonStyle(DeskButtonStyle(kind: .primary))
                        .disabled(!model.canSendPullRequestAlert(alert))
                        .help(alert.kind == .checksFailed
                              ? L10n.text("Поставить в очередь этого чата одно сообщение: упавшие проверки и отрывок журнала CI (как данные).",
                                          "Queue one message in this chat: the failing checks and an excerpt of the CI log (as data).")
                              : L10n.text("Поставить в очередь этого чата одно сообщение с новыми отзывами и комментариями (как данные).",
                                          "Queue one message in this chat with the new reviews and comments (as data)."))
                    }
                    Button { Task { await model.resolvePullRequestAlert(alert.id) } } label: {
                        Label(L10n.text("Решено", "Resolved"), systemImage: "checkmark")
                    }.buttonStyle(DeskButtonStyle(kind: alert.canSendToAgent ? .secondary : .primary))
                    if let chat {
                        Button { Task { await model.openChat(chat) } } label: {
                            Label(L10n.text("Открыть чат", "Open chat"), systemImage: "bubble.left")
                        }.buttonStyle(DeskButtonStyle())
                    }
                    if let url = URL(string: alert.url), !alert.url.isEmpty {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label(L10n.text("Открыть на GitHub", "Open on GitHub"), systemImage: "arrow.up.right.square")
                        }.buttonStyle(DeskButtonStyle())
                    }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(problem ? DeskPalette.problemWash : DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 14))
    }

    private func symbol(_ kind: PullRequestAlert.Kind) -> String {
        switch kind {
        case .checksFailed: "xmark.octagon.fill"
        case .checksPassed: "checkmark.circle.fill"
        case .newActivity: "text.bubble.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    /// The newest comment's first line, so the card says what was written.
    private func detail(_ alert: PullRequestAlert) -> String? {
        guard alert.kind == .newActivity, let last = alert.activity?.last(where: { !$0.body.isEmpty }) else { return nil }
        return "@\(last.author): " + PullRequestAgentMessage.excerpt(last.body, limit: 240, keepEnd: false)
    }
}
