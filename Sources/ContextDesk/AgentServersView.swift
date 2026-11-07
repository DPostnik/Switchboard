import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// Servers the chats' agents started (`AgentServers`), rescanned every few seconds while a chat view is shown and the
/// app is active. One scan serves every window.
@MainActor final class AgentServersMonitor: ObservableObject {
    static let shared = AgentServersMonitor()
    @Published private(set) var servers: [AgentServer] = []
    @Published private(set) var stopping: Set<String> = []
    private var watchers = 0
    private var loop: Task<Void, Never>?
    private let interval: Duration = .seconds(3)

    /// Keeps the scan running while the calling view's task lives.
    func watch() async {
        watchers += 1
        if loop == nil {
            loop = Task { [weak self, interval] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: interval)
                }
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        watchers -= 1
        if watchers == 0 { loop?.cancel(); loop = nil }
    }

    func refresh(force: Bool = false) async {
        guard force || NSApplication.shared.isActive else { return }
        let found = await Task.detached(priority: .utility) { AgentServers.current() }.value
        guard found != servers else { return }
        AppLog.processes.notice("Agent servers: \(found.map { "\($0.port) pid \($0.record.pid)" }.joined(separator: ", "), privacy: .public)")
        servers = found
    }

    /// Stops the server and its child processes (SIGTERM, then SIGKILL); logged to the chat's events.
    func stop(_ server: AgentServer) {
        guard stopping.insert(server.id).inserted else { return }
        Task {
            let targets = await Task.detached(priority: .userInitiated) {
                AgentServers.tree(of: server.record, in: ProcessTable.current())
            }.value
            _ = await ProcessSweeper.shared.terminate(targets, reason: "stopped by the user")
            stopping.remove(server.id)
            await refresh(force: true)
        }
    }
}

/// A line above the composer with the open chat's servers: click opens the address, the square stops the server.
struct ChatServersBar: View {
    @ObservedObject private var monitor = AgentServersMonitor.shared
    /// The chat's agent session ID, which labels its processes.
    let label: String?
    let folder: String?

    var body: some View {
        let servers = AgentServers.servers(monitor.servers, chat: label, folder: folder)
        VStack(spacing: 0) {
            if !servers.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    Text(L10n.text("Серверы", "Servers") + ":").foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(servers) { chip($0) } }
                    }
                }
                .font(.ui(.callout))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: servers.map(\.id))
        .task { await monitor.watch() }
    }

    private func chip(_ server: AgentServer) -> some View {
        let stopping = monitor.stopping.contains(server.id)
        return HStack(spacing: 5) {
            Button { NSWorkspace.shared.open(server.url) } label: {
                HStack(spacing: 5) {
                    Circle().fill(DeskPalette.accent).frame(width: 6, height: 6)
                    Text(verbatim: "localhost:\(server.port)").monospacedDigit().foregroundStyle(DeskPalette.accentDeep)
                    Text(server.name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .buttonStyle(.plain).pointingHandCursor()
            .help(L10n.text("Открыть \(server.url.absoluteString) в браузере", "Open \(server.url.absoluteString) in the browser")
                  + "\n" + details(server))
            Button { monitor.stop(server) } label: {
                Image(systemName: stopping ? "hourglass" : "stop.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor().disabled(stopping)
            .help(L10n.text("Остановить сервер", "Stop the server"))
            .accessibilityLabel(L10n.text("Остановить сервер на порту \(server.port)", "Stop the server on port \(server.port)"))
        }
        .padding(.leading, 8).padding(.trailing, 5).padding(.vertical, 3)
        .background(DeskPalette.subtle, in: Capsule())
        .frame(maxWidth: 260)
        .contextMenu { menu(server, stopping: stopping) }
    }

    @ViewBuilder private func menu(_ server: AgentServer, stopping: Bool) -> some View {
        ForEach(server.ports, id: \.self) { port in
            Button(L10n.text("Открыть localhost:\(port)", "Open localhost:\(port)")) { NSWorkspace.shared.open(AgentServer.url(port)) }
        }
        ForEach(EditorLauncher.installedBrowsers, id: \.browser.id) { found in
            Button(EditorLauncher.openTitle(found.browser.title)) {
                EditorLauncher.openInBrowser(server.url, browser: found.browser, app: found.app)
            }
        }
        Divider()
        Button(L10n.text("Скопировать адрес", "Copy Address")) { copy(server.url.absoluteString) }
        Button(L10n.text("Скопировать команду", "Copy Command")) { copy(server.record.command) }
        if let directory = server.directory {
            Button(L10n.text("Показать папку в Finder", "Show Folder in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
            }
        }
        Divider()
        Button(L10n.text("Остановить сервер", "Stop the Server")) { monitor.stop(server) }.disabled(stopping)
    }

    private func details(_ server: AgentServer) -> String {
        var lines = [server.record.command.isEmpty ? server.record.path : server.record.command,
                     L10n.text("Процесс \(server.record.pid)", "Process \(server.record.pid)")]
        if server.ports.count > 1 {
            lines.append(L10n.text("Порты: ", "Ports: ") + server.ports.map(String.init).joined(separator: ", "))
        }
        if server.record.chat == nil {
            lines.append(L10n.text("Запущен агентом без метки чата (Codex); показан по папке чата.",
                                   "Started by an agent without a chat label (Codex); shown by the chat's folder."))
        }
        return lines.joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
