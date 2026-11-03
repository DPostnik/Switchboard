import AppKit
import SwiftUI
import AgentContract
import ContextCore
import ContextTranscript

extension GitActions {
    @MainActor private static var cached: (actions: GitActions, checked: TimeInterval)?
    /// One `GitActions` for the views, built again after 10 s so a newly installed `gh` is found: views are created
    /// on every render, and each new value looked for `gh` on disk.
    @MainActor static var current: GitActions {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.checked < 10 { return cached.actions }
        let actions = GitActions()
        cached = (actions, now)
        return actions
    }
}

extension DeskModel {
    /// The folder a chat's git actions (and its composer branch chip) work in: its worktree or its project folder.
    func gitActionsFolder(forChat chatID: String) -> String? {
        workingDirectory(forChat: chatID)
    }

    /// The composer's folder: the selected chat's, else the selected project's (a new chat).
    var composerGitFolder: String? { selectedWorkingDirectory }

    /// A chat working in the folder may move files under a commit, push or pull, so they wait for it.
    func gitFolderBusy(_ folder: String) -> Bool {
        activeRunChatIDs.contains { gitActionsFolder(forChat: $0) == folder }
    }

    /// Drafts run as an isolated generation on the agent connection of a chat in this folder: the selected chat
    /// when it qualifies, else the folder's most recent one. Nil when no chat's agent is connected and signed in.
    func gitDraftGenerator(folder: String) -> GitDraftGenerator? {
        let candidates = state.chats.filter { canGenerateSummary($0) && gitActionsFolder(forChat: $0.id) == folder }
        guard let chat = candidates.first(where: { $0.id == chatID }) ?? candidates.max(by: { $0.updated < $1.updated }),
              let source = chat.nativeSession, let client = try? clientForChat(chat.id) else { return nil }
        return GitDraftGenerator(runner: AgentGenerationRunner(integration: client.integration), source: source,
                                 model: generationModel(for: chat), route: chat.route ?? .direct,
                                 environment: generationEnvironment(for: chat.id, workspace: ".git-draft-workspace"))
    }
}

/// One cancellable draft request: a commit message or a pull request. Each call is a single request, never retried.
struct GitDraftGenerator: Sendable {
    let runner: AgentGenerationRunner
    let source: AgentSessionReference
    let model: String
    let route: RequestRoute
    let environment: AgentGenerationEnvironment

    func commitMessage(_ input: String) async throws -> String {
        try await runner.commitMessage(source: source, input: input, model: model, route: route, environment: environment)
    }

    func pullRequest(_ input: String) async throws -> GitPullRequestText {
        try await runner.pullRequest(source: source, input: input, model: model, route: route, environment: environment)
    }

    func stop() async { await runner.stop() }
}

enum GitActionSheet: Identifiable {
    case commit(GitAction, GitRepositoryState)
    case pullRequest(GitRepositoryState)

    var id: String {
        switch self {
        case .commit(let action, _): "commit-" + action.rawValue
        case .pullRequest: "pull-request"
        }
    }
}

/// The composer's branch chip; a click opens a native «Git» menu with the folder's state and the actions it allows.
/// The menu opens at once: it is built from the live branch status and a cached copy of the slower facts (remote,
/// default branch), refreshed in the background whenever the status changes. Like any menu it closes on a
/// choice: Push and Pull run with a spinner in the chip, a failure shows git's output in an alert, and the
/// commit and pull request flows open their sheets.
struct GitActionsChip: View {
    @ObservedObject var model: DeskModel
    let folder: String?
    /// A chat in its own worktree shows the worktree icon first.
    var worktree: ChatWorktree? = nil
    @State private var cached: GitRepositoryState?
    @State private var running: GitAction?
    @State private var succeeded: GitAction?
    @State private var failure: GitActionFailure?
    @State private var confirmingPush: GitRepositoryState?
    @State private var sheet: GitActionSheet?
    private let actions = GitActions.current

    var body: some View {
        // The stack stays in place without a status so a running sheet is not torn down by a status refresh.
        HStack(spacing: 0) {
            if let folder, let status = model.gitStatus.status(for: folder) {
                Menu { menu(folder: folder, status: status) } label: {
                    HStack(spacing: .ui(4)) {
                        if running != nil { ProgressView().uiSmallSpinner() }
                        else if succeeded != nil { Image(systemName: "checkmark").foregroundStyle(DeskPalette.accent).imageScale(.small) }
                        else if worktree != nil { Image(systemName: WorktreeText.symbol).imageScale(.small).foregroundStyle(.secondary) }
                        GitBranchBadge(status: status, maxNameWidth: 160)
                    }
                }
                .menuStyle(.button).buttonStyle(ChipButtonStyle()).menuIndicator(.hidden).fixedSize()
                .pointingHandCursor()
                .disabled(running != nil)
                .help([worktree.map { WorktreeText.tooltip($0) }, GitBranchText.summary(status)].compactMap { $0 }.joined(separator: "\n"))
                .task(id: GitCacheKey(folder: folder, status: status)) { await refreshCache(folder) }
            } else if let worktree {
                // The worktree folder is gone or not read yet: its recorded branch.
                Label(WorktreeText.name(worktree), systemImage: WorktreeText.symbol)
                    .font(.ui(.callout)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, .ui(9)).frame(height: .ui(28))
                    .help(WorktreeText.tooltip(worktree))
            }
        }
        .confirmationDialog(L10n.text("Отправить прямо в \(confirmingPush?.pushBranch ?? "")?", "Push directly to \(confirmingPush?.pushBranch ?? "")?"),
                            isPresented: Binding(get: { confirmingPush != nil }, set: { if !$0 { confirmingPush = nil } }),
                            presenting: confirmingPush) { state in
            Button(L10n.text("Отправить в \(state.pushBranch ?? "")", "Push to \(state.pushBranch ?? "")")) { run(.push, state: state) }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.text("Это основная ветка репозитория. Коммиты попадут в неё без PR.",
                           "This is the repository's default branch. The commits land there without a pull request."))
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }), presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.output)
        }
        .sheet(item: $sheet) { value in
            if let folder {
                switch value {
                case .commit(let action, let state):
                    GitCommitSheet(model: model, folder: folder, action: action, state: state) { fresh in
                        sheet = .pullRequest(fresh)
                    }
                case .pullRequest(let state):
                    GitPullRequestSheet(model: model, folder: folder, state: state)
                }
            }
        }
    }

    @ViewBuilder private func menu(folder: String, status: GitStatus) -> some View {
        let busy = model.gitFolderBusy(folder)
        let state = cached.map { GitRepositoryState(root: $0.root, status: status, files: $0.files, remote: $0.remote, defaultBranch: $0.defaultBranch) }
        let pullRequest = knownPullRequest(folder)
        Section(GitMenuText.header(status)) {
            Text(GitMenuText.subtitle(status))
        }
        if busy {
            Text(L10n.text("Агент работает в этой папке: действия доступны после конца хода.",
                           "An agent is working in this folder: actions unlock when the turn ends."))
        } else if status.isDetached {
            Text(L10n.text("HEAD отсоединён: переключись на ветку, чтобы коммитить.", "Detached HEAD: switch to a branch to commit."))
        } else if status.behind > 0 {
            Text(L10n.text("Ветка отстаёт: сначала подтяни изменения.", "The branch is behind: pull before pushing."))
        }
        if case .open(let url) = pullRequest, let link = URL(string: url) {
            Divider()
            Button { NSWorkspace.shared.open(link) } label: {
                Label(L10n.text("Открыть PR этой ветки", "Open This Branch's Pull Request"), systemImage: "arrow.triangle.pull")
            }
        }
        if let state {
            let offered = GitAction.allCases.filter { action in
                if action == .createPR, case .open = pullRequest { return false }
                return GitActions.availability(action, state: state, gitHubAvailable: actions.gitHubAvailable,
                                               pullRequest: pullRequest, folderBusy: false).isEnabled
            }
            if !offered.isEmpty { Divider() }
            ForEach(offered) { action in
                Button { perform(action, folder: folder, state: state) } label: {
                    Label(action.menuTitle + (action == .push && status.ahead > 0 ? "  ↑\(status.ahead)" : "")
                                           + (action == .pull && status.behind > 0 ? "  ↓\(status.behind)" : ""),
                          systemImage: action.icon)
                }
                .disabled(busy)
            }
            if offered.isEmpty && !busy && !status.isDetached {
                Text(L10n.text("Изменений нет, ветка синхронизирована.", "Nothing to do: no changes and in sync."))
            }
        } else {
            Text(L10n.text("Читаю репозиторий…", "Reading the repository…"))
        }
    }

    /// The PR badge's knowledge of an open PR for this branch; Create PR stays possible when it knows none
    /// (gh then reports an existing one).
    private func knownPullRequest(_ folder: String) -> GitPullRequestLookup {
        guard let known = model.pullRequestStatus(folder: folder), known.state == .open || known.state == .draft else { return .none }
        return .open(known.url)
    }

    private func refreshCache(_ folder: String) async {
        let actions = actions
        if let fresh = await Task.detached(operation: { await actions.state(at: folder) }).value { cached = fresh }
    }

    private func perform(_ action: GitAction, folder: String, state: GitRepositoryState) {
        // The menu was built a moment ago; a turn may have started since.
        guard running == nil, !model.gitFolderBusy(folder) else { return }
        switch action {
        case .commit, .commitAndPush, .commitPushAndCreatePR, .createPR:
            // The sheets list the files to commit, so they get a fresh read rather than the cached one.
            running = action
            Task {
                let actions = actions
                let fresh = await Task.detached { await actions.state(at: folder) }.value
                running = nil
                guard let fresh else { return }
                cached = fresh
                sheet = action == .createPR ? .pullRequest(fresh) : .commit(action, fresh)
            }
        case .push:
            if state.pushesToDefaultBranch { confirmingPush = state } else { run(.push, state: state) }
        case .pull:
            run(.pull, state: state)
        }
    }

    private func run(_ action: GitAction, state: GitRepositoryState) {
        guard let folder, running == nil, !model.gitFolderBusy(folder) else { return }
        running = action; succeeded = nil
        Task {
            let outcome = action == .push ? await actions.push(state: state) : await actions.pull(root: state.root)
            running = nil
            model.gitStatus.refresh(folder, after: .zero)
            if outcome.succeeded {
                succeeded = action
                try? await Task.sleep(for: .seconds(2))
                if succeeded == action { succeeded = nil }
            } else {
                failure = GitActionFailure(title: L10n.text("\(action.title): ошибка", "\(action.title) failed"),
                                           output: String(outcome.output.suffix(1500)))
            }
        }
    }
}

/// Refreshes the chip's cached repository facts whenever the folder or its status changes.
private struct GitCacheKey: Equatable {
    let folder: String
    let status: GitStatus
}

private struct GitActionFailure: Equatable {
    let title: String
    let output: String
}

/// The menu's header: the branch with its sync state, then the upstream and the changes.
enum GitMenuText {
    static func header(_ status: GitStatus) -> String {
        var parts = [status.branch ?? status.displayName]
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.joined(separator: "  ")
    }

    static func subtitle(_ status: GitStatus, language: AppLanguage = L10n.language) -> String {
        let upstream = status.upstream ?? (status.branch == nil ? L10n.text("без ветки", "no branch", language: language)
                                                                : L10n.text("не опубликована", "not published", language: language))
        let changes = status.hasChanges
            ? L10n.text("изменено файлов: \(status.changedFiles)", status.changedFiles == 1 ? "1 changed file" : "\(status.changedFiles) changed files", language: language)
            : L10n.text("нет изменений", "no changes", language: language)
        return upstream + " · " + changes
    }
}

/// git's or gh's own output, selectable and scrollable.
struct GitOutputText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text).font(.ui(.caption).monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .ui(140))
    }
}

/// The draft request's progress beside a field: spinner with «Skip», a failure note, or «Draft again».
private struct GitDraftStatus: View {
    let generating: Bool
    let note: String?
    let canGenerate: Bool
    let skip: () -> Void
    let generate: () -> Void

    var body: some View {
        HStack(spacing: .ui(8)) {
            if generating {
                ProgressView().uiSmallSpinner()
                Text(L10n.text("Модель пишет черновик…", "The model is drafting…")).foregroundStyle(.secondary)
                Button(L10n.text("Пропустить", "Skip"), action: skip).controlSize(.small)
            } else {
                if let note { Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                if canGenerate { Button(L10n.text("Написать черновик", "Draft with model"), action: generate).controlSize(.small) }
            }
        }
        .font(.ui(.caption))
    }
}

/// Commit (and optionally push and continue to a pull request): pick files, review the drafted message, run once.
struct GitCommitSheet: View {
    @ObservedObject var model: DeskModel
    let folder: String
    let action: GitAction
    let state: GitRepositoryState
    let continueToPullRequest: (GitRepositoryState) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<String> = []
    @State private var message = ""
    @State private var generator: GitDraftGenerator?
    @State private var generation: Task<Void, Never>?
    @State private var generating = false
    @State private var note: String?
    @State private var confirmedDefaultBranch = false
    @State private var running = false
    @State private var committed = false
    @State private var finished = false
    @State private var output: [(text: String, failed: Bool)] = []
    private let actions = GitActions.current

    private var selected: [GitWorkingFile] { state.files.filter { !excluded.contains($0.id) } }
    private var needsConfirmation: Bool { action.pushes && state.pushesToDefaultBranch }

    var body: some View {
        VStack(alignment: .leading, spacing: .ui(12)) {
            Text(action.title).font(.ui(.title2).bold())
            Text(L10n.text("Ветка \(state.status.displayName) · выбрано файлов: \(selected.count) из \(state.files.count)",
                           "Branch \(state.status.displayName) · \(selected.count) of \(state.files.count) files selected"))
                .foregroundStyle(.secondary)
            fileList
            Text(L10n.text("Сообщение коммита", "Commit message")).font(.ui(.headline))
            TextEditor(text: Binding(get: { message }, set: { value in
                // Typing takes over from the draft.
                if generating { skipDraft() }
                message = value
            }))
            .font(.ui(.body).monospaced()).frame(height: .ui(110))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DeskPalette.selection))
            .disabled(committed || running)
            GitDraftStatus(generating: generating, note: note, canGenerate: generator != nil && !committed && !running && !selected.isEmpty,
                           skip: skipDraft, generate: startDraft)
            if needsConfirmation && !committed {
                Toggle(L10n.text("Отправить прямо в основную ветку \(state.pushBranch ?? "") без PR",
                                 "Push directly to the default branch \(state.pushBranch ?? "") without a pull request"), isOn: $confirmedDefaultBranch)
                    .foregroundStyle(DeskPalette.attention)
            }
            if model.gitFolderBusy(folder) && !finished {
                Text(L10n.text("Агент работает в этой папке: дождись конца хода.", "An agent is working in this folder: wait for the turn to end."))
                    .font(.ui(.caption)).foregroundStyle(DeskPalette.attention)
            }
            ForEach(Array(output.enumerated()), id: \.offset) { _, entry in
                GitOutputText(text: entry.text).foregroundStyle(entry.failed ? DeskPalette.problemInk : Color.primary)
            }
            HStack {
                Spacer()
                if finished || committed {
                    Button(L10n.text("Закрыть", "Close")) { dismiss() }.keyboardShortcut(.defaultAction).disabled(running)
                } else {
                    Button(L10n.text("Отмена", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    if running { ProgressView().uiSmallSpinner() }
                    Button(action.title) { Task { await run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || selected.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (needsConfirmation && !confirmedDefaultBranch) || model.gitFolderBusy(folder))
                }
            }
        }
        .font(.ui(.callout))
        .padding(.ui(24)).frame(width: .ui(640), height: .ui(640))
        .interactiveDismissDisabled(running)
        .task {
            generator = model.gitDraftGenerator(folder: folder)
            if generator == nil {
                note = L10n.text("Нет чата с подключённым агентом в этой папке: напиши сообщение сам.",
                                 "No chat with a connected agent in this folder: write the message yourself.")
            } else { startDraft() }
        }
        .onDisappear { skipDraft() }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: .ui(4)) {
            HStack {
                Button(L10n.text("Выбрать все", "Select all")) { excluded = [] }.controlSize(.small)
                Button(L10n.text("Снять все", "Select none")) { excluded = Set(state.files.map(\.id)) }.controlSize(.small)
            }
            .disabled(committed || running)
            List(state.files) { file in
                Toggle(isOn: Binding(get: { !excluded.contains(file.id) }, set: { included in
                    if included { excluded.remove(file.id) } else { excluded.insert(file.id) }
                })) {
                    HStack(spacing: .ui(6)) {
                        Text(file.code).font(.ui(.caption).monospaced()).foregroundStyle(.secondary).frame(width: .ui(14))
                        Text(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox).disabled(committed || running)
            }
            .listStyle(.bordered).frame(minHeight: .ui(120), maxHeight: .ui(200))
        }
    }

    private func startDraft() {
        guard let generator, !generating else { return }
        let files = selected, root = state.root, actions = actions
        generating = true; note = nil
        generation = Task {
            defer { generating = false; generation = nil }
            do {
                let context = try await Task.detached { try await actions.commitContext(root: root, files: files) }.value
                let input = try GitGeneration.commitInput(recentCommits: context.recentCommits, stat: context.stat, diff: context.diff)
                let draft = try await generator.commitMessage(input)
                try Task.checkCancellation()
                message = draft
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                note = L10n.text("Черновик не получен: ", "No draft: ") + error.localizedDescription
            }
        }
    }

    private func skipDraft() {
        guard generating else { return }
        generation?.cancel(); generation = nil; generating = false
        note = L10n.text("Черновик пропущен.", "Draft skipped.")
        if let generator { Task { await generator.stop() } }
    }

    private func run() async {
        guard !running, !committed, !model.gitFolderBusy(folder) else { return }
        skipDraft()
        running = true
        defer { running = false; model.gitStatus.refresh(folder, after: .zero) }
        let commit = await actions.commit(selected, message: message, root: state.root)
        output.append((commit.output.isEmpty ? L10n.text("Коммит создан.", "Committed.") : commit.output, !commit.succeeded))
        // A refused commit (for example a hook) can be fixed and committed again by the user; nothing repeats by
        // itself, and after a timeout the commit may exist, so the sheet only offers to close.
        guard commit.succeeded else { finished = commit.uncertain; return }
        committed = true
        guard action.pushes else { finished = true; return }
        guard let fresh = await actions.state(at: folder) else {
            output.append((L10n.text("Не удалось прочитать состояние репозитория; отправка не выполнена.", "Could not read the repository state; nothing was pushed."), true))
            finished = true; return
        }
        let push = await actions.push(state: fresh)
        output.append((push.output.isEmpty ? L10n.text("Отправлено.", "Pushed.") : push.output, !push.succeeded))
        guard push.succeeded, action == .commitPushAndCreatePR, let pushed = await actions.state(at: folder) else { finished = true; return }
        continueToPullRequest(pushed)
    }
}

/// Create a pull request with `gh`: drafted title and body, base branch, draft flag; created only on the final click.
struct GitPullRequestSheet: View {
    @ObservedObject var model: DeskModel
    let folder: String
    let state: GitRepositoryState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var base = ""
    @State private var branches: [String] = []
    @State private var draft = false
    @State private var generator: GitDraftGenerator?
    @State private var generation: Task<Void, Never>?
    @State private var generating = false
    @State private var note: String?
    @State private var running = false
    @State private var outcome: GitActions.Outcome?
    private let actions = GitActions.current

    private var head: String { state.pushBranch ?? state.status.displayName }
    /// Created, or possibly created (gh timed out): either way the button does not run again.
    private var created: Bool { outcome?.succeeded == true || outcome?.uncertain == true }

    var body: some View {
        VStack(alignment: .leading, spacing: .ui(12)) {
            Text(L10n.text("Создать PR", "Create pull request")).font(.ui(.title2).bold())
            HStack(spacing: .ui(8)) {
                if branches.isEmpty {
                    TextField(L10n.text("Базовая ветка", "Base branch"), text: $base).frame(width: .ui(200))
                } else {
                    Picker(L10n.text("Базовая ветка", "Base branch"), selection: $base) {
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: .ui(280))
                }
                Text("← \(head)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle(L10n.text("Черновик", "Draft"), isOn: $draft).toggleStyle(.checkbox)
            }
            .disabled(created || running)
            TextField(L10n.text("Заголовок", "Title"), text: Binding(get: { title }, set: { value in
                if generating { skipDraft() }
                title = value
            }))
            .disabled(created || running)
            TextEditor(text: Binding(get: { text }, set: { value in
                if generating { skipDraft() }
                text = value
            }))
            .font(.ui(.body).monospaced())
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DeskPalette.selection))
            .disabled(created || running)
            GitDraftStatus(generating: generating, note: note, canGenerate: generator != nil && !created && !running && !base.isEmpty,
                           skip: skipDraft, generate: startDraft)
            if let outcome {
                if let address = outcome.url, let link = URL(string: address) {
                    HStack {
                        Text(address).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L10n.text("Открыть", "Open")) { NSWorkspace.shared.open(link) }
                    }
                } else if !outcome.output.isEmpty {
                    GitOutputText(text: outcome.output).foregroundStyle(outcome.succeeded ? Color.primary : DeskPalette.problemInk)
                }
            }
            HStack {
                Spacer()
                if created {
                    Button(L10n.text("Закрыть", "Close")) { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.text("Отмена", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    if running { ProgressView().uiSmallSpinner() }
                    Button(L10n.text("Создать PR", "Create pull request")) { Task { await create() } }
                        .disabled(running || base.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || base == head || model.gitFolderBusy(folder))
                }
            }
        }
        .font(.ui(.callout))
        .padding(.ui(24)).frame(width: .ui(680), height: .ui(640))
        .interactiveDismissDisabled(running)
        .task { await prepare() }
        .onDisappear { skipDraft() }
    }

    private func prepare() async {
        let actions = actions, state = state
        let remote = state.remote ?? "origin"
        branches = await Task.detached { await actions.remoteBranches(root: state.root, remote: remote, defaultBranch: state.defaultBranch) }.value
            .filter { $0 != head }
        base = state.defaultBranch.flatMap { branches.isEmpty || branches.contains($0) ? $0 : nil } ?? branches.first ?? ""
        // The template is the body's skeleton until (or unless) a draft replaces it.
        if text.isEmpty { text = GitActions.pullRequestTemplate(root: state.root) ?? "" }
        generator = model.gitDraftGenerator(folder: folder)
        if generator == nil {
            note = L10n.text("Нет чата с подключённым агентом в этой папке: напиши заголовок и описание сам.",
                             "No chat with a connected agent in this folder: write the title and description yourself.")
        } else { startDraft() }
    }

    private func startDraft() {
        guard let generator, !generating, !base.isEmpty else { return }
        let root = state.root, remote = state.remote ?? "origin", base = base, head = head, actions = actions
        generating = true; note = nil
        generation = Task {
            defer { generating = false; generation = nil }
            do {
                let context = try await Task.detached { try await actions.pullRequestContext(root: root, remote: remote, base: base) }.value
                let input = try GitGeneration.pullRequestInput(base: base, head: head, commits: context.commits, stat: context.stat,
                                                               diff: context.diff, template: context.template)
                let drafted = try await generator.pullRequest(input)
                try Task.checkCancellation()
                title = drafted.title; text = drafted.body
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                note = L10n.text("Черновик не получен: ", "No draft: ") + error.localizedDescription
            }
        }
    }

    private func skipDraft() {
        guard generating else { return }
        generation?.cancel(); generation = nil; generating = false
        note = L10n.text("Черновик пропущен.", "Draft skipped.")
        if let generator { Task { await generator.stop() } }
    }

    private func create() async {
        guard !running, !created, !model.gitFolderBusy(folder) else { return }
        skipDraft()
        running = true
        defer { running = false; model.gitStatus.refresh(folder, after: .zero) }
        outcome = await actions.createPullRequest(title: title, body: text, base: base, head: head, draft: draft, root: state.root)
    }
}

private extension GitAction {
    var icon: String {
        switch self {
        case .commit: "checkmark.circle"
        case .commitAndPush: "arrow.up.circle"
        case .commitPushAndCreatePR, .createPR: "arrow.triangle.pull"
        case .push: "arrow.up"
        case .pull: "arrow.down"
        }
    }

    /// Menu wording: actions that open a sheet end with an ellipsis.
    var menuTitle: String {
        switch self {
        case .commit: L10n.text("Коммит…", "Commit…")
        case .commitAndPush: L10n.text("Коммит и отправка…", "Commit and Push…")
        case .commitPushAndCreatePR: L10n.text("Коммит, отправка и PR…", "Commit, Push and Open PR…")
        case .push: L10n.text("Отправить", "Push")
        case .pull: L10n.text("Подтянуть", "Pull")
        case .createPR: L10n.text("Создать PR…", "Create Pull Request…")
        }
    }
}
