import SwiftUI
import Observation
import ContextCore
import ContextTranscript

@MainActor struct ManagedChromeTabButton: View {
    @ObservedObject var model: DeskModel
    let monitor: ManagedChromeInventory
    let chatID: String

    private var showing: Binding<Bool> {
        Binding(get: { monitor.presentedChatID == chatID }, set: { presented in
            if presented { monitor.presentedChatID = chatID }
            else if monitor.presentedChatID == chatID { monitor.closePanel() }
        })
    }
    private var tabs: [UserChromeControl.ManagedTab] { monitor.tabsByChat[chatID, default: []] }
    private var title: String {
        tabs.isEmpty ? L10n.text("Мой Chrome", "My Chrome") : L10n.text("Использует мой Chrome", "Uses My Chrome")
    }
    private var releaseFailed: Bool { monitor.releaseFailedChatID == chatID }
    var body: some View {
        if !tabs.isEmpty || showing.wrappedValue || releaseFailed {
            Button { showing.wrappedValue.toggle() } label: {
                HStack(spacing: .ui(4)) {
                    Image(systemName: monitor.refreshFailed || releaseFailed ? "exclamationmark.circle" : "macwindow.on.rectangle")
                    Text(title)
                    if !tabs.isEmpty {
                        Text("\(tabs.count)").monospacedDigit()
                    }
                }
                .foregroundStyle(monitor.refreshFailed || releaseFailed ? DeskPalette.attention : DeskPalette.browser)
            }
            .pointingHandCursor()
            .help(([title] + tabs.map(tabTitle)).joined(separator: "\n"))
            .accessibilityLabel(title)
            .accessibilityValue(monitor.refreshFailed
                ? L10n.text("Список недоступен", "Tab list unavailable") : "\(tabs.count)")
            .popover(isPresented: showing, arrowEdge: .top) { inventory }
        }
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: .ui(10)) {
            Text(L10n.text("Основной Chrome", "Main Chrome")).font(.ui(.headline))
            if monitor.refreshFailed {
                Text(L10n.text("Не удалось обновить список вкладок.", "Could not refresh the tab list."))
                    .font(.ui(.caption)).foregroundStyle(DeskPalette.attention)
            }
            if releaseFailed, monitor.unconfirmed.isDisjoint(with: tabs.map(\.id)) {
                Text(L10n.text("Освобождение вкладки не подтверждено.", "Release of the tab was not confirmed."))
                    .font(.ui(.caption)).foregroundStyle(DeskPalette.attention)
            }
            if tabs.isEmpty && !monitor.refreshFailed {
                Text(L10n.text("Нет вкладок под управлением.", "No managed tabs."))
                    .foregroundStyle(.secondary)
            } else if !tabs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: .ui(10)) {
                        ForEach(tabs) { tab in
                            tabRow(tab)
                            if tab.id != tabs.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: .ui(360))
            }
        }
        .padding(.ui(14))
        .frame(width: .ui(380))
    }

    private func tabRow(_ tab: UserChromeControl.ManagedTab) -> some View {
        let title = tabTitle(tab)
        let status = activity(tab.operation)
        return HStack(alignment: .top, spacing: .ui(12)) {
            VStack(alignment: .leading, spacing: .ui(3)) {
                Text(title).fontWeight(.medium).lineLimit(1).help(title)
                if let chatStatus = chatActivity(tab.chatId) {
                    Text(chatStatus).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).help(chatStatus)
                }
                Text([tab.profileName, status].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                if monitor.unconfirmed.contains(tab.id) {
                    Text(L10n.text("Освобождение не подтверждено.", "Release was not confirmed."))
                        .font(.ui(.caption)).foregroundStyle(DeskPalette.attention)
                }
            }
            Spacer(minLength: 0)
            Button(monitor.releasing == tab.id ? L10n.text("Освобождаем…", "Releasing…")
                   : L10n.text("Освободить", "Release")) {
                monitor.release(tab)
            }
            .disabled(monitor.releasing != nil || monitor.unconfirmed.contains(tab.id))
            .help(L10n.text("Остановить управление и оставить вкладку открытой", "Stop control and keep the tab open"))
            .accessibilityLabel(L10n.text("Освободить вкладку \(title)", "Release tab \(title)"))
        }
    }

    private func chatActivity(_ id: String) -> String? {
        if model.pending.contains(where: { $0.threadID == id }) || model.settingsProposalsByChat[id] != nil {
            return L10n.text("Чат ждёт ответа", "Chat needs a response")
        }
        if model.isBusy(threadID: id) {
            return model.runActivity(threadID: id).status ?? L10n.text("Чат работает", "Chat is working")
        }
        if model.isSending(threadID: id) { return L10n.text("Отправляет сообщение", "Sending message") }
        if let wait = model.backgroundWaitNotice(id) { return wait }
        return model.hasChat(id) ? L10n.text("Чат неактивен", "Chat is idle") : nil
    }

    private func tabTitle(_ tab: UserChromeControl.ManagedTab) -> String {
        tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Вкладка \(tab.tabId)", "Tab \(tab.tabId)")
    }

    private func activity(_ operation: String?) -> String {
        switch operation {
        case nil: L10n.text("Вкладка без действий", "Tab idle")
        case "open": L10n.text("Открывает страницу", "Opening page")
        case "release", "release-lease": L10n.text("Освобождает вкладку", "Releasing tab")
        case "read", "find": L10n.text("Читает страницу", "Reading page")
        case "screenshot": L10n.text("Снимает скриншот", "Taking screenshot")
        case "input": L10n.text("Вводит данные", "Entering input")
        case "verify": L10n.text("Проверяет страницу", "Checking page")
        case "upload": L10n.text("Загружает файл", "Uploading file")
        default: L10n.text("Выполняет действие", "Working")
        }
    }
}

@MainActor @Observable final class ManagedChromeInventory {
    var presentedChatID: String?
    @ObservationIgnored private var tabs: [UserChromeControl.ManagedTab] = []
    private(set) var tabsByChat: [String: [UserChromeControl.ManagedTab]] = [:]
    private(set) var refreshFailed = false
    private(set) var releasing: String?
    private(set) var unconfirmed: Set<String> = []
    private(set) var releaseFailedChatID: String?
    @ObservationIgnored private var releaseRevision = 0

    func closePanel() {
        if let presentedChatID, releaseFailedChatID == presentedChatID,
           tabsByChat[presentedChatID, default: []].allSatisfy({ !unconfirmed.contains($0.id) }) {
            releaseFailedChatID = nil
        }
        presentedChatID = nil
    }

    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(presentedChatID == nil ? 6 : 2))
        }
    }

    private func refresh() async {
        let revision = releaseRevision
        do {
            let updated = try await UserChromeControl.shared.managedTabs()
            guard !Task.isCancelled, releaseRevision == revision else { return }
            updateTabs(updated)
            unconfirmed.formIntersection(updated.map(\.id))
            refreshFailed = false
        } catch {
            guard !Task.isCancelled, releaseRevision == revision else { return }
            refreshFailed = true
        }
    }

    func release(_ tab: UserChromeControl.ManagedTab) {
        let id = tab.id
        guard releasing == nil, !unconfirmed.contains(id) else { return }
        if releaseFailedChatID == tab.chatId { releaseFailedChatID = nil }
        releasing = id
        Task {
            do {
                try await UserChromeControl.shared.releaseManagedTab(id)
                updateTabs(tabs.filter { $0.id != id })
            } catch {
                unconfirmed.insert(id)
                releaseFailedChatID = tab.chatId
            }
            releaseRevision += 1
            releasing = nil
            await refresh()
        }
    }

    private func updateTabs(_ updated: [UserChromeControl.ManagedTab]) {
        guard updated != tabs else { return }
        tabs = updated
        tabsByChat = Dictionary(grouping: updated, by: \.chatId)
    }
}
