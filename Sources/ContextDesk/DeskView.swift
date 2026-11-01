import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ContextCore
import ContextTranscript

struct DeskView: View {
    @ObservedObject var model: DeskModel
    @State private var search = ""
    @State private var renaming: Chat?
    @State private var renamingProject: Project?
    @State private var newProjectName = ""
    @State private var permissionsProject: Project?
    @State private var deleting: Chat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargetProjectID: UUID?
    @State private var dropTargetChatID: String?
    /// Sidebar row whose context menu is open; it stays marked until the menu closes.
    @State private var menuRowID: String?
    /// Hover sources per sidebar row: the native row itself, and `#tools` for a project's trailing buttons.
    @State private var rowHover = SidebarHover()
    /// Sidebar row under a held mouse button; it shows the selection fill before the click completes.
    @State private var pressedRowID: String?
    @State private var expandedProjects: Set<UUID> = []
    @State private var collapsedSearchProjects: Set<UUID> = []
    @State private var visibleChatCounts: [UUID: Int] = [:]
    @State private var selection = ChatSelection()
    @State private var archivingSelection = false
    private let chatPageSize = 5
    private var sidebarAnimation: Animation? { DeskMotion.standard(reduceMotion) }
    @State private var newTitle = ""
    @State private var showingLimits = false
    @State private var limitsPlacement = PopoverPlacement.fallback
    @State private var limitsAnchor = ScreenFrameProbe()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The sidebar state before a document preview was expanded, restored when it collapses.
    @State private var sidebarBeforeDocument: NavigationSplitViewVisibility?
    @State private var sidebarViewportHeight: CGFloat = 0
    @State private var sidebarContentHeight: CGFloat = 0
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // The system toggle lives in the sidebar column (and moves into the detail toolbar when the
            // sidebar is hidden); removing it only on the split view left it next to our own button.
            sidebar.toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .background(DeskPalette.canvas)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(DeskMotion.standard(reduceMotion)) { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .help(L10n.text("Показать или скрыть боковую панель", "Show or hide sidebar"))
                .accessibilityLabel(L10n.text("Показать или скрыть боковую панель", "Show or hide sidebar"))
            }
        }
        .tint(DeskPalette.accent)
        .onChange(of: model.projectID, initial: true) { _, projectID in
            if let projectID { expandedProjects.insert(projectID) }
        }
        .onChange(of: search) { _, _ in
            collapsedSearchProjects.removeAll()
        }
        .onChange(of: model.chatID) { _, _ in
            revealSelectedChat()
        }
        .onChange(of: model.documentExpanded) { _, expanded in
            withAnimation(DeskMotion.standard(reduceMotion)) {
                if expanded {
                    sidebarBeforeDocument = columnVisibility
                    columnVisibility = .detailOnly
                } else if let previous = sidebarBeforeDocument {
                    columnVisibility = previous
                    sidebarBeforeDocument = nil
                }
            }
        }
        .onChange(of: activeChatIDs) { _, ids in
            selection.prune(keeping: ids)
        }
        .sheet(item: $permissionsProject) { project in ProjectSettingsView(model: model, project: project) }
        .alert(L10n.text("Название чата", "Chat title"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.text("Название", "Title"), text: $newTitle)
            Button(L10n.text("Сохранить", "Save")) { if let chat = renaming { Task { await model.renameChat(chat.id, title: newTitle) } }; renaming = nil }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) { renaming = nil }
        }
        .alert(L10n.text("Название проекта", "Project name"), isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } }), presenting: renamingProject) { project in
            TextField(L10n.text("Название", "Name"), text: $newProjectName)
            Button(L10n.text("Сохранить", "Save")) { model.renameProject(project.id, to: newProjectName); renamingProject = nil }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) { renamingProject = nil }
        } message: { project in
            Text(L10n.text("Меняется только название в списке, папка «\(URL(fileURLWithPath: project.path).lastPathComponent)» остаётся прежней. Пустое название вернёт имя папки.", "Only the name in the list changes; the folder “\(URL(fileURLWithPath: project.path).lastPathComponent)” stays the same. An empty name restores the folder name."))
        }
        .alert(L10n.text("Удалить чат?", "Delete chat?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { chat in
            Button(L10n.text("Удалить", "Delete"), role: .destructive) { Task { await model.deleteChat(chat.id) } }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) { }
        } message: { chat in
            Text(L10n.text("Чат «\(chat.title)» и его сообщения в очереди будут удалены. Отменить это действие нельзя. Файлы проекта останутся на месте.", "The chat “\(chat.title)” and its queued messages will be deleted. This cannot be undone. Project files will be kept."))
        }
    }
    private var sidebar: some View {
            VStack(spacing: .ui(12)) {
                HStack {
                    Text("Switchboard").font(.ui(.headline))
                    Spacer()
                }.padding(.horizontal, .ui(16)).padding(.top, .ui(16))
                DeskSearchField(prompt: L10n.text("Найти проект или чат", "Find a project or chat"), text: $search, clearable: true)
                    .padding(.horizontal, .ui(12))
                needsYouRow.padding(.horizontal, .ui(12))
                ScrollView {
                    VStack(alignment: .leading, spacing: .ui(4)) {
                        if !model.state.visiblePinnedChats.isEmpty {
                            Text(L10n.text("Избранное", "Favorites"))
                                .sidebarSectionHeader()
                            ForEach(model.state.visiblePinnedChats.filter { chat in
                                (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search)
                                    || model.state.projects.contains { $0.id == chat.projectID && ($0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)) })
                            }) { chat in
                                chatEntry(chat, favorite: true)
                            }
                            Divider().padding(.vertical, .ui(6))
                        }
                        projectsHeader
                        ForEach(model.state.visibleProjects.filter { project in
                            search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search) || model.state.chats.contains { $0.projectID == project.id && !$0.isArchived && $0.title.localizedCaseInsensitiveContains(search) }
                        }) { project in
                            projectEntries(project)
                        }
                    }.padding(.horizontal, .ui(12)).padding(.bottom, .ui(8))
                        // Legacy scrollers take layout width only while the list overflows; reserve it otherwise so rows keep their width.
                        .padding(.trailing, sidebarScrollerReserve)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarContentHeight = $0 }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarViewportHeight = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                    scrollerStyle = NSScroller.preferredScrollerStyle
                }
                // The edge line only marks where the list scrolls under the controls below it.
                DeskPalette.border.frame(height: 0.5).opacity(sidebarContentHeight > sidebarViewportHeight ? 1 : 0)
                if !selection.isEmpty { selectionBar.transition(DeskMotion.slide(from: .bottom, reduceMotion)) }
                sidebarDock
            }.background(DeskPalette.sidebar)
                .animation(sidebarAnimation, value: selection.isEmpty)
                .navigationSplitViewColumnWidth(min: .ui(240), ideal: .ui(285), max: .ui(380))
                .background(SidebarWidthLimits(min: .ui(240), ideal: .ui(285), max: .ui(380)))
    }
    /// Everything that waits for the user: waiting chats, unresolved important messages and notifications.
    private var needsYouCount: Int { model.attentionChats.count + model.openAttentionCount + model.notices.count }
    /// The one place for what needs the user; it opens the "Needs you" page. Amber while anything waits.
    private var needsYouRow: some View {
        let count = needsYouCount
        let title = L10n.text("Ждёт тебя", "Needs you")
        return Button { model.openAttention() } label: {
            HStack(spacing: .ui(8)) {
                Image(systemName: count > 0 ? "tray.full.fill" : "tray")
                    .foregroundStyle(count > 0 ? DeskPalette.attention : Color.secondary)
                    .frame(width: .ui(18))
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(.ui(.caption).weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, .ui(7)).padding(.vertical, .ui(1))
                        .background(DeskPalette.attention, in: Capsule())
                        .contentTransition(.numericText())
                }
            }
            .font(.ui(.callout))
            .foregroundStyle(count > 0 ? DeskPalette.attentionInk : DeskPalette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(NeedsYouRowStyle(active: count > 0, selected: model.showingAttention && !model.showingArchive))
        .animation(sidebarAnimation, value: count)
        .help(L10n.text("Чаты, которые ждут тебя, важные сообщения и уведомления", "Chats waiting for you, important messages and notifications"))
        .accessibilityLabel(count > 0 ? "\(title): \(count)" : title)
        .accessibilityAddTraits(model.showingAttention && !model.showingArchive ? .isSelected : [])
    }
    /// "Projects" with the add button at its trailing edge.
    private var projectsHeader: some View {
        HStack(spacing: 0) {
            Text(L10n.text("Проекты", "Projects")).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { model.openProject() } label: {
                Image(systemName: "plus").font(.ui(.caption).weight(.semibold))
            }
            .buttonStyle(SidebarIconButtonStyle(width: .ui(24), height: .ui(22)))
            .help(L10n.text("Добавить проект…", "Add project…"))
            .accessibilityLabel(L10n.text("Добавить проект…", "Add project…"))
        }
        .padding(.leading, .ui(8)).padding(.trailing, .ui(2)).padding(.top, .ui(4)).padding(.bottom, .ui(2))
    }
    /// Pages and status in one row: schedule, archive, usage, settings, then the account.
    private var sidebarDock: some View {
        let jobs = model.showingJobs && !model.showingArchive && !model.showingAttention
        let account = model.currentAgent == .appClaude ? (model.claudeAuthenticated ? L10n.text("Claude · подключён", "Claude · connected") : L10n.text("Claude · вход не выполнен", "Claude · not signed in")) : (model.connecting ? L10n.text("Подключение…", "Connecting…") : model.accountLabel)
        return HStack(spacing: .ui(2)) {
            Button { model.showingArchive = false; model.showingAttention = false; model.showingJobs = true; Task { await model.refreshJobs() } } label: {
                Image(systemName: "calendar")
            }
            .buttonStyle(SidebarIconButtonStyle(selected: jobs))
            .help(L10n.text("По расписанию", "Scheduled jobs"))
            .accessibilityLabel(L10n.text("По расписанию", "Scheduled jobs"))
            .accessibilityAddTraits(jobs ? .isSelected : [])
            Button { model.openArchive() } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(SidebarIconButtonStyle(selected: model.showingArchive))
            .help(L10n.text("Архив", "Archive"))
            .accessibilityLabel(L10n.text("Архив", "Archive"))
            .accessibilityAddTraits(model.showingArchive ? .isSelected : [])
            Button { limitsPlacement = limitsAnchor.placement; showingLimits = true } label: {
                Image(systemName: "chart.bar")
            }
            .buttonStyle(SidebarIconButtonStyle(selected: showingLimits))
            .background(ScreenFrameReader(probe: limitsAnchor))
            .help(L10n.text("Usage и лимиты", "Usage and limits"))
            .accessibilityLabel(L10n.text("Usage и лимиты", "Usage and limits"))
            .popover(isPresented: $showingLimits, arrowEdge: limitsPlacement.edge) {
                AccountLimitsView(model: model, maxListHeight: limitsPlacement.listHeight)
            }
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(SidebarIconButtonStyle())
                .help(L10n.text("Настройки", "Settings"))
                .accessibilityLabel(L10n.text("Настройки", "Settings"))
            Spacer(minLength: .ui(4))
            HStack(spacing: .ui(5)) {
                Circle().fill(!model.currentAgentConnected ? DeskPalette.muted : model.currentAgentAuthenticated ? DeskPalette.accent : DeskPalette.attention)
                    .frame(width: .ui(6), height: .ui(6))
                Text(model.currentAgentName).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, .ui(6))
            .help(account)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(account)
        }
        .padding(.horizontal, .ui(10)).padding(.bottom, .ui(10))
    }
    private var sidebarScrollerReserve: CGFloat {
        guard scrollerStyle == .legacy, sidebarContentHeight <= sidebarViewportHeight else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
    private var detail: some View {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DeskPalette.problem)
                        Text(error).font(.ui(.callout)).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Закрыть", "Close"))
                    }.foregroundStyle(DeskPalette.problemInk).padding(.ui(12)).background(DeskPalette.problemWash, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, .ui(12)).padding(.top, .ui(8))
                        .transition(DeskMotion.slide(from: .top, reduceMotion))
                }
                if model.showingArchive {
                    ArchiveView(model: model)
                } else if model.showingAttention {
                    AttentionView(model: model)
                } else if model.showingJobs {
                    JobsView(model: model)
                } else if model.selectedProject == nil {
                    EmptyState(icon: "folder", title: L10n.text("С каким проектом работаем?", "Which project are we working on?"), text: L10n.text("Проект — это папка на компьютере. Добавь свои проекты, и чаты появятся под каждой папкой слева.", "A project is a folder on your computer. Add your projects, and chats will appear under each folder on the left."))
                    Button(L10n.text("Добавить проект…", "Add project…")) { model.openProject() }.buttonStyle(DeskButtonStyle()).padding(.bottom, .ui(60))
                } else { ChatView(model: model) }
            }.animation(DeskMotion.standard(reduceMotion), value: model.error)
                .navigationTitle(detailTitle)
                .navigationSubtitle(detailSubtitle)
                .toolbarBackground(DeskPalette.canvas, for: .windowToolbar)
                .modifier(ZoomedWindowTitle(title: detailTitle, subtitle: detailSubtitle))
    }
    private var detailTitle: String {
        model.showingArchive ? L10n.text("Архив", "Archive") : model.showingAttention ? L10n.text("Ждёт тебя", "Needs you") : model.showingJobs ? L10n.text("Расписание", "Schedule") : (model.selectedChat?.title ?? L10n.text("Новый чат", "New chat"))
    }
    private var detailSubtitle: String {
        model.showingArchive || model.showingJobs || model.showingAttention ? "" : model.selectedProject?.name ?? ""
    }
    private func adjacentProjectMove(_ project: Project, offset: Int) -> (() -> Void)? {
        let projects = model.state.visibleProjects
        guard let index = projects.firstIndex(where: { $0.id == project.id }),
              projects.indices.contains(index + offset) else { return nil }
        let targetID = projects[index + offset].id
        return { _ = model.moveProject(project.id, to: targetID) }
    }
    /// The "…" menu and the right-click menu of a project row; one list keeps them identical.
    private func projectActions(_ project: Project) -> [SidebarMenuAction] {
        ProjectMenu.actions(path: project.path, hasChats: model.state.chats.contains { $0.projectID == project.id && !$0.isArchived },
                            settings: { permissionsProject = project }, newChat: { startChat(in: project) },
                            rename: { startRenaming(project) },
                            selectAllChats: { selection.select(model.state.orderedChats(projectID: project.id, archived: false).map(\.id)) },
                            remove: { Task { await model.hideProject(project.id) } })
    }
    /// Projects reorder by dragging; VoiceOver gets the same moves as custom actions.
    private func projectReorderActions(_ project: Project) -> [SidebarMenuAction] {
        [(-1, L10n.text("Переместить выше", "Move up")), (1, L10n.text("Переместить ниже", "Move down"))].compactMap { offset, title in
            adjacentProjectMove(project, offset: offset).map { SidebarMenuAction(title: title, perform: $0) }
        }
    }

    @ViewBuilder private func projectEntries(_ project: Project) -> some View {
        let isExpanded = search.isEmpty ? expandedProjects.contains(project.id) : !collapsedSearchProjects.contains(project.id)
        VStack(spacing: 0) {
            HStack(spacing: .ui(2)) {
                ProjectHeader(project: project, expanded: isExpanded, activate: {
                    withAnimation(sidebarAnimation) {
                        if isExpanded {
                            expandedProjects.remove(project.id)
                            if !search.isEmpty { collapsedSearchProjects.insert(project.id) }
                            model.selectProject(project.id)
                        } else {
                            // Reset on opening so collapsing keeps the full content height.
                            visibleChatCounts[project.id] = nil
                            expandedProjects.insert(project.id)
                            collapsedSearchProjects.remove(project.id)
                            model.selectProject(project.id)
                        }
                    }
                }, move: { sourceID in
                    model.moveProject(sourceID, to: project.id)
                }, targeted: { targeted in
                    if targeted { dropTargetProjectID = project.id }
                    else if dropTargetProjectID == project.id { dropTargetProjectID = nil }
                }, actions: projectActions(project), reorder: projectReorderActions(project),
                   menuShown: menuShown("project:\(project.id)"),
                   hovered: hover("project:\(project.id)"), pressed: press("project:\(project.id)")) {
                    HStack(spacing: .ui(9)) {
                        Image(systemName: "chevron.right")
                            .font(.ui(.caption).weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            // This label lives in its own hosting view, so the outer withAnimation does not reach it.
                            .animation(sidebarAnimation, value: isExpanded)
                            .frame(width: .ui(10), height: .ui(16))
                            .foregroundStyle(.secondary)
                        Image(systemName: model.projectID == project.id ? "folder.fill" : "folder")
                        Text(project.name).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 0)
                        let projectChats = model.state.chats.filter { $0.projectID == project.id && !$0.isArchived }
                        if projectChats.contains(where: { chat in model.pending.contains { $0.threadID == chat.id } || model.restartWaitingChatIDs.contains(chat.id) }) {
                            Circle().fill(DeskPalette.attention).frame(width: .ui(7), height: .ui(7))
                                .help(L10n.text("Есть чаты, которые ждут действия или перезапуска", "Chats are waiting for action or a restart"))
                                .accessibilityLabel(L10n.text("Есть чаты, которые ждут действия или перезапуска", "Chats are waiting for action or a restart"))
                        } else if projectChats.contains(where: \.hasUnreadResponse) {
                            Circle().fill(DeskPalette.accent).frame(width: .ui(7), height: .ui(7))
                                .help(L10n.text("Есть непрочитанные ответы", "Unread responses"))
                                .accessibilityLabel(L10n.text("Есть непрочитанные ответы", "Unread responses"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, .ui(8)).padding(.vertical, .ui(4))
                    .contentShape(Rectangle())
                }
                .frame(height: .ui(32))

                HStack(spacing: .ui(2)) {
                    Menu {
                        SidebarMenuItems(actions: projectActions(project))
                    } label: {
                        Image(systemName: "ellipsis").frame(width: .ui(28), height: .ui(28)).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointingHandCursor()
                    .help(L10n.text("Действия проекта", "Project actions"))
                    .accessibilityLabel(L10n.text("Действия проекта: \(project.name)", "Project actions: \(project.name)"))

                    Button { startChat(in: project) } label: {
                        Image(systemName: "square.and.pencil").frame(width: .ui(28), height: .ui(28)).contentShape(Rectangle())
                    }
                    .buttonStyle(PointerButtonStyle(base: .plain))
                    .help(L10n.text("Новый чат в проекте", "New chat in project"))
                    .accessibilityLabel(L10n.text("Новый чат в проекте \(project.name)", "New chat in \(project.name)"))
                }
                .onHover(perform: hover("project:\(project.id)#tools"))
            }
            .padding(.trailing, .ui(4))
            .frame(height: .ui(32))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTargetProjectID == project.id || menuRowID == "project:\(project.id)" ? DeskPalette.accent : .clear, lineWidth: 2).allowsHitTesting(false))
            .background(SidebarRowBackground(hover: rowHover, rowID: "project:\(project.id)", base: pressedRowID == "project:\(project.id)" || model.projectID == project.id && model.chatID == nil && !model.showingJobs && !model.showingAttention && !model.showingArchive ? DeskPalette.selection
                        : rowHighlighted("project:\(project.id)") ? DeskPalette.rowHover : Color.clear))

            SidebarDisclosure(isExpanded: isExpanded, animation: sidebarAnimation) {
                VStack(alignment: .leading, spacing: .ui(4)) {
                    let matching = model.state.orderedChats(projectID: project.id, archived: false).filter {
                        search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)
                    }
                    chatEntries(matching, projectID: project.id)
                    if model.state.chats.allSatisfy({ $0.projectID != project.id || $0.isArchived }) {
                        Text(L10n.text("Пока нет чатов", "No chats yet")).font(.ui(.caption)).foregroundStyle(.secondary).padding(.leading, .ui(24))
                    }
                }
            }
        }.animation(sidebarAnimation, value: isExpanded)
    }

    private func startRenaming(_ project: Project) {
        newProjectName = project.name
        renamingProject = project
    }

    private func startChat(in project: Project) {
        search = ""
        withAnimation(sidebarAnimation) {
            expandedProjects.insert(project.id)
            collapsedSearchProjects.remove(project.id)
            visibleChatCounts[project.id] = nil
            model.selectProject(project.id)
        }
    }

    @ViewBuilder private func chatEntries(_ chats: [Chat], projectID: UUID) -> some View {
        let limit = search.isEmpty ? (visibleChatCounts[projectID] ?? chatPageSize) : chats.count
        ForEach(chats.prefix(limit)) { chat in
            chatEntry(chat)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if chats.count > limit {
            Button {
                withAnimation(sidebarAnimation) {
                    visibleChatCounts[projectID] = limit + chatPageSize
                }
            } label: {
                Label(L10n.text("Показать ещё", "Show more"), systemImage: "ellipsis")
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                    .padding(.leading, .ui(16)).padding(.vertical, .ui(8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PointerButtonStyle(base: .plain))
            .help(L10n.text("Осталось чатов: \(chats.count - limit)", "More chats: \(chats.count - limit)"))
        }
    }

    private func revealSelectedChat() {
        guard let chat = model.selectedChat, !chat.isArchived else { return }
        expandedProjects.insert(chat.projectID)
        let siblings = model.state.orderedChats(projectID: chat.projectID, archived: chat.isArchived)
        guard let index = siblings.firstIndex(where: { $0.id == chat.id }) else { return }
        let limit = (index / chatPageSize + 1) * chatPageSize
        visibleChatCounts[chat.projectID] = max(visibleChatCounts[chat.projectID] ?? chatPageSize, limit)
    }

    /// Chat row menu: the chat's own actions, then the agent tools in a submenu. Chats reorder by dragging.
    private func chatActions(_ chat: Chat) -> [SidebarMenuAction] {
        if selection.contains(chat.id) && selection.ids.count > 1 {
            let count = selection.ids.count
            return [
                SidebarMenuAction(title: L10n.text("Архивировать выбранные (\(count))", "Archive selected (\(count))"), enabled: canArchiveSelection) { archiveSelection() },
                SidebarMenuAction(title: L10n.text("Снять выделение", "Deselect all")) { selection.clear() }
            ]
        }
        var actions: [SidebarMenuAction] = []
        if model.runningBrowserChats[chat.id] != nil {
            actions += [SidebarMenuAction(title: L10n.text("Показать браузер этого чата", "Show this chat’s browser")) { model.showBrowser(chatID: chat.id) }, .separator]
        }
        actions += [
            SidebarMenuAction(title: chat.isPinned ? L10n.text("Открепить из избранного", "Unpin from favorites") : L10n.text("Закрепить в избранном", "Pin to favorites")) { model.toggleChatPin(chat.id) },
            SidebarMenuAction(title: L10n.text("Переименовать…", "Rename…")) { renaming = chat; newTitle = chat.title },
            SidebarMenuAction(title: chat.isArchived ? L10n.text("Восстановить из архива", "Restore from archive") : L10n.text("Архивировать", "Archive"), enabled: model.canDeleteChat(chat.id)) {
                Task {
                    await model.setChatArchived(chat.id, archived: !chat.isArchived)
                }
            },
            SidebarMenuAction(title: L10n.text("Удалить чат…", "Delete chat…"), enabled: model.canDeleteChat(chat.id)) { deleting = chat },
            .separator
        ]
        var agents = [
            SidebarMenuAction(title: L10n.text("Скопировать ID чата", "Copy chat ID")) { copyToPasteboard(chat.id) },
            SidebarMenuAction(title: L10n.text("Скопировать ссылку на чат для агента", "Copy chat reference for an agent")) {
                copyToPasteboard(ChatReference.text(chat, projectPath: model.state.projects.first { $0.id == chat.projectID }?.path))
            },
        ]
        if chat.nativeSession?.connection == .appClaude {
            agents.append(SidebarMenuAction(title: chat.chatDirectoryAccess == true
                ? L10n.text("Закрыть доступ к другим чатам", "Remove access to other chats")
                : L10n.text("Дать доступ к другим чатам", "Give access to other chats")) { model.toggleChatDirectory(chat.id) })
        }
        actions.append(.submenu(L10n.text("Для агентов", "For agents"), agents))
        return actions
    }
    /// Move up/down within the project, offered to VoiceOver as custom actions.
    private func chatReorderActions(_ chat: Chat) -> [SidebarMenuAction] {
        let siblings = model.state.orderedChats(projectID: chat.projectID, archived: chat.isArchived)
        guard let index = siblings.firstIndex(where: { $0.id == chat.id }) else { return [] }
        return [(-1, L10n.text("Переместить выше", "Move up")), (1, L10n.text("Переместить ниже", "Move down"))].compactMap { offset, title in
            guard siblings.indices.contains(index + offset) else { return nil }
            let target = siblings[index + offset].id
            return SidebarMenuAction(title: title) { _ = model.moveChat(chat.id, to: target) }
        }
    }
    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    private func chatEntry(_ chat: Chat, favorite: Bool = false) -> some View {
        let rowID = (favorite ? "favorite:" : "chat:") + chat.id
        return Group {
            if favorite {
                chatLabel(chat, favorite: true)
                    .accessibilityHidden(true)
                    .overlay {
                        ChatRow(chat: chat, enabled: !model.isChangingChat(chat.id), activate: {
                            Task { await model.openChat(chat) }
                        }, move: { _ in false }, targeted: { _ in },
                           actions: chatActions(chat), favorite: true, menuShown: menuShown(rowID), hovered: hover(rowID), pressed: press(rowID))
                    }
            } else {
                // Measure and render the same label; the native overlay only handles interaction.
                chatLabel(chat, favorite: false)
                    .accessibilityHidden(true) // The overlay exposes the row as one accessible button.
                    .overlay {
                        ChatRow(chat: chat, enabled: !model.isChangingChat(chat.id), activate: {
                            selection.clear()
                            Task { await model.openChat(chat) }
                        }, select: { gesture in
                            switch gesture {
                            case .toggle: selection.toggle(chat.id, current: model.chatID, eligible: activeChatIDs)
                            case .extend: selection.extend(to: chat.id, in: model.state.orderedChats(projectID: chat.projectID, archived: false).map(\.id), current: model.chatID)
                            }
                        }, move: { model.moveChat($0, to: chat.id) }, targeted: { targeted in
                            if targeted { dropTargetChatID = chat.id }
                            else if dropTargetChatID == chat.id { dropTargetChatID = nil }
                        }, actions: chatActions(chat), reorder: chatReorderActions(chat), menuShown: menuShown(rowID), hovered: hover(rowID), pressed: press(rowID))
                    }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((!favorite && dropTargetChatID == chat.id) || menuRowID == rowID ? DeskPalette.accent : .clear, lineWidth: 2).allowsHitTesting(false))
        .background(SidebarRowBackground(hover: rowHover, rowID: rowID,
                                         base: pressedRowID == rowID ? DeskPalette.selection : chatBackground(chat, favorite: favorite, highlighted: rowHighlighted(rowID)),
                                         marked: chatSelected(chat, favorite: favorite)))
        .disabled(model.isChangingChat(chat.id))
    }

    private var activeChatIDs: Set<String> {
        Set(model.state.chats.lazy.filter { !$0.isArchived }.map(\.id))
    }
    private var canArchiveSelection: Bool {
        !archivingSelection && selection.ids.allSatisfy { model.canDeleteChat($0) }
    }
    private func chatBackground(_ chat: Chat, favorite: Bool, highlighted: Bool) -> Color {
        if !favorite && selection.contains(chat.id) { return DeskPalette.accentWash }
        if model.chatID == chat.id && !model.showingJobs && !model.showingAttention && !model.showingArchive { return DeskPalette.selection }
        return highlighted ? DeskPalette.rowHover : .clear
    }
    /// The open chat's row carries the moss bar at its leading edge; a multi-selected row shows its check instead.
    private func chatSelected(_ chat: Chat, favorite: Bool) -> Bool {
        model.chatID == chat.id && !model.showingJobs && !model.showingAttention && !model.showingArchive && (favorite || !selection.contains(chat.id))
    }
    private func menuShown(_ rowID: String) -> (Bool) -> Void {
        { shown in
            if shown { menuRowID = rowID } else if menuRowID == rowID { menuRowID = nil }
        }
    }
    private func hover(_ source: String) -> (Bool) -> Void {
        { inside in
            rowHover.set(source, inside: inside)
        }
    }
    private func press(_ rowID: String) -> (Bool) -> Void {
        { down in
            if down { pressedRowID = rowID } else if pressedRowID == rowID { pressedRowID = nil }
        }
    }
    /// Hover is drawn by `SidebarRowBackground`; reading it here would re-render the window on every hover change.
    private func rowHighlighted(_ rowID: String) -> Bool {
        menuRowID == rowID
    }
    private func archiveSelection() {
        // Archive in sidebar order so partial failures are predictable.
        let ids = model.state.projects.flatMap { model.state.orderedChats(projectID: $0.id, archived: false) }
            .map(\.id).filter(selection.contains)
        guard !ids.isEmpty, !archivingSelection else { return }
        archivingSelection = true
        Task {
            await model.archiveChats(ids)
            archivingSelection = false
        }
    }
    private var selectionBar: some View {
        let count = selection.ids.count
        return HStack(spacing: .ui(8)) {
            Text(L10n.text("Выбрано: \(count)", "Selected: \(count)")).font(.ui(.callout).weight(.medium))
            Spacer(minLength: 0)
            if archivingSelection { ProgressView().uiSmallSpinner() }
            Button { archiveSelection() } label: {
                Label(L10n.text("В архив", "Archive"), systemImage: "archivebox")
            }.buttonStyle(DeskButtonStyle()).disabled(!canArchiveSelection)
                .help(canArchiveSelection ? L10n.text("Архивировать выбранные чаты. Полный вывод инструментов в архиве сокращается до кратких строк и при восстановлении чата не возвращается.", "Archive the selected chats. Full tool output is reduced to one-line summaries in the archive and is not restored when a chat is restored.") : L10n.text("Дождись завершения работы в выбранных чатах", "Wait until the selected chats are idle"))
            Button { selection.clear() } label: { Image(systemName: "xmark") }
                .buttonStyle(PointerButtonStyle(base: .plain)).keyboardShortcut(.cancelAction).disabled(archivingSelection)
                .help(L10n.text("Снять выделение (Esc)", "Deselect all (Esc)"))
                .accessibilityLabel(L10n.text("Снять выделение", "Deselect all"))
        }
        .padding(.ui(10)).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, .ui(12))
    }

    private func chatLabel(_ chat: Chat, favorite: Bool) -> some View {
            HStack(spacing: .ui(8)) {
                if !favorite && selection.contains(chat.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskPalette.accent)
                        .accessibilityLabel(L10n.text("Выбран", "Selected"))
                } else if chat.isArchived {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: .ui(3)) {
                    Text(chat.title)
                        .lineLimit(2, reservesSpace: true)
                        .frame(height: .ui(32), alignment: .leading)
                    if favorite, let project = model.state.projects.first(where: { $0.id == chat.projectID }) {
                        Text(project.name).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                            .help(project.path)
                    }
                }
                if model.runningBrowserChats[chat.id] != nil {
                    Image(systemName: "globe").font(.ui(.caption2)).foregroundStyle(DeskPalette.browser)
                        .help(L10n.text("Браузер этого чата открыт. Показать его можно из контекстного меню чата или меню «Браузеры».",
                                        "This chat’s browser is open. Show it from the chat’s context menu or the Browsers menu."))
                        .accessibilityLabel(L10n.text("Браузер открыт", "Browser is open"))
                }
                if chat.isPinned {
                    Image(systemName: "pin.fill").font(.ui(.caption2)).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("В избранном", "In favorites"))
                }
                Spacer(minLength: 0)
                // Amber: the chat waits for the user or for the app restart. Moss: an unread response.
                if model.restartWaitingChatIDs.contains(chat.id) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.ui(.caption)).foregroundStyle(DeskPalette.attention)
                        .help(L10n.text("Ждёт перезапуска приложения", "Waiting for the app restart"))
                        .accessibilityLabel(L10n.text("Ждёт перезапуска приложения", "Waiting for the app restart"))
                }
                if model.pending.contains(where: { $0.threadID == chat.id }) {
                    Circle().fill(DeskPalette.attention).frame(width: .ui(7), height: .ui(7))
                        .help(L10n.text("Требуется действие", "Action required"))
                        .accessibilityLabel(L10n.text("Требуется действие", "Action required"))
                } else if chat.hasUnreadResponse {
                    Circle().fill(DeskPalette.accent).frame(width: .ui(7), height: .ui(7))
                        .help(L10n.text("Непрочитанный ответ", "Unread response"))
                        .accessibilityLabel(L10n.text("Непрочитанный ответ", "Unread response"))
                }
                if model.isBusy(threadID: chat.id) { ProgressView().uiSmallSpinner() }
                else if let notice = model.backgroundWaitNotice(chat.id) {
                    Image(systemName: "hourglass").font(.ui(.caption)).foregroundStyle(.secondary)
                        .help(notice).accessibilityLabel(notice)
                }
            }.font(.ui(.callout)).padding(.horizontal, .ui(16)).padding(.vertical, .ui(4))
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

}

/// Keep the content mounted while animating its allocated height. A system List
/// removes rows before SwiftUI can animate this kind of continuous disclosure.
private struct SidebarDisclosure<Content: View>: View {
    let isExpanded: Bool
    let animation: Animation?
    @ViewBuilder var content: Content

    var body: some View {
        SidebarDisclosureLayout(progress: isExpanded ? 1 : 0) {
            content
        }
        .clipped()
        .opacity(isExpanded ? 1 : 0)
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(animation, value: isExpanded)
    }
}

private struct SidebarDisclosureLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Always lay out at natural height; only the enclosing viewport shrinks.
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Reads the dropped file URLs from the drag pasteboard while the drop is still on. Item providers resolve
/// after the drag ends, and a screenshot thumbnail deletes its temporary file by then, so the first drop was lost.
private struct ChatFileDrop: DropDelegate {
    let enabled: Bool
    @Binding var targeted: Bool
    let add: ([URL]) -> Void
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Re-arm the highlight: the watchdog may have cleared it while the drag is still on.
        if !targeted { targeted = true }
        return DropProposal(operation: enabled ? .copy : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard enabled else { return false }
        let pasteboard = NSPasteboard(name: .drag)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
            return true
        }
        // Fallback for sources that only answer through item providers; keeps the drop order.
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { done in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            add(urls)
        }
        return true
    }
}

/// Clears a drop highlight that outlived its drag. AppKit skips `dropExited` and `performDrop` when the drag source
/// cancels over the view (a screenshot thumbnail that is dismissed mid-drag), which left the overlay on the chat and
/// the composer unreachable. The watchdog clears the highlight once the mouse button is up or the user acts again.
@MainActor
final class DropTargetWatchdog: ObservableObject {
    private var monitor: Any?
    private var poll: Task<Void, Never>?
    /// `clear` runs once the drag ended without a drop callback; the caller hides the highlight and restores focus.
    func start(clear: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            Task { @MainActor in clear() }
            return event
        }
        poll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 { clear(); return }
            }
        }
    }
    func stop() {
        poll?.cancel(); poll = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Runs the watchdog while the drop highlight is on; kept out of the chat body so the type checker stays fast.
private struct DropTargetRecovery: ViewModifier {
    @Binding var targeted: Bool
    let watchdog: DropTargetWatchdog
    let recovered: () -> Void
    func body(content: Content) -> some View {
        content
            .onChange(of: targeted) { _, on in
                guard on else { watchdog.stop(); return }
                watchdog.start {
                    guard targeted else { return }
                    targeted = false
                    recovered()
                }
            }
            .onDisappear { watchdog.stop() }
    }
}

/// One motion vocabulary for the shell: a critically damped spring (no overshoot without a flick behind it),
/// and opacity-only changes under Reduce Motion.
enum DeskMotion {
    static func standard(_ reduceMotion: Bool, response: Double = 0.32) -> Animation? {
        reduceMotion ? nil : .spring(response: response, dampingFraction: 1)
    }
    /// Enters and leaves along the same edge; a plain fade under Reduce Motion.
    static func slide(from edge: Edge, _ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// Shell buttons. `secondary`: tonal fill; `primary`: the one main action, moss; `wash`: moss wash for "New chat";
/// `text`: a tertiary text-only action in deep moss.
struct DeskButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, wash, text }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, kind: kind) }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            Group {
                // Secondary keeps the foreground its caller sets.
                if let foreground { configuration.label.foregroundStyle(foreground) } else { configuration.label }
            }.font(.ui(.callout).weight(.medium)).padding(.horizontal, .ui(kind == .text ? 8 : 14)).padding(.vertical, .ui(10))
                .background(fill)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovering = $0 }
                .pointingHandCursor()
        }
        private var hovered: Bool { hovering && isEnabled }
        private var foreground: Color? {
            switch kind {
            case .secondary: nil
            case .primary: isEnabled ? .white : .secondary
            case .wash, .text: isEnabled ? DeskPalette.accentDeep : .secondary
            }
        }
        /// Moss kinds darken on hover and press by layering the deeper tone over the base, so no extra shades are needed.
        private var fill: some View {
            let shape = RoundedRectangle(cornerRadius: 10)
            let (base, tone, amount): (Color, Color, Double) = switch kind {
            case .secondary: (configuration.isPressed ? DeskPalette.selection : hovered ? DeskPalette.rowHover : DeskPalette.subtle, .clear, 0)
            case .primary: isEnabled ? (DeskPalette.accent, DeskPalette.accentDeep, configuration.isPressed ? 1 : hovered ? 0.5 : 0) : (DeskPalette.selection, .clear, 0)
            case .wash: (DeskPalette.accentWash, DeskPalette.accent, configuration.isPressed ? 0.16 : hovered ? 0.08 : 0)
            case .text: (configuration.isPressed ? DeskPalette.selection : hovered ? DeskPalette.subtle : .clear, .clear, 0)
            }
            return shape.fill(base).overlay(shape.fill(tone.opacity(amount)))
        }
    }
}

/// Search field of the sidebar and lists: tonal fill without a stroke; focused, it turns to canvas with a moss ring.
struct DeskSearchField: View {
    let prompt: String
    @Binding var text: String
    var clearable = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: .ui(8)) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
            if clearable && !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Очистить поиск", "Clear search"))
            }
        }.padding(.ui(10)).modifier(DeskFieldChrome(focused: focused))
    }
}

/// Fill and focus ring shared by the shell's text fields: subtle at rest, canvas plus a 3 pt moss ring outside the edge when focused.
struct DeskFieldChrome: ViewModifier {
    let focused: Bool
    var cornerRadius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(focused ? DeskPalette.canvas : DeskPalette.subtle, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius + 1.5).stroke(DeskPalette.focusBorder, lineWidth: 3).padding(-1.5)
                .opacity(focused ? 1 : 0).allowsHitTesting(false))
    }
}

extension View {
    /// "Favorites" and similar titles above the sidebar groups.
    func sidebarSectionHeader() -> some View {
        font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, .ui(8)).padding(.top, .ui(8)).padding(.bottom, .ui(4))
    }
}

/// The composer's round send/stop control: it gives under the pointer on press.
struct RoundControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
                .contentShape(Circle())
                .pointingHandCursor()
        }
    }
}

/// Sidebar icon buttons (the bottom dock, "+" beside Projects): a hover tint, and the selection fill while their page is open.
struct SidebarIconButtonStyle: ButtonStyle {
    var selected = false
    var width: CGFloat = .ui(34)
    var height: CGFloat = .ui(30)
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, style: self) }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let style: SidebarIconButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.ui(size: 14))
                .foregroundStyle(style.selected ? DeskPalette.ink : DeskPalette.inkSoft)
                .frame(width: style.width, height: style.height)
                .background(style.selected || configuration.isPressed ? DeskPalette.selection : hovering ? DeskPalette.rowHover : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
                .pointingHandCursor()
        }
    }
}

/// The "Needs you" row: an amber wash while anything waits, otherwise a plain sidebar item.
struct NeedsYouRowStyle: ButtonStyle {
    let active: Bool
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, active: active, selected: selected) }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10)
            configuration.label
                .padding(.horizontal, .ui(8)).padding(.vertical, .ui(8))
                .background(fill(shape))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .pointingHandCursor()
        }
        @ViewBuilder private func fill(_ shape: RoundedRectangle) -> some View {
            if active {
                // Amber deepens on hover, press and while the page is open, layered like the moss wash buttons.
                shape.fill(DeskPalette.attentionWash)
                    .overlay(shape.fill(DeskPalette.attention.opacity(configuration.isPressed ? 0.18 : selected ? 0.14 : hovering ? 0.08 : 0)))
            } else {
                shape.fill(selected || configuration.isPressed ? DeskPalette.selection : hovering ? DeskPalette.rowHover : .clear)
            }
        }
    }
}

struct ChatView: View {
    @ObservedObject var model: DeskModel
    @State private var composerFocused = false
    @State private var composerHeight: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var handoff: ContextHandoff?
    @State private var fileDropTargeted = false
    @StateObject private var dropWatchdog = DropTargetWatchdog()
    /// Files opened from answers in the preview pane, with back/forward history.
    @StateObject private var preview = DocumentPreviewSession()
    /// Composer column: the transcript's readable text width (magnified with the interface zoom) plus the composer's side insets.
    private var columnWidth: CGFloat { InterfaceZoom.shared.scaled(TranscriptScrollView.readableWidth) + 48 }
    /// The composer grows and shrinks smoothly; past its cap the height no longer changes, so nothing animates.
    /// The footer under the composer only names a non-direct or unavailable route.
    private var showsComposerFooter: Bool { model.currentRoute != .direct || !model.routeIsAvailable(model.currentRoute) }
    private func resizeComposer(_ height: CGFloat) {
        let visible = { (h: CGFloat) in min(max(h, 40), 220) }
        guard !reduceMotion, visible(height) != visible(composerHeight) else { composerHeight = height; return }
        withAnimation(.easeOut(duration: 0.16)) { composerHeight = height }
    }
    var body: some View {
        VStack(spacing: 0) {
            if !model.currentAgentAuthenticated {
                HStack {
                    Text(model.currentAgent == .appClaude ? L10n.text("Войди по подписке Claude в отдельный профиль приложения.", "Sign in with your Claude subscription in the app’s separate profile.") : L10n.text("Войди через ChatGPT, чтобы начать чат.", "Sign in with ChatGPT to start a chat.")).font(.ui(.callout))
                    Spacer()
                    Button(model.currentAgentConnected ? L10n.text("Войти", "Sign in") : L10n.text("Подключиться", "Connect")) { Task { await model.loginCurrentAgent() } }
                        .buttonStyle(DeskButtonStyle()).disabled(model.connecting || model.claudeConnecting)
                    if model.currentAgent == .appClaude && model.claudeConnected {
                        Button(L10n.text("Проверить вход", "Check sign-in")) { Task { await model.refreshClaudeAccount() } }
                    }
                }.padding()
            }
            if let notice = model.localHistoryNotice {
                Text(notice).font(.ui(.caption)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, .ui(24)).padding(.vertical, .ui(8))
            }
            if let origin = model.selectedChat?.handoffOrigin {
                HStack {
                    Text(L10n.text("Контекст из чата", "Context from chat") + ": " + origin.conversation.value)
                        .font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    HandoffRestoreButton(model: model, composer: model.composer)
                }.padding(.horizontal, .ui(24))
            }
            ChatHistoryView(model: model, transcript: model.transcript, onOpenFile: openPreview)
            if let action = model.currentAction {
                ActionView(action: action, model: model).id(action.id)
                    .task(id: "\(action.id):\(model.loadingChat)") {
                        if NSApplication.shared.isActive { model.markActionRead(action) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        model.markActionRead(action)
                    }
                    // Same column as the composer it sits on, and it arrives from the composer's side.
                    .frame(maxWidth: columnWidth).padding(.horizontal, .ui(24))
                    .transition(DeskMotion.slide(from: .bottom, reduceMotion))
            }
            if let chat = model.selectedChat, chat.isScheduledRecord, !model.selectedChatIsArchived {
                Label(DeskModel.scheduledRecordFollowUpNotice, systemImage: "clock.arrow.circlepath")
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, .ui(24)).padding(.vertical, .ui(8))
            }
            if let chat = model.selectedChat { SubagentsBar(model: model, chatID: chat.id) }
            if let chat = model.selectedChat, let notice = model.backgroundWaitNotice(chat.id) {
                HStack(alignment: .firstTextBaseline, spacing: .ui(12)) {
                    Label(notice, systemImage: "hourglass").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { Task { await model.stopBackgroundTasks(threadID: chat.id) } } label: {
                        Label(L10n.text("Остановить фоновые задачи", "Stop background tasks"), systemImage: "stop.circle")
                    }
                    .controlSize(.small).fixedSize()
                    .disabled(model.stoppingTasks.contains(DeskModel.stopKey(threadID: chat.id, task: nil)))
                    .help(L10n.text("Остановить все фоновые задачи и подагентов этого чата. Чат останется открытым.",
                                    "Stop all background tasks and sub-agents of this chat. The chat stays open."))
                }
                .font(.ui(.callout))
                .frame(maxWidth: columnWidth, alignment: .leading).padding(.horizontal, .ui(24)).padding(.vertical, .ui(8))
            }
            if model.selectedChatIsArchived, let chat = model.selectedChat {
                HStack {
                    Label(L10n.text("Чат в архиве. Полный вывод инструментов сокращён до кратких строк и после восстановления не возвращается.", "This chat is archived. Full tool output was reduced to one-line summaries and does not come back when the chat is restored."), systemImage: "archivebox")
                    Spacer()
                    Button(L10n.text("Восстановить", "Restore")) { Task { await model.setChatArchived(chat.id, archived: false) } }
                        .buttonStyle(DeskButtonStyle(kind: .text)).disabled(!model.canDeleteChat(chat.id))
                }.frame(maxWidth: columnWidth).padding(.horizontal, .ui(24)).padding(.vertical, .ui(12))
            }
            if !model.visibleQueue.isEmpty {
                VStack(alignment: .leading, spacing: .ui(6)) {
                    HStack {
                        Text(model.queuePaused ? L10n.text("Очередь приостановлена", "Queue paused") : L10n.text("В очереди · \(model.visibleQueue.count)", "Queued · \(model.visibleQueue.count)"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.queuePaused && model.priorityMessageID == nil {
                            Button(L10n.text("Продолжить", "Resume")) { model.resumeQueue() }.disabled(model.busy || !model.connected || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
                        }
                    }.font(.ui(.caption))
                    ScrollView {
                        VStack(spacing: .ui(6)) {
                            ForEach(model.visibleQueue) { message in
                                HStack(alignment: .center, spacing: .ui(12)) {
                                    Text(message.text).font(.ui(.callout)).lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading).help(message.text)
                                    Button {
                                        Task { await model.sendQueuedMessageNow(message.id) }
                                    } label: {
                                        Label(model.priorityMessageID == message.id ? L10n.text("Останавливаю…", "Stopping…") : model.busy ? L10n.text("Прервать и отправить", "Interrupt and send") : L10n.text("Отправить сейчас", "Send now"), systemImage: "arrow.up")
                                    }.disabled(model.sending || !model.connected || model.priorityMessageID != nil || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
                                    Button { model.removeQueuedMessage(message.id) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Убрать из очереди", "Remove from queue"))
                                        .disabled(model.priorityMessageID == message.id)
                                }.padding(.ui(10))
                                    .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.frame(maxHeight: min(CGFloat(model.visibleQueue.count) * 78, 180))
                }.frame(maxWidth: columnWidth).padding(.horizontal, .ui(24)).padding(.top, .ui(8))
            }
            if !model.selectedChatIsArchived {
            VStack(spacing: 4) {
                ComposerEditor(composer: model.composer,
                               placeholder: model.selectedChat?.isScheduledRecord == true ? L10n.text("Ответить в новом чате…", "Reply in a new chat…") : L10n.text("Напиши сообщение…", "Write a message…"),
                               focused: $composerFocused, focusRequest: model.composerFocusRequest,
                               height: min(max(composerHeight, 40), 220), onContentHeight: resizeComposer) { Task { await model.send() } }
                if !model.roleApproximations.isEmpty {
                    // No vertical fixedSize here: during the window's minimum-size pass it wrapped the notice one
                    // character per line, so both columns got a ~1500 pt minimum height and overflowed the window.
                    Text(model.roleApproximationNotice).font(.ui(.caption)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 6)
                        .accessibilityLabel(model.roleApproximationNotice)
                }
                HStack(spacing: 2) {
                    ChipMenu(title: model.roleSelection.flatMap { model.roleCatalog.role($0)?.title } ?? model.projectRoleTitle,
                             systemImage: model.accessMode == .fullAccess ? "lock.open" : "lock") {
                        Picker(L10n.text("Роль", "Role"), selection: Binding(get: { model.roleSelection }, set: { model.selectRole($0) })) {
                            Text(model.projectRoleTitle).tag(Optional<String>.none)
                            ForEach(model.roleCatalog.interactive) { role in Text(role.title).tag(Optional(role.id)) }
                        }.pickerStyle(.inline).labelsHidden()
                    }.disabled(model.busy || model.sending)
                        .help(model.currentRole.summary + " " + L10n.text("Роль этого чата; применяется со следующего сообщения. Роль по умолчанию задаётся в настройках проекта.", "This chat’s role; applies from the next message. The default role is set in the project settings."))
                    ModelChip(model: model)
                    Spacer()
                    ContextRing(usage: model.currentUsage, claude: model.currentAgent == .appClaude)
                    SendControl(model: model, composer: model.composer, reduceMotion: reduceMotion)
                }.padding(.horizontal, .ui(8)).padding(.bottom, .ui(8))
            }.background(RoundedRectangle(cornerRadius: 20).fill(DeskPalette.canvas).shadow(color: DeskPalette.shadow, radius: 14, y: 4))
                .overlay(RoundedRectangle(cornerRadius: 20.75).stroke(DeskPalette.focusBorder, lineWidth: 1.5).padding(-0.75)
                    .opacity(composerFocused ? 1 : 0).allowsHitTesting(false))
                .frame(maxWidth: columnWidth).padding(.horizontal, .ui(24)).padding(.top, .ui(10))
                .padding(.bottom, showsComposerFooter ? 0 : .ui(14))
            }
            // Only a non-direct route or an unavailable one leaves anything to say below the composer.
            if showsComposerFooter {
                HStack(spacing: .ui(12)) {
                    if model.currentRoute != .direct {
                        Text(model.routeTitle(model.currentRoute)).help(model.routeMessage(model.currentRoute))
                    }
                    if !model.routeIsAvailable(model.currentRoute) {
                        Text(L10n.text("Недоступен", "Unavailable")).foregroundStyle(DeskPalette.attention)
                    }
                    Spacer()
                }.font(.ui(.caption2)).foregroundStyle(.secondary).padding(.horizontal, .ui(12))
                    .frame(maxWidth: columnWidth).padding(.horizontal, .ui(24)).padding(.top, .ui(8)).padding(.bottom, .ui(12))
            }
        }
        .animation(DeskMotion.standard(reduceMotion), value: model.currentAction?.id)
        .background(DeskPalette.canvas)
        // The whole chat accepts dropped files, such as a screenshot thumbnail, and adds their paths to the draft.
        .onDrop(of: [.fileURL], delegate: ChatFileDrop(enabled: !model.selectedChatIsArchived, targeted: $fileDropTargeted) { model.addDroppedFiles($0) })
        .overlay {
            ZStack {
            if fileDropTargeted && !model.selectedChatIsArchived {
                RoundedRectangle(cornerRadius: 16).fill(DeskPalette.subtle.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DeskPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .overlay(Label(L10n.text("Отпусти, чтобы добавить путь к файлу в сообщение", "Drop to add the file path to the message"), systemImage: "photo.badge.plus")
                        .font(.ui(.title3).weight(.medium)).foregroundStyle(.secondary))
                    .padding(12).allowsHitTesting(false)
                    .transition(.opacity)
            }
            }.animation(.snappy(duration: 0.15), value: fileDropTargeted)
        }
        .modifier(DropTargetRecovery(targeted: $fileDropTargeted, watchdog: dropWatchdog) { model.focusComposer() })
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let chat = model.selectedChat {
                    if model.state.browserEnabled == true, let session = chat.nativeSession,
                       [.originalCodex, .appClaude].contains(session.connection) {
                        ChatBrowserControls(session: session, project: model.selectedProject?.path ?? "",
                                            busy: model.isBusy(threadID: chat.id) || model.isChangingChat(chat.id),
                                            ownerName: model.browserProfileOwnerName) { action in
                            try await model.changeBrowserProfile(chatID: chat.id, action: action)
                        }
                            .id(session.nativeID)
                    }
                    if model.preparingHandoff {
                        ProgressView().uiSmallSpinner()
                        Text(model.handoffProgress).font(.ui(.caption)).lineLimit(1)
                        Button(L10n.text("Отмена", "Cancel")) { Task { await model.cancelHandoffPreparation() } }
                    }
                    Button { Task { handoff = await model.prepareHandoff(chat) } } label: {
                        Label(L10n.text("Передать контекст…", "Hand off context…"), systemImage: "arrowshape.turn.up.right")
                    }.pointingHandCursor().help(L10n.text("Передать контекст в новый чат", "Hand off context to a new chat"))
                        .disabled(model.loadingChat || model.creatingHandoff || model.preparingHandoff || model.isBusy(threadID: chat.id))
                } else if model.state.browserEnabled == true, [.originalCodex, .appClaude].contains(model.currentAgent), let project = model.selectedProject {
                    NewChatBrowserProfilePicker(project: project.path, connection: model.currentAgent, ownerName: model.browserProfileOwnerName, selection: Binding(
                        get: { model.newChatBrowserProfiles[project.id] },
                        set: { model.newChatBrowserProfiles[project.id] = $0 }))
                        .disabled(model.sending)
                }
            }
        }
        .sheet(item: $handoff) { value in
            HandoffEditor(model: model, handoff: value,
                projectID: model.state.chats.first(where: { $0.id == value.origin.conversation.value })?.projectID,
                route: model.state.chats.first(where: { $0.id == value.origin.conversation.value })?.route ?? model.defaultRoute)
        }
        // Expanding moves the preview out of the inspector, so hiding the inspector then must not close it.
        .inspector(isPresented: Binding(get: { preview.current != nil && !preview.expanded },
                                        set: { if !$0 && !preview.expanded { preview.close() } })) {
            if let current = preview.current, !preview.expanded {
                DocumentPreviewView(session: preview, model: current, onQuote: quoteIntoDraft)
                    .id(current.id)
                    .inspectorColumnWidth(min: 320, ideal: 520, max: 1100)
            }
        }
        .overlay {
            ZStack {
                if preview.expanded, let current = preview.current {
                    // Grows out of the inspector's side and returns there; only scale and opacity animate, never the frame.
                    DocumentPreviewView(session: preview, model: current, onQuote: quoteIntoDraft)
                        .id(current.id)
                        .background(DeskPalette.canvas)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
                }
            }.animation(DeskMotion.standard(reduceMotion, response: 0.28) ?? .easeOut(duration: 0.12), value: preview.expanded)
        }
        .onChange(of: preview.expanded) { _, expanded in model.documentExpanded = expanded }
        .onDisappear { model.documentExpanded = false }
    }

    private func openPreview(_ url: URL, line: Int?) {
        preview.open(url, line: line)
    }

    /// A fragment selected in the preview goes into the draft with its file and lines; nothing is sent.
    private func quoteIntoDraft(_ url: URL, text: String, lines: ClosedRange<Int>?) {
        let path = TranscriptScrollView.relativePath(url.path, project: model.selectedProject?.path) ?? url.path
        model.composer.text = DocumentQuote.draft(path: path, lines: lines, text: text, appendingTo: model.composer.text)
        // The composer is hidden behind an expanded preview.
        preview.expanded = false
        model.focusComposer()
    }
}

/// Only this subtree observes streamed text; the composer/sidebar/settings do not.
struct ChatHistoryView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var transcript: TranscriptPresentation
    var onOpenFile: ((URL, Int?) -> Void)? = nil
    var body: some View {
        if model.loadingChat {
            ChatLoadingIndicator()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if transcript.items.isEmpty {
            VStack {
                EmptyState(icon: "bubble.left.and.bubble.right", title: L10n.text("Чем помочь с проектом?", "How can I help with your project?"), text: model.chatID == nil ? L10n.text("Первое сообщение создаст новый чат в папке «\(model.selectedProject?.name ?? "")»", "Your first message will create a new chat in “\(model.selectedProject?.name ?? "")”") : L10n.text("Чат в папке «\(model.selectedProject?.name ?? "")»", "Chat in “\(model.selectedProject?.name ?? "")”"))
                if !model.selectedChatIsArchived {
                    HStack {
                        suggestion(L10n.text("Объясни проект", "Explain the project"), prompt: L10n.text("Объясни структуру этого проекта и как его запустить.", "Explain this project’s structure and how to run it."))
                        suggestion(L10n.text("Найди проблемы", "Find problems"), prompt: L10n.text("Проверь проект и расскажи о найденных проблемах.", "Review the project and describe any problems you find."))
                    }.padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let renderedItems = transcript.items
            // Always following: the transcript itself stops while the reader is scrolled up and resumes at the end.
            NativeTranscript(items: renderedItems, conversationID: model.chatID, followOutput: true,
                             isWorking: model.busy, workingStatus: model.workingStatus, workingSince: model.workingSince, unreadCompletionID: model.selectedChat?.unreadCompletionID,
                             unreadResponseItemID: model.chatID.flatMap { model.unreadResponseItems[$0] },
                             projectPath: model.selectedProject?.path, onOpenFile: onOpenFile) { threadID, completionID in
                guard transcript.items == renderedItems else { return }
                model.markResponseRead(threadID: threadID, completionID: completionID)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func suggestion(_ title: String, prompt: String) -> some View {
        Button(title) { model.composer.text = prompt }.buttonStyle(DeskButtonStyle())
    }
}

/// The editor with its placeholder. Only this view and the two buttons below follow the composer's
/// state; the chat view itself does not, so a keystroke renders nothing above the composer.
private struct ComposerEditor: View {
    @ObservedObject var composer: ComposerState
    let placeholder: String
    @Binding var focused: Bool
    let focusRequest: UUID?
    let height: CGFloat
    let onContentHeight: (CGFloat) -> Void
    let onSubmit: () -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            if !composer.hasText {
                Text(placeholder).font(.ui(size: 14)).foregroundStyle(.secondary).padding(.horizontal, 21).padding(.top, 16).allowsHitTesting(false)
            }
            MessageComposer(state: composer, focused: $focused, focusRequest: focusRequest, onContentHeight: onContentHeight, onSubmit: onSubmit)
                .frame(height: height).padding(.horizontal, 16).padding(.top, 14).accessibilityLabel(L10n.text("Сообщение", "Message"))
        }
    }
}

/// One round control: stop while a response runs and nothing is typed, otherwise send or queue.
/// A single button, so the symbol morphs in place instead of one control replacing another.
/// It observes the composer's flags, not its text: only the first typed character and a cleared draft render it.
private struct SendControl: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var composer: ComposerState
    let reduceMotion: Bool
    var body: some View {
        let stops = model.busy && !composer.hasMessage
        Button { Task { if stops { await model.interrupt() } else { await model.send() } } } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(stops ? .ui(size: 11) : .ui(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: .ui(32), height: .ui(32))
                .foregroundStyle(stops || model.canSend ? Color.white : Color.secondary)
                .background(stops || model.canSend ? DeskPalette.accent : DeskPalette.selection, in: Circle())
        }.buttonStyle(RoundControlStyle())
            .keyboardShortcut(stops ? nil : KeyboardShortcut(.return, modifiers: .command))
            .disabled(!stops && !model.canSend).padding(.leading, .ui(6))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: stops)
            .animation(.easeOut(duration: 0.12), value: model.canSend)
            .help(stops ? L10n.text("Остановить ответ", "Stop response") : model.busy ? L10n.text("Добавить в очередь · Enter. Shift+Enter — новая строка", "Add to queue · Enter. Shift+Enter for a new line") : L10n.text("Отправить · Enter. Shift+Enter — новая строка", "Send · Enter. Shift+Enter for a new line"))
            .accessibilityLabel(stops ? L10n.text("Остановить ответ", "Stop response") : L10n.text("Отправить сообщение", "Send message"))
    }
}

/// Enabled only while the composer is empty, so the restored context never replaces typed text.
private struct HandoffRestoreButton: View {
    let model: DeskModel
    @ObservedObject var composer: ComposerState
    var body: some View {
        Button(L10n.text("Вернуть исходный контекст в черновик", "Restore initial context to draft")) { Task { await model.restoreHandoffDraft() } }
            .disabled(composer.hasText)
    }
}

struct MessageRow: View {
    let item: TranscriptItem
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.kind == "user" { Spacer(minLength: 70) }
            else { Image(systemName: "sparkle").font(.ui(.title3)).padding(.top, 4).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 10) {
                Text(item.kind == "user" ? L10n.text("Ты", "You") : (item.agentName ?? "Codex")).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                MessageText(text: item.text)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                } label: { Label(copied ? L10n.text("Скопировано", "Copied") : L10n.text("Копировать", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc").font(.ui(.caption2)) }
                    .buttonStyle(PointerButtonStyle(base: .plain)).foregroundStyle(.secondary)
            }.padding(item.kind == "user" ? 16 : 0)
                .background(item.kind == "user" ? Color(nsColor: DeskPalette.outgoingBubble) : .clear, in: RoundedRectangle(cornerRadius: 20))
            if item.kind != "user" { Spacer(minLength: 0) }
        }
    }
}

struct UsageDetail: View {
    let usage: UsageSnapshot?
    var claude = false
    /// Until the window is reported, the occupied size alone is still a measurement.
    static func footer(_ usage: UsageSnapshot?, language: AppLanguage = L10n.language) -> String {
        if let fraction = usage?.contextFraction { return L10n.text("Контекст ≈\(Int(fraction * 100))%", "Context ≈\(Int(fraction * 100))%", language: language) }
        if let last = usage?.last {
            let value = last.formatted(.number.locale(language.locale))
            return L10n.text("Контекст (токены): \(value)", "Context: \(value) tokens", language: language)
        }
        return L10n.text("Контекст: нет данных", "Context: no data", language: language)
    }
    /// Footer badge: minutes left in the prompt cache, or that it has expired.
    static func cacheBadge(_ state: PromptCacheState, language: AppLanguage = L10n.language) -> String {
        switch state {
        case .warm(let remaining), .expiring(let remaining):
            let minutes = max(1, Int((remaining / 60).rounded(.up)))
            return L10n.text("Кэш: \(minutes) мин", "Cache: \(minutes) min", language: language)
        case .cold: return L10n.text("Кэш остыл", "Cache expired", language: language)
        }
    }
    static var cacheHelp: String {
        L10n.text("Кэш промпта живёт ограниченное время после последнего запроса. Пока он тёплый, следующее сообщение перечитывает разговор дёшево. После истечения следующее сообщение заново оплачивает весь контекст: для длинного чата дешевле начать новый или сделать передачу.",
                  "The prompt cache lasts a limited time after the last request. While it is warm, the next message re-reads the conversation cheaply. After it expires, the next message pays for the whole context again: for a long chat, a new chat or a handoff costs less.")
    }
    static func cacheLifetime(_ ttl: TimeInterval, language: AppLanguage = L10n.language) -> String {
        ttl >= 3600 ? L10n.text("\(Int(ttl / 3600)) ч", "\(Int(ttl / 3600)) h", language: language)
                    : L10n.text("\(Int(ttl / 60)) мин", "\(Int(ttl / 60)) min", language: language)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Контекст и токены", "Context and tokens")).font(.ui(.headline))
            if let usage {
                LabeledContent(L10n.text("Последний запрос", "Last request"), value: usage.last.map(String.init) ?? L10n.text("Нет данных", "No data"))
                LabeledContent(L10n.text("Окно контекста", "Context window"), value: usage.window.map(String.init) ?? L10n.text("Нет данных", "No data"))
                Divider()
                LabeledContent(L10n.text("Входные за разговор", "Conversation input"), value: usage.input.map(String.init) ?? L10n.text("Нет данных", "No data"))
                LabeledContent(L10n.text("Из них из кэша", "Cached input"), value: usage.cached.map(String.init) ?? L10n.text("Нет данных", "No data"))
                LabeledContent(L10n.text("Выходные", "Output"), value: usage.output.map(String.init) ?? L10n.text("Нет данных", "No data"))
                if let requested = usage.lastRequestAt, let ttl = usage.cacheTTL, let state = usage.cacheState() {
                    Divider()
                    LabeledContent(L10n.text("Кэш промпта", "Prompt cache"), value: Self.cacheBadge(state))
                    LabeledContent(L10n.text("Срок кэша", "Cache lifetime"), value: Self.cacheLifetime(ttl))
                    LabeledContent(L10n.text("Запрос к модели", "Model request"), value: L10n.date(requested))
                }
                Text(L10n.text("Измерено: \(L10n.date(usage.measuredAt))", "Measured: \(L10n.date(usage.measuredAt))")).font(.ui(.caption))
            } else { Text(claude ? L10n.text("Показатели появятся после ответа Claude.", "Metrics will appear after Claude responds.") : L10n.text("Показатели появятся после ответа Codex.", "Metrics will appear after Codex responds.")) }
            Text(L10n.text("Процент — оценка по последнему событию, а не точный порог сжатия. Кэш уже входит во входные токены. Эти числа не равны расходу лимита подписки.", "The percentage is an estimate from the latest event, not an exact compaction threshold. Cached tokens are included in input tokens. These numbers do not represent subscription usage."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }
}

struct MessageText: View {
    let text: String
    var body: some View {
        let blocks = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if index % 2 == 1 {
                    ScrollView(.horizontal) { Text(block).font(.ui(.callout, design: .monospaced)).textSelection(.enabled).padding(12) }
                        .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                        .textSelection(.enabled).lineSpacing(4)
                }
            }
        }.environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }
}

struct EmptyState: View {
    var icon: String; var title: String; var text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.ui(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.ui(.title2).weight(.medium))
            Text(text).font(.ui(.callout)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobDetail: View {
    let job: ScheduledJob
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(job.name).font(.ui(.title2).bold())
                Label(L10n.text("Исходное задание · ещё не управляется Switchboard", "Source task · not yet managed by Switchboard"), systemImage: "eye").foregroundStyle(.secondary)
                LabeledContent(L10n.text("Состояние", "Status"), value: job.status == "ACTIVE" ? L10n.text("Включено", "Enabled") : job.status == "PAUSED" ? L10n.text("Приостановлено", "Paused") : L10n.text("Неизвестно", "Unknown"))
                LabeledContent(L10n.text("Тип", "Type"), value: job.kind)
                VStack(alignment: .leading, spacing: 8) { Text(L10n.text("Расписание", "Schedule")).font(.ui(.headline)); Text(job.schedule).textSelection(.enabled) }
                Text(L10n.text("Часовой пояс и результаты запусков здесь не проверены.", "The time zone and run results have not been verified here.")).font(.ui(.caption)).foregroundStyle(.secondary)
                if let issue = job.issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(DeskPalette.attention) }
                Divider()
                Text(L10n.text("Задание", "Task")).font(.ui(.headline))
                Text(job.prompt).textSelection(.enabled)
                if let thread = job.targetThread { Text(L10n.text("Исходный чат: \(thread)", "Source chat: \(thread)")).font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: DeskModel
    let keepAwake: KeepAwake
    @ObservedObject private var browserApply = BrowserSettingApply.shared
    @AppStorage(AppLanguage.preferenceKey) private var selectedLanguage = L10n.language.rawValue
    @AppStorage("parallelBrowserLimit") private var parallelBrowserLimit = 2
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettings
                .tabItem { Label(L10n.text("Основные", "General"), systemImage: "gearshape") }
                .tag("general")
            notificationSettings
                .tabItem { Label(L10n.text("Уведомления", "Notifications"), systemImage: "bell.badge") }
                .tag("notifications")
            accountsSettings
                .tabItem { Label(L10n.text("Аккаунты", "Accounts"), systemImage: "person.crop.circle") }
                .tag("accounts")
            browserSettings
                .tabItem { Label(L10n.text("Браузер", "Browser"), systemImage: "globe") }
                .tag("browser")
            AdvancedSettings(model: model)
                .tabItem { Label(L10n.text("Дополнительно", "Advanced"), systemImage: "slider.horizontal.3") }
                .tag("advanced")
        }
        .frame(height: 600)
    }

    private var generalSettings: some View {
        Form {
            Section("Язык / Language") {
                Picker(L10n.text("Язык интерфейса", "Interface language"), selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                }
                .pointingHandCursor()
                .onChange(of: selectedLanguage) { _, value in
                    (AppLanguage(rawValue: value) ?? .russian).save()
                }
                if selectedLanguage != L10n.language.rawValue {
                    Text("Чтобы применить язык, выйди через ⌘Q и открой приложение снова.\nTo apply the language, quit with ⌘Q and reopen the app.")
                        .font(.ui(.callout)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Новый язык применяется после перезапуска приложения.", "Language changes take effect after restarting the app."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
            InterfaceZoomSettings()
            MainWindowScreenSettings()
            NotchIslandSettings()
            KeepAwakeSettings(controller: keepAwake)
        }.formStyle(.grouped)
    }

    private var notificationSettings: some View {
        Form {
            Section(L10n.text("Уведомления macOS", "macOS notifications")) {
                Text(model.notificationStatus).font(.ui(.callout))
                Button(L10n.text("Разрешить уведомления", "Allow notifications")) { Task { await model.enableNotifications() } }
            }
            TelegramSettings(bridge: model.telegram)
            Section(L10n.text("Звук", "Sound")) {
                Button { selectedTab = "general" } label: {
                    Label(L10n.text("Звук, когда агент закончил или ждёт ответа, включается у острова в нотче: Основные → Остров в нотче.",
                                    "The sound when an agent finishes or needs you belongs to the notch island: General → Notch island."),
                          systemImage: "speaker.wave.2")
                        .font(.ui(.callout)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }.formStyle(.grouped)
    }

    private var accountsSettings: some View {
        Form {
            Section(L10n.text("Аккаунт Codex", "Codex account")) {
                LabeledContent(L10n.text("Аккаунт", "Account"), value: model.accountLabel)
                if model.authenticated { Button(L10n.text("Выйти из аккаунта этого приложения", "Sign out of this app")) { Task { await model.logout() } }.disabled(model.anyBusy) }
                else { Button(L10n.text("Войти через ChatGPT", "Sign in with ChatGPT")) { Task { await model.login() } }.disabled(!model.connected) }
                Button(L10n.text("Переподключить Codex", "Reconnect Codex")) { Task { await model.connect() } }.disabled(model.connecting || model.anyBusy)
            }
            Section(L10n.text("Подписка Claude", "Claude subscription")) {
                Text(model.claudeAuthenticated ? L10n.text("Вход выполнен", "Signed in") : L10n.text("Вход не выполнен", "Not signed in"))
                Text(L10n.text("Официальный Claude Code \(ClaudeRuntime.pinnedVersion). Вход открывается в Terminal в отдельном профиле Switchboard, затем нажми «Проверить вход»; твой профиль Claude Code не меняется.",
                               "Official Claude Code \(ClaudeRuntime.pinnedVersion). Sign-in opens in Terminal in a separate Switchboard profile, then click Check sign-in; your own Claude Code profile is unchanged."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                Button(L10n.text("Войти по подписке Claude", "Sign in with Claude subscription")) { Task { await model.loginClaude() } }.disabled(model.anyBusy || model.claudeConnecting)
                Button(L10n.text("Проверить вход", "Check sign-in")) { Task { if model.claudeConnected { await model.refreshClaudeAccount() } else { await model.connectClaude() } } }.disabled(model.claudeConnecting)
                if model.claudeAuthenticated {
                    Button(L10n.text("Выйти из Claude в этом приложении", "Sign out of Claude in this app")) { Task { await model.logoutClaude() } }.disabled(model.anyBusy)
                }
            }
            Section(L10n.text("Советник Claude", "Claude advisor")) {
                Picker(L10n.text("Советник", "Advisor"), selection: Binding(get: { model.state.claudeAdvisor ?? "" }, set: { model.selectClaudeAdvisor($0) })) {
                    ForEach(ClaudeAdvisor.options, id: \.id) { Text($0.name).tag($0.id) }
                }
                Text(L10n.text("Более сильная модель, с которой Claude советуется перед выбором подхода, при повторяющейся ошибке и перед завершением; только для чатов и задач на более слабой модели (Sonnet и Haiku получают Opus, Opus — только Fable). Советы расходуют лимиты подписки, Fable может списывать кредиты; действует со следующего сообщения.",
                               "A stronger model Claude consults before choosing an approach, on a recurring error and before finishing; only for chats and jobs on a weaker model (Sonnet and Haiku get Opus, Opus gets only Fable). Advice counts toward subscription limits, Fable may use credits; takes effect from the next message."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var browserSettings: some View {
        Form {
            Section(L10n.text("Браузер агента", "Agent browser")) {
                Toggle(L10n.text("Использовать Chrome DevTools", "Use Chrome DevTools"),
                       isOn: Binding(get: { model.state.browserEnabled == true }, set: {
                           model.selectBrowserEnabled($0); browserApply.schedule(model: model)
                       }))
                Text(L10n.text("У каждого чата свой Chrome for Testing и сохранённый профиль. Чаты работают параллельно. В меню «Браузер» можно импортировать входы из выбранного профиля Chrome или войти на сайты вручную. Браузеры остаются открытыми после переподключения.", "Each chat has its own Chrome for Testing and saved profile. Chats work in parallel. Use the Browser menu to import sign-ins from a selected Chrome profile, or sign in manually. Browsers stay open after reconnecting."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                Picker(L10n.text("Одновременно открытых браузеров", "Simultaneously open browsers"),
                       selection: Binding(get: { parallelBrowserLimit }, set: {
                           guard $0 != parallelBrowserLimit else { return }
                           parallelBrowserLimit = $0; browserApply.schedule(model: model)
                       })) {
                    ForEach(1...8, id: \.self) { Text(String($0)).tag($0) }
                }
                Text(L10n.text("По умолчанию — 2. При достижении лимита заверши неиспользуемый Chrome через Cmd+Q; открытые браузеры автоматически не закрываются.", "Default: 2. At the limit, quit an unused Chrome with Cmd+Q; open browsers are never closed automatically."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                if browserApply.pending {
                    Label(L10n.text("Применится, когда чаты освободятся", "Applies when chats are idle"), systemImage: "clock")
                        .font(.ui(.callout)).foregroundStyle(DeskPalette.attentionInk)
                    Text(L10n.text("Codex переподключится сам, когда не будет выполняющихся ходов, одобрений, сообщений в очереди и фоновых задач. Действия не повторяются.",
                                   "Codex reconnects on its own once no turn, approval, queued message or background task is active. No action is replayed."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                } else if model.connecting {
                    Label(L10n.text("Подключение…", "Connecting…"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.ui(.callout)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Изменения применяются сами: Codex переподключается, когда все чаты свободны. Браузер открывается при первом обращении агента.",
                                   "Changes apply on their own: Codex reconnects once every chat is idle. The browser opens on the agent’s first browser request."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Button(L10n.text("Инструкция по установке", "Installation instructions")) {
                    if let resources = Bundle.main.resourceURL {
                        NSWorkspace.shared.open(resources.appendingPathComponent("BrowserRuntime/README.md"))
                    }
                }
            }
            Section(L10n.text("Мой Chrome", "My Chrome")) {
                Toggle(L10n.text("Разрешить чатам Claude управлять моим Chrome", "Let Claude chats control my Chrome"),
                       isOn: Binding(get: { model.state.userChromeEnabled != false }, set: { model.selectUserChromeEnabled($0) }))
                Text(L10n.text("Чаты Claude с полным доступом получают инструменты расширения Claude in Chrome: агент открывает свои вкладки в твоём обычном Chrome с твоими входами на сайты и может загружать файлы. Нужны расширение Claude in Chrome, вход в нём в тот же аккаунт Claude, что и в Switchboard, и открытый Chrome. Пока агент работает, Chrome показывает полосу об отладке. Запланированные задачи и чаты Codex этот путь не используют.", "Full-access Claude chats get the Claude in Chrome extension tools: the agent opens its own tabs in your regular Chrome with your site sign-ins and can upload files. Requires the Claude in Chrome extension signed in to the same Claude account as Switchboard, and Chrome running. While the agent works, Chrome shows a debugging bar. Scheduled tasks and Codex chats do not use this path."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                Text(L10n.text("Применяется переподключением Claude сразу после переключения, если ни один чат Claude не выполняет задачу. Иначе переключи настройку ещё раз, когда задачи завершатся.", "Applied by reconnecting Claude right after the switch, if no Claude chat is running a task. Otherwise switch it again once those tasks finish."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
