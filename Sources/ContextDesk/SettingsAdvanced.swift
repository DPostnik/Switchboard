import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// Settings → Advanced: rarely used groups behind a small list on the left; each panel scrolls on its own.
struct AdvancedSettings: View {
    enum Panel: String, CaseIterable, Identifiable {
        case plugins, mobile, permissions, folders, processes, data, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .plugins: L10n.text("Плагины", "Plugins")
            case .mobile: L10n.text("Мобильный доступ", "Mobile access")
            case .permissions: L10n.text("Журнал разрешений", "Permission log")
            case .folders: L10n.text("Папки для всех проектов", "Folders for every project")
            case .processes: L10n.text("Процессы чатов", "Chat processes")
            case .data: L10n.text("Данные", "Data")
            case .about: L10n.text("О приложении", "About")
            }
        }
        var icon: String {
            switch self {
            case .plugins: "puzzlepiece.extension"
            case .mobile: "iphone"
            case .permissions: "lock.shield"
            case .folders: "folder.badge.plus"
            case .processes: "cpu"
            case .data: "externaldrive"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var model: DeskModel
    @State private var panel = Panel.plugins

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Panel.allCases) { item in
                    AdvancedPanelRow(item: item, selected: item == panel) { panel = item }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .background(DeskPalette.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, 12).padding(.leading, 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .plugins: Form { PluginSettings(model: model) }.formStyle(.grouped)
        case .mobile: Form { MobileRemoteSettings(host: model.mobileRemote, model: model) }.formStyle(.grouped)
        case .permissions: PermissionsLedgerView(model: model)
        case .folders: Form { SharedRootsSettings(model: model) }.formStyle(.grouped)
        case .processes: Form { OrphanProcessSettings(controller: model.orphanProcesses) }.formStyle(.grouped)
        case .data: Form { DataSettings() }.formStyle(.grouped)
        case .about: Form { AboutSettings() }.formStyle(.grouped)
        }
    }
}

private struct AdvancedPanelRow: View {
    let item: AdvancedSettings.Panel
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Label {
                Text(item.title).foregroundStyle(DeskPalette.ink).lineLimit(1)
            } icon: {
                Image(systemName: item.icon).foregroundStyle(selected ? DeskPalette.accent : DeskPalette.inkSoft)
                    .frame(width: 20)
            }
            .font(.ui(.body))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DeskPalette.selection : hovered ? DeskPalette.rowHover : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Settings → Advanced → Plugins.
struct PluginSettings: View {
    @ObservedObject var model: DeskModel
    var body: some View {
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
                Task { if let host = model.optimizerHost { await model.connect(host) } }
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
                    ForEach(model.agentIDs, id: \.self) { id in
                        Text((model.profile(id)?.productName ?? model.agentName(id)) + ": " + OptimizerCompatibility.summary(agent: id.agent, requirements: plugin.manifest.requirements))
                            .font(.ui(.caption)).foregroundStyle(model.traits(id).contains(.optimizerPlugins) ? .primary : .secondary)
                    }
                    PluginMetricsList(metrics: model.pluginMetrics, pluginID: plugin.id)
                }
            }
            ForEach(model.pluginIssues, id: \.self) { Text($0).font(.ui(.caption)).foregroundStyle(DeskPalette.attention) }
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
    }
}

/// Settings → Advanced → Data. The archive opens from the sidebar.
struct DataSettings: View {
    var body: some View {
        Section(L10n.text("Данные", "Data")) {
            Text(L10n.text("Разговоры и настройки этого приложения хранятся отдельно от текущего Codex.", "This app’s conversations and settings are stored separately from your existing Codex setup."))
                .font(.ui(.callout)).foregroundStyle(.secondary)
            Button(L10n.text("Открыть папку данных", "Open data folder")) { NSWorkspace.shared.open(Locations.root) }
        }
    }
}

/// A plugin's counters; it observes them alone, so their ticks do not redraw the rest of Settings or the window.
private struct PluginMetricsList: View {
    @ObservedObject var metrics: PluginMetricsState
    let pluginID: String
    var body: some View {
        ForEach(metrics.metrics[pluginID] ?? []) { metric in
            LabeledContent(metric.localizedTitle(), value: String(metric.value))
        }
    }
}
