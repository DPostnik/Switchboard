import AppKit
import Combine
import QuartzCore
import SwiftUI
import Darwin
import ContextCore
import AgentContract
@testable import ContextTranscript
@testable import ContextDesk

/// Chat memory probe: process footprint after opening, switching, streaming into and closing synthetic chats through
/// the app's own path (`DeskView` + `DeskModel.openChat` + `AppStore` in a temporary directory). Synthetic transcripts
/// only; no agents, network, credentials or app state. Run through `scripts/perf/profile-memory.py`. Environment:
///   SWITCHBOARD_MEMORY_REPORT    output JSON path (required)
///   SWITCHBOARD_MEMORY_SCENARIO  open | switch | stream | views (one scenario per process, so baselines are clean)
///   SWITCHBOARD_MEMORY_SIZE      messages per chat (default 200)
///   SWITCHBOARD_MEMORY_CHATS     chats for "open" (default 20; checkpoints after 1, 5 and the last)
///   SWITCHBOARD_MEMORY_SWITCHES  switches for "switch" (default 50)
///   SWITCHBOARD_MEMORY_SECONDS   streaming duration for "stream" (default 300)
///   SWITCHBOARD_MEMORY_VIEWS     kept transcript views for "views" (default 3)
///   SWITCHBOARD_MEMORY_HOLD      after closing, keep running this many seconds with a checkpoint every 15 s, so a
///                                profiler (`heap`, `vmmap`) can attach to the probe (default 0)
///   SWITCHBOARD_MEMORY_NO_TEXT_CHECKING  1: experiment, turn off NSTextView automatic text checking on each opened
///                                transcript view (the app keeps it on)
///   SWITCHBOARD_MEMORY_FIND_BAR  1: "views" configures the find bar and incremental search as the app's chat transcript
///   SWITCHBOARD_SCROLL_PROJECT   directory used as the chats' project, so file chips resolve (optional)
@main struct MemoryProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await Probe().run(); exit(0) }
            catch { fputs("memory probe failed: \(error)\n", stderr); exit(1) }
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
func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

/// phys_footprint (what Activity Monitor and jetsam use), its peak, and bytes in use in all malloc zones.
func memory() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    guard result == KERN_SUCCESS else { return ["footprint_mb": -1] }
    return ["footprint_mb": mb(info.phys_footprint), "peak_mb": mb(UInt64(info.ledger_phys_footprint_peak)),
            "malloc_in_use_mb": mb(UInt64(stats.size_in_use)), "malloc_allocated_mb": mb(UInt64(stats.size_allocated))]
}

@MainActor final class Probe {
    let env = ProcessInfo.processInfo.environment
    var report: [String: Any] = [:]
    var checkpoints: [[String: Any]] = []
    var window: NSWindow!
    lazy var project: String? = env["SWITCHBOARD_SCROLL_PROJECT"]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-probe-" + UUID().uuidString)
    var model: DeskModel!
    var store: AppStore!
    var chats: [Chat] = []
    /// Every transcript view the app built, held weakly: shows how many old chats' views are still alive.
    let seenViews = NSHashTable<TranscriptScrollView>.weakObjects()

    func int(_ key: String, _ fallback: Int) -> Int { env[key].flatMap(Int.init) ?? fallback }

    /// Lets deferred work (flushes, SwiftUI updates, autorelease pools of run-loop turns) finish before reading memory.
    func settle(_ seconds: Double = 1.5) async throws {
        let end = now() + seconds
        while now() < end {
            window.displayIfNeeded(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func checkpoint(_ label: String, _ extra: [String: Any] = [:], relief: Bool = false) async throws {
        try await settle()
        var row: [String: Any] = ["label": label, "t_s": (now() * 10).rounded() / 10]
        row.merge(memory().mapValues { $0 as Any }) { $1 }
        if relief {
            // What a memory-pressure handler could return without dropping any app cache: free pages malloc holds.
            let released = malloc_zone_pressure_relief(nil, 0)
            try await settle(0.5)
            row["after_relief"] = memory()
            row["relief_released_mb"] = mb(UInt64(released))
        }
        row.merge(extra) { $1 }
        let alive = seenViews.allObjects
        row["transcript_views_alive"] = alive.count
        row["transcript_views_in_window"] = alive.filter { $0.window != nil }.count
        row["alive_storage_chars"] = alive.reduce(0) { $0 + ($1.transcript.textStorage?.length ?? 0) }
        checkpoints.append(row)
        fputs("checkpoint \(label): \(row)\n", stderr)
    }

    func run() async throws {
        guard let path = env["SWITCHBOARD_MEMORY_REPORT"] else { throw NSError(domain: "probe", code: 1) }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scenario = env["SWITCHBOARD_MEMORY_SCENARIO"] ?? "open"
        let size = int("SWITCHBOARD_MEMORY_SIZE", 200)
        report["scenario"] = scenario; report["messages_per_chat"] = size
        report["text_checking_off"] = env["SWITCHBOARD_MEMORY_NO_TEXT_CHECKING"] == "1"
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1050, height: 720), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Memory probe"
        window.orderFront(nil)
        try await checkpoint("process start")
        if scenario == "views" { try await keptViews(size: size) } else { try await desk(scenario: scenario, size: size) }
        report["checkpoints"] = checkpoints
        report["date"] = Date().description
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    // MARK: App path

    func chatCount(_ scenario: String) -> Int {
        switch scenario {
        case "open": return int("SWITCHBOARD_MEMORY_CHATS", 20)
        case "switch": return 2
        default: return 1
        }
    }

    func desk(scenario: String, size: Int) async throws {
        store = AppStore(file: root.appendingPathComponent("state.sqlite"))
        let projectRecord = Project(path: project ?? root.path)
        let count = chatCount(scenario)
        chats = (0..<count).map { Chat(id: "chat-\(size)-\($0)", projectID: projectRecord.id, title: "Probe \($0)", model: "fixture") }
        var state = SavedState()
        state.projects = [projectRecord]; state.chats = chats
        try await store.save(state)
        var stats: [[String: Any]] = []
        for (index, chat) in chats.enumerated() {
            // One chat at a time, so the generator's arrays are freed before the next one.
            let snapshot = try autoreleasepool { () throws -> AgentTranscriptSnapshot in
                let items = Synth.transcript(messages: size, seed: UInt64(size * 1000 + index))
                if index == 0 { stats.append(["items": items.count, "utf8_mb": Double(items.reduce(0) { $0 + $1.text.utf8.count }) / 1_048_576]) }
                return try LocalHistory.snapshot(conversation: ConversationID(chat.id), source: chat.nativeSession!, items: items,
                                                 completeness: .complete)
            }
            try await store.saveTranscript(snapshot)
        }
        await store.flushTranscripts()
        report["transcript"] = stats.first ?? [:]
        try await checkpoint("transcripts stored (AppStore keeps its LRU of 4)")
        model = DeskModel(store: store, pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
        model.state.projects = [projectRecord]; model.projectID = projectRecord.id
        model.state.chats = chats
        let host = NSHostingView(rootView: DeskView(model: model))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        try await checkpoint("DeskView shown, no chat selected", relief: true)
        switch scenario {
        case "open":
            for index in chats.indices {
                let ms = try await open(chats[index])
                if [0, 4, chats.count - 1].contains(index) {
                    try await checkpoint("opened \(index + 1) chats", ["open_ms": ms, "storage_chars": storageChars()], relief: index == chats.count - 1)
                }
            }
            try await close()
        case "switch":
            let switches = int("SWITCHBOARD_MEMORY_SWITCHES", 50)
            _ = try await open(chats[0]); _ = try await open(chats[1])
            try await checkpoint("both chats opened once")
            var trace: [Double] = []
            for index in 0..<switches {
                _ = try await open(chats[index % 2])
                trace.append(memory()["footprint_mb"] ?? -1)
                if (index + 1) % 10 == 0 { try await checkpoint("switch \(index + 1)") }
            }
            report["footprint_per_switch_mb"] = trace
            try await close()
        case "stream":
            _ = try await open(chats[0])
            try await checkpoint("chat opened before streaming")
            try await stream(chat: chats[0], seconds: Double(int("SWITCHBOARD_MEMORY_SECONDS", 300)))
            try await close()
        default: throw NSError(domain: "probe", code: 2)
        }
    }

    /// Font objects in a rendered storage: equal fonts that are distinct objects each carry their own glyph caches.
    func fontCensus(_ storage: NSTextStorage?) -> [String: Any] {
        guard let storage else { return [:] }
        var objects = Set<ObjectIdentifier>()
        var perName: [String: Int] = [:]
        var runs = 0
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let font = value as? NSFont else { return }
            runs += 1
            if objects.insert(ObjectIdentifier(font)).inserted { perName["\(font.fontName) \(font.pointSize)", default: 0] += 1 }
        }
        // Where the most duplicated font sits (synthetic text only): a few sample runs with their attribute keys.
        var samples: [String] = []
        if let name = perName.max(by: { $0.value < $1.value })?.key {
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let font = value as? NSFont, "\(font.fontName) \(font.pointSize)" == name else { return }
                let keys = storage.attributes(at: range.location, effectiveRange: nil).keys.map(\.rawValue).sorted().joined(separator: ",")
                samples.append("\(range.length) chars [\(keys)] " + String(storage.attributedSubstring(from: NSRange(location: range.location, length: min(40, range.length))).string))
                if samples.count >= 4 { stop.pointee = true }
            }
        }
        let top = perName.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key): \($0.value)" }
        return ["samples": samples, "font_runs": runs, "distinct_font_objects": objects.count, "distinct_name_size": perName.count, "top_duplicates": top]
    }

    func storageChars() -> Int { TranscriptScrollView.chatTranscript?.transcript.textStorage?.length ?? 0 }

    /// `DeskModel.openChat` (stored transcript; the engine history step fails without a connection), then waits until
    /// the transcript view holds every grouped row.
    func open(_ chat: Chat) async throws -> Double {
        let start = now()
        await model.openChat(chat)
        if env["SWITCHBOARD_MEMORY_NO_TEXT_CHECKING"] == "1", let text = TranscriptScrollView.chatTranscript?.transcript {
            text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticDataDetectionEnabled = false; text.isAutomaticTextCompletionEnabled = false
            text.isContinuousSpellCheckingEnabled = false; text.isGrammarCheckingEnabled = false
        }
        if let view = TranscriptScrollView.chatTranscript { seenViews.add(view) }
        let expected = TranscriptScrollView.groupActivities(model.items, isWorking: false).items.count
        let deadline = now() + 30
        while now() < deadline {
            if let view = TranscriptScrollView.chatTranscript, view.window != nil, view.conversationIDForProbe == chat.id,
               view.previous.count >= expected, expected > 0 { seenViews.add(view); break }
            try await Task.sleep(for: .milliseconds(2))
        }
        window.displayIfNeeded(); CATransaction.flush()
        return ((now() - start) * 1000).rounded()
    }

    func close() async throws {
        model.newChat()
        try await checkpoint("chat closed (new chat, nothing selected)", relief: true)
        // Lets any remaining scheduled flush and release run, then reads again.
        try await Task.sleep(for: .seconds(3))
        try await checkpoint("closed + 3 s", relief: true)
        let hold = int("SWITCHBOARD_MEMORY_HOLD", 0)
        if hold > 0 {
            fputs("holding pid \(getpid()) for \(hold) s\n", stderr)
            for step in stride(from: 15, through: hold, by: 15) {
                try await Task.sleep(for: .seconds(15))
                try await checkpoint("closed + \(step + 3) s")
            }
        }
    }

    /// Text deltas through `TranscriptPresentation` every 75 ms (the app's batching interval); each answer of about
    /// 9 000 characters completes like an `.item` event: recorded in the store (flushed about a second later) and merged.
    func stream(chat: Chat, seconds: Double) async throws {
        var synth = Synth(seed: 77)
        let end = now() + seconds
        var turn = 0, chunks = 0, nextCheckpoint = now() + 30
        var trace: [[String: Double]] = []
        while now() < end {
            let userItem = TranscriptItem(id: "live-\(turn)-user", kind: "user", text: synth.sentence())
            TranscriptItem.merge(userItem, into: &model.items)
            try await store.recordTranscriptItem(userItem, conversationID: chat.id, source: chat.nativeSession!)
            let answer = synth.answer(size: 9000)
            let id = "live-\(turn)-answer"
            var offset = answer.startIndex
            while offset < answer.endIndex, now() < end {
                let stop = answer.index(offset, offsetBy: 60, limitedBy: answer.endIndex) ?? answer.endIndex
                model.transcript.enqueue(id: id, text: String(answer[offset..<stop]), turn: "live-turn-\(turn)")
                offset = stop; chunks += 1
                try await Task.sleep(for: .milliseconds(75))
                if now() >= nextCheckpoint {
                    var sample = memory(); sample["t_s"] = (seconds - (end - now())).rounded()
                    trace.append(sample); nextCheckpoint += 30
                }
            }
            model.transcript.flush()
            var final = TranscriptItem(id: id, kind: "assistant", text: answer, phase: "final_answer")
            final.turnID = "live-turn-\(turn)"
            TranscriptItem.merge(final, into: &model.items)
            try await store.recordTranscriptItem(final, conversationID: chat.id, source: chat.nativeSession!)
            turn += 1
        }
        report["stream"] = ["seconds": seconds, "answers": turn, "chunks": chunks, "trace": trace,
                            "items_after": model.items.count, "storage_chars": storageChars()]
        try await checkpoint("streamed \(Int(seconds)) s, \(turn) answers", relief: true)
    }

    // MARK: Kept views (cost of caching rendered chats)

    func keptViews(size: Int) async throws {
        let count = int("SWITCHBOARD_MEMORY_VIEWS", 3)
        var views: [TranscriptScrollView] = []
        for index in 0..<count {
            let items = Synth.transcript(messages: size, seed: UInt64(size * 1000 + index))
            let view = TranscriptScrollView(positions: TranscriptReadingPositions())
            if env["SWITCHBOARD_MEMORY_FIND_BAR"] == "1" {
                // As `NativeTranscript.makeNSView` configures the app's chat transcript.
                view.transcript.usesFindBar = true
                view.transcript.isIncrementalSearchingEnabled = true
            }
            window.contentView = view
            view.update(items: items, conversationID: "view-\(index)", followOutput: true, projectPath: project)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded(); CATransaction.flush()
            views.append(view); seenViews.add(view)
            try await checkpoint("\(index + 1) rendered views kept", ["storage_chars": view.transcript.textStorage?.length ?? 0,
                                                                     "fonts": fontCensus(view.transcript.textStorage)])
        }
        window.contentView = NSView()
        views.removeAll()
        try await checkpoint("views released", relief: true)
        try await Task.sleep(for: .seconds(20))
        try await checkpoint("views released + 20 s")
    }
}

extension TranscriptScrollView {
    /// `conversationID` is private; read through reflection.
    @MainActor var conversationIDForProbe: String? { Mirror(reflecting: self).children.first { $0.label == "conversationID" }?.value as? String }
}
