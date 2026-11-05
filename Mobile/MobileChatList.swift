import SwiftUI

struct MobileChatDestination: Hashable { let device: String; let chat: String }

/// One row of a chat list section.
struct MobileChatEntry: Identifiable {
    let device: RemoteDevice
    let chat: RemoteChat
    let project: RemoteProject?
    var id: String { device.id + ":" + chat.id }
}

/// The signed-in home: connection line, "Needs you" and "Working" across all Macs and projects, then projects.
/// A chat in a top group is still listed in its project: the groups are shortcuts, the projects stay complete.
struct MobileChatList: View {
    @ObservedObject var model: MobileModel
    @Binding var search: String

    var body: some View {
        let multipleMacs = model.devices.count > 1
        let entries = model.devices.flatMap { device in
            device.snapshot.chats.map { chat in MobileChatEntry(device: device, chat: chat, project: device.snapshot.projects.first { $0.id == chat.project }) }
        }
        let needsYou = entries.filter { !$0.chat.approvals.isEmpty || model.receipt(MobileChatKey(device: $0.device.id, chat: $0.chat.id)) != nil }
        let working = entries.filter { $0.chat.running && !needsYou.map(\.id).contains($0.id) }
        let creations = model.pendingCreations
        List {
            if !model.devices.isEmpty {
                Section {
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.devices) { ConnectionStatus(model: model, device: $0, showsName: multipleMacs) }
                    }.textCase(nil)
                }
            }
            // Search lists matches in their projects only, so a result never appears twice.
            if search.isEmpty {
                if !needsYou.isEmpty || !creations.isEmpty {
                    MobileChatSection(id: "needs-you", title: L10n.text("Ждут тебя", "Needs you"), systemImage: "hand.raised.fill", tint: .orange,
                                      entries: needsYou, search: "", rowPrefix: "needs-row-", showsProject: true, showsMac: multipleMacs,
                                      extraCount: creations.count, model: model) {
                        ForEach(creations, id: \.id) { command in
                            NavigationLink(value: MobileChatDestination(device: command.device, chat: command.chat)) {
                                MobilePendingCreationRow(command: command, project: model.devices.first { $0.id.lowercased() == command.device.lowercased() }?
                                    .snapshot.projects.first { $0.id.lowercased() == command.project.lowercased() }?.name)
                            }.accessibilityIdentifier("creation-row-" + command.id)
                        }
                    }
                }
                if !working.isEmpty {
                    MobileChatSection(id: "working", title: L10n.text("Работают", "Working"), systemImage: "circle.dotted", tint: .accentColor,
                                      entries: working, search: "", rowPrefix: "working-row-", showsProject: true, showsMac: multipleMacs, model: model)
                }
            }
            ForEach(model.devices) { device in
                ForEach(device.snapshot.projects) { project in
                    MobileChatSection(id: device.id + ":" + project.id,
                                      title: multipleMacs ? project.name + " · " + device.name : project.name,
                                      entries: entries.filter { $0.device.id == device.id && $0.chat.project == project.id },
                                      search: search, rowPrefix: "chat-row-", disclosureID: project.id, model: model)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.devices.isEmpty {
                ContentUnavailableView(L10n.text("Подключи Mac", "Connect your Mac"), systemImage: "desktopcomputer",
                    description: Text(L10n.text("В настройках Switchboard на Mac выбери проекты и включи мобильный доступ.", "Select projects and enable mobile access in Switchboard settings on your Mac.")))
            } else if !search.isEmpty && !entries.contains(where: { $0.chat.title.localizedCaseInsensitiveContains(search) }) {
                ContentUnavailableView.search(text: search)
            } else if search.isEmpty && model.devices.allSatisfy({ $0.snapshot.projects.isEmpty }) {
                ContentUnavailableView(L10n.text("Нет проектов", "No projects"), systemImage: "folder",
                    description: Text(L10n.text("Выбери проекты для телефона в настройках проекта на Mac → Телефон.", "Choose projects for the phone in each project's settings on your Mac → Phone.")))
            }
        }
    }
}

/// A titled group of chats. Disclosure only changes presentation: five rows, then five more per tap.
/// The shared snapshot and live updates stay intact.
struct MobileChatSection<Extra: View>: View {
    let id: String
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    let entries: [MobileChatEntry]
    let search: String
    let rowPrefix: String
    /// Accessibility identifiers of the disclosure controls; projects keep their project ID.
    var disclosureID: String?
    var showsProject = false
    var showsMac = false
    /// Rows added by `extra`, counted in the header.
    var extraCount = 0
    @ObservedObject var model: MobileModel
    @ViewBuilder var extra: () -> Extra
    @State private var visibleCount = 5
    private let pageSize = 5

    var body: some View {
        let matches = search.isEmpty ? entries : entries.filter { $0.chat.title.localizedCaseInsensitiveContains(search) }
        let limit = search.isEmpty ? visibleCount : matches.count
        let remaining = max(0, matches.count - limit)
        let hiddenApprovals = matches.dropFirst(limit).filter { !$0.chat.approvals.isEmpty }.count
        let controls = disclosureID ?? id
        if !matches.isEmpty || search.isEmpty {
            Section {
                ForEach(matches.prefix(limit)) { entry in
                    NavigationLink(value: MobileChatDestination(device: entry.device.id, chat: entry.chat.id)) {
                        ChatRow(entry: entry, showsProject: showsProject, showsMac: showsMac,
                                unconfirmed: model.receipt(MobileChatKey(device: entry.device.id, chat: entry.chat.id)) != nil).equatable()
                    }.accessibilityIdentifier(rowPrefix + entry.chat.id)
                }
                extra()
                if matches.isEmpty {
                    Text(L10n.text("Пока нет чатов", "No chats yet")).foregroundStyle(.secondary)
                }
                if remaining > 0 {
                    Button {
                        visibleCount += pageSize
                    } label: {
                        HStack {
                            Label(L10n.text("Показать ещё", "Show more"), systemImage: "chevron.down")
                            Spacer()
                            Text(L10n.text("Осталось: \(remaining)", "Remaining: \(remaining)")).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("more-chats-" + controls)
                }
                if search.isEmpty && visibleCount > pageSize && entries.count > pageSize {
                    Button {
                        visibleCount = pageSize
                    } label: {
                        Label(L10n.text("Свернуть", "Show fewer"), systemImage: "chevron.up")
                    }.accessibilityIdentifier("fewer-chats-" + controls)
                }
            } header: {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true) }
                    Text(title).lineLimit(2)
                    Spacer()
                    let count = matches.count + extraCount
                    Text(count.formatted()).monospacedDigit()
                        .accessibilityLabel(L10n.text("Чатов: \(count)", "Chats: \(count)"))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } footer: {
                if disclosureID != nil && hiddenApprovals > 0 {
                    Label(L10n.text("Скрытые чаты ждут ответа: \(hiddenApprovals)", "Hidden chats needing your attention: \(hiddenApprovals)"),
                          systemImage: "hand.raised")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("hidden-approvals-" + controls)
                }
            }
        }
    }
}

extension MobileChatSection where Extra == EmptyView {
    init(id: String, title: String, systemImage: String? = nil, tint: Color = .secondary, entries: [MobileChatEntry], search: String,
         rowPrefix: String, disclosureID: String? = nil, showsProject: Bool = false, showsMac: Bool = false, model: MobileModel) {
        self.init(id: id, title: title, systemImage: systemImage, tint: tint, entries: entries, search: search, rowPrefix: rowPrefix,
                  disclosureID: disclosureID, showsProject: showsProject, showsMac: showsMac, model: model, extra: { EmptyView() })
    }
}

/// Row equality compares only what is displayed, so unrelated snapshot changes skip rebuilding it.
struct ChatRow: View, Equatable {
    let title: String
    let preview: String?
    let running: Bool
    let activity: String?
    let runningSince: String?
    let approvals: Int
    let readOnly: Bool
    let unconfirmed: Bool
    /// Project (and Mac) name in cross-project groups.
    let context: String?
    let agent: String?

    init(entry: MobileChatEntry, showsProject: Bool, showsMac: Bool, unconfirmed: Bool) {
        let chat = entry.chat
        title = chat.title; preview = chat.messages.last.map { MarkdownInline.plain($0.text) }
        running = chat.running; activity = chat.activity; runningSince = chat.runningSince
        approvals = chat.approvals.count; readOnly = chat.readOnly == true
        self.unconfirmed = unconfirmed
        let names = [showsProject ? entry.project?.name : nil, showsMac ? entry.device.name : nil].compactMap { $0 }
        context = names.isEmpty ? nil : names.joined(separator: " · ")
        agent = chat.agentTitle(in: entry.project)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                Text(preview ?? L10n.text("Пока нет сообщений", "No messages yet"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                statusLine.padding(.top, 2)
            }
            Spacer(minLength: 0)
            // One quiet status mark: orange when an answer is needed, a spinner while working.
            if approvals > 0 || unconfirmed {
                Circle().fill(Color.orange).frame(width: 10, height: 10).padding(.top, 6).accessibilityHidden(true)
            } else if running {
                ProgressView().controlSize(.small).padding(.top, 2).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusLine: some View {
        let meta = [context, agent].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 2) {
            if approvals > 0 {
                RowStatus(text: approvals > 1 ? L10n.text("Ждут ответа: \(approvals)", "Waiting for you: \(approvals)") : L10n.text("Нужен ответ", "Needs your attention"),
                          systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            } else if unconfirmed {
                RowStatus(text: L10n.text("Доставка не подтверждена", "Delivery unconfirmed"), systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            } else if running {
                HStack(spacing: 6) {
                    Text(activity ?? L10n.text("Работает", "Working")).lineLimit(1).truncationMode(.middle)
                    if let start = runningSince.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                        Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                }.foregroundStyle(Color.accentColor)
            }
            if readOnly {
                RowStatus(text: L10n.text("Только чтение", "Read-only"), systemImage: "lock")
                    .foregroundStyle(.secondary).accessibilityIdentifier("read-only-badge")
            }
            if !meta.isEmpty {
                Text(meta).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .font(.caption.weight(.medium))
    }
}

/// A new chat whose first command is unconfirmed; the Mac has not published it yet.
struct MobilePendingCreationRow: View {
    let command: RemoteCommand
    let project: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("Новый чат", "New chat")).font(.body.weight(.semibold))
            Text(command.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            RowStatus(text: L10n.text("Доставка не подтверждена", "Delivery unconfirmed"), systemImage: "questionmark.circle")
                .font(.caption.weight(.medium)).foregroundStyle(.orange)
            if let project { Text(project).font(.caption.weight(.medium)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A compact icon and text for row status lines; `Label` spaces them too widely at caption size.
struct RowStatus: View {
    let text: String
    let systemImage: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            Text(text)
        }
    }
}
