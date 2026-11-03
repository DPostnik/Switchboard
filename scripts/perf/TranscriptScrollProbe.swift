import AppKit
import Combine
import QuartzCore
import SwiftUI
import Darwin
import ContextCore
import AgentContract
@testable import ContextTranscript
@testable import ContextDesk

/// Chat transcript latency probe: chat open / switch, scrolling frame times, streaming into long chats.
/// Synthetic transcripts only; no agents, network, credentials or app state. Run through
/// `scripts/perf/profile-transcript-scroll.py`. Environment:
///   SWITCHBOARD_SCROLL_REPORT   output JSON path (required)
///   SWITCHBOARD_SCROLL_PROJECT  directory used as the chats' project, so file chips resolve (optional)
///   SWITCHBOARD_SCROLL_SIZES    comma-separated message counts (default "200,1000")
///   SWITCHBOARD_SCROLL_ONLY     run one phase in a loop for a profiler: "open", "scroll" or "stream"
///   SWITCHBOARD_SCROLL_SECONDS  duration of that loop (default 20)
@main struct TranscriptScrollProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await Probe().run(); exit(0) }
            catch { fputs("scroll probe failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}

// MARK: - Synthetic transcripts

/// Deterministic generator: the same seed gives the same transcript.
struct Synth {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }

    static let words = ("the transcript renders each message into one text storage and lays out only what is visible while "
        + "streaming appends text to the last answer every seventy five milliseconds so the cost of a tick should not grow "
        + "with the length of the chat вывод агента часто содержит русский текст пути к файлам и фрагменты кода которые "
        + "подсвечиваются при отрисовке").split(separator: " ").map(String.init)
    static let paths = ["Sources/ContextTranscript/NativeTranscript.swift", "Sources/ContextTranscript/TranscriptMarkdown.swift",
                        "Sources/ContextDesk/DeskView.swift", "Sources/ContextDesk/DeskModel.swift", "Package.swift",
                        "docs/performance.md", "Sources/ContextCore/MarkdownBlocks.swift", "scripts/test.sh"]

    mutating func sentence(_ count: ClosedRange<Int> = 8...22) -> String {
        var parts: [String] = []
        for index in 0..<int(count) {
            var word = pick(Self.words)
            switch int(0...40) {
            case 0: word = "**\(word)**"
            case 1: word = "`\(word)()`"
            case 2: word = "`\(pick(Self.paths)):\(int(10...900))`"
            case 3: word = "[\(word)](https://example.com/\(word)/\(index))"
            case 4: word = "*\(word)*"
            default: break
            }
            parts.append(word)
        }
        return parts.joined(separator: " ").prefix(1).uppercased() + parts.joined(separator: " ").dropFirst() + "."
    }

    mutating func paragraph() -> String { (0..<int(2...5)).map { _ in sentence() }.joined(separator: " ") }

    mutating func code(lines: Int) -> String {
        var out = ["```swift"]
        for line in 0..<lines {
            switch line % 6 {
            case 0: out.append("    // \(sentence(4...8))")
            case 1: out.append("    func render\(line)(_ item: TranscriptItem, width: CGFloat) -> NSAttributedString {")
            case 2: out.append("        let value = items[\(line)].text.utf8.count + \(int(1...999))")
            case 3: out.append("        guard value > 0, let storage = transcript.textStorage else { return \"empty\" }")
            case 4: out.append("        storage.replaceCharacters(in: NSRange(location: \(line), length: 0), with: rendered)")
            default: out.append("    }")
            }
        }
        out.append("```")
        return out.joined(separator: "\n")
    }

    mutating func table() -> String {
        var rows = ["| Phase | Time | Note |", "|---|---:|---|"]
        for index in 0..<int(3...8) { rows.append("| step \(index) | \(int(1...400)) ms | \(sentence(3...6)) |") }
        return rows.joined(separator: "\n")
    }

    /// Long Markdown answers: headings, prose with inline code/paths/links, lists, code, tables, quotes.
    mutating func answer(size: Int) -> String {
        var blocks: [String] = []
        var length = 0
        while length < size {
            let block: String
            switch int(0...11) {
            case 0: block = "## \(sentence(2...5))"
            case 1, 2: block = (0..<int(2...6)).map { _ in "- " + sentence(5...14) }.joined(separator: "\n")
            case 3: block = (1...int(2...5)).map { "\($0). " + sentence(5...14) }.joined(separator: "\n")
            case 4: block = code(lines: int(6...60))
            case 5: block = chance(40) ? table() : "> " + sentence()
            default: block = paragraph()
            }
            blocks.append(block); length += block.utf8.count
        }
        return blocks.joined(separator: "\n\n")
    }

    mutating func toolCalls(turn: Int) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for call in 0..<int(2...8) {
            let id = "t\(turn)-call\(call)"
            switch int(0...3) {
            case 0, 1:
                let command = pick(["git status --short", "swift build -c release", "rg -n \"func render\" Sources", "ls -la docs"])
                items.append(TranscriptItem(id: id, kind: "activity", text: "Bash\n{\"command\" : \"\(command)\", \"description\" : \"\(sentence(2...4))\"}"))
                var result = TranscriptItem(id: id + ":result", kind: "activity",
                                            text: (0..<int(2...60)).map { _ in sentence(4...12) }.joined(separator: "\n"))
                result.exitCode = chance(85) ? 0 : 1
                items.append(result)
            case 2:
                items.append(TranscriptItem(id: id, kind: "activity", text: "Read\n{\"file_path\" : \"/tmp/\(pick(Self.paths))\"}"))
                items.append(TranscriptItem(id: id + ":result", kind: "activity", text: code(lines: int(10...80))))
            default:
                items.append(TranscriptItem(id: id, kind: "activity",
                                            text: "Edit\n{\"file_path\" : \"/tmp/\(pick(Self.paths))\", \"old_string\" : \"a\", \"new_string\" : \"b\"}"))
            }
        }
        return items
    }

    /// `messages` user + assistant messages (half each); each turn also carries tool calls and sometimes thinking.
    static func transcript(messages: Int, seed: UInt64) -> [TranscriptItem] {
        var synth = Synth(seed: seed)
        var items: [TranscriptItem] = []
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for turn in 0..<(messages / 2) {
            let user = synth.chance(20) ? synth.paragraph() + "\n\n" + synth.paragraph() : synth.sentence(6...30)
            items.append(TranscriptItem(id: "t\(turn)-user", kind: "user", text: user))
            if synth.chance(30) {
                var thinking = TranscriptItem(id: "t\(turn)-thinking", kind: ActivityDetail.thinkingKind, text: synth.paragraph())
                thinking.seconds = Double(synth.int(1...30))
                items.append(thinking)
            }
            if synth.chance(40) {
                items.append(TranscriptItem(id: "t\(turn)-commentary", kind: "assistant", text: synth.sentence(), phase: "commentary"))
            }
            items += synth.toolCalls(turn: turn)
            let size = synth.pick([400, 900, 1600, 3000, 6000, 10000])
            let completed = base.addingTimeInterval(Double(turn * 300))
            var answer = TranscriptItem(id: "t\(turn)-answer", kind: "assistant", text: synth.answer(size: size), phase: "final_answer",
                                        timing: ResponseTiming(startedAt: completed.addingTimeInterval(-90), completedAt: completed, durationSeconds: 90))
            answer.turnID = "turn-\(turn)"
            items.append(answer)
        }
        return items
    }
}

// MARK: - Measurement helpers

@MainActor func now() -> Double { CACurrentMediaTime() }
func ms(_ seconds: Double) -> Double { (seconds * 1000 * 100).rounded() / 100 }

func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576).rounded() : -1
}

func stats(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["count": 0] }
    let sorted = values.sorted()
    func quantile(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
    return ["count": values.count, "mean_ms": ms(values.reduce(0, +) / Double(values.count)), "p50_ms": ms(quantile(0.5)),
            "p95_ms": ms(quantile(0.95)), "p99_ms": ms(quantile(0.99)), "max_ms": ms(sorted.last!),
            "over_8ms": values.filter { $0 > 0.0084 }.count, "over_16ms": values.filter { $0 > 0.0168 }.count,
            "over_50ms": values.filter { $0 > 0.05 }.count]
}

/// Scrolls one frame per display refresh and records the intervals between frames.
@MainActor final class LinkScroller: NSObject {
    let view: TranscriptScrollView
    let speed: Double
    let limit: Double
    var link: CADisplayLink?
    var intervals: [Double] = []
    var periods: [Double] = []
    var last: Double?
    var start: Double = 0
    var y: CGFloat = 0
    var target: CGFloat = 0
    var origin: CGFloat = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(view: TranscriptScrollView, speed: Double, limit: Double) { self.view = view; self.speed = speed; self.limit = limit }

    func run(from: CGFloat, to: CGFloat) async {
        y = from; target = to; origin = from
        view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc func tick(_ link: CADisplayLink) {
        let stamp = link.timestamp
        if let last {
            let dt = stamp - last
            intervals.append(dt)
            periods.append(link.targetTimestamp - link.timestamp)
            let step = CGFloat(speed * dt)
            y = target > y ? min(target, y + step) : max(target, y - step)
        } else { start = stamp }
        last = stamp
        view.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.reflectScrolledClipView(view.contentView)
        if y == target || stamp - start > limit {
            link.invalidate(); self.link = nil
            continuation?.resume(); continuation = nil
        }
    }

    func summary() -> [String: Any] {
        let period = periods.sorted().first.map { max($0, 1.0 / 240) } ?? 1.0 / 60
        let nominal = periods.isEmpty ? period : periods.sorted()[periods.count / 2]
        let late = intervals.filter { $0 > nominal * 1.5 }
        let total = intervals.reduce(0, +)
        let hitchTime = late.reduce(0) { $0 + ($1 - nominal) }
        var result = stats(intervals)
        result["refresh_hz"] = (1 / nominal).rounded()
        result["frames"] = intervals.count
        result["hitches"] = late.count
        result["over_33ms"] = intervals.filter { $0 > 0.033 }.count
        result["hitch_ms_per_s"] = total > 0 ? ms(hitchTime / total) : 0
        result["seconds"] = (total * 100).rounded() / 100
        result["distance_pt"] = Int(abs(y - origin))
        return result
    }
}

// MARK: - Probe

@MainActor final class Probe {
    let env = ProcessInfo.processInfo.environment
    var report: [String: Any] = [:]
    var window: NSWindow!
    var view: TranscriptScrollView!
    lazy var project: String? = env["SWITCHBOARD_SCROLL_PROJECT"]

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1050, height: 720), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Transcript scroll probe"
        window.orderFront(nil)
    }

    /// The app builds a new transcript view on each chat switch (the loading state replaces it), so opens start fresh.
    func freshView() {
        let next = TranscriptScrollView(positions: TranscriptReadingPositions())
        next.transcript.usesFindBar = true
        next.transcript.isIncrementalSearchingEnabled = true
        if env["SWITCHBOARD_SCROLL_NO_TEXT_CHECKING"] == "1" {
            // Experiment: the automatic text checking a read-only transcript does not need.
            next.transcript.isAutomaticTextReplacementEnabled = false
            next.transcript.isAutomaticSpellingCorrectionEnabled = false
            next.transcript.isAutomaticQuoteSubstitutionEnabled = false
            next.transcript.isAutomaticDashSubstitutionEnabled = false
            next.transcript.isAutomaticDataDetectionEnabled = false
            next.transcript.isAutomaticTextCompletionEnabled = false
            next.transcript.isContinuousSpellCheckingEnabled = false
            next.transcript.isGrammarCheckingEnabled = false
        }
        report["text_checking_types"] = next.transcript.enabledTextCheckingTypes
        report["text_checking_flags"] = ["replacement": next.transcript.isAutomaticTextReplacementEnabled,
            "spelling_correction": next.transcript.isAutomaticSpellingCorrectionEnabled,
            "continuous_spelling": next.transcript.isContinuousSpellCheckingEnabled,
            "quotes": next.transcript.isAutomaticQuoteSubstitutionEnabled, "dashes": next.transcript.isAutomaticDashSubstitutionEnabled,
            "data_detection": next.transcript.isAutomaticDataDetectionEnabled, "grammar": next.transcript.isGrammarCheckingEnabled]
        window.contentView = next
        window.contentView?.layoutSubtreeIfNeeded()
        view = next
    }

    func flushFrame() {
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// update (render into storage) -> layout (TextKit + scroll to end) -> draw. Returns phase timings in ms.
    func timedUpdate(_ items: [TranscriptItem], id: String, working: Bool = false, since: Date? = nil) -> [String: Double] {
        let renders = view.renderCount
        let t0 = now()
        view.update(items: items, conversationID: id, followOutput: true, isWorking: working, workingStatus: working ? "Writing" : nil,
                    workingSince: since, projectPath: project)
        let t1 = now()
        window.contentView?.layoutSubtreeIfNeeded()
        let t2 = now()
        flushFrame()
        let t3 = now()
        return ["render_ms": ms(t1 - t0), "layout_ms": ms(t2 - t1), "draw_ms": ms(t3 - t2), "total_ms": ms(t3 - t0),
                "rendered_items": Double(view.renderCount - renders)]
    }

    func median(_ runs: [[String: Double]]) -> [String: Double] {
        guard let keys = runs.first?.keys else { return [:] }
        var out: [String: Double] = [:]
        for key in keys { let values = runs.compactMap { $0[key] }.sorted(); out[key] = values[values.count / 2] }
        out["runs"] = Double(runs.count)
        return out
    }

    func run() async throws {
        guard let path = env["SWITCHBOARD_SCROLL_REPORT"] else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "SWITCHBOARD_SCROLL_REPORT is not set"]) }
        makeWindow()
        defer { window.orderOut(nil) }
        let sizes = (env["SWITCHBOARD_SCROLL_SIZES"] ?? "200,1000").split(separator: ",").compactMap { Int($0) }
        var transcripts: [Int: [TranscriptItem]] = [:]
        for size in sizes { transcripts[size] = Synth.transcript(messages: size, seed: UInt64(size)) }
        report["window"] = ["width": 1050, "height": 720, "backing_scale": window.backingScaleFactor]
        report["transcripts"] = sizes.map { size -> [String: Any] in
            let items = transcripts[size]!
            return ["messages": size, "items": items.count, "utf8_mb": Double(items.reduce(0) { $0 + $1.text.utf8.count }) / 1_048_576,
                    "code_blocks": items.reduce(0) { $0 + $1.text.components(separatedBy: "```").count / 2 }]
        }
        // Warm up fonts, symbol images, the Markdown parser and the syntax highlighter once.
        freshView(); _ = timedUpdate(Array(transcripts[sizes[0]]!.prefix(60)), id: "warmup")
        try await Task.sleep(for: .milliseconds(300))

        if let only = env["SWITCHBOARD_SCROLL_ONLY"] {
            try await loop(only, items: transcripts[sizes.last!]!)
        } else {
            let phases = Set((env["SWITCHBOARD_SCROLL_PHASES"] ?? "open,scroll,stream,desk").split(separator: ",").map(String.init))
            var idle: [String: Double] = ["start": try await idleCPU()]
            if phases.contains("open") { try await measureOpen(sizes: sizes, transcripts: transcripts); idle["after_open"] = try await idleCPU() }
            if phases.contains("scroll") { try await measureScroll(sizes: sizes, transcripts: transcripts); idle["after_scroll"] = try await idleCPU() }
            if phases.contains("stream") { try await measureStreaming(sizes: sizes, transcripts: transcripts); idle["after_streaming"] = try await idleCPU() }
            if phases.contains("desk") { try await measureDeskSwitch(sizes: sizes, transcripts: transcripts); idle["after_desk_switch"] = try await idleCPU() }
            report["idle_cpu_percent"] = idle
        }
        report["date"] = Date().description
        report["scope"] = "Synthetic transcripts in a standalone release process (1050x720 window). Main-thread work per phase; "
            + "frame intervals from CADisplayLink. No agents, network or app state."
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    /// CPU of the process while the probe itself does nothing for two seconds: work left running by a phase.
    func idleCPU() async throws -> Double {
        let before = cpuSeconds(), wall = now()
        try await Task.sleep(for: .seconds(2))
        return ((cpuSeconds() - before) / (now() - wall) * 1000).rounded() / 10
    }

    /// Waits (up to 30 s) until the process is quiet, so one phase's leftovers do not count in the next one.
    @discardableResult func settle() async throws -> Double {
        var last = try await idleCPU()
        var waited = 2.0
        while last > 3, waited < 30 { last = try await idleCPU(); waited += 2 }
        return waited
    }

    // MARK: Open and switch

    func measureOpen(sizes: [Int], transcripts: [Int: [TranscriptItem]]) async throws {
        var rows: [[String: Any]] = []
        for size in sizes {
            let items = transcripts[size]!
            // Cold open on a new view, as the app does on every chat switch.
            var runs: [[String: Double]] = []
            var cpu = 0.0
            for run in 0..<3 {
                freshView()
                try await Task.sleep(for: .milliseconds(150))
                let before = cpuSeconds()
                runs.append(timedUpdate(items, id: "chat-\(size)-\(run)"))
                cpu += cpuSeconds() - before
            }
            let height = view.transcript.frame.height
            var row: [String: Any] = ["messages": size, "scenario": "open (new view)", "document_height_pt": Int(height),
                                      "storage_chars": view.transcript.textStorage?.length ?? 0, "footprint_mb": footprintMB(),
                                      "cpu_s_per_open": (cpu / 3 * 1000).rounded() / 1000]
            row.merge(median(runs).mapValues { $0 as Any }) { $1 }
            rows.append(row)

            // Same view: switching away and back (the app recreates the view, so this is the best case if it kept it).
            freshView()
            _ = timedUpdate(items, id: "same-\(size)")
            var back: [[String: Double]] = []
            for run in 0..<3 {
                _ = timedUpdate(transcripts[sizes[0]]!, id: "other-\(run)")
                back.append(timedUpdate(items, id: "same-\(size)"))
            }
            var same: [String: Any] = ["messages": size, "scenario": "switch back (kept view)"]
            same.merge(median(back).mapValues { $0 as Any }) { $1 }
            rows.append(same)

            // Unchanged items re-published (any DeskModel publication reaches updateNSView).
            var noop: [Double] = []
            for _ in 0..<50 {
                let t0 = now()
                view.update(items: items, conversationID: "same-\(size)", followOutput: true, projectPath: project)
                noop.append(now() - t0)
            }
            var idle = stats(noop); idle["messages"] = size; idle["scenario"] = "updateNSView, unchanged items"
            rows.append(idle)
        }
        report["open"] = rows
    }

    // MARK: Scroll

    func measureScroll(sizes: [Int], transcripts: [Int: [TranscriptItem]]) async throws {
        var rows: [[String: Any]] = []
        for size in sizes {
            freshView()
            try await settle()
            _ = timedUpdate(transcripts[size]!, id: "scroll-\(size)")
            try await Task.sleep(for: .milliseconds(300))
            let maxY = max(0, view.transcript.frame.height - view.contentView.bounds.height)
            // Jump to the top (Home / scroll bar drag): one long step.
            let t0 = now()
            view.contentView.scroll(to: .zero); view.reflectScrolledClipView(view.contentView); flushFrame()
            rows.append(["messages": size, "scenario": "jump end->top", "ms": ms(now() - t0)])
            try await Task.sleep(for: .milliseconds(200))

            // Synchronous steps: main-thread cost of one scroll step plus its drawing, no vsync wait.
            for step in [40.0, 400.0] {
                var steps: [Double] = []
                let before = cpuSeconds(), wall = now()
                var y: CGFloat = 0
                while y < maxY {
                    y = min(maxY, y + step)
                    let s = now()
                    view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
                    flushFrame()
                    steps.append(now() - s)
                }
                var row = stats(steps)
                row["messages"] = size; row["scenario"] = "sync steps \(Int(step)) pt top->bottom"
                row["cpu_percent"] = ((cpuSeconds() - before) / (now() - wall) * 1000).rounded() / 10
                rows.append(row)
                view.contentView.scroll(to: .zero); view.reflectScrolledClipView(view.contentView); flushFrame()
                try await Task.sleep(for: .milliseconds(200))
            }

            // Display-link driven scrolling at a fixed speed, as a trackpad flick would move it.
            for (label, speed, from, to) in [("vsync 3000 pt/s top->bottom", 3000.0, CGFloat(0), maxY),
                                             ("vsync 3000 pt/s bottom->top", 3000.0, maxY, CGFloat(0)),
                                             ("vsync 12000 pt/s top->bottom", 12000.0, CGFloat(0), maxY)] {
                let scroller = LinkScroller(view: view, speed: speed, limit: 25)
                let before = cpuSeconds(), wall = now()
                await scroller.run(from: from, to: to)
                var row = scroller.summary()
                row["messages"] = size; row["scenario"] = label
                row["cpu_percent"] = ((cpuSeconds() - before) / (now() - wall) * 1000).rounded() / 10
                rows.append(row)
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        // Fresh open, then scroll right away: the first pass over each region after a chat switch.
        if let size = sizes.last {
            freshView()
            _ = timedUpdate(transcripts[size]!, id: "fresh-scroll-\(size)")
            let maxY = max(0, view.transcript.frame.height - view.contentView.bounds.height)
            let scroller = LinkScroller(view: view, speed: 3000, limit: 25)
            await scroller.run(from: maxY, to: 0)
            var row = scroller.summary()
            row["messages"] = size; row["scenario"] = "vsync 3000 pt/s bottom->top, right after open"
            rows.append(row)
        }
        report["scroll"] = rows
    }

    // MARK: Streaming

    func measureStreaming(sizes: [Int], transcripts: [Int: [TranscriptItem]]) async throws {
        var rows: [[String: Any]] = []
        var synth = Synth(seed: 99)
        let answer = synth.answer(size: 9000)
        let chunks = stride(from: 0, to: answer.count, by: 60).map { offset -> String in
            let start = answer.index(answer.startIndex, offsetBy: offset)
            return String(answer[start..<(answer.index(start, offsetBy: 60, limitedBy: answer.endIndex) ?? answer.endIndex)])
        }
        for size in [10] + sizes {
            let history = size == 10 ? Array(transcripts[sizes[0]]!.prefix(12)) : transcripts[size]!
            freshView()
            let settled = try await settle()
            let since = Date()
            var items = history + [TranscriptItem(id: "live-user", kind: "user", text: "Stream a long answer")]
            _ = timedUpdate(items, id: "stream-\(size)", working: true, since: since)
            try await Task.sleep(for: .milliseconds(200))
            items.append(TranscriptItem(id: "live-answer", kind: "assistant", text: ""))
            var ticks: [[String: Double]] = []
            let before = cpuSeconds(), wall = now()
            for chunk in chunks {
                items[items.count - 1].text += chunk
                ticks.append(timedUpdate(items, id: "stream-\(size)", working: true, since: since))
                // The app batches deltas every 75 ms.
                try await Task.sleep(for: .milliseconds(75))
            }
            let cpu = (cpuSeconds() - before) / (now() - wall)
            let finish = timedUpdate(items, id: "stream-\(size)", working: false)
            // The grouping pass a streaming tick repeats when the last item's length changes (its memo key).
            var grouping: [Double] = []
            for _ in 0..<20 { let t = now(); _ = TranscriptScrollView.groupActivities(items, isWorking: true); grouping.append(now() - t) }
            func col(_ key: String) -> [Double] { ticks.map { ($0[key] ?? 0) / 1000 } }
            var row: [String: Any] = ["messages": size, "ticks": ticks.count, "settled_s": settled, "answer_chars": answer.count,
                                      "cpu_percent_one_core": (cpu * 1000).rounded() / 10]
            row["tick_total"] = stats(col("total_ms"))
            row["tick_render"] = stats(col("render_ms"))
            row["tick_layout"] = stats(col("layout_ms"))
            row["tick_draw"] = stats(col("draw_ms"))
            row["finish_turn"] = finish
            row["group_activities"] = stats(grouping)
            rows.append(row)
        }
        report["streaming"] = rows
    }

    // MARK: Desk switch (SwiftUI host)

    /// The app's own path: ChatHistoryView swaps in ChatLoadingIndicator while a chat loads, so the transcript
    /// view is rebuilt; then the stored items arrive. Measures from the selection to a drawn transcript.
    func measureDeskSwitch(sizes: [Int], transcripts: [Int: [TranscriptItem]]) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                              pluginDirectory: root, summaryResources: nil,
                              jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
        let projectRecord = Project(path: project ?? root.path)
        model.state.projects = [projectRecord]; model.projectID = projectRecord.id
        model.state.chats = sizes.map { Chat(id: "desk-\($0)", projectID: projectRecord.id, title: "Probe \($0)", model: "fixture") }
        model.chatID = model.state.chats[0].id
        let host = NSHostingView(rootView: DeskView(model: model))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        defer { observer.cancel() }
        // Each transcript view seen gets a tag; identifiers of freed views could be reused and undercount.
        var views = 0
        var rows: [[String: Any]] = []
        var shown: Double?
        func waitForTranscript(_ id: String, count: Int) async throws -> Bool {
            let deadline = now() + 10
            shown = nil
            while now() < deadline {
                if let view = TranscriptScrollView.chatTranscript, view.window != nil, view.conversationIDForProbe == id {
                    // The end of the chat is on screen; older history may still be filling in above it.
                    if shown == nil, !view.previous.isEmpty { window.displayIfNeeded(); CATransaction.flush(); shown = now() }
                }
                if let view = TranscriptScrollView.chatTranscript, view.window != nil, view.conversationIDForProbe == id,
                   view.previous.count >= count {
                    if view.identifier?.rawValue != "probe-seen" { view.identifier = NSUserInterfaceItemIdentifier("probe-seen"); views += 1 }
                    return true
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        // Grouped row count of each chat, to know when its transcript is complete.
        let grouped = Dictionary(uniqueKeysWithValues: sizes.map { ($0, TranscriptScrollView.groupActivities(transcripts[$0]!, isWorking: false).items.count) })
        var order: [Int] = []
        for _ in 0..<3 { order += sizes }
        for size in order {
            let id = "desk-\(size)"
            let start = now(), cpu = cpuSeconds(), published = publications
            // DeskModel.openChat: selection, loading state, then the stored transcript.
            model.transcript.cancelPending()
            model.chatID = id
            model.loadingChat = true; model.items = []
            try await Task.sleep(for: .milliseconds(1))
            let loading = now()
            model.items = transcripts[size]!
            model.loadingChat = false
            let ok = try await waitForTranscript(id, count: grouped[size]!)
            let rendered = now()
            window.displayIfNeeded(); CATransaction.flush()
            let drawn = now()
            rows.append(["messages": size, "ok": ok, "loading_state_ms": ms(loading - start), "first_frame_ms": shown.map { ms($0 - start) } ?? -1,
                         "items_to_transcript_ms": ms(rendered - loading),
                         "draw_ms": ms(drawn - rendered), "total_ms": ms(drawn - start), "cpu_s": ((cpuSeconds() - cpu) * 1000).rounded() / 1000,
                         "workspace_publications": publications - published])
            try await Task.sleep(for: .milliseconds(400))
        }
        report["desk_switch"] = ["rows": rows, "distinct_transcript_views": views, "switches": order.count]
    }

    // MARK: Profiler loops

    func loop(_ phase: String, items: [TranscriptItem]) async throws {
        let seconds = Double(env["SWITCHBOARD_SCROLL_SECONDS"] ?? "20") ?? 20
        let end = now() + seconds
        var cycles = 0
        fputs("probe pid \(getpid()) looping \(phase) for \(seconds)s\n", stderr)
        switch phase {
        case "open":
            while now() < end { freshView(); _ = timedUpdate(items, id: "loop-\(cycles)"); cycles += 1; try await Task.sleep(for: .milliseconds(20)) }
        case "scroll":
            freshView(); _ = timedUpdate(items, id: "loop")
            let maxY = max(0, view.transcript.frame.height - view.contentView.bounds.height)
            while now() < end {
                let scroller = LinkScroller(view: view, speed: 6000, limit: end - now())
                await scroller.run(from: cycles % 2 == 0 ? maxY : 0, to: cycles % 2 == 0 ? 0 : maxY)
                cycles += 1
            }
        case "scrollfull":
            // The whole scroll phase, then idle samples.
            try await measureScroll(sizes: [items.count > 2000 ? 1000 : 200], transcripts: [items.count > 2000 ? 1000 : 200: items])
            fputs("probe idle phase starts\n", stderr)
            var samples: [Double] = []
            while now() < end { samples.append(try await idleCPU()) }
            report["idle_after_scroll_cpu_percent"] = samples
        case "afteropen":
            // The scroll right after a chat opens, repeated: older history fills in above while the reader scrolls up.
            var runs: [[String: Any]] = []
            while now() < end {
                freshView()
                try await Task.sleep(for: .milliseconds(150))
                let open = timedUpdate(items, id: "afteropen-\(cycles)")
                let maxY = max(0, view.transcript.frame.height - view.contentView.bounds.height)
                let scroller = LinkScroller(view: view, speed: 3000, limit: 25)
                await scroller.run(from: maxY, to: 0)
                var row = scroller.summary()
                row["open_total_ms"] = open["total_ms"]
                row["backlog_left"] = view.historyBacklog.count
                runs.append(row)
                cycles += 1
                try await settle()
            }
            report["after_open"] = runs
        case "fill":
            // Open and wait at the end until the older history is all in the text; the longest main-thread gap counts.
            var runs: [[String: Any]] = []
            while now() < end {
                freshView()
                try await Task.sleep(for: .milliseconds(150))
                let start = now()
                _ = timedUpdate(items, id: "fill-\(cycles)")
                var longest = 0.0, last = now()
                while !view.historyBacklog.isEmpty, now() - start < 60 {
                    try await Task.sleep(for: .milliseconds(1))
                    let t = now(); longest = max(longest, t - last); last = t
                }
                runs.append(["fill_ms": ms(now() - start), "longest_gap_ms": ms(longest), "complete": view.historyBacklog.isEmpty,
                             "storage_chars": view.transcript.textStorage?.length ?? 0])
                cycles += 1
            }
            report["fill"] = runs
        case "scrollidle":
            // One scroll pass, then nothing: shows work the scroll leaves running after it stops.
            freshView(); _ = timedUpdate(items, id: "loop")
            let maxY = max(0, view.transcript.frame.height - view.contentView.bounds.height)
            let scrollStart = now(), scrollCPU = cpuSeconds()
            await LinkScroller(view: view, speed: Double(env["SWITCHBOARD_SCROLL_SPEED"] ?? "12000") ?? 12000, limit: 60).run(from: maxY, to: 0)
            report["scroll_cpu_percent"] = ((cpuSeconds() - scrollCPU) / (now() - scrollStart) * 1000).rounded() / 10
            report["scroll_seconds"] = ((now() - scrollStart) * 10).rounded() / 10
            var samples: [Double] = []
            while now() < end { samples.append(try await idleCPU()) }
            report["idle_after_scroll_cpu_percent"] = samples
        default:
            freshView()
            var live = items + [TranscriptItem(id: "live-user", kind: "user", text: "Stream"), TranscriptItem(id: "live", kind: "assistant", text: "")]
            var synth = Synth(seed: 5)
            let answer = synth.answer(size: 9000)
            var offset = 0
            let since = Date()
            while now() < end {
                if offset >= answer.count { live[live.count - 1].text = ""; offset = 0 }
                let start = answer.index(answer.startIndex, offsetBy: offset)
                let stop = answer.index(start, offsetBy: 60, limitedBy: answer.endIndex) ?? answer.endIndex
                live[live.count - 1].text += String(answer[start..<stop]); offset += 60
                _ = timedUpdate(live, id: "loop", working: true, since: since)
                cycles += 1
                try await Task.sleep(for: .milliseconds(75))
            }
        }
        report["loop"] = ["phase": phase, "cycles": cycles, "seconds": seconds]
    }
}

extension TranscriptScrollView {
    /// `conversationID` is private; the probe reads it through the reading-position key it is stored under.
    @MainActor var conversationIDForProbe: String? { Mirror(reflecting: self).children.first { $0.label == "conversationID" }?.value as? String }
}
