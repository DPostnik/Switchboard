import AppKit
import SwiftUI
import os
import ContextCore

private let worktreeLog = Logger(subsystem: AppLog.subsystem, category: "worktrees")

/// Where a project's next new chat works, besides the default project folder (no entry).
enum NewChatWorkspace: Hashable {
    /// A worktree is created when the first message is sent.
    case newWorktree
    /// A worktree picked from the repository, or one already created for a send that did not go out.
    case worktree(ChatWorktree)
}

/// A worktree whose chat was archived or deleted; the user decides whether it goes.
struct WorktreeRemovalOffer: Identifiable, Equatable {
    let chatTitle: String
    let worktree: ChatWorktree
    let projectPath: String
    var id: String { worktree.path }
}

enum WorktreeText {
    static let symbol = "square.on.square"

    static func choice(_ workspace: NewChatWorkspace?, language: AppLanguage = L10n.language) -> String {
        switch workspace {
        case nil: return L10n.text("В папке проекта", "In project folder", language: language)
        case .newWorktree: return L10n.text("В новой копии (worktree)", "In a new worktree", language: language)
        case .worktree(let worktree): return name(worktree)
        }
    }

    static func name(_ worktree: ChatWorktree) -> String {
        worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent
    }

    static func tooltip(_ worktree: ChatWorktree, language: AppLanguage = L10n.language) -> String {
        L10n.text("Чат работает в своей копии репозитория (worktree): \(worktree.path)",
                  "This chat works in its own worktree: \(worktree.path)", language: language)
    }
}

@MainActor extension DeskModel {
    /// The chat's working folder by ID: `Chat.workingDirectory(in:)` for that chat; nil when the chat or its
    /// project is gone.
    func workingDirectory(forChat id: String) -> String? {
        guard let chat = state.chats.first(where: { $0.id == id }),
              let project = state.projects.first(where: { $0.id == chat.projectID }) else { return nil }
        return chat.workingDirectory(in: project)
    }

    /// The selected chat's folder, or the selected project's folder for a new chat.
    var selectedWorkingDirectory: String? {
        chatID.flatMap(workingDirectory(forChat:)) ?? selectedProject?.path
    }

    /// Folders whose git status the window shows: the sidebar's projects and the worktrees of their active chats.
    var trackedGitPaths: [String] {
        let projects = state.visibleProjects
        let ids = Set(projects.map(\.id))
        let worktrees = state.chats.compactMap { chat in
            !chat.isArchived && ids.contains(chat.projectID) ? chat.worktree?.workingDirectory : nil
        }
        return projects.map(\.path) + worktrees
    }

    /// The worktree for a new chat's first message: created now when "new worktree" is chosen (once; a send that
    /// fails afterwards reuses it), the picked one, or nil for the project folder. A git failure is shown and
    /// returns `.failed`, so the message is not sent.
    func worktreeForNewChat(_ project: Project) async -> (worktree: ChatWorktree?, failed: Bool) {
        switch newChatWorkspaces[project.id] {
        case nil: return (nil, false)
        case .worktree(let worktree): return (worktree, false)
        case .newWorktree:
            creatingWorktree = true
            defer { creatingWorktree = false }
            let engine = worktrees, path = project.path
            let outcome = await Task.detached { () async -> Result<ChatWorktree, GitWorktrees.Failure> in
                do { return .success(try await engine.create(projectPath: path)) } catch {
                    return .failure(error as? GitWorktrees.Failure ?? GitWorktrees.Failure(error.localizedDescription))
                }
            }.value
            switch outcome {
            case .success(let created):
                worktreeLog.info("Created worktree \(created.path, privacy: .public) on \(created.branch ?? "-", privacy: .public)")
                newChatWorkspaces[project.id] = .worktree(created)
                return (created, false)
            case .failure(let failure):
                self.error = L10n.text("Не удалось создать worktree: ", "Could not create the worktree: ") + failure.message
                return (nil, true)
            }
        }
    }

    /// The new chat took its worktree: the next new chat in the project starts in the project folder again.
    func consumeNewChatWorktree(_ worktree: ChatWorktree, project: UUID) {
        if case .worktree(let pending) = newChatWorkspaces[project], pending == worktree { newChatWorkspaces[project] = nil }
    }

    /// Existing worktrees of the project's repository for the composer's choice; empty outside a repository.
    func existingWorktrees(_ project: Project) async -> [ChatWorktree] {
        let engine = worktrees, path = project.path
        let listed = await Task.detached { () async -> [ChatWorktree] in (try? await engine.list(projectPath: path)) ?? [] }.value
        let used = Set(state.chats.compactMap { $0.worktree?.path })
        return listed.filter { !used.contains($0.path) }
    }

    /// Renames an app-created worktree branch to the chat title's slug, once, after the title exists and while the
    /// chat is idle; a running turn defers it to the turn's end.
    func settleWorktreeBranch(_ id: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == id }), let worktree = state.chats[index].worktree,
              worktree.existing != true, worktree.branchSettled != true, !isBusy(threadID: id), !isSending(threadID: id) else { return }
        let title = state.chats[index].title
        guard !AppLanguage.allCases.contains(where: { ChatTitle.placeholder(language: $0) == title }) else { return }
        state.chats[index].worktree?.branchSettled = true
        persist()
        let engine = worktrees
        Task {
            let (settled, problem) = await Task.detached { await engine.settleBranch(worktree, title: title) }.value
            if let problem { worktreeLog.error("Worktree branch kept for chat \(id, privacy: .public): \(problem, privacy: .public)") }
            guard let index = state.chats.firstIndex(where: { $0.id == id }), state.chats[index].worktree?.path == worktree.path,
                  state.chats[index].worktree?.branch != settled.branch else { return }
            state.chats[index].worktree?.branch = settled.branch
            persist()
            gitStatus.refresh(worktree.workingDirectory)
        }
    }

    /// After archiving or deleting a chat: offers to remove its worktree when the app created it under its own
    /// folder, it still exists and no other chat uses it.
    func offerWorktreeRemoval(_ chat: Chat) {
        guard let worktree = chat.worktree, worktrees.contains(worktree.path),
              FileManager.default.fileExists(atPath: worktree.path),
              !state.chats.contains(where: { $0.id != chat.id && $0.worktree?.path == worktree.path }),
              !worktreeRemovalOffers.contains(where: { $0.worktree.path == worktree.path }),
              let project = state.projects.first(where: { $0.id == chat.projectID }) else { return }
        worktreeRemovalOffers.append(WorktreeRemovalOffer(chatTitle: chat.title, worktree: worktree, projectPath: project.path))
    }

    func answerWorktreeRemoval(_ offer: WorktreeRemovalOffer, remove: Bool) {
        worktreeRemovalOffers.removeAll { $0.id == offer.id }
        guard remove else { return }
        let engine = worktrees
        Task {
            let outcome = await Task.detached { await engine.remove(offer.worktree, projectPath: offer.projectPath) }.value
            switch outcome {
            case .removed:
                worktreeLog.info("Removed worktree \(offer.worktree.path, privacy: .public)")
                gitStatus.refresh(offer.projectPath)
            case .keptWithChanges(let detail):
                error = L10n.text("В worktree есть незакоммиченные изменения, он оставлен: \(offer.worktree.path)",
                                  "The worktree has uncommitted changes and was kept: \(offer.worktree.path)") + "\n" + detail
            case .refused(let detail):
                error = L10n.text("Worktree не удалён: ", "The worktree was not removed: ") + detail
            }
        }
    }

    func revealWorktree(_ worktree: ChatWorktree) {
        if FileManager.default.fileExists(atPath: worktree.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
        } else {
            error = L10n.text("Папка worktree не найдена: \(worktree.path)", "The worktree folder was not found: \(worktree.path)")
        }
    }
}

/// For a new chat in a git project: work in the project folder, a new worktree or an existing one.
struct NewChatWorkspaceChip: View {
    @ObservedObject var model: DeskModel
    let project: Project
    @State private var existing: [ChatWorktree] = []

    var body: some View {
        let selection = model.newChatWorkspaces[project.id]
        ChipMenu(title: WorktreeText.choice(selection), systemImage: selection == nil ? "folder" : WorktreeText.symbol) {
            option(nil)
            option(.newWorktree)
            if case .worktree(let pending) = selection, !existing.contains(pending) { option(.worktree(pending)) }
            if !existing.isEmpty {
                Menu(L10n.text("Существующий worktree", "Existing worktree")) {
                    ForEach(existing, id: \.path) { worktree in option(.worktree(worktree)).help(worktree.path) }
                }
            }
        }
        .disabled(model.sending || model.creatingWorktree)
        .help(L10n.text("Где будет работать новый чат. Новая копия (worktree) создаётся в ~/.switchboard/worktrees на отдельной ветке switchboard/… от текущей ветки проекта, когда уйдёт первое сообщение.",
                        "Where the new chat works. A new worktree is created in ~/.switchboard/worktrees on its own switchboard/… branch from the project's current branch when the first message is sent."))
        .task(id: project.path) { existing = await model.existingWorktrees(project) }
    }

    private func option(_ workspace: NewChatWorkspace?) -> some View {
        Toggle(WorktreeText.choice(workspace), isOn: Binding(
            get: { model.newChatWorkspaces[project.id] == workspace },
            set: { if $0 { model.newChatWorkspaces[project.id] = workspace } }))
    }
}

/// Asks once per archived or deleted chat whether its worktree goes; git refuses a worktree with changes.
struct WorktreeRemovalAlert: ViewModifier {
    @ObservedObject var model: DeskModel

    func body(content: Content) -> some View {
        let offer = model.worktreeRemovalOffers.first
        content.alert(L10n.text("Удалить worktree чата?", "Remove the chat's worktree?"),
                      isPresented: Binding(get: { offer != nil }, set: { if !$0, let offer { model.answerWorktreeRemoval(offer, remove: false) } }),
                      presenting: offer) { offer in
            Button(L10n.text("Удалить worktree", "Remove worktree"), role: .destructive) { model.answerWorktreeRemoval(offer, remove: true) }
            Button(L10n.text("Оставить", "Keep"), role: .cancel) { model.answerWorktreeRemoval(offer, remove: false) }
        } message: { offer in
            let branch = offer.worktree.branch.map { L10n.text(" Ветка \($0) остаётся в репозитории.", " The branch \($0) stays in the repository.") } ?? ""
            Text(L10n.text("Чат «\(offer.chatTitle)» работал в \(offer.worktree.path). Папка удаляется командой git worktree remove без --force: если в ней есть незакоммиченные изменения, она останется.",
                           "The chat “\(offer.chatTitle)” worked in \(offer.worktree.path). The folder is removed with git worktree remove without --force: if it has uncommitted changes, it stays.") + branch)
        }
    }
}
