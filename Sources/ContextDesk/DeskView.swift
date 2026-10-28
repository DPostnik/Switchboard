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
    @State private var hoveredRows: Set<String> = []
    @State private var expandedProjects: Set<UUID> = []
    @State private var collapsedSearchProjects: Set<UUID> = []
    @State private var visibleChatCounts: [UUID: Int] = [:]
    @State private var selection = ChatSelection()
    @State private var archivingSelection = false
    private let chatPageSize = 5
    private var sidebarAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9) }
    @State private var newTitle = ""
    @State private var showingNotifications = false
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
                    withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .help(L10n.text("Показать или скрыть боковую панель", "Show or hide sidebar"))
                .accessibilityLabel(L10n.text("Показать или скрыть боковую панель", "Show or hide sidebar"))
            }
        }
        .tint(.primary)
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
            withAnimation {
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
        .popover(isPresented: $showingNotifications) {
            notificationsPanel
        }
        .sheet(item: $permissionsProject) { project in ProjectPermissionsView(model: model, project: project) }
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
                    Button { showingNotifications.toggle() } label: {
                        Image(systemName: (model.notices.isEmpty && !model.state.chats.contains(where: \.hasUnreadResponse)) ? "bell" : "bell.badge.fill")
                            .foregroundStyle((model.notices.isEmpty && !model.state.chats.contains(where: \.hasUnreadResponse)) ? Color.primary : .blue)
                    }.buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Уведомления", "Notifications"))
                }.padding(.horizontal, .ui(16)).padding(.top, .ui(16))
                if model.openAttentionCount > 0 && !model.showingAttention {
                    AttentionBanner(model: model).padding(.horizontal, .ui(12))
                }
                Button { model.newChat() } label: {
                    Label(L10n.text("Новый чат", "New chat"), systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(DeskButtonStyle()).disabled(model.selectedProject == nil).padding(.horizontal, .ui(12))
                HStack(spacing: .ui(8)) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("Найти проект или чат", "Find a project or chat"), text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Очистить поиск", "Clear search"))
                    }
                }.padding(.ui(10)).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskPalette.border))
                    .padding(.horizontal, .ui(12))
                ScrollView {
                    VStack(alignment: .leading, spacing: .ui(4)) {
                        if !model.state.visiblePinnedChats.isEmpty {
                            Text(L10n.text("Избранное", "Favorites"))
                                .font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, .ui(8)).padding(.top, .ui(8)).padding(.bottom, .ui(4))
                            ForEach(model.state.visiblePinnedChats.filter { chat in
                                (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search)
                                    || model.state.projects.contains { $0.id == chat.projectID && ($0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)) })
                            }) { chat in
                                chatEntry(chat, favorite: true)
                            }
                            Divider().padding(.vertical, .ui(6))
                        }
                        Text(L10n.text("Проекты", "Projects"))
                            .font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, .ui(8)).padding(.top, .ui(8)).padding(.bottom, .ui(4))
                        ForEach(model.state.visibleProjects.filter { project in
                            search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search) || model.state.chats.contains { $0.projectID == project.id && !$0.isArchived && $0.title.localizedCaseInsensitiveContains(search) }
                        }) { project in
                            projectEntries(project)
                        }
                        Button { model.openProject() } label: {
                            Label(L10n.text("Добавить проект…", "Add project…"), systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, .ui(8)).padding(.vertical, .ui(10)).contentShape(Rectangle())
                        }.buttonStyle(PointerButtonStyle(base: .plain))
                        Divider().padding(.vertical, .ui(6))
                        Button { model.showingArchive = false; model.showingAttention = false; model.showingJobs = true; Task { await model.refreshJobs() } } label: {
                            Label(L10n.text("По расписанию", "Scheduled jobs"), systemImage: "calendar")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, .ui(8)).padding(.vertical, .ui(10)).contentShape(Rectangle())
                        }.buttonStyle(PointerButtonStyle(base: .plain))
                        Button { model.openAttention() } label: {
                            HStack {
                                Label(L10n.text("Важное", "Important"), systemImage: model.openAttentionCount > 0 ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                    .foregroundStyle(model.openAttentionCount > 0 ? AttentionPalette.accent : Color.primary)
                                Spacer()
                                if model.openAttentionCount > 0 {
                                    Text("\(model.openAttentionCount)").font(.ui(.caption).weight(.bold)).foregroundStyle(.white)
                                        .padding(.horizontal, .ui(7)).padding(.vertical, .ui(2)).background(AttentionPalette.accent, in: Capsule())
                                }
                            }
                            .padding(.horizontal, .ui(8)).padding(.vertical, .ui(10)).contentShape(Rectangle())
                            .background(model.showingAttention ? DeskPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(PointerButtonStyle(base: .plain))
                    }.padding(.horizontal, .ui(12)).padding(.bottom, .ui(8))
                        // Legacy scrollers take layout width only while the list overflows; reserve it otherwise so rows keep their width.
                        .padding(.trailing, sidebarScrollerReserve)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarContentHeight = $0 }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarViewportHeight = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                    scrollerStyle = NSScroller.preferredScrollerStyle
                }
                DeskPalette.border.frame(height: 0.5)
                if !selection.isEmpty { selectionBar }
                Button { limitsPlacement = limitsAnchor.placement; showingLimits = true } label: {
                    Label(L10n.text("Usage и лимиты", "Usage and limits"), systemImage: "chart.bar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(DeskButtonStyle()).background(ScreenFrameReader(probe: limitsAnchor)).padding(.horizontal, .ui(12)).padding(.top, .ui(10))
                    .popover(isPresented: $showingLimits, arrowEdge: limitsPlacement.edge) {
                        AccountLimitsView(model: model, maxListHeight: limitsPlacement.listHeight)
                    }
                HStack {
                    Circle().fill(model.currentAgentConnected ? Color.primary : .secondary).frame(width: .ui(6), height: .ui(6))
                    Text(model.currentAgent == .appClaude ? (model.claudeAuthenticated ? L10n.text("Claude · подключён", "Claude · connected") : L10n.text("Claude · вход не выполнен", "Claude · not signed in")) : (model.connecting ? L10n.text("Подключение…", "Connecting…") : model.accountLabel)).font(.ui(.caption)).lineLimit(1)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(PointerButtonStyle(base: .plain))
                }.padding(.ui(14))
            }.background(DeskPalette.sidebar)
                .navigationSplitViewColumnWidth(min: .ui(240), ideal: .ui(285), max: .ui(380))
                .background(SidebarWidthLimits(min: .ui(240), ideal: .ui(285), max: .ui(380)))
    }
    private var sidebarScrollerReserve: CGFloat {
        guard scrollerStyle == .legacy, sidebarContentHeight <= sidebarViewportHeight else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
    private var detail: some View {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.blue)
                        Text(error).font(.ui(.callout)).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Закрыть", "Close"))
                    }.padding().background(.blue.opacity(0.08))
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
            }.navigationTitle(detailTitle)
                .navigationSubtitle(detailSubtitle)
                .modifier(ZoomedWindowTitle(title: detailTitle, subtitle: detailSubtitle))
    }
    private var detailTitle: String {
        model.showingArchive ? L10n.text("Архив", "Archive") : model.showingAttention ? L10n.text("Важное", "Important") : model.showingJobs ? L10n.text("Расписание", "Schedule") : (model.selectedChat?.title ?? L10n.text("Новый чат", "New chat"))
    }
    private var detailSubtitle: String {
        model.showingArchive || model.showingJobs || model.showingAttention ? "" : model.selectedProject?.name ?? ""
    }
    private var notificationsPanel: some View {
            VStack(alignment: .leading, spacing: .ui(16)) {
                HStack {
                    Label(L10n.text("Уведомления", "Notifications"), systemImage: "bell.fill").font(.ui(.headline)).foregroundStyle(.blue)
                    Spacer()
                    Button(L10n.text("Очистить", "Clear")) { model.notices.removeAll() }.disabled(model.notices.isEmpty)
                }
                Button(L10n.text("Включить уведомления macOS", "Enable macOS notifications")) { Task { await model.enableNotifications() } }
                Text(model.notificationStatus).font(.ui(.caption)).foregroundStyle(.secondary)
                if model.notices.isEmpty { Text(L10n.text("Новых уведомлений нет", "No new notifications")).foregroundStyle(.secondary).padding(.vertical) }
                ScrollView {
                    VStack(spacing: .ui(8)) {
                        ForEach(model.notices) { notice in
                            Button {
                                showingNotifications = false
                                Task { await model.focusAction(threadID: notice.threadID) }
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: "bubble.left.fill").foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: .ui(5)) {
                                        Text(notice.title).fontWeight(.medium)
                                        Text(notice.detail).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.padding(.ui(12)).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(PointerButtonStyle(base: .plain))
                        }
                    }
                }.frame(maxHeight: 320)
            }.padding(.ui(20)).frame(width: .ui(350))
    }
    private func adjacentProjectMove(_ project: Project, offset: Int) -> (() -> Void)? {
        let projects = model.state.visibleProjects
        guard let index = projects.firstIndex(where: { $0.id == project.id }),
              projects.indices.contains(index + offset) else { return nil }
        let targetID = projects[index + offset].id
        return { _ = model.moveProject(project.id, to: targetID) }
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
                }, moveUp: adjacentProjectMove(project, offset: -1), moveDown: adjacentProjectMove(project, offset: 1),
                   remove: { Task { await model.hideProject(project.id) } },
                   rename: { startRenaming(project) }, menuShown: menuShown("project:\(project.id)"),
                   hovered: hover("project:\(project.id)")) {
                    HStack(spacing: .ui(9)) {
                        Image(systemName: "chevron.right")
                            .font(.ui(.caption).weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: .ui(10), height: .ui(16))
                            .foregroundStyle(.secondary)
                        Image(systemName: model.projectID == project.id ? "folder.fill" : "folder")
                        Text(project.name).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 0)
                        let projectChats = model.state.chats.filter { $0.projectID == project.id && !$0.isArchived }
                        if projectChats.contains(where: { chat in model.pending.contains { $0.threadID == chat.id } || model.restartWaitingChatIDs.contains(chat.id) }) {
                            Circle().fill(.yellow).frame(width: .ui(7), height: .ui(7))
                                .help(L10n.text("Есть чаты, которые ждут действия или перезапуска", "Chats are waiting for action or a restart"))
                                .accessibilityLabel(L10n.text("Есть чаты, которые ждут действия или перезапуска", "Chats are waiting for action or a restart"))
                        } else if projectChats.contains(where: \.hasUnreadResponse) {
                            Circle().fill(.blue).frame(width: .ui(7), height: .ui(7))
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
                        Button { startChat(in: project) } label: {
                            Label(L10n.text("Новый чат", "New chat"), systemImage: "square.and.pencil")
                        }
                        Divider()
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                        } label: {
                            Label(L10n.text("Открыть в Finder", "Open in Finder"), systemImage: "folder")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.path, forType: .string)
                        } label: {
                            Label(L10n.text("Скопировать путь", "Copy path"), systemImage: "doc.on.doc")
                        }
                        Button {
                            selection.select(model.state.orderedChats(projectID: project.id, archived: false).map(\.id))
                        } label: {
                            Label(L10n.text("Выделить все чаты", "Select all chats"), systemImage: "checkmark.circle")
                        }.disabled(!model.state.chats.contains { $0.projectID == project.id && !$0.isArchived })
                        Button { startRenaming(project) } label: {
                            Label(L10n.text("Переименовать…", "Rename…"), systemImage: "pencil")
                        }
                        Button { permissionsProject = project } label: {
                            Label(L10n.text("Разрешения…", "Permissions…"), systemImage: "lock.shield")
                        }
                        Divider()
                        Button(L10n.text("Переместить выше", "Move up")) {
                            adjacentProjectMove(project, offset: -1)?()
                        }.disabled(adjacentProjectMove(project, offset: -1) == nil)
                        Button(L10n.text("Переместить ниже", "Move down")) {
                            adjacentProjectMove(project, offset: 1)?()
                        }.disabled(adjacentProjectMove(project, offset: 1) == nil)
                        Divider()
                        Button { Task { await model.hideProject(project.id) } } label: {
                            Label(L10n.text("Убрать проект из списка", "Remove project from list"), systemImage: "minus.circle")
                        }
                        .help(L10n.text("Файлы и чаты сохранятся. Вернуть проект можно через «Добавить проект».", "Files and chats are kept. Restore it with Add project."))
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
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargetProjectID == project.id || menuRowID == "project:\(project.id)" ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
            .background(model.projectID == project.id && model.chatID == nil && !model.showingJobs && !model.showingAttention && !model.showingArchive ? DeskPalette.selection
                        : rowHighlighted("project:\(project.id)") ? DeskPalette.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 8))

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

    private func chatActions(_ chat: Chat, reorder: Bool) -> [ChatRowAction] {
        var actions: [ChatRowAction] = []
        if selection.contains(chat.id) && selection.ids.count > 1 {
            let count = selection.ids.count
            return [
                ChatRowAction(title: L10n.text("Архивировать выбранные (\(count))", "Archive selected (\(count))"), enabled: canArchiveSelection) { archiveSelection() },
                ChatRowAction(title: L10n.text("Снять выделение", "Deselect all")) { selection.clear() }
            ]
        }
        if model.runningBrowserChats[chat.id] != nil {
            actions.append(ChatRowAction(title: L10n.text("Показать браузер этого чата", "Show this chat’s browser")) { model.showBrowser(chatID: chat.id) })
        }
        if reorder {
            let siblings = model.state.orderedChats(projectID: chat.projectID, archived: chat.isArchived)
            if let index = siblings.firstIndex(where: { $0.id == chat.id }) {
                for (offset, title) in [(-1, L10n.text("Переместить выше", "Move up")), (1, L10n.text("Переместить ниже", "Move down"))] {
                    let target = siblings.indices.contains(index + offset) ? siblings[index + offset].id : nil
                    actions.append(ChatRowAction(title: title, enabled: target != nil) {
                        if let target { _ = model.moveChat(chat.id, to: target) }
                    })
                }
            }
        }
        actions += [
            ChatRowAction(title: chat.isPinned ? L10n.text("Открепить из избранного", "Unpin from favorites") : L10n.text("Закрепить в избранном", "Pin to favorites")) { model.toggleChatPin(chat.id) },
            ChatRowAction(title: L10n.text("Переименовать…", "Rename…")) { renaming = chat; newTitle = chat.title },
            ChatRowAction(title: chat.isArchived ? L10n.text("Восстановить из архива", "Restore from archive") : L10n.text("Архивировать", "Archive"), enabled: model.canDeleteChat(chat.id)) {
                Task {
                    await model.setChatArchived(chat.id, archived: !chat.isArchived)
                }
            },
            ChatRowAction(title: L10n.text("Удалить чат…", "Delete chat…"), enabled: model.canDeleteChat(chat.id)) { deleting = chat }
        ]
        return actions
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
                           actions: chatActions(chat, reorder: false), favorite: true, menuShown: menuShown(rowID), hovered: hover(rowID))
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
                        }, actions: chatActions(chat, reorder: true), menuShown: menuShown(rowID), hovered: hover(rowID))
                    }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((!favorite && dropTargetChatID == chat.id) || menuRowID == rowID ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
        .background(chatBackground(chat, favorite: favorite, highlighted: rowHighlighted(rowID)), in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.isChangingChat(chat.id))
    }

    private var activeChatIDs: Set<String> {
        Set(model.state.chats.lazy.filter { !$0.isArchived }.map(\.id))
    }
    private var canArchiveSelection: Bool {
        !archivingSelection && selection.ids.allSatisfy { model.canDeleteChat($0) }
    }
    private func chatBackground(_ chat: Chat, favorite: Bool, highlighted: Bool) -> Color {
        if !favorite && selection.contains(chat.id) { return Color.accentColor.opacity(0.18) }
        if model.chatID == chat.id && !model.showingJobs && !model.showingAttention && !model.showingArchive { return DeskPalette.selection }
        return highlighted ? DeskPalette.rowHover : .clear
    }
    private func menuShown(_ rowID: String) -> (Bool) -> Void {
        { shown in
            if shown { menuRowID = rowID } else if menuRowID == rowID { menuRowID = nil }
        }
    }
    private func hover(_ source: String) -> (Bool) -> Void {
        { inside in
            if inside { hoveredRows.insert(source) } else { hoveredRows.remove(source) }
        }
    }
    private func rowHighlighted(_ rowID: String) -> Bool {
        menuRowID == rowID || hoveredRows.contains(rowID) || hoveredRows.contains(rowID + "#tools")
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
                .help(canArchiveSelection ? L10n.text("Архивировать выбранные чаты", "Archive the selected chats") : L10n.text("Дождись завершения работы в выбранных чатах", "Wait until the selected chats are idle"))
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
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
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
                    Image(systemName: "globe").font(.ui(.caption2)).foregroundStyle(.teal)
                        .help(L10n.text("Браузер этого чата открыт. Показать его можно из контекстного меню чата или меню «Браузеры».",
                                        "This chat’s browser is open. Show it from the chat’s context menu or the Browsers menu."))
                        .accessibilityLabel(L10n.text("Браузер открыт", "Browser is open"))
                }
                if chat.isPinned {
                    Image(systemName: "pin.fill").font(.ui(.caption2)).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("В избранном", "In favorites"))
                }
                Spacer(minLength: 0)
                // Yellow: the chat waits for the user or for the app restart. Blue: an unread response.
                if model.restartWaitingChatIDs.contains(chat.id) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.ui(.caption)).foregroundStyle(.yellow)
                        .help(L10n.text("Ждёт перезапуска приложения", "Waiting for the app restart"))
                        .accessibilityLabel(L10n.text("Ждёт перезапуска приложения", "Waiting for the app restart"))
                }
                if model.pending.contains(where: { $0.threadID == chat.id }) {
                    Circle().fill(.yellow).frame(width: .ui(7), height: .ui(7))
                        .help(L10n.text("Требуется действие", "Action required"))
                        .accessibilityLabel(L10n.text("Требуется действие", "Action required"))
                } else if chat.hasUnreadResponse {
                    Circle().fill(.blue).frame(width: .ui(7), height: .ui(7))
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

struct DeskButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.ui(.callout).weight(.medium)).padding(.horizontal, .ui(14)).padding(.vertical, .ui(10))
            .background(configuration.isPressed ? DeskPalette.selection : DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .pointingHandCursor()
    }
}

struct ChatView: View {
    @ObservedObject var model: DeskModel
    @State private var followOutput = true
    @State private var showingUsage = false
    @State private var composerFocused = false
    @State private var composerHeight: CGFloat = 22
    @State private var handoff: ContextHandoff?
    @State private var fileDropTargeted = false
    @StateObject private var dropWatchdog = DropTargetWatchdog()
    /// Files opened from answers in the preview pane, with back/forward history.
    @StateObject private var preview = DocumentPreviewSession()
    /// Composer column: the transcript's readable text width (magnified with the interface zoom) plus the composer's side insets.
    private var columnWidth: CGFloat { InterfaceZoom.shared.scaled(TranscriptScrollView.readableWidth) + 48 }
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
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if let origin = model.selectedChat?.handoffOrigin {
                HStack {
                    Text(L10n.text("Контекст из чата", "Context from chat") + ": " + origin.conversation.value)
                        .font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L10n.text("Вернуть исходный контекст в черновик", "Restore initial context to draft")) { Task { await model.restoreHandoffDraft() } }.disabled(!model.draft.isEmpty)
                }.padding(.horizontal, 24)
            }
            ChatHistoryView(model: model, transcript: model.transcript, followOutput: followOutput, onOpenFile: openPreview)
            if let action = model.currentAction {
                ActionView(action: action, model: model).id(action.id)
                    .task(id: "\(action.id):\(model.loadingChat)") {
                        if NSApplication.shared.isActive { model.markActionRead(action) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        model.markActionRead(action)
                    }
                    .padding(12)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)).tint(.blue).padding(.horizontal, 24)
            }
            if let chat = model.selectedChat, chat.isScheduledRecord, !model.selectedChatIsArchived {
                Label(DeskModel.scheduledRecordFollowUpNotice, systemImage: "clock.arrow.circlepath")
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if let chat = model.selectedChat { SubagentsBar(model: model, chatID: chat.id) }
            if let chat = model.selectedChat, let notice = model.backgroundWaitNotice(chat.id) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
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
                .frame(maxWidth: columnWidth, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if model.selectedChatIsArchived, let chat = model.selectedChat {
                HStack {
                    Label(L10n.text("Чат в архиве.", "This chat is archived."), systemImage: "archivebox")
                    Spacer()
                    Button(L10n.text("Восстановить", "Restore")) { Task { await model.setChatArchived(chat.id, archived: false) } }
                        .disabled(!model.canDeleteChat(chat.id))
                }.frame(maxWidth: columnWidth).padding(.horizontal, 24).padding(.vertical, 12)
            }
            if !model.visibleQueue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.queuePaused ? L10n.text("Очередь приостановлена", "Queue paused") : L10n.text("В очереди · \(model.visibleQueue.count)", "Queued · \(model.visibleQueue.count)"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.queuePaused && model.priorityMessageID == nil {
                            Button(L10n.text("Продолжить", "Resume")) { model.resumeQueue() }.disabled(model.busy || !model.connected || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
                        }
                    }.font(.ui(.caption))
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.visibleQueue) { message in
                                HStack(alignment: .center, spacing: 12) {
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
                                }.padding(10)
                                    .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.frame(maxHeight: min(CGFloat(model.visibleQueue.count) * 78, 180))
                }.frame(maxWidth: columnWidth).padding(.horizontal, 24).padding(.top, 8)
            }
            if !model.selectedChatIsArchived {
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty { Text(model.selectedChat?.isScheduledRecord == true ? L10n.text("Ответить в новом чате…", "Reply in a new chat…") : L10n.text("Напиши сообщение…", "Write a message…")).foregroundStyle(.secondary).padding(.horizontal, 21).padding(.top, 16).allowsHitTesting(false) }
                    MessageComposer(text: $model.draft, focused: $composerFocused, focusRequest: model.composerFocusRequest,
                                    onContentHeight: { composerHeight = $0 }) { Task { await model.send() } }
                        .frame(height: min(max(composerHeight, 40), 220)).padding(.horizontal, 16).padding(.top, 14).accessibilityLabel(L10n.text("Сообщение", "Message"))
                }
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
                            if model.selectedChat != nil { Text(model.projectRoleTitle).tag(Optional<String>.none) }
                            ForEach(model.roleCatalog.interactive) { role in Text(role.title).tag(Optional(role.id)) }
                        }.pickerStyle(.inline).labelsHidden()
                    }.disabled(model.busy || model.sending)
                        .help(model.currentRole.summary + " " + L10n.text("В новом чате задаёт роль по умолчанию для проекта; в существующем — роль этого чата. Применяется со следующего сообщения.", "In a new chat, sets the project's default role; in an existing chat, this chat's role. Applies from the next message."))
                    Spacer()
                    if model.chatID == nil {
                        ChipMenu(title: model.currentAgent == .appClaude ? "Claude" : "Codex", systemImage: "sparkle") {
                            Picker(L10n.text("Провайдер", "Provider"), selection: Binding(get: { model.currentAgent }, set: { model.selectAgent($0) })) {
                                Text("Codex").tag(AgentConnectionID.originalCodex)
                                Text("Claude").tag(AgentConnectionID.appClaude)
                            }.pickerStyle(.inline).labelsHidden()
                        }.disabled(model.sending)
                            .help(L10n.text("Провайдер нового чата", "Provider for the new chat"))
                    } else {
                        ChipLabel(title: model.currentAgentName, systemImage: "sparkle")
                            .font(.ui(.callout)).foregroundStyle(.secondary).padding(.horizontal, 9)
                            .help(L10n.text("Провайдер этого чата", "Provider for this chat"))
                    }
                    if model.currentAgent == .appClaude {
                        ClaudeModelSelector(model: model)
                        ClaudeEffortPicker(model: model)
                    } else if !model.models.isEmpty {
                        ChipMenu(title: model.currentModel.isEmpty ? L10n.text("Авто", "Auto")
                                 : model.models.first(where: { $0.id == model.currentModel })?.displayName ?? model.currentModel) {
                            Picker(L10n.text("Модель", "Model"), selection: Binding(get: { model.currentModel }, set: { model.selectModel($0) })) {
                                Text(L10n.text("Авто", "Auto")).tag("")
                                if !model.currentModel.isEmpty && !model.models.contains(where: { $0.id == model.currentModel }) {
                                    Text(model.currentModel).tag(model.currentModel)
                                }
                                ForEach(model.models, id: \.self) { entry in Text(entry.displayName).tag(entry.id) }
                            }.pickerStyle(.inline).labelsHidden()
                        }.disabled(model.busy)
                        if !model.supportedEfforts.isEmpty {
                            ChipMenu(title: model.effort.isEmpty ? L10n.text("Авто", "Auto") : model.effort) {
                                Picker(L10n.text("Рассуждение", "Reasoning"), selection: Binding(get: { model.effort }, set: { model.effort = $0 })) {
                                    Text(L10n.text("Авто", "Auto")).tag("")
                                    if !model.effort.isEmpty && !model.supportedEfforts.contains(model.effort) {
                                        Text(model.effort).tag(model.effort)
                                    }
                                    ForEach(model.supportedEfforts, id: \.self) { Text($0).tag($0) }
                                }.pickerStyle(.inline).labelsHidden()
                            }.disabled(model.busy)
                        }
                    }
                    // One round control: stop while a response runs and nothing is typed, otherwise send or queue.
                    if model.busy && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { Task { await model.interrupt() } } label: {
                            Image(systemName: "stop.fill").font(.ui(size: 11)).frame(width: 32, height: 32)
                                .foregroundStyle(.white).background(DeskPalette.ink, in: Circle())
                        }.buttonStyle(PointerButtonStyle(base: .plain)).padding(.leading, 6)
                            .help(L10n.text("Остановить ответ", "Stop response")).accessibilityLabel(L10n.text("Остановить ответ", "Stop response"))
                    } else {
                        Button { Task { await model.send() } } label: {
                            Image(systemName: "arrow.up").font(.ui(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                                .foregroundStyle(.white)
                                .background(DeskPalette.ink.opacity(model.canSend ? 1 : 0.2), in: Circle())
                        }.buttonStyle(PointerButtonStyle(base: .plain)).keyboardShortcut(.return, modifiers: .command).disabled(!model.canSend).padding(.leading, 6)
                            .help(model.busy ? L10n.text("Добавить в очередь · Enter. Shift+Enter — новая строка", "Add to queue · Enter. Shift+Enter for a new line") : L10n.text("Отправить · Enter. Shift+Enter — новая строка", "Send · Enter. Shift+Enter for a new line")).accessibilityLabel(L10n.text("Отправить сообщение", "Send message"))
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.background(DeskPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(composerFocused ? DeskPalette.focusBorder : DeskPalette.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
                .frame(maxWidth: columnWidth).padding(.horizontal, 24).padding(.top, 10)
            }
            HStack(spacing: 12) {
                if model.currentRoute != .direct {
                    Text(model.routeTitle(model.currentRoute)).help(model.routeMessage(model.currentRoute))
                }
                if !model.routeIsAvailable(model.currentRoute) {
                    Text(L10n.text("Недоступен", "Unavailable")).foregroundStyle(.orange)
                }
                Button { showingUsage.toggle() } label: {
                    Text(UsageDetail.footer(model.currentUsage))
                }.buttonStyle(PointerButtonStyle(base: .plain)).popover(isPresented: $showingUsage) { UsageDetail(usage: model.currentUsage, claude: model.currentAgent == .appClaude).padding(20).frame(width: 330) }
                if let usage = model.currentUsage, usage.cacheTTL != nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let state = usage.cacheState(now: context.date) {
                            Text(UsageDetail.cacheBadge(state))
                                .foregroundStyle(state.needsAttention ? Color.orange : Color.secondary)
                                .help(UsageDetail.cacheHelp)
                        }
                    }
                }
                Spacer()
                Toggle(L10n.text("Следить за ответом", "Follow response"), isOn: $followOutput).toggleStyle(.checkbox).pointingHandCursor()
            }.font(.ui(.caption2)).foregroundStyle(.secondary).padding(.horizontal, 12)
                .frame(maxWidth: columnWidth).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
        }
        .background(DeskPalette.canvas)
        // The whole chat accepts dropped files, such as a screenshot thumbnail, and adds their paths to the draft.
        .onDrop(of: [.fileURL], delegate: ChatFileDrop(enabled: !model.selectedChatIsArchived, targeted: $fileDropTargeted) { model.addDroppedFiles($0) })
        .overlay {
            if fileDropTargeted && !model.selectedChatIsArchived {
                RoundedRectangle(cornerRadius: 16).fill(DeskPalette.subtle.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DeskPalette.focusBorder, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    .overlay(Label(L10n.text("Отпусти, чтобы добавить путь к файлу в сообщение", "Drop to add the file path to the message"), systemImage: "photo.badge.plus")
                        .font(.ui(.title3).weight(.medium)).foregroundStyle(.secondary))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .modifier(DropTargetRecovery(targeted: $fileDropTargeted, watchdog: dropWatchdog) { model.focusComposer() })
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let chat = model.selectedChat {
                    if model.state.browserEnabled == true, let session = chat.nativeSession,
                       [.originalCodex, .appClaude].contains(session.connection) {
                        ChatBrowserControls(session: session, project: model.selectedProject?.path ?? "",
                                            busy: model.isBusy(threadID: chat.id) || model.isChangingChat(chat.id),
                                            ownerNames: model.browserProfileOwnerNames) { action in
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
                    NewChatBrowserProfilePicker(project: project.path, connection: model.currentAgent, ownerNames: model.browserProfileOwnerNames, selection: Binding(
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
                DocumentPreviewView(session: preview, model: current)
                    .id(current.id)
                    .inspectorColumnWidth(min: 320, ideal: 520, max: 1100)
            }
        }
        .overlay {
            if preview.expanded, let current = preview.current {
                DocumentPreviewView(session: preview, model: current)
                    .id(current.id)
                    .background(DeskPalette.canvas)
            }
        }
        .onChange(of: preview.expanded) { _, expanded in model.documentExpanded = expanded }
        .onDisappear { model.documentExpanded = false }
    }

    private func openPreview(_ url: URL, line: Int?) {
        preview.open(url, line: line)
    }
}

/// Only this subtree observes streamed text; the composer/sidebar/settings do not.
struct ChatHistoryView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var transcript: TranscriptPresentation
    let followOutput: Bool
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
            NativeTranscript(items: renderedItems, conversationID: model.chatID, followOutput: followOutput,
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
        Button(title) { model.draft = prompt }.buttonStyle(DeskButtonStyle())
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
                        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
                if let issue = job.issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Divider()
                Text(L10n.text("Задание", "Task")).font(.ui(.headline))
                Text(job.prompt).textSelection(.enabled)
                if let thread = job.targetThread { Text(L10n.text("Исходный чат: \(thread)", "Source chat: \(thread)")).font(.ui(.caption)).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DeskModel
    let keepAwake: KeepAwake
    @AppStorage(AppLanguage.preferenceKey) private var selectedLanguage = L10n.language.rawValue
    @AppStorage("parallelBrowserLimit") private var parallelBrowserLimit = 2
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettings
                .tabItem { Label(L10n.text("Основные", "General"), systemImage: "gearshape") }
                .tag("general")
            accountsSettings
                .tabItem { Label(L10n.text("Аккаунты", "Accounts"), systemImage: "person.crop.circle") }
                .tag("accounts")
            browserSettings
                .tabItem { Label(L10n.text("Браузер", "Browser"), systemImage: "globe") }
                .tag("browser")
            pluginsSettings
                .tabItem { Label(L10n.text("Плагины", "Plugins"), systemImage: "puzzlepiece.extension") }
                .tag("plugins")
            mobileSettings
                .tabItem { Label(L10n.text("Мобильный доступ", "Mobile access"), systemImage: "iphone") }
                .tag("mobile")
            PermissionsLedgerView(model: model)
                .tabItem { Label(L10n.text("Разрешения", "Permissions"), systemImage: "lock.shield") }
                .tag("permissions")
            dataSettings
                .tabItem { Label(L10n.text("Данные", "Data"), systemImage: "externaldrive") }
                .tag("data")
        }
        .frame(height: 560)
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
            Section(L10n.text("Уведомления", "Notifications")) {
                Text(model.notificationStatus).font(.ui(.callout))
                Button(L10n.text("Разрешить уведомления", "Allow notifications")) { Task { await model.enableNotifications() } }
            }
            KeepAwakeSettings(controller: keepAwake)
            OrphanProcessSettings(controller: model.orphanProcesses)
            NotchIslandSettings()
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
                Text(L10n.text("Официальный Claude Code \(ClaudeRuntime.pinnedVersion). Вход открывается в Terminal, в отдельном профиле Switchboard. После входа нажми «Проверить вход». Существующий профиль Claude Code не изменяется.", "Official Claude Code \(ClaudeRuntime.pinnedVersion). Sign-in opens in Terminal using a separate Switchboard profile. Afterwards, click Check sign-in. Your existing Claude Code profile is unchanged."))
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
                Text(L10n.text("Более сильная модель, с которой Claude советуется перед выбором подхода, при повторяющейся ошибке и перед завершением задачи. Подключается только к чатам и задачам на более слабой модели: Sonnet или Haiku получат Opus, Opus получит только Fable. Советы расходуют лимиты подписки, Fable может списывать кредиты. Применяется со следующего сообщения.", "A stronger model Claude consults before choosing an approach, on a recurring error and before finishing a task. It applies only to chats and jobs on a weaker model: Sonnet or Haiku get Opus, Opus gets only Fable. Advice counts toward subscription limits; Fable may use usage credits. Takes effect from the next message."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var browserSettings: some View {
        Form {
            Section(L10n.text("Браузер", "Browser")) {
                Toggle(L10n.text("Использовать Chrome DevTools", "Use Chrome DevTools"),
                       isOn: Binding(get: { model.state.browserEnabled == true }, set: { model.selectBrowserEnabled($0) }))
                Text(L10n.text("У каждого чата свой Chrome for Testing и сохранённый профиль. Чаты работают параллельно. В меню «Браузер» можно импортировать входы из выбранного профиля Chrome или войти на сайты вручную. Браузеры остаются открытыми после переподключения.", "Each chat has its own Chrome for Testing and saved profile. Chats work in parallel. Use the Browser menu to import sign-ins from a selected Chrome profile, or sign in manually. Browsers stay open after reconnecting."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                Picker(L10n.text("Одновременно открытых браузеров", "Simultaneously open browsers"), selection: $parallelBrowserLimit) {
                    ForEach(1...8, id: \.self) { Text(String($0)).tag($0) }
                }
                Text(L10n.text("По умолчанию — 2. При достижении лимита заверши неиспользуемый Chrome через Cmd+Q. Новый лимит применяется после переподключения; открытые браузеры автоматически не закрываются.", "Default: 2. At the limit, quit an unused Chrome with Cmd+Q. Apply the new limit by reconnecting; open browsers are never closed automatically."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                Button(L10n.text("Инструкция по установке", "Installation instructions")) {
                    if let resources = Bundle.main.resourceURL {
                        NSWorkspace.shared.open(resources.appendingPathComponent("BrowserRuntime/README.md"))
                    }
                }
                Button(model.connecting ? L10n.text("Подключение…", "Connecting…") : L10n.text("Применить настройку браузера", "Apply browser setting")) {
                    Task { await model.connect() }
                }.disabled(model.anyBusy || model.connecting)
                if model.anyBusy {
                    Text(L10n.text("Кнопка недоступна, пока выполняются задачи в чатах или фоновая обработка. Дождись их завершения либо останови нужную задачу в её чате, затем примени настройку. Текущие действия браузера автоматически не повторяются.", "This button is unavailable while chats or background tasks are running. Wait for them to finish or stop the relevant task in its chat, then apply the setting. Browser actions are not automatically replayed."))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Text(L10n.text("Применяется при переподключении Codex после завершения текущих задач. Браузер открывается при первом обращении агента.", "Takes effect when Codex reconnects after current tasks finish. The browser opens on the agent’s first browser request."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
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

    private var pluginsSettings: some View {
        Form {
            Section(L10n.text("Плагины", "Plugins")) {
                Text(L10n.text("Плагины дополнительно обрабатывают запросы Codex. Они необязательны: выбери «Без плагина», чтобы работать напрямую.", "Plugins add processing to Codex requests. They are optional: choose No plugin to work directly."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                Picker(L10n.text("Для новых чатов", "For new chats"), selection: Binding(get: { model.defaultRoute }, set: { model.selectDefaultRoute($0) })) {
                    ForEach(model.availableRoutes, id: \.self) { route in
                        Text(model.routeTitle(route)).tag(route).disabled(model.routeCompatibilityIssue(route) != nil)
                    }
                }.pointingHandCursor()
                Text(model.routeMessage(model.defaultRoute)).font(.ui(.callout)).foregroundStyle(.secondary)
                Button(model.connecting ? L10n.text("Подключение…", "Connecting…") : L10n.text("Применить выбор", "Apply selection")) {
                    Task { await model.connect() }
                }.disabled(model.anyBusy || model.connecting)
                Text(L10n.text("Переподключает Codex, чтобы запустить выбранные плагины. Дождись завершения текущих задач. Существующие чаты сохраняют свой выбор плагина.", "Reconnects Codex to start the selected plugins. Wait for current tasks to finish. Existing chats keep their plugin selection."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                if model.plugins.isEmpty {
                    Text(L10n.text("Плагины пока не установлены. Codex может работать без них.", "No plugins installed yet. Codex can work without them."))
                        .font(.ui(.callout)).foregroundStyle(.secondary)
                }
                ForEach(model.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plugin.manifest.localizedTitle()) · \(plugin.manifest.version)").font(.ui(.headline))
                        if let description = plugin.manifest.descriptionTranslations {
                            Text(description.text()).font(.ui(.callout)).foregroundStyle(.secondary)
                        }
                        Text(model.routeMessage(plugin.route)).font(.ui(.caption)).foregroundStyle(.secondary)
                        Text("Codex: " + OptimizerCompatibility.summary(agent: .codex, requirements: plugin.manifest.requirements)).font(.ui(.caption))
                        Text("Claude Code: " + OptimizerCompatibility.summary(agent: .claudeCode, requirements: plugin.manifest.requirements)).font(.ui(.caption)).foregroundStyle(.secondary)
                        if let status = model.pluginStatuses[plugin.id] {
                            ForEach(status.metrics) { metric in
                                LabeledContent(metric.localizedTitle(), value: String(metric.value))
                            }
                        }
                    }
                }
                ForEach(model.pluginIssues, id: \.self) { Text($0).font(.ui(.caption)).foregroundStyle(.orange) }
                Button(L10n.text("Обновить список", "Refresh list")) { model.refreshPlugins() }.disabled(model.anyBusy || model.connecting)
                Button(L10n.text("Открыть папку плагинов", "Open plugins folder")) {
                    do {
                        try FileManager.default.createDirectory(at: model.pluginDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.pluginDirectory)
                    } catch { model.error = error.localizedDescription }
                }
                Text(L10n.text("Установи плагин с помощью его установщика, затем нажми «Обновить список».", "Use the plugin's installer, then click Refresh list."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var mobileSettings: some View {
        Form {
            MobileRemoteSettings(host: model.mobileRemote, model: model)
        }.formStyle(.grouped)
    }

    private var dataSettings: some View {
        Form {
            Section(L10n.text("История чатов", "Chat history")) {
                Button {
                    model.openArchive()
                    openWindow(id: "main")
                    dismiss()
                } label: {
                    Label(L10n.text("Открыть архив", "Open archive"), systemImage: "archivebox")
                }
                Text(L10n.text("Просматривай и восстанавливай архивные чаты всех проектов.", "Browse and restore archived chats from all projects."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            Section(L10n.text("Данные", "Data")) {
                Text(L10n.text("Разговоры и настройки этого приложения хранятся отдельно от текущего Codex.", "This app’s conversations and settings are stored separately from your existing Codex setup."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
                Button(L10n.text("Открыть папку данных", "Open data folder")) { NSWorkspace.shared.open(Locations.root) }
            }
        }.formStyle(.grouped)
    }
}
