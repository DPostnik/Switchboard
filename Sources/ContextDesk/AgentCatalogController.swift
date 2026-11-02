import Foundation
import SwiftUI
import ContextCore

/// The ACP agent catalog for Settings: the cached registry, install records and one install, update or removal per
/// agent at a time. Network only on an explicit refresh, an install, or the update check when Settings opens (at most
/// once a day, and only while something is installed from the catalog). Nothing polls in the background.
@MainActor final class AgentCatalogController: ObservableObject {
    enum Operation: Equatable { case installing, removing }
    struct Message: Equatable { let text: String; let isError: Bool }

    @Published private(set) var snapshot: AgentCatalogSnapshot?
    @Published private(set) var records: [String: AgentInstallRecord] = [:]
    @Published private(set) var updates: [String: AgentCatalogUpdate] = [:]
    @Published private(set) var operations: [String: Operation] = [:]
    @Published private(set) var messages: [String: Message] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var refreshError: String?

    let store: AgentCatalogStore
    let installer: AgentCatalogInstaller
    private let now: () -> Date
    private var lastUpdateCheck: Date?
    private var loaded = false

    init(directory: URL = Locations.agentsHome, store: AgentCatalogStore? = nil, installer: AgentCatalogInstaller? = nil,
         now: @escaping () -> Date = Date.init) {
        self.store = store ?? AgentCatalogStore(directory: directory)
        self.installer = installer ?? AgentCatalogInstaller(directory: directory)
        self.now = now
    }

    /// Cached catalog and install records, without network.
    func load() async {
        if snapshot == nil { snapshot = await store.cached() }
        await reloadRecords()
        loaded = true
    }

    /// Requests the registry (a conditional request when a copy exists). The Refresh button forces it.
    func refresh(force: Bool) async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let snapshot = try await store.refresh(force: force)
            self.snapshot = snapshot; refreshError = snapshot.failure
        } catch { refreshError = error.localizedDescription }
        await reloadRecords()
    }

    /// When Settings opens: reads the cache; with agents installed from the catalog, refreshes it at most once a day
    /// (the store reuses a copy younger than 24 hours without network).
    func checkForUpdatesIfDue() async {
        await load()
        guard !records.isEmpty else { return }
        if let last = lastUpdateCheck, now().timeIntervalSince(last) < AgentCatalogStore.maxAge { return }
        lastUpdateCheck = now()
        await refresh(force: false)
    }

    func reloadRecords() async {
        let list = await installer.records()
        records = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        if let catalog = snapshot?.catalog {
            updates = Dictionary(uniqueKeysWithValues: await installer.availableUpdates(catalog: catalog).map { ($0.id, $0) })
        } else { updates = [:] }
    }

    /// The update Settings offers for a linked agent: only a version the agent's version policy accepts.
    func offeredUpdate(_ link: AgentCatalogLink) -> AgentCatalogUpdate? {
        guard let update = updates[link.id], AgentCatalogVersionChoice.isAcceptable(update.available, verified: link.verifiedVersions) else { return nil }
        return update
    }

    /// Installs (or updates) a linked agent: the catalog entry (refreshed now, reusing a copy under a day old; the
    /// built-in fallback when there is none), at the version the policy allows. Reports the outcome once; no retry.
    @discardableResult
    func install(_ link: AgentCatalogLink) async -> AgentInstallRecord? {
        guard operations[link.id] == nil else { return nil }
        operations[link.id] = .installing; messages[link.id] = nil
        defer { operations[link.id] = nil }
        if let fresh = try? await store.refresh() { snapshot = fresh }
        var entry = snapshot?.catalog.entry(link.id) ?? link.fallback
        var choice = AgentCatalogVersionChoice.choose(for: entry, verified: link.verifiedVersions)
        if choice == nil { entry = link.fallback; choice = AgentCatalogVersionChoice.choose(for: entry, verified: link.verifiedVersions) }
        guard let choice else {
            messages[link.id] = Message(text: AgentInstallFailure.notInstallable(entry.name).errorDescription ?? "", isError: true); return nil
        }
        do {
            let record = try await installer.install(entry, version: choice.version, checkEnvironment: link.checkEnvironment)
            let done = L10n.text("Установлена версия \(record.version).", "Installed version \(record.version).")
            messages[link.id] = Message(text: [done, choice.note].compactMap { $0 }.joined(separator: " "), isError: false)
            await reloadRecords()
            return record
        } catch {
            messages[link.id] = Message(text: error.localizedDescription, isError: true)
            await reloadRecords()
            return nil
        }
    }

    @discardableResult
    func remove(_ id: String) async -> Bool {
        guard operations[id] == nil else { return false }
        operations[id] = .removing; messages[id] = nil
        defer { operations[id] = nil }
        do {
            try await installer.remove(id)
            messages[id] = Message(text: L10n.text("Удалено из папки Switchboard.", "Removed from Switchboard's folder."), isError: false)
        } catch { messages[id] = Message(text: error.localizedDescription, isError: true) }
        await reloadRecords()
        return records[id] == nil
    }
}

extension DeskModel {
    /// Installs or updates the agent's CLI from the catalog, then connects it again (a running shared engine restarts
    /// only when the app is idle, as for every reconnect).
    func installCatalogAgent(_ id: AgentConnectionID) async {
        guard let link = profile(id)?.installation?.catalog else { return }
        guard await agentCatalog.install(link) != nil else { return }
        refreshInstallations()
        if agentState(id).installed { await connect(id) }
    }

    /// Stops the agent and removes its catalog install; another copy (Homebrew, PATH) connects again if present.
    func removeCatalogAgent(_ id: AgentConnectionID) async {
        guard let link = profile(id)?.installation?.catalog, !anyBusy else { return }
        let wasConnected = agentState(id).connected
        await stopAgent(id)
        await agentCatalog.remove(link.id)
        refreshInstallations()
        if wasConnected && agentState(id).installed { await connect(id) }
    }
}

/// Install, update and remove rows of one linked agent in its Settings → Accounts section.
struct AgentCatalogInstallRows: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var catalog: AgentCatalogController
    let id: AgentConnectionID
    let link: AgentCatalogLink
    let productName: String

    var body: some View {
        let operation = catalog.operations[link.id], record = catalog.records[link.id], installed = model.agentState(id).installed
        if !installed {
            Button(L10n.text("Установить \(productName)", "Install \(productName)")) { Task { await model.installCatalogAgent(id) } }
                .disabled(operation != nil || model.anyBusy)
        }
        if let record {
            LabeledContent(L10n.text("Из каталога агентов", "From the agent catalog"), value: record.version)
            if record.checksum == .unverified {
                Text(L10n.text("Контрольная сумма архива не указана в каталоге.", "The catalog gives no checksum for this archive."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                if let update = catalog.offeredUpdate(link) {
                    Button(L10n.text("Обновить до \(update.available)", "Update to \(update.available)")) { Task { await model.installCatalogAgent(id) } }
                        .disabled(operation != nil || model.anyBusy)
                }
                Button(L10n.text("Удалить", "Remove"), role: .destructive) { Task { await model.removeCatalogAgent(id) } }
                    .disabled(operation != nil || model.anyBusy)
            }
            if let update = catalog.updates[link.id], catalog.offeredUpdate(link) == nil {
                Text(L10n.text("В каталоге есть \(update.available), но эта версия ещё не проверена для Switchboard.",
                               "The catalog has \(update.available), but that version is not verified for Switchboard yet."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
        if let operation {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(operation == .installing ? L10n.text("Установка… (npm может работать несколько минут)", "Installing… (npm may take a few minutes)")
                     : L10n.text("Удаление…", "Removing…")).font(.ui(.caption)).foregroundStyle(.secondary)
            }
        } else if let message = catalog.messages[link.id] {
            Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.ui(.caption)).foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).textSelection(.enabled)
        }
    }
}

/// The catalog list in Settings → Accounts: cached entries, a Refresh button, an Installed badge. Agents the app has a
/// profile for install from their own section; the others are listed only (installing them is not wired yet).
struct AgentCatalogSection: View {
    @ObservedObject var catalog: AgentCatalogController
    /// Registry ids the app can install (from the profiles' catalog links).
    let linkedIDs: Set<String>
    @State private var expanded = false

    var body: some View {
        Section {
            HStack {
                if let snapshot = catalog.snapshot {
                    Text(L10n.text("Обновлён \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))",
                                   "Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.ui(.caption)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Каталог ещё не загружен.", "The catalog has not been loaded yet.")).font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if catalog.refreshing { ProgressView().controlSize(.small) }
                Button(L10n.text("Обновить", "Refresh")) { Task { await catalog.refresh(force: true) } }.disabled(catalog.refreshing)
            }
            if let error = catalog.refreshError {
                Label(error, systemImage: "wifi.exclamationmark").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if let entries = catalog.snapshot?.catalog.entries, !entries.isEmpty {
                DisclosureGroup(L10n.text("Агенты: \(entries.count)", "Agents: \(entries.count)"), isExpanded: $expanded) {
                    ForEach(entries) { entry in row(entry) }
                }
            }
            Text(L10n.text("Каталог загружается только по кнопке «Обновить», при установке и при открытии настроек раз в сутки, если что-то установлено из него. Установка других агентов из списка появится позже.",
                           "The catalog is fetched only with Refresh, when installing, and once a day when Settings opens while something is installed from it. Installing other agents from the list is coming later."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        } header: {
            Label(L10n.text("Каталог агентов ACP", "ACP agent catalog"), systemImage: "shippingbox")
        }
    }

    @ViewBuilder private func row(_ entry: AgentCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.name).font(.ui(.callout)).fontWeight(.medium)
                Text(entry.version).font(.ui(.caption)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let record = catalog.records[entry.id] {
                    Text(L10n.text("Установлен \(record.version)", "Installed \(record.version)"))
                        .font(.ui(.caption)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                } else if linkedIDs.contains(entry.id) {
                    Text(L10n.text("Ставится в разделе аккаунта", "Install in its account section")).font(.ui(.caption)).foregroundStyle(.secondary)
                } else if entry.installable == nil {
                    Text(L10n.text("Не для этого Mac", "Not for this Mac")).font(.ui(.caption)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Скоро", "Coming soon")).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }
            if let description = entry.description, !description.isEmpty {
                Text(description).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
