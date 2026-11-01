import SwiftUI
import ContextTranscript
import ContextCore

/// Unresolved blockers and run problems stay here, highlighted, until the user marks them resolved.
struct AttentionView: View {
    @ObservedObject var model: DeskModel
    @State private var showingResolved = false
    var body: some View {
        let open = model.attention.open, resolved = model.attention.resolved
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text("Важное", "Important"), systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(.title2).weight(.semibold)).foregroundStyle(open.isEmpty ? Color.primary : AttentionPalette.accent)
                    Text(L10n.text("Блокеры из отчётов заданий по расписанию и неудачные запуски. Сообщение остаётся здесь, пока ты не отметишь его решённым. Неудачный запуск закрывается сам после следующего успешного запуска того же задания.",
                                   "Blockers from scheduled task reports and failed runs. A message stays here until you mark it resolved. A failed run clears itself after the next successful run of the same task."))
                        .font(.ui(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if open.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                        Text(L10n.text("Нерешённых проблем нет", "No unresolved problems")).foregroundStyle(.secondary)
                    }.padding(.vertical, 24)
                } else {
                    ForEach(open) { item in card(item) }
                }
                if !resolved.isEmpty {
                    Divider().padding(.vertical, 4)
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
                    }.font(.ui(.callout).weight(.medium))
                    if showingResolved { ForEach(resolved) { item in card(item) } }
                }
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(DeskPalette.canvas)
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

/// The always-visible sidebar highlight while important messages are unresolved.
struct AttentionBanner: View {
    @ObservedObject var model: DeskModel
    var body: some View {
        let count = model.openAttentionCount
        Button { model.openAttention() } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DeskPalette.attention)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Нужно решить: \(count)", "Needs your action: \(count)")).font(.ui(.callout).weight(.semibold))
                    if let latest = model.attention.open.first {
                        Text(latest.text).font(.ui(.caption)).opacity(0.85).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.ui(.caption).weight(.bold)).foregroundStyle(DeskPalette.attention)
            }
            .foregroundStyle(DeskPalette.attentionInk)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(DeskPalette.attentionWash, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle(base: .plain))
        .help(L10n.text("Открыть важные сообщения", "Open important messages"))
    }
}

enum AttentionPalette {
    static let accent = DeskPalette.attention
    static let problem = DeskPalette.problem
}
