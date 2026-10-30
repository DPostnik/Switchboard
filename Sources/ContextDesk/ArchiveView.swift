import ContextTranscript
import SwiftUI
import ContextCore

struct ArchiveView: View {
    @ObservedObject var model: DeskModel
    @State private var search = ""
    @State private var summary: ArchiveSummaryRecord?
    /// Narrows the list and the search to one project; nil shows every project.
    @State private var projectFilter: UUID?
    /// Chats whose messages match the search, with a snippet, from the local chat index.
    @State private var textMatches: [String: String] = [:]

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
        for project in state.projects {
            result.projects[project.id] = project
            let archived = state.orderedChats(projectID: project.id, archived: true)
            result.counts[project.id] = archived.count
            result.total += archived.count
            guard filter == nil || filter == project.id else { continue }
            let projectMatches = search.isEmpty || project.name.localizedCaseInsensitiveContains(search)
                || project.path.localizedCaseInsensitiveContains(search)
            func matches(_ chat: Chat) -> Bool {
                if projectMatches || chat.title.localizedCaseInsensitiveContains(search) { return true }
                guard let snippet = textMatches[chat.id] else { return false }
                result.snippets[chat.id] = snippet
                return true
            }
            result.chats += archived.filter(matches)
            if !search.isEmpty {
                result.active += state.orderedChats(projectID: project.id, archived: false).filter { !$0.isScheduledRecord && $0.chatSearch != true && matches($0) }
            }
        }
        return result
    }

    private func makeListing() -> Listing {
        var result = Self.listing(model.state, project: projectFilter, search: search, textMatches: search.isEmpty ? [:] : textMatches)
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
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(projectFilter.flatMap { listing.projects[$0] }.map { L10n.text("Найти чат в проекте \($0.name)", "Find a chat in \($0.name)") }
                              ?? L10n.text("Найти чат или проект", "Find a chat or project"), text: $search)
                        .textFieldStyle(.roundedBorder)
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
                        guard !search.isEmpty else { textMatches = [:]; return }
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        textMatches = await model.chatTextMatches(search)
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if !search.isEmpty {
                                sectionTitle(L10n.text("В архиве", "Archived"), count: listing.chats.count)
                            }
                            ForEach(listing.chats) { chat in archivedRow(chat, listing) }
                            if !listing.active.isEmpty {
                                sectionTitle(L10n.text("Не в архиве", "Not archived"), count: listing.active.count).padding(.top, 6)
                                ForEach(listing.active) { chat in
                                    Button { Task { await model.openChat(chat) } } label: { chatSummary(chat, listing) }
                                        .buttonStyle(PointerButtonStyle(base: .plain))
                                        .padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)").font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
    }

    private func chatSummary(_ chat: Chat, _ listing: Listing) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(chat.title).font(.ui(.headline)).lineLimit(2)
            if let snippet = listing.snippets[chat.id] {
                Text(snippet).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let project = listing.projects[chat.projectID] {
                Text(project.name + " · " + L10n.date(chat.updated)).font(.ui(.caption)).foregroundStyle(.secondary)
                Text(project.path).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func archivedRow(_ chat: Chat, _ listing: Listing) -> some View {
        HStack(spacing: 16) {
            Button { Task { await model.openChat(chat) } } label: { chatSummary(chat, listing) }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .disabled(model.isChangingChat(chat.id))
            if let record = model.archiveSummaries[chat.id] {
                VStack(alignment: .trailing, spacing: 6) {
                    if record.status == .ready {
                        Button(record.status.label()) { summary = record }.buttonStyle(DeskButtonStyle())
                    } else {
                        Text(record.status.label()).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    if [.failed, .uncertain, .stale].contains(record.status) {
                        Button(L10n.text("Создать итог заново", "Generate summary again")) {
                            Task { await model.retryArchiveSummary(chat.id) }
                        }.buttonStyle(DeskButtonStyle()).disabled(!model.canGenerateSummary(chat) || model.isChangingChat(chat.id))
                        if record.status == .uncertain {
                            Text(L10n.text("Прошлый запрос мог выполниться. Новый использует лимиты повторно.", "The previous request may have completed. A new one uses allowance again."))
                                .font(.ui(.caption2)).foregroundStyle(.secondary).frame(maxWidth: 220)
                        }
                    }
                }.help(record.issue ?? record.status.label())
            }
            Button(L10n.text("Восстановить", "Restore")) {
                Task { await model.setChatArchived(chat.id, archived: false) }
            }.buttonStyle(DeskButtonStyle()).disabled(!model.canDeleteChat(chat.id))
        }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
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
