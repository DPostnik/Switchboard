import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// Copy for the branch chips and the branch-change banner.
enum GitBranchText {
    static let symbol = "arrow.triangle.branch"

    /// "↑2 ↓1", only the non-zero parts; empty when level with the upstream.
    static func aheadBehind(_ status: GitStatus) -> String {
        [status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// Full branch, upstream with ahead/behind, and uncommitted changes, one per line.
    static func summary(_ status: GitStatus, language: AppLanguage = L10n.language) -> String {
        var lines = [status.branch.map { L10n.text("Ветка: \($0)", "Branch: \($0)", language: language) }
            ?? L10n.text("HEAD отсоединён: \(status.displayName)", "Detached HEAD at \(status.displayName)", language: language)]
        if let upstream = status.upstream {
            lines.append(L10n.text("Вышестоящая ветка: \(upstream) · впереди \(status.ahead), позади \(status.behind)",
                                   "Upstream: \(upstream) · ahead \(status.ahead), behind \(status.behind)", language: language))
        } else if status.branch != nil {
            lines.append(L10n.text("Без вышестоящей ветки", "No upstream", language: language))
        }
        lines.append(status.hasChanges
            ? L10n.text("Незакоммиченных файлов: \(status.changedFiles)", "Uncommitted files: \(status.changedFiles)", language: language)
            : L10n.text("Нет незакоммиченных изменений", "No uncommitted changes", language: language))
        return lines.joined(separator: "\n")
    }

    static func changed(_ change: GitBranchChange, language: AppLanguage = L10n.language) -> String {
        L10n.text("Ветка сменилась: чат работал в \(change.from), сейчас \(change.to)",
                  "Branch changed: this chat worked on \(change.from), now \(change.to)", language: language)
    }

    static func switchBack(_ branch: String, language: AppLanguage = L10n.language) -> String {
        L10n.text("Вернуть \(branch)", "Switch back to \(branch)", language: language)
    }
}

/// Branch name (middle-truncated), a dot for uncommitted changes and ↑/↓ against the upstream.
/// When space is short the ↑/↓ counts go first (they stay in the tooltip), then the name truncates.
struct GitBranchBadge: View {
    let status: GitStatus
    var maxNameWidth: CGFloat = 96

    var body: some View {
        let aheadBehind = GitBranchText.aheadBehind(status)
        ViewThatFits(in: .horizontal) {
            if !aheadBehind.isEmpty { line(aheadBehind) }
            line(nil)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GitBranchText.summary(status))
    }

    private func line(_ aheadBehind: String?) -> some View {
        HStack(spacing: .ui(3)) {
            Image(systemName: GitBranchText.symbol).imageScale(.small)
            CappedWidth(limit: .ui(maxNameWidth)) {
                Text(status.displayName).lineLimit(1).truncationMode(.middle)
            }
            if status.hasChanges {
                Circle().fill(DeskPalette.attention).frame(width: .ui(5), height: .ui(5))
            }
            if let aheadBehind { Text(aheadBehind).monospacedDigit().lineLimit(1).fixedSize() }
        }
    }
}

/// Proposes at most `limit` to its content and takes the content's own width, so a short name stays short
/// (a `frame(maxWidth:)` would grow to the limit).
private struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A sidebar project's name and, right-aligned, its branch badge. It fills the line like a spacer. The name
/// keeps its full width when it fits and at least `nameShare` of the line otherwise; the badge gets the rest.
struct ProjectTitleLayout: Layout {
    var spacing: CGFloat = 8
    var nameShare: CGFloat = 0.55

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideal.map(\.height).max() ?? 0
        if let width = proposal.width, width.isFinite { return CGSize(width: width, height: height) }
        return CGSize(width: ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(ideal.count - 1, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let name = subviews.first else { return }
        let available = bounds.width
        let nameIdeal = name.sizeThatFits(.unspecified).width
        var nameWidth = min(nameIdeal, available)
        if subviews.count > 1 {
            let badge = subviews[1]
            let badgeIdeal = badge.sizeThatFits(.unspecified).width
            let badgeMinimum = badge.sizeThatFits(ProposedViewSize(width: 0, height: bounds.height)).width
            nameWidth = min(nameIdeal, max(available - spacing - badgeIdeal, available * nameShare), max(0, available - spacing - badgeMinimum))
            let badgeWidth = max(0, min(badgeIdeal, available - nameWidth - spacing))
            badge.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                        proposal: ProposedViewSize(width: badgeWidth, height: bounds.height))
        }
        name.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                   proposal: ProposedViewSize(width: nameWidth, height: bounds.height))
    }
}

/// A chat row's title; when the chat works in its own worktree, or last worked on another branch than the
/// project's current one, the title keeps one line and that branch appears under it, so the row height does not change.
struct ChatRowTitle: View {
    let title: String
    let branch: String?
    /// The branch of the chat's own worktree; takes the place of `branch`.
    var worktreeBranch: String? = nil

    var body: some View {
        Group {
            if let line = worktreeBranch ?? branch {
                VStack(alignment: .leading, spacing: .ui(1)) {
                    Text(title).lineLimit(1)
                    HStack(spacing: .ui(3)) {
                        Image(systemName: worktreeBranch == nil ? GitBranchText.symbol : WorktreeText.symbol).imageScale(.small)
                        Text(line).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.ui(.caption2)).foregroundStyle(.secondary)
                }
            } else {
                Text(title).lineLimit(2, reservesSpace: true)
            }
        }
        .frame(height: .ui(32), alignment: .leading)
    }
}

/// Above the composer: the chat's last turn started on another branch than the project is on now.
struct BranchChangeBanner: View {
    @ObservedObject var model: DeskModel
    let width: CGFloat
    @State private var failure: (key: String, text: String)?

    var body: some View {
        if let chat = model.selectedChat, !chat.isArchived, !model.isBusy(threadID: chat.id),
           let path = model.workingDirectory(forChat: chat.id),
           let change = model.gitStatus.branchChange(for: chat, projectPath: path) {
            let key = GitStatusStore.bannerKey(chatID: chat.id, change: change)
            if !model.gitStatus.dismissedBanners.contains(key) {
                banner(chat: chat, path: path, change: change, key: key)
            }
        }
    }

    private func banner(chat: Chat, path: String, change: GitBranchChange, key: String) -> some View {
        let switching = model.gitStatus.switching.contains(path)
        // Switching under a running agent would move its files mid-turn.
        let projectBusy = model.state.chats.contains {
            $0.projectID == chat.projectID && (model.isBusy(threadID: $0.id) || model.isSending(threadID: $0.id))
        }
        return VStack(alignment: .leading, spacing: .ui(6)) {
            HStack(alignment: .firstTextBaseline, spacing: .ui(12)) {
                Label(GitBranchText.changed(change), systemImage: GitBranchText.symbol).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if switching { ProgressView().uiSmallSpinner() }
                Button {
                    Task {
                        let error = await model.gitStatus.switchBranch(path, to: change.from)
                        failure = error.map { (key, $0) }
                    }
                } label: {
                    Text(GitBranchText.switchBack(change.from)).lineLimit(1).truncationMode(.middle)
                }
                .controlSize(.small).frame(maxWidth: .ui(240))
                .disabled(switching || projectBusy)
                .help(projectBusy
                      ? L10n.text("Дождись, пока чаты этого проекта закончат работу", "Wait until the chats in this project are idle")
                      : L10n.text("Выполнить git switch \(change.from) в папке проекта. Без принудительного переключения и stash: если git откажет, будет показана его ошибка.",
                                  "Run git switch \(change.from) in the project folder. No force and no stash: if git refuses, its error is shown."))
                Button { model.gitStatus.dismissBanner(key) } label: { Image(systemName: "xmark") }
                    .buttonStyle(PointerButtonStyle(base: .plain))
                    .help(L10n.text("Скрыть", "Dismiss"))
                    .accessibilityLabel(L10n.text("Скрыть уведомление о ветке", "Dismiss the branch notice"))
            }
            if let failure, failure.key == key {
                Text(failure.text).font(.ui(.caption)).foregroundStyle(DeskPalette.problemInk)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.ui(.callout))
        .frame(maxWidth: width, alignment: .leading).padding(.horizontal, .ui(24)).padding(.vertical, .ui(8))
    }
}

/// When to read git status: the sidebar's projects and their chats' worktrees are tracked (and watched), the selected project is read
/// again on selection, and every tracked folder when the app becomes active.
struct GitStatusTracking: ViewModifier {
    @ObservedObject var model: DeskModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.trackedGitPaths, initial: true) { _, paths in model.gitStatus.track(paths) }
            .onChange(of: model.projectID) { _, _ in model.gitStatus.refresh(model.selectedProject?.path) }
            .onChange(of: model.chatID) { _, chatID in model.gitStatus.refresh(chatID.flatMap(model.workingDirectory(forChat:))) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.gitStatus.refreshAll()
            }
    }
}
