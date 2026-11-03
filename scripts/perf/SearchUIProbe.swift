// Main-thread cost of typing into the app's real search fields: the sidebar filter, the command palette and the
// archive search, hosted in an offscreen-capable window with a synthetic state (no agents, no network, temp homes).
// Built by scripts/perf/search-bench.py --ui, linked against testable release objects like TranscriptCPUProbe.
import AgentContract
import AppKit
import ContextCore
import Darwin
import SwiftUI
@testable import ContextDesk

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

/// CPU time of one thread, in milliseconds.
func threadCPU(_ thread: thread_act_t) -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds + info.system_time.seconds) * 1000
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
let words = ["the", "a", "to", "and", "file", "run", "test", "build", "и", "в", "что", "файл", "сделай", "проверь",
             "background", "transcript", "index", "search", "sidebar", "palette", "archive", "commit", "streaming",
             "приложение", "индекс", "поиск", "архив", "проект", "окно", "агент", "задача", "ошибка", "результат"]

@MainActor func findField(_ view: NSView, placeholders: [String]) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable,
       let placeholder = field.placeholderString ?? field.placeholderAttributedString?.string, placeholders.contains(placeholder) { return field }
    for subview in view.subviews { if let found = findField(subview, placeholders: placeholders) { return found } }
    return nil
}

@main struct SearchUIProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await measure(); exit(0) } catch { log("UI probe failed: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func measure() async throws {
        guard let output = ProcessInfo.processInfo.environment["SEARCH_UI_REPORT"] else { return }
        let mainThread = mach_thread_self()
        var results: [[String: Any]] = []
        // The user's state on 2026-11-03 has 11 projects, 897 chats and 17 active ones: the first shape copies it.
        for (projects, chats, activeEvery) in [(11, 897, 53), (25, 800, 4), (60, 3000, 4)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                                  capabilityLedger: CapabilityLedger(file: root.appendingPathComponent("ledger.sqlite")),
                                  pluginDirectory: root, summaryResources: nil, summaryHome: root, claudeHome: root,
                                  jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
            var rng = SplitMix(state: 3)
            let projectList = (0..<projects).map { Project(path: root.appendingPathComponent("project-\($0)").path) }
            model.state.projects = projectList
            model.state.chats = (0..<chats).map { index in
                var chat = Chat(id: "chat-\(index)", projectID: projectList[index % projects].id,
                                title: (0..<5).map { _ in words.randomElement(using: &rng)! }.joined(separator: " "), model: "fixture")
                chat.archived = index % activeEvery != 0 ? true : nil
                chat.pinned = index % 50 == 0 ? true : nil
                chat.updated = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                return chat
            }
            model.projectID = projectList[0].id
            model.chatID = model.state.chats[0].id
            model.items = (0..<40).map { .init(id: "history-\($0)", kind: $0.isMultiple(of: 2) ? "user" : "assistant", text: "History line \($0)") }
            let session = model.state.chats[0].nativeSession!
            let host = NSHostingView(rootView: DeskView(model: model).overlay { CommandPaletteHost(model: model, navigation: model.navigation) })
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(800))

            func settle(_ seconds: Double) async throws -> (cpu: Double, wall: Double) {
                let cpu = threadCPU(mainThread), wall = now()
                try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                host.layoutSubtreeIfNeeded()
                return (threadCPU(mainThread) - cpu, Double(now() - wall) / 1e6)
            }
            var idle = try await settle(1.0)

            func type(_ name: String, placeholders: [String], text: String, window seconds: Double) async throws {
                guard let field = findField(host, placeholders: placeholders) else { log("no field for \(name)"); return }
                window.makeFirstResponder(field)
                try await Task.sleep(for: .milliseconds(300))
                guard let editor = field.currentEditor() as? NSTextView else { log("no editor for \(name)"); return }
                // Fresh idle rate right before typing: the window's own timers and the previous scenario's tail.
                try await Task.sleep(for: .milliseconds(1000))
                idle = try await settle(1.0)
                var keys: [[String: Any]] = []
                var total = 0.0
                for character in text {
                    let start = threadCPU(mainThread)
                    editor.insertText(String(character), replacementRange: editor.selectedRange())
                    let synchronous = threadCPU(mainThread) - start
                    let after = try await settle(seconds)
                    let cost = synchronous + after.cpu - idle.cpu * seconds
                    total += cost
                    keys.append(["len": editor.string.count, "main_cpu_ms": cost, "raw_main_cpu_ms": synchronous + after.cpu])
                }
                // Clearing the field restores the full list.
                let start = threadCPU(mainThread)
                editor.selectAll(nil); editor.deleteBackward(nil)
                let synchronous = threadCPU(mainThread) - start
                let after = try await settle(seconds)
                let costs = keys.compactMap { $0["main_cpu_ms"] as? Double }.sorted()
                results.append(["scenario": name, "chats": chats, "projects": projects, "active": model.state.chats.count(where: { !$0.isArchived }), "per_key": keys,
                                "p50_main_cpu_ms": costs[costs.count / 2], "max_main_cpu_ms": costs.last ?? 0,
                                "sum_main_cpu_ms": total, "clear_main_cpu_ms": synchronous + after.cpu - idle.cpu * seconds,
                                "idle_main_cpu_ms_per_s": idle.cpu])
                log("\(name) \(chats)/\(model.state.chats.count(where: { !$0.isArchived })) active: idle \(Int(idle.cpu)) ms/s; per key " + keys.map { String(format: "%.0f", $0["main_cpu_ms"] as! Double) }.joined(separator: " ")
                    + String(format: "; clear %.0f", synchronous + after.cpu - idle.cpu * seconds))
            }

            try await type("sidebar", placeholders: ["Найти проект или чат", "Find a project or chat"], text: "background index", window: 0.25)

            model.navigation.paletteShown = true
            try await Task.sleep(for: .milliseconds(500))
            try await type("palette", placeholders: ["Чаты, проекты и действия", "Chats, projects and actions"], text: "background index", window: 0.4)

            // A streamed answer while the palette stays open: every model publication re-ranks the palette.
            func stream(_ label: String) async throws {
                await model.receive(.init(session: session, payload: .started(turn: "turn-\(label)")), from: session.connection)
                let cpu = threadCPU(mainThread), wall = now()
                for _ in 0..<150 {
                    await model.receive(.init(session: session, payload: .delta(turn: "turn-\(label)", item: "reply-\(label)", text: "word ")), from: session.connection)
                    try await Task.sleep(for: .milliseconds(20))
                }
                let seconds = Double(now() - wall) / 1e9
                results.append(["scenario": "streaming_" + label, "chats": chats, "main_cpu_percent": (threadCPU(mainThread) - cpu) / 10 / seconds])
                log("streaming \(label) \(chats): \((threadCPU(mainThread) - cpu) / 10 / seconds)% main")
            }
            try await stream("palette_open")
            model.navigation.paletteShown = false
            try await Task.sleep(for: .milliseconds(500))
            try await stream("palette_closed")

            model.openArchive()
            try await Task.sleep(for: .milliseconds(800))
            try await type("archive", placeholders: ["Найти чат или проект", "Find a chat or project"], text: "background index", window: 0.4)
            model.closeArchive()
            results.append(["scenario": "idle_baseline", "chats": chats, "main_cpu_ms_per_s": idle.cpu])
        }
        try JSONSerialization.data(withJSONObject: ["results": results, "note": "main-thread CPU per keystroke minus idle baseline; synthetic state"],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
