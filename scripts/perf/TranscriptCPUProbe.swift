import AppKit
import Combine
import ContextCore
import AgentContract
import SwiftUI
import Darwin
@testable import ContextDesk

@main struct TranscriptCPUProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await measure(); exit(0) }
            catch { fputs("CPU probe failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func measure() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWITCHBOARD_CPU_REPORT"] else { return }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                              pluginDirectory: root, summaryResources: nil,
                              jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
        let project = Project(path: root.path)
        model.state.projects = [project]; model.projectID = project.id
        model.state.chats = (0..<4).map { Chat(id: "fixture-\($0)", projectID: project.id, title: "CPU fixture \($0)", model: "fixture") }
        model.chatID = model.state.chats[0].id
        model.authenticated = true
        model.items = [.init(id: "user", kind: "user", text: "Синтетический тест / Synthetic test")]
        let sessions = model.state.chats.map { $0.nativeSession! }
        let host = NSHostingView(rootView: DeskView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1050, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var changes = 0
        let observer = model.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        var results: [[String: Any]] = []
        for scenario in ["idle", "waiting", "streaming", "long-history", "four-chats", "hidden"] {
            if scenario == "waiting" { await model.receive(.init(session: sessions[0], payload: .started(turn: "turn"))) }
            if scenario == "long-history" {
                model.items = (0..<200).map { .init(id: "history-\($0)", kind: $0.isMultiple(of: 2) ? "user" : "assistant",
                    text: String(repeating: "Строка истории / History line.\n", count: 8)) }
            }
            if scenario == "four-chats" {
                for session in sessions.dropFirst() { await model.receive(.init(session: session, payload: .started(turn: "turn"))) }
            }
            if scenario == "hidden" { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let start = ContinuousClock.now, before = cpu(), count = changes
            for _ in 0..<180 {
                if !["idle", "waiting"].contains(scenario) {
                    for session in scenario == "four-chats" ? sessions : [sessions[0]] {
                        await model.receive(.init(session: session, payload: .delta(turn: "turn", item: "reply", text: "word ")))
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            results.append(["scenario": scenario, "seconds": seconds, "cpu_percent_one_core": 100 * (cpu() - before) / seconds,
                            "workspace_publications": changes - count, "window_visible": window.isVisible,
                            "window_occluded": !window.occlusionState.contains(.visible)])
        }
        try JSONSerialization.data(withJSONObject: ["scenarios": results, "date": Date().description,
            "scope": "Synthetic release native run-loop process; no agents/network; CPU includes the harness"], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
