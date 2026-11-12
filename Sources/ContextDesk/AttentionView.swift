import SwiftUI
import ContextTranscript
import ContextCore

/// The "Needs you" page: chats waiting for the user, unresolved important messages and notifications, in that order.
/// Important messages stay until the user marks them resolved; empty sections are hidden.
struct AttentionView: View {
    @ObservedObject var model: DeskModel
    @State private var showingResolved = false
    var body: some View {
        let waiting = model.attentionChats, open = model.attention.open, resolved = model.attention.resolved, notices = model.attentionNotices
        let pullRequestAlerts = model.pullRequests.openAlerts
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label(L10n.text("Ждёт тебя", "Needs you"), systemImage: "tray.full")
                    .font(.ui(.title2).weight(.semibold)).foregroundStyle(DeskPalette.ink)
                if waiting.isEmpty && open.isEmpty && notices.isEmpty && pullRequestAlerts.isEmpty { calm }
                if !waiting.isEmpty { waitingSection(waiting) }
                PullRequestAlertsSection(model: model)
                if !open.isEmpty || !resolved.isEmpty { importantSection(open: open, resolved: resolved) }
                if !notices.isEmpty { notificationsSection(notices) }
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(DeskPalette.canvas)
    }

    private var calm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text(L10n.text("Сейчас ничего не ждёт тебя", "Nothing needs you right now")).font(.ui(.body).weight(.medium))
            }
            Text(L10n.text("Здесь появятся чаты, которые ждут ответа или одобрения, важные сообщения заданий по расписанию и уведомления.",
                           "Chats waiting for an answer or approval, important messages from scheduled jobs and notifications appear here."))
                .font(.ui(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.notificationsAllowed { enableNotifications }
        }.padding(.vertical, 12)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.ui(.headline)).foregroundStyle(DeskPalette.ink)
            Text("\(count)").font(.ui(.callout)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func waitingSection(_ waiting: [(chat: Chat, attention: ChatAttention)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L10n.text("Ждущие чаты", "Waiting chats"), count: waiting.count)
            ForEach(waiting, id: \.chat.id) { entry in
                Button { Task { await model.openChat(entry.chat) } } label: { waitingRow(entry.chat, entry.attention) }
                    .buttonStyle(AttentionRowStyle())
                    .help(L10n.text("Открыть чат", "Open chat"))
            }
        }
    }

    private func waitingRow(_ chat: Chat, _ attention: ChatAttention) -> some View {
        let tint: Color = switch attention {
        case .needsApproval, .needsAnswer: DeskPalette.attention
        case .failed: DeskPalette.problem
        case .finishedUnread: DeskPalette.accent
        }
        let project = model.state.projects.first { $0.id == chat.projectID }?.name
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(tint).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title).font(.ui(.body).weight(.medium)).foregroundStyle(DeskPalette.ink).lineLimit(1)
                Text([attention.title, project].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(.caption).weight(.semibold)).foregroundStyle(attention == .finishedUnread ? Color.secondary : tint)
                if let detail = model.attentionDetail(chat) {
                    Text(detail).font(.ui(.callout)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.ui(.caption).weight(.semibold)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func importantSection(open: [AttentionItem], resolved: [AttentionItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(L10n.text("Важное", "Important"), count: open.count)
                Text(L10n.text("Блокеры из отчётов заданий по расписанию и неудачные запуски. Сообщение остаётся здесь, пока ты не отметишь его решённым. Неудачный запуск закрывается сам после следующего успешного запуска того же задания.",
                               "Blockers from scheduled task reports and failed runs. A message stays here until you mark it resolved. A failed run clears itself after the next successful run of the same task."))
                    .font(.ui(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if open.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                    Text(L10n.text("Нерешённых проблем нет", "No unresolved problems")).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            ForEach(open) { item in card(item) }
            if !resolved.isEmpty {
                HStack {
                    Button { showingResolved.toggle() } label: {
                        Label(L10n.text("Решённые (\(resolved.count))", "Resolved (\(resolved.count))"),
                              systemImage: showingResolved ? "chevron.down" : "chevron.right")
                    }.buttonStyle(PointerButtonStyle(base: .plain))
                    Spacer()
                    if showingResolved {
                        Button(L10n.text("Очистить решённые", "Clear resolved")) { Task { await model.clearResolvedAttention() } }
                            .buttonStyle(PointerButtonStyle(base: .plain)).foregroundStyle(.secondary)
                    }
                }.font(.ui(.callout).weight(.medium)).padding(.top, 4)
                if showingResolved { ForEach(resolved) { item in card(item) } }
            }
        }
    }

    private func notificationsSection(_ notices: [DeskNotice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader(L10n.text("Уведомления", "Notifications"), count: notices.count)
                Spacer()
                Button(L10n.text("Очистить", "Clear")) { model.notices.removeAll() }.buttonStyle(DeskButtonStyle(kind: .text))
            }
            if !model.notificationsAllowed { enableNotifications }
            ForEach(notices) { notice in
                Button { Task { await model.focusAction(threadID: notice.threadID) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "bubble.left.fill").foregroundStyle(DeskPalette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.title).font(.ui(.body).weight(.medium)).foregroundStyle(DeskPalette.ink)
                            Text(notice.detail).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }.accessibilityElement(children: .combine)
                }.buttonStyle(AttentionRowStyle(wash: DeskPalette.accentWash))
            }
        }
    }

    private var enableNotifications: some View {
        HStack(spacing: 8) {
            Text(model.notificationStatus).font(.ui(.caption)).foregroundStyle(.secondary)
            Button(L10n.text("Включить уведомления macOS", "Enable macOS notifications")) { Task { await model.enableNotifications() } }
                .buttonStyle(DeskButtonStyle(kind: .text))
        }
    }

    private func card(_ item: AttentionItem) -> some View {
        let tint = item.kind == .blocker ? AttentionPalette.accent : AttentionPalette.problem
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .blocker ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(.ui(.title3)).foregroundStyle(item.isOpen ? tint : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.kind == .blocker ? L10n.text("Блокер", "Blocker") : L10n.text("Проблема запуска", "Run problem"))
                    .font(.ui(.caption).weight(.semibold)).foregroundStyle(item.isOpen ? tint : .secondary)
                Text(item.text).font(.ui(.body).weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(detail).font(.ui(.callout)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meta(item)).font(.ui(.caption)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if item.isOpen {
                        Button { Task { await model.resolveAttention(item.id) } } label: {
                            Label(L10n.text("Решено", "Resolved"), systemImage: "checkmark")
                        }.buttonStyle(DeskButtonStyle(kind: .primary))
                    } else {
                        Button { Task { await model.reopenAttention(item.id) } } label: {
                            Label(L10n.text("Вернуть", "Reopen"), systemImage: "arrow.uturn.backward")
                        }.buttonStyle(DeskButtonStyle())
                    }
                    if let jobID = item.jobID, model.jobLedger.jobs.contains(where: { $0.id == jobID }) {
                        Button { model.openScheduledJob(jobID) } label: {
                            Label(L10n.text("Открыть задание", "Open task"), systemImage: "calendar")
                        }.buttonStyle(DeskButtonStyle())
                    }
                    if let thread = item.threadID, let chat = model.state.chats.first(where: { $0.id == thread }) {
                        Button { Task { await model.openChat(chat) } } label: {
                            Label(L10n.text("Открыть отчёт", "Open report"), systemImage: "bubble.left")
                        }.buttonStyle(DeskButtonStyle())
                    }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(!item.isOpen ? DeskPalette.subtle : item.kind == .blocker ? DeskPalette.attentionWash : DeskPalette.problemWash,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func meta(_ item: AttentionItem) -> String {
        var parts = [item.jobName, L10n.text("впервые ", "first ") + item.created.formatted(date: .abbreviated, time: .shortened)]
        if item.occurrences > 1 {
            parts.append(L10n.text("повторялось: \(item.occurrences), последний раз ", "seen \(item.occurrences) times, last ")
                         + item.lastSeen.formatted(date: .abbreviated, time: .shortened))
        }
        if let resolved = item.resolved {
            parts.append((item.resolvedAutomatically ? L10n.text("закрыто успешным запуском ", "cleared by a successful run ") : L10n.text("решено ", "resolved "))
                         + resolved.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

/// A clickable card on the "Needs you" page: a tonal fill that deepens under the pointer and on press.
private struct AttentionRowStyle: ButtonStyle {
    var wash = DeskPalette.subtle
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, wash: wash) }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let wash: Color
        @State private var hovering = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12)
            configuration.label
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(wash).overlay(shape.fill(DeskPalette.accentDeep.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .pointingHandCursor()
        }
    }
}

enum AttentionPalette {
    static let accent = DeskPalette.attention
    static let problem = DeskPalette.problem
}
