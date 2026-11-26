import ContextTranscript
import SwiftUI
import ContextCore

struct ArchiveView: View {
    @ObservedObject var model: DeskModel
    @State private var search = ""
    @State private var summary: ArchiveSummaryRecord?
    /// Narrows the list and the search to one project; nil shows every project.
    @State private var projectFilter: UUID?
    /// Chats whose messages match the search, with a snippet, from the local chat index, and the search they answer.
    @State private var textMatches: (query: String, matches: [String: String]) = ("", [:])
    @State private var matchesRevision = 0
    @State private var cache = ListingCache()
    /// Position of the first chat the list holds; the window of `windowSize` chats moves while scrolling (`page`).
    @State private var windowStart = 0
    /// Set while the window moves and the list scrolls back to the row it showed, so the edge rows do not move it again.
    @State private var shifting = false

    /// Everything the list needs, computed once per render: the archive can hold hundreds of chats,
    /// and the body reruns on every model change.
    struct Listing {
        var chats: [Chat] = []
        /// Active chats matching the search, so a chat that was never archived is still found.
        var active: [Chat] = []
        var projects: [UUID: Project] = [:]
        /// Message snippets of chats found by their text rather than their title or project.
        var snippets: [String: String] = [:]
        /// Archived chats per project, independent of the search.
        var counts: [UUID: Int] = [:]
        var total = 0
        /// Archived chats without a summary, across the whole archive.
        var missing = 0
        var shownMissing = false
        var canSummarizeShown = false
    }

    nonisolated static func listing(_ state: SavedState, project filter: UUID?, search: String, textMatches: [String: String] = [:]) -> Listing {
        var result = Listing()
        // One pass over the chats instead of one per project; positions, so no chat is copied before it matches.
        var archivedByProject: [UUID: [Int]] = [:], activeByProject: [UUID: [Int]] = [:]
        for (position, chat) in state.chats.enumerated() {
            if chat.isArchived { archivedByProject[chat.projectID, default: []].append(position) }
            else if !search.isEmpty, filter == nil || filter == chat.projectID, !chat.isScheduledRecord, chat.chatSearch != true {
                activeByProject[chat.projectID, default: []].append(position)
            }
        }
        for project in state.projects {
            result.projects[project.id] = project
            let archived = archivedByProject[project.id] ?? []
            result.counts[project.id] = archived.count
            result.total += archived.count
            guard filter == nil || filter == project.id else { continue }
            let projectMatches = search.isEmpty || project.name.localizedCaseInsensitiveContains(search)
                || project.path.localizedCaseInsensitiveContains(search)
            func matching(_ positions: [Int]) -> [Chat] {
                positions.compactMap { position in
                    let chat = state.chats[position]
                    if projectMatches || chat.title.localizedCaseInsensitiveContains(search) { return chat }
                    guard let snippet = textMatches[chat.id] else { return nil }
                    result.snippets[chat.id] = snippet
                    return chat
                }.sorted(by: sidebarOrder)
            }
            result.chats += matching(archived)
            if !search.isEmpty { result.active += matching(activeByProject[project.id] ?? []) }
        }
        return result
    }

    /// `SavedState.orderedChats`' order: saved sidebar positions, new chats above them, otherwise newest first.
    nonisolated static func sidebarOrder(_ a: Chat, _ b: Chat) -> Bool {
        switch (a.sidebarOrder, b.sidebarOrder) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return true
        case (_?, nil): return false
        default: return a.updated == b.updated ? a.id < b.id : a.updated > b.updated
        }
    }

    /// The last listing and what it was built from; a class, so reusing it during a body run changes no view state.
    private final class ListingCache {
        struct Key: Equatable { let state: Int; let filter: UUID?; let search: String; let matches: Int }
        var key: Key?
        var listing = Listing()
    }

    private func makeListing() -> Listing {
        // Model publications that leave the chats alone (streaming in another chat) reuse the last listing.
        let key = ListingCache.Key(state: model.state.listingFingerprint, filter: projectFilter, search: search, matches: matchesRevision)
        if cache.key != key {
            cache.key = key
            cache.listing = Self.listing(model.state, project: projectFilter, search: search,
                                         textMatches: search.isEmpty || textMatches.query != search ? [:] : textMatches.matches)
        }
        var result = cache.listing
        // The same chats `queueMissingArchiveSummaries` queues: every archived one, not just the search results.
        result.missing = model.state.chats.count(where: { $0.isArchived && model.supportsSummaries($0) && model.archiveSummaries[$0.id] == nil })
        for chat in result.chats where model.archiveSummaries[chat.id] == nil {
            result.shownMissing = true
            if model.canGenerateSummary(chat) { result.canSummarizeShown = true; break }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if model.archiveViewingChat { model.archiveViewingChat = false }
                    else { model.closeArchive() }
                } label: {
                    Label(model.archiveViewingChat ? L10n.text("К архиву", "Back to archive") : L10n.text("Вернуться", "Back"), systemImage: "chevron.left")
                }.buttonStyle(DeskButtonStyle())
                Spacer()
                Label(L10n.text("Архив чатов", "Chat archive"), systemImage: "archivebox").font(.ui(.headline))
                if !model.archiveViewingChat {
                    Text(Self.chatCount(model.state.chats.count(where: \.isArchived))).font(.ui(.callout)).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding()
            Divider()
            if model.archiveViewingChat && model.selectedChatIsArchived {
                ChatView(model: model)
            } else {
                // Built only for the list: while an archived chat is open, the body reruns on every streamed event.
                let listing = makeListing()
                HStack {
                    DeskSearchField(prompt: projectFilter.flatMap { listing.projects[$0] }.map { L10n.text("Найти чат в проекте \($0.name)", "Find a chat in \($0.name)") }
                                    ?? L10n.text("Найти чат или проект", "Find a chat or project"), text: $search)
                    if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            Task { await model.startChatSearch(query: search, projectID: projectFilter) }
                        } label: {
                            Label(L10n.text("Найти с агентом", "Find with agent"), systemImage: "sparkle.magnifyingglass")
                        }.buttonStyle(DeskButtonStyle()).disabled(!model.canStartChatSearch)
                            .help(model.canStartChatSearch
                                  ? L10n.text("Открыть чат Claude, который ищет по смыслу, синонимам и датам. Использует модель и лимиты аккаунта Claude.",
                                              "Open a Claude chat that searches by meaning, synonyms and dates. Uses the model and your Claude allowance.")
                                  : L10n.text("Подключи Claude, чтобы искать с агентом.", "Connect Claude to search with an agent."))
                    }
                }.padding([.horizontal, .top])
                    .task(id: search) {
                        // Debounced: the index query runs after typing pauses.
                        let query = search
                        guard !query.isEmpty else { textMatches = ("", [:]); matchesRevision &+= 1; return }
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        let matches = await model.chatTextMatches(query)
                        // A newer search replaced this one while it ran: its matches would show under other text.
                        guard !Task.isCancelled, query == search else { return }
                        textMatches = (query, matches); matchesRevision &+= 1
                    }
                projectChips(listing)
                if listing.missing > 0, listing.shownMissing {
                    Button(Self.summarizeTitle(listing.missing)) {
                        Task { await model.queueMissingArchiveSummaries() }
                    }.buttonStyle(DeskButtonStyle()).disabled(!listing.canSummarizeShown)
                        .help(L10n.text("Создать краткие итоги для архива. Использует модель и лимиты твоего аккаунта.", "Create compact archive summaries. Uses your model and account allowance."))
                        .padding(.bottom, 10)
                }
                if listing.chats.isEmpty && listing.active.isEmpty {
                    EmptyState(icon: "archivebox", title: search.isEmpty ? L10n.text("Архив пуст", "Archive is empty") : L10n.text("Ничего не найдено", "No results"),
                               text: search.isEmpty ? L10n.text("Архивные чаты всех проектов появятся здесь.", "Archived chats from all projects will appear here.") : L10n.text("Попробуй другие слова или «Найти с агентом»: он учитывает синонимы и даты.", "Try other words or \"Find with agent\": it understands synonyms and dates."))
                } else {
                    let page = Self.page(listing, start: windowStart, size: Self.windowSize, searching: !search.isEmpty)
                    // A `List` reuses the rows that scroll out of view, and it never holds more than `windowSize` chats:
                    // reaching an edge moves the window by `windowStep` and scrolls back to the row that was at that edge.
                    ScrollViewReader { proxy in
                        List {
                            if page.hasBefore {
                                edgeRow { moveWindow(to: page.start - Self.windowStep, anchor: page.entries.first?.id, edge: .top, proxy) }
                            }
                            ForEach(page.entries) { entry in
                                entryView(entry, listing)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                            if page.hasAfter {
                                edgeRow { moveWindow(to: page.start + Self.windowStep, anchor: page.entries.last?.id, edge: .bottom, proxy) }
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                            .environment(\.defaultMinListRowHeight, 0)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // A new search or project starts from the first page again.
            .onChange(of: search) { windowStart = 0 }
            .onChange(of: projectFilter) { windowStart = 0 }
            .sheet(item: $summary) { record in
                ArchiveSummaryDetail(record: record) {
                    summary = nil
                    if let chat = model.state.chats.first(where: { $0.id == record.threadID }) {
                        Task { await model.openChat(chat) }
                    }
                }
            }
    }

    private func projectChips(_ listing: Listing) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ProjectChip(title: L10n.text("Все", "All"), count: listing.total, selected: projectFilter == nil) { projectFilter = nil }
                ForEach(model.state.projects.filter { listing.counts[$0.id, default: 0] > 0 }) { project in
                    ProjectChip(title: project.name, count: listing.counts[project.id, default: 0], selected: projectFilter == project.id) {
                        projectFilter = projectFilter == project.id ? nil : project.id
                    }.help(project.path)
                }
            }.padding(.horizontal).padding(.vertical, 10)
        }
    }

    /// The most chats the list holds at once.
    static let windowSize = 100
    /// How far the window moves when the list reaches one of its edges.
    static let windowStep = 50

    private func edgeRow(_ reached: @escaping () -> Void) -> some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            .onAppear { if !shifting { reached() } }
    }

    private func moveWindow(to start: Int, anchor: Entry.ID?, edge: UnitPoint, _ proxy: ScrollViewProxy) {
        shifting = true
        windowStart = max(0, start)
        // After the rows change, keep the row that was at the edge where it was on screen.
        DispatchQueue.main.async {
            if let anchor { proxy.scrollTo(anchor, anchor: edge) }
            DispatchQueue.main.async { shifting = false }
        }
    }

    /// One row of the archive list: a section title or a chat.
    enum Entry: Identifiable, Equatable {
        case section(String, count: Int)
        case archived(Chat)
        case active(Chat)

        var id: String {
            switch self {
            case let .section(title, _): "section:" + title
            case let .archived(chat): "archived:" + chat.id
            case let .active(chat): "active:" + chat.id
            }
        }
    }

    struct Page: Equatable {
        var entries: [Entry] = []
        /// Position of the first chat, after clamping to the listing.
        var start = 0
        var hasBefore = false
        var hasAfter = false
    }

    /// Up to `size` chats from position `start` of the listing (archived ones first, then active ones), with each
    /// section title while searching when its first chat is in the window. Titles keep the full counts.
    nonisolated static func page(_ listing: Listing, start: Int, size: Int, searching: Bool) -> Page {
        let archivedCount = listing.chats.count, total = archivedCount + listing.active.count
        var page = Page()
        page.start = max(0, min(start, total - size))
        let end = min(total, page.start + size)
        page.hasBefore = page.start > 0
        page.hasAfter = end < total
        if searching, page.start == 0, total > 0 {
            page.entries.append(.section(L10n.text("В архиве", "Archived"), count: archivedCount))
        }
        for position in page.start..<end {
            if position < archivedCount {
                page.entries.append(.archived(listing.chats[position]))
            } else {
                if position == archivedCount {
                    page.entries.append(.section(L10n.text("Не в архиве", "Not archived"), count: listing.active.count))
                }
                page.entries.append(.active(listing.active[position - archivedCount]))
            }
        }
        return page
    }

    @ViewBuilder private func entryView(_ entry: Entry, _ listing: Listing) -> some View {
        switch entry {
        case let .section(title, count):
            Text("\(title) · \(count)").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
        case let .archived(chat):
            ArchiveChatRow(content: rowContent(chat, listing, archived: true), actions: rowActions(chat)).equatable()
        case let .active(chat):
            ArchiveChatRow(content: rowContent(chat, listing, archived: false), actions: rowActions(chat)).equatable()
        }
    }

    private func rowContent(_ chat: Chat, _ listing: Listing, archived: Bool) -> ArchiveChatRow.Content {
        let project = listing.projects[chat.projectID]
        return ArchiveChatRow.Content(
            chat: chat, archived: archived, projectName: project?.name, projectPath: project?.path, snippet: listing.snippets[chat.id],
            summary: archived ? model.archiveSummaries[chat.id] : nil, changing: archived && model.isChangingChat(chat.id),
            canRestore: archived && model.canDeleteChat(chat.id), canGenerate: archived && model.canGenerateSummary(chat))
    }

    private func rowActions(_ chat: Chat) -> ArchiveChatRow.Actions {
        let model = model
        return ArchiveChatRow.Actions(
            open: { Task { await model.openChat(chat) } },
            showSummary: { summary = $0 },
            retrySummary: { Task { await model.retryArchiveSummary(chat.id) } },
            restore: { Task { await model.setChatArchived(chat.id, archived: false) } })
    }

    nonisolated static func chatCount(_ count: Int, language: AppLanguage = L10n.language) -> String {
        let tens = count % 100, ones = count % 10
        let russian = (11...14).contains(tens) ? "чатов" : ones == 1 ? "чат" : (2...4).contains(ones) ? "чата" : "чатов"
        return L10n.text("\(count) \(russian)", count == 1 ? "1 chat" : "\(count) chats", language: language)
    }

    static func summarizeTitle(_ count: Int) -> String {
        // Genitive after "итоги": 1, 21, 31… take the singular, every other number the plural.
        let singular = count % 10 == 1 && count % 100 != 11
        return L10n.text(singular ? "Подготовить итоги \(count) архивного чата" : "Подготовить итоги \(count) архивных чатов",
                         count == 1 ? "Summarize 1 archived chat" : "Summarize \(count) archived chats")
    }
}

extension SavedState {
    /// Hash of what the archive and the command palette list and order by: projects (name, path, hidden) and chats
    /// (project, title, archive state, sidebar order, last activity, kind). A list built from an equal value can be
    /// reused; hashing about a thousand chats costs a fraction of building the list again.
    var listingFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(projects.count)
        for project in projects {
            hasher.combine(project.id); hasher.combine(project.name); hasher.combine(project.path); hasher.combine(project.isHidden)
        }
        hasher.combine(chats.count)
        for chat in chats {
            hasher.combine(chat.id); hasher.combine(chat.projectID); hasher.combine(chat.title); hasher.combine(chat.isArchived)
            hasher.combine(chat.sidebarOrder); hasher.combine(chat.updated); hasher.combine(chat.isScheduledRecord); hasher.combine(chat.chatSearch)
        }
        return hasher.finalize()
    }
}

/// One chat in the archive list, rendered from values only: a model publication that changes none of them
/// (streaming in another chat) skips the row.
private struct ArchiveChatRow: View, Equatable {
    struct Content: Equatable {
        let chat: Chat
        /// false: an active chat found by the search; it only opens.
        let archived: Bool
        let projectName: String?
        let projectPath: String?
        let snippet: String?
        let summary: ArchiveSummaryRecord?
        let changing: Bool
        let canRestore: Bool
        let canGenerate: Bool
    }

    struct Actions {
        let open: () -> Void
        let showSummary: (ArchiveSummaryRecord) -> Void
        let retrySummary: () -> Void
        let restore: () -> Void
    }

    let content: Content
    let actions: Actions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content }

    var body: some View {
        let chat = content.chat
        HStack(spacing: 16) {
            Button(action: actions.open) { details }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .disabled(content.changing)
            if let record = content.summary {
                VStack(alignment: .trailing, spacing: 6) {
                    if record.status == .ready {
                        Button(record.status.label()) { actions.showSummary(record) }.buttonStyle(DeskButtonStyle())
                    } else {
                        Text(record.status.label()).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    if [.failed, .uncertain, .stale].contains(record.status) {
                        Button(L10n.text("Создать итог заново", "Generate summary again"), action: actions.retrySummary)
                            .buttonStyle(DeskButtonStyle()).disabled(!content.canGenerate || content.changing)
                        if record.status == .uncertain {
                            Text(L10n.text("Прошлый запрос мог выполниться. Новый использует лимиты повторно.", "The previous request may have completed. A new one uses allowance again."))
                                .font(.ui(.caption2)).foregroundStyle(.secondary).frame(maxWidth: 220)
                        }
                    }
                }.help(record.issue ?? record.status.label())
            }
            if content.archived {
                Button(L10n.text("Восстановить", "Restore"), action: actions.restore)
                    .buttonStyle(DeskButtonStyle(kind: .text)).disabled(!content.canRestore)
            }
        }.padding(16).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .contextMenu {
                Button(L10n.text("Скопировать ID чата", "Copy chat ID")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ChatReference.link(chat), forType: .string)
                }
                Button(L10n.text("Скопировать ссылку на чат для агента", "Copy chat reference for an agent")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ChatReference.text(chat, projectPath: content.projectPath), forType: .string)
                }
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(content.chat.title).font(.ui(.headline)).lineLimit(2)
            if let snippet = content.snippet {
                Text(snippet).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let name = content.projectName, let path = content.projectPath {
                Text(name + " · " + L10n.date(content.chat.updated)).font(.ui(.caption)).foregroundStyle(.secondary)
                Text(path).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

/// A project filter in the archive: name and archived-chat count, highlighted while selected.
private struct ProjectChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Text(String(count)).foregroundStyle(.secondary).monospacedDigit()
            }.font(.ui(.callout)).padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? DeskPalette.selection : hovering ? DeskPalette.rowHover : DeskPalette.subtle, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(PointerButtonStyle(base: .plain)).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ArchiveSummaryDetail: View {
    let record: ArchiveSummaryRecord
    let openSource: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("Краткий итог чата", "Conversation summary")).font(.ui(.title2))
                Spacer()
                Button(L10n.text("Готово", "Done")) { dismiss() }.buttonStyle(DeskButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if record.omittedDetails {
                        Text(L10n.text("Длинные результаты инструментов сокращены; вложения не анализировались.", "Long tool results were shortened; attachments were not analyzed."))
                            .font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(record.parts.enumerated()), id: \.offset) { _, part in
                        Text(part.content.overview)
                        ForEach(Array(part.content.activities.enumerated()), id: \.offset) { _, activity in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(activity.goal).font(.ui(.headline))
                                lines(L10n.text("Действия", "Actions"), activity.actions)
                                if !activity.outcome.isEmpty { Text(activity.outcome) }
                                lines(L10n.text("Осталось", "Unfinished"), activity.unfinished)
                                lines(L10n.text("Повторяемые шаги", "Reusable steps"), activity.reusableSteps)
                                lines(L10n.text("Переменные данные", "Variable inputs"), activity.variableInputs)
                                Text(L10n.text("Ссылок на исходные сообщения: \(activity.evidence.count)", "Source references: \(activity.evidence.count)"))
                                    .font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Button(L10n.text("Открыть исходный чат", "Open source conversation"), action: openSource).buttonStyle(DeskButtonStyle())
        }.padding(24).frame(width: 640, height: 580)
    }

    @ViewBuilder private func lines(_ label: String, _ values: [String]) -> some View {
        if !values.isEmpty { Text(label + ": " + values.joined(separator: "; ")) }
    }
}
