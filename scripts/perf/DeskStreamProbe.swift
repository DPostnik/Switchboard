import AppKit
import Combine
import QuartzCore
import SwiftUI
import Darwin
import ContextCore
import AgentContract
@testable import ContextDesk

/// Whole-window cost of one streaming chat: the real `DeskView` (sidebar with four projects of 25 chats, the open
/// chat with its composer) while `DeskModel.receive` gets a Claude-like event mix. Synthetic data only; no agents,
/// network, credentials or app state. Run through `scripts/perf/profile-desk-stream.py`. Environment:
///   SWITCHBOARD_DESK_STREAM_REPORT   output JSON path (required)
///   SWITCHBOARD_DESK_STREAM_SECONDS  streaming time after the warm-up (default 16)
///   SWITCHBOARD_DESK_STREAM_MODE     "publish": no stream; five bare model publications per second (`objectWillChange`),
///                                    to measure what one publication costs the window (sidebar, chat, composer)
///
/// Event mix per 8 s (one tool call every 1.6 s): 200 text deltas (40 ms apart), 10 tool items (start and finish),
/// 5 status lines, 10 usage reports and 2-3 sub-agent updates.
@main struct DeskStreamProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("desk stream probe failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SWITCHBOARD_DESK_STREAM_REPORT"] else { throw NSError(domain: "probe", code: 1) }
        let seconds = Double(env["SWITCHBOARD_DESK_STREAM_SECONDS"] ?? "16") ?? 16
        let publishOnly = env["SWITCHBOARD_DESK_STREAM_MODE"] == "publish"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desk-stream-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                              pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil,
                              jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
        var projects: [Project] = []
        for index in 0..<4 {
            let folder = root.appendingPathComponent("project-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(Project(path: folder.path))
        }
        var chats: [Chat] = []
        for (p, project) in projects.enumerated() {
            for c in 0..<25 {
                var chat = Chat(id: "p\(p)-c\(c)", projectID: project.id, title: "Probe chat \(p).\(c) with a longer title", model: "fixture")
                chat.updated = Date(timeIntervalSince1970: 1_700_000_000 - Double(p * 100 + c))
                if p == 0 && c < 3 { chat.pinned = true }
                chats.append(chat)
            }
        }
        model.state.projects = projects
        model.state.chats = chats
        // Recorded items check the chat's identity against the stored state, as in the app.
        try await model.store.save(model.state)
        model.projectID = projects[0].id
        let chat = chats[0]
        model.chatID = chat.id
        model.items = (0..<60).map { index in
            var item = TranscriptItem(id: "history-\(index)", kind: index.isMultiple(of: 2) ? "user" : "assistant",
                                      text: String(repeating: "History line with `code` and **bold** text. ", count: index.isMultiple(of: 2) ? 2 : 12))
            item.turnID = "old-\(index / 2)"
            return item
        }
        let session = try require(chat.nativeSession)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DeskView(model: model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // Each selected project expands (DeskView keeps the expansion in its own state).
        for project in projects { model.projectID = project.id; try await Task.sleep(for: .milliseconds(150)) }
        model.projectID = projects[0].id
        model.chatID = chat.id
        try await Task.sleep(for: .seconds(2))

        var willChange = 0, transcriptChanges = 0
        var byName: [String: Int] = [:]
        var observers: [AnyCancellable] = [model.objectWillChange.sink { willChange += 1 },
                                           model.transcript.objectWillChange.sink { transcriptChanges += 1 }]
        observers += model.observePublications { byName[$0, default: 0] += 1 }
        defer { observers.forEach { $0.cancel() } }

        let turn = "probe-turn"
        func send(_ payload: AgentEvent.Payload) async { await model.receive(.init(session: session, payload: payload), from: session.connection) }
        await send(.started(turn: turn))
        await send(.item({ var user = TranscriptItem(id: "user:" + turn, kind: "user", text: "Stream please"); user.turnID = turn; return user }()))
        try await Task.sleep(for: .milliseconds(500))

        let tick = 0.04
        let ticks = Int(seconds / tick)
        let start = CACurrentMediaTime(), cpu0 = cpuSeconds(), main0 = mainThreadCPU()
        let changes0 = willChange, transcript0 = transcriptChanges
        var output = 100, late: [Double] = []
        for index in 0..<ticks {
            let due = start + Double(index) * tick
            let wait = due - CACurrentMediaTime()
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) } else { late.append(-wait) }
            if publishOnly {
                // A model publication no view depends on, five times a second: the cost every observing view pays.
                if index % 5 == 0 { model.objectWillChange.send() }
                continue
            }
            await send(.delta(turn: turn, item: "answer:\(index / 40)", text: "word\(index) "))
            let cycle = index / 40, phase = index % 40
            if phase == 0 {
                var tool = TranscriptItem(id: "tool-\(cycle)", kind: "activity", text: "Running `ls -la Sources/\(cycle)`")
                tool.turnID = turn
                await send(.item(tool))
                await send(.status(turn: turn, text: "Running ls \(cycle)"))
            }
            if phase == 0 || phase == 20 {
                output += 37
                let total = TokenCounters(input: 10_000 + cycle * 500, cached: 8_000, output: output)
                await send(.usage(turn: turn, total: total, snapshot: UsageSnapshot(last: 10_000 + cycle * 500 + output, window: 200_000,
                    input: total.input, cached: total.cached, output: output, measuredAt: Date(), lastRequestAt: Date(), cacheTTL: 300)))
            }
            if phase == 20 {
                var tool = TranscriptItem(id: "tool-\(cycle)", kind: "activity", text: "Ran `ls -la Sources/\(cycle)`\n\nfile-a\nfile-b")
                tool.turnID = turn
                await send(.item(tool))
            }
            if index % 80 == 10 {
                let agent = AgentSubagent(id: "sub", title: "Explore", type: nil, prompt: "Find the files", background: false, depth: 1,
                                          activity: "Reading file \(index)", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
                await send(.subagents([agent]))
            }
        }
        let elapsed = CACurrentMediaTime() - start
        let scale = 8 / elapsed
        let report: [String: Any] = [
            "seconds": elapsed, "ticks": ticks, "mode": publishOnly ? "publish" : "stream",
            "per_8s": [
                "model_publications": Double(willChange - changes0) * scale,
                "transcript_publications": Double(transcriptChanges - transcript0) * scale,
                "main_thread_cpu_ms": (mainThreadCPU() - main0) * 1000 * scale,
                "process_cpu_ms": (cpuSeconds() - cpu0) * 1000 * scale,
            ],
            "publications_by_name": byName,
            "model_error": model.error ?? "",
            "late_ticks": late.count, "late_max_ms": (late.max() ?? 0) * 1000,
            "date": Date().description,
            "scope": "Synthetic DeskView 1200x800, 4 projects x 25 chats, one streaming chat; release build; no agents or app state",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "probe", code: 2) }
    return value
}
