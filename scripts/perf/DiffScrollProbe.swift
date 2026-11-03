// Diff scroll probe: hosts Switchboard's real diff views in this process's own windows, scrolls them
// programmatically frame by frame and records frame pacing and main-thread busy time.
// Built and run by scripts/perf/profile-diff-scroll.py; never touches the running app or the user's data.
import AppKit
import QuartzCore
import SwiftUI
import Darwin
import AgentContract
@testable import ContextCore
@testable import ContextTranscript
@testable import ContextDesk

// MARK: Measurement

/// Main-thread busy time per run-loop iteration (after waking until going back to sleep).
@MainActor final class RunLoopMeter {
    private var observer: CFRunLoopObserver?
    private var wake: CFTimeInterval = 0
    private(set) var busy: [Double] = []
    var recording = false

    init() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.wake = now }
                else if self.recording, self.wake > 0 { self.busy.append((now - self.wake) * 1000) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    func reset() { busy = []; wake = 0 }
}

/// Drives one scroll run from a CADisplayLink on the window's screen.
@MainActor final class ScrollDriver: NSObject {
    enum Mode: String { case clip, wheel }
    let scrollView: NSScrollView
    let mode: Mode
    let speed: CGFloat           // points per second
    let frames: Int
    private var link: CADisplayLink?
    private var direction: CGFloat = 1
    private(set) var intervals: [Double] = []
    private(set) var stepTimes: [Double] = []
    private(set) var period: Double = 0
    private var last: CFTimeInterval = 0
    private var lastVsync: CFTimeInterval = 0
    private(set) var vsyncIntervals: [Double] = []
    private var done: CheckedContinuation<Void, Never>?
    private(set) var travelled: CGFloat = 0

    init(scrollView: NSScrollView, mode: Mode, speed: CGFloat, frames: Int) {
        self.scrollView = scrollView; self.mode = mode; self.speed = speed; self.frames = frames
    }

    func run() async {
        await withCheckedContinuation { continuation in
            done = continuation
            let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Wall time of the callback: when the main thread is busy, callbacks come late and frames are skipped.
        // (link.timestamp is the vsync the callback was scheduled for and hides that lateness.)
        let now = CACurrentMediaTime()
        if last > 0 { intervals.append((now - last) * 1000); vsyncIntervals.append((link.timestamp - lastVsync) * 1000) }
        last = now; lastVsync = link.timestamp
        period = link.duration > 0 ? link.duration : period
        let frameSeconds = period > 0 ? period : 1.0 / 60
        let dy = speed * CGFloat(frameSeconds) * direction
        let clip = scrollView.contentView
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, docHeight - clip.bounds.height)
        let start = CACurrentMediaTime()
        switch mode {
        case .clip:
            var y = clip.bounds.origin.y + dy
            if y >= maxY { y = maxY; direction = -1 } else if y <= 0 { y = 0; direction = 1 }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        case .wheel:
            let y = clip.bounds.origin.y
            if y >= maxY - 1, direction > 0 { direction = -1 } else if y <= 1, direction < 0 { direction = 1 }
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy.rounded()), wheel2: 0, wheel3: 0),
               let event = NSEvent(cgEvent: cg) {
                // Delivered straight to this process's scroll view; the CGEvent is never posted to the system.
                scrollView.scrollWheel(with: event)
            }
        }
        stepTimes.append((CACurrentMediaTime() - start) * 1000)
        travelled += abs(dy)
        if intervals.count >= frames {
            link.invalidate(); self.link = nil
            done?.resume(); done = nil
        }
    }
}

/// Seconds since this process started (wall clock), to line scroll runs up with a Time Profiler trace.
func secondsSinceLaunch() -> Double {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
    let start = info.kp_proc.p_un.__p_starttime
    return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
}

func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

// MARK: Fixtures

enum Fixture {
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Probe", "-c", "user.email=probe@localhost", "-c", "commit.gpgsign=false",
                             "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a large diff fills the pipe and git would block forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func line(_ i: Int, width: Int, version: Int) -> String {
        // Short lines (no wrapping in a 740 pt column) keep the version near the start, so the change survives the cut.
        if width < 60 { return String("    let v\(i) = f(\(version), \(i % 7)) // step \(i) of the fixture".prefix(width)) }
        let base = "    let value\(i) = compute(\(i), factor: \(i % 7), scale: \(version)) // step \(i) of the synthetic fixture"
        guard width > base.count else { return String(base.prefix(width)) }
        return base + " " + String(repeating: "payload\(i % 10) ", count: (width - base.count) / 9 + 1).prefix(width - base.count)
    }

    /// Old file of `count` lines; the new version changes every third line, so a diff shows ~1.33 × count lines in one hunk.
    static func text(count: Int, width: Int, version: Int) -> String {
        (0..<count).map { i in line(i, width: width, version: version > 0 && i % 3 == 1 ? version : 0) }.joined(separator: "\n") + "\n"
    }

    struct Repo {
        let root: URL
        /// Commits: c0 (base), c1, c2, c3 (each changes every third line of every file again).
        let commits: [String]
    }

    static let files: [(name: String, lines: Int, width: Int)] = [
        ("small.swift", 150, 60), ("medium.swift", 1500, 60), ("large.swift", 7500, 60), ("wide.swift", 1500, 240),
        ("short.swift", 1500, 48)
    ]

    static func repository(at root: URL) throws -> Repo {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "-q"], in: root)
        var commits: [String] = []
        for version in 0...3 {
            for file in files {
                try text(count: file.lines, width: file.width, version: version).write(to: root.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
            }
            _ = try git(["add", "-A"], in: root)
            _ = try git(["commit", "-q", "-m", "v\(version)"], in: root)
            commits.append(try git(["rev-parse", "HEAD"], in: root))
        }
        return Repo(root: root, commits: commits)
    }

    /// Diff lines as the app shows them (DiffLine.parse of a real git patch).
    static func diffLines(_ repo: Repo, file: String, turn: Int = 1) throws -> [DiffLine] {
        let patch = try git(["diff", "--no-color", repo.commits[turn - 1], repo.commits[turn], "--", file], in: repo.root)
        return DiffLine.parse(patch)
    }

    static func unified(_ lines: [DiffLine]) -> String {
        lines.map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .hunk, .note: line.text
            }
        }.joined(separator: "\n")
    }
}

// MARK: Replica rows (variants of DiffLineRow, to attribute cost to its modifiers)

struct Variant: OptionSet { let rawValue: Int
    static let help = Variant(rawValue: 1), hover = Variant(rawValue: 2), tap = Variant(rawValue: 4), cursor = Variant(rawValue: 8)
    static let contextMenu = Variant(rawValue: 16), textSelection = Variant(rawValue: 32), signGroup = Variant(rawValue: 64)
    /// Line numbers and sign opt out of selection: only the code Text stays selectable.
    static let codeOnlySelection = Variant(rawValue: 128)
    static let all: Variant = [.help, .hover, .tap, .cursor, .contextMenu, .textSelection, .signGroup]
}

struct ReplicaRow: View {
    let line: DiffLine
    let variant: Variant
    @State private var hovering = false
    private static let added = Color(nsColor: DeskPalette.ns.accent.withAlphaComponent(0.13))
    private static let removed = Color(nsColor: DeskPalette.ns.problem.withAlphaComponent(0.11))

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                numbers
                Group {
                    if variant.contains(.signGroup), hovering { Image(systemName: "plus.bubble").font(.system(size: 9.5)) }
                    else { Text(sign).foregroundStyle(DeskPalette.muted) }
                }
                .frame(width: 16, alignment: .center)
            }
            .modifier(DiffColumn.Selection(on: false, applies: variant.contains(.codeOnlySelection)))
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? DeskPalette.muted : DeskPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 3 : 0.5)
        .background(background)
    }

    @ViewBuilder private var numbers: some View {
        let base = HStack(spacing: 0) { number(line.old); number(line.new) }
            .background(hovering ? DeskPalette.subtle : .clear)
            .contentShape(Rectangle())
        let hovered = Group {
            if variant.contains(.hover) { base.onHover { hovering = $0 } } else { base }
        }
        let tapped = Group {
            if variant.contains(.tap) { hovered.onTapGesture { _ = NSEvent.modifierFlags } } else { hovered }
        }
        let cursor = Group { if variant.contains(.cursor) { tapped.pointingHandCursor() } else { tapped } }
        if variant.contains(.help) {
            cursor.help(L10n.text("Прокомментировать строку для агента (Shift — диапазон)", "Comment on this line for the agent (Shift for a range)"))
        } else { cursor }
    }

    private var sign: String { line.kind == .added ? "+" : line.kind == .removed ? "−" : "" }
    private var background: Color {
        switch line.kind {
        case .added: Self.added
        case .removed: Self.removed
        case .hunk: DeskPalette.subtle
        case .context, .note: .clear
        }
    }
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(DeskPalette.muted.opacity(0.75))
            .frame(width: 44, alignment: .trailing).padding(.trailing, 6)
    }
}

/// The diff column of TurnChangesView (`diff`), with the real DiffLineRow or a replica row.
struct DiffColumn: View {
    let lines: [DiffLine]
    let variant: Variant?   // nil: the real DiffLineRow
    let eager: Bool         // VStack instead of LazyVStack

    var body: some View {
        ScrollView {
            if eager {
                VStack(alignment: .leading, spacing: 0) { rows }.modifier(Selection(on: variant?.contains(.textSelection) ?? true))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) { rows }.modifier(Selection(on: variant?.contains(.textSelection) ?? true))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var rows: some View {
        ForEach(lines) { line in
            if let variant {
                let row = ReplicaRow(line: line, variant: variant)
                if variant.contains(.contextMenu) { row.contextMenu { Button("Open") {} } } else { row }
            } else {
                DiffLineRow(line: line, selected: false) { _ in }.contextMenu { Button("Open") {} }
            }
        }
    }

    struct Selection: ViewModifier {
        let on: Bool
        var applies = true
        @ViewBuilder func body(content: Content) -> some View {
            if !applies { content } else if on { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
        }
    }
}

/// The proposed direction: one TextKit view for the whole diff (non-contiguous layout, line washes as attributes).
@MainActor func textKitDiffView(_ lines: [DiffLine], frame: NSRect) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = frame
    let view = scroll.documentView as! NSTextView
    view.isEditable = false; view.isSelectable = true
    view.layoutManager?.allowsNonContiguousLayout = true
    view.textContainer?.lineFragmentPadding = 0
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let text = NSMutableAttributedString()
    let added = DeskPalette.ns.accent.withAlphaComponent(0.13), removed = DeskPalette.ns.problem.withAlphaComponent(0.11)
    for line in lines {
        let number = { (value: Int?) in value.map { String($0).leftPad(5) } ?? "     " }
        let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
        var attributes: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor]
        if line.kind == .added { attributes[.backgroundColor] = added }
        if line.kind == .removed { attributes[.backgroundColor] = removed }
        text.append(NSAttributedString(string: number(line.old) + " " + number(line.new) + "  " + sign + " " + line.text + "\n", attributes: attributes))
    }
    view.textStorage?.setAttributedString(text)
    return scroll
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}

// MARK: Probe

@main struct DiffScrollProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await measure(); exit(0) }
            catch { fputs("Diff scroll probe failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// The scroll view showing the diff: the tallest document among the window's scroll views.
    @MainActor static func diffScrollView(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        return descendants(content).compactMap { $0 as? NSScrollView }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    @MainActor static func waitForDocument(_ window: NSWindow, minimum: CGFloat, timeout: Double = 20) async -> NSScrollView? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastHeight: CGFloat = -1, stable = 0
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let scroll = diffScrollView(in: window) else { continue }
            let height = scroll.documentView?.frame.height ?? 0
            if height >= minimum, abs(height - lastHeight) < 1 { stable += 1 } else { stable = 0 }
            lastHeight = height
            if stable >= 3 { return scroll }
        }
        return diffScrollView(in: window)
    }

    struct Scenario {
        let name: String
        let lines: Int
        let note: String
        let make: () async throws -> (NSWindow, NSScrollView?)
    }

    @MainActor static func measure() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIFF_PROBE_REPORT"] else { fputs("DIFF_PROBE_REPORT not set\n", stderr); return }
        let only = ProcessInfo.processInfo.environment["DIFF_PROBE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let frames = Int(ProcessInfo.processInfo.environment["DIFF_PROBE_FRAMES"] ?? "") ?? 300
        let speeds = (ProcessInfo.processInfo.environment["DIFF_PROBE_SPEEDS"] ?? "2400").split(separator: ",").compactMap { Double($0) }
        let modes = (ProcessInfo.processInfo.environment["DIFF_PROBE_MODES"] ?? "clip").split(separator: ",").compactMap { ScrollDriver.Mode(rawValue: String($0)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diff-scroll-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try Fixture.repository(at: root.appendingPathComponent("repo"))
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let model = DeskModel(store: AppStore(file: data.appendingPathComponent("state.sqlite")),
                              capabilityLedger: CapabilityLedger(file: data.appendingPathComponent("ledger.sqlite")),
                              pluginDirectory: data, summaryResources: nil, summaryHome: data, claudeHome: data,
                              jobStore: JobStore(file: data.appendingPathComponent("jobs.json")))
        let meter = RunLoopMeter()
        var lineCounts: [String: Int] = [:]
        for file in Fixture.files { lineCounts[file.name] = try Fixture.diffLines(repo, file: file.name).count }

        func changes(_ turn: Int) -> TurnChanges {
            TurnChanges(repository: repo.root.path, start: repo.commits[turn - 1], end: repo.commits[turn], files: Fixture.files.count,
                        added: 0, removed: 0,
                        list: Fixture.files.map { TurnChanges.File(path: $0.name, status: "modified", added: $0.lines / 3, removed: $0.lines / 3) })
        }
        func turnWindow(_ file: String, turn: Int = 1) async throws -> (NSWindow, NSScrollView?) {
            TurnChangesWindow.show(changes(turn), chatID: nil, model: model, file: file)
            guard let window = NSApp.windows.last(where: { $0.isVisible && $0 is EscapeClosingWindow }) else { throw NSError(domain: "no window", code: 1) }
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            return (window, await waitForDocument(window, minimum: CGFloat(min(lineCounts[file] ?? 0, 400)) * 10))
        }
        func chatWindow(_ file: String) async throws -> (NSWindow, NSScrollView?) {
            let items = (1...3).map { turn in
                TranscriptItem(id: "answer-\(turn)", kind: "assistant", text: "Turn \(turn)",
                               timing: ResponseTiming(startedAt: nil, completedAt: Date(), changes: changes(turn)))
            }
            let files = ChatFilesModel()
            files.update(chatID: "probe-chat", items: items, projectPath: repo.root.path, engine: GitCheckpoints(), immediately: true)
            for _ in 0..<100 where files.changed.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            guard let changed = files.changed.first(where: { $0.path == file }) else { throw NSError(domain: "no changed file", code: 2) }
            ChatChangesWindow.show(files.snapshot(), file: changed.id, model: model)
            guard let window = NSApp.windows.last(where: { $0.isVisible && $0 is EscapeClosingWindow }) else { throw NSError(domain: "no window", code: 1) }
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            return (window, await waitForDocument(window, minimum: CGFloat(min(3 * (lineCounts[file] ?? 0), 400)) * 10))
        }
        func hosted<V: View>(_ view: V) async -> (NSWindow, NSScrollView?) {
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 740, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view.preferredColorScheme(.light))
            window.orderFront(nil)
            return (window, await waitForDocument(window, minimum: 2000))
        }
        func plainWindow(_ view: NSView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 740, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = window.contentLayoutRect
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.orderFront(nil)
            return window
        }
        func transcriptWindow(text: String, document: Bool, expandBlocks: Bool) async -> (NSWindow, NSScrollView?) {
            let view = TranscriptScrollView()
            view.isDocument = document
            if document { view.transcript.usesFindBar = true }
            let window = plainWindow(view)
            let items: [TranscriptItem]
            if document {
                items = DocumentTextView.items(DocumentPreview.chunks(text, kind: .markdown))
            } else {
                items = [TranscriptItem(id: "user", kind: "user", text: "Show the diff"), TranscriptItem(id: "answer", kind: "assistant", text: text)]
            }
            view.update(items: items, conversationID: "probe", followOutput: false, projectPath: root.path)
            view.layoutSubtreeIfNeeded()
            if expandBlocks, let storage = view.transcript.textStorage {
                var toggles: [(String, Int)] = []
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    if let link = value as? String, link.hasPrefix("contextdesk-toggle:") { toggles.append((link, range.location)) }
                }
                for (link, index) in toggles { _ = view.textView(view.transcript, clickedOnLink: link, at: index) }
            }
            try? await Task.sleep(for: .milliseconds(300))
            view.contentView.scroll(to: .zero); view.reflectScrolledClipView(view.contentView)
            return (window, view)
        }
        func diffMarkdown(_ file: String) throws -> String {
            "# Patch\n\n```diff\n" + Fixture.unified(try Fixture.diffLines(repo, file: file)) + "\n```\n"
        }
        func codeDocument(_ lines: Int) -> String {
            DocumentPreview.transcriptText(Fixture.text(count: lines, width: 60, version: 0), kind: .code(language: "swift"))
        }

        let medium = try Fixture.diffLines(repo, file: "medium.swift"), large = try Fixture.diffLines(repo, file: "large.swift")
        var scenarios: [Scenario] = []
        for file in Fixture.files {
            scenarios.append(Scenario(name: "turn-window/\(file.name)", lines: lineCounts[file.name] ?? 0,
                                      note: "Real TurnChangesWindow (TurnChangesView, DiffLineRow in LazyVStack), real git patch") { try await turnWindow(file.name) })
        }
        scenarios.append(Scenario(name: "chat-window/medium.swift x3 turns", lines: 3 * medium.count,
                                  note: "Real ChatChangesWindow (ChatChangeDiffView), three turns of the same file") { try await chatWindow("medium.swift") })
        scenarios.append(Scenario(name: "chat-window/large.swift x3 turns", lines: 3 * large.count,
                                  note: "Real ChatChangesWindow, three turns of large.swift") { try await chatWindow("large.swift") })
        // Attribution: the same column with the real row, replica rows without one modifier each, and alternatives.
        let variants: [(String, Variant?, Bool)] = [
            ("real-row", nil, false), ("replica-all", .all, false),
            ("no-help", Variant.all.subtracting(.help), false),
            ("no-hover", Variant.all.subtracting([.hover, .signGroup]), false),
            ("no-cursor", Variant.all.subtracting(.cursor), false),
            ("no-contextmenu", Variant.all.subtracting(.contextMenu), false),
            ("no-textselection", Variant.all.subtracting(.textSelection), false),
            ("code-only-selection", Variant.all.union(.codeOnlySelection), false),
            ("bare-row", [], false),
        ]
        for (name, variant, eager) in variants {
            scenarios.append(Scenario(name: "column/\(name)/medium", lines: medium.count,
                                      note: "DiffColumn in a 740x620 window, medium.swift diff") { await hosted(DiffColumn(lines: medium, variant: variant, eager: eager)) })
        }
        scenarios.append(Scenario(name: "column/real-row/large", lines: large.count, note: "DiffColumn, real row, large.swift") {
            await hosted(DiffColumn(lines: large, variant: nil, eager: false)) })
        scenarios.append(Scenario(name: "column/bare-row/large", lines: large.count, note: "DiffColumn, bare replica row, large.swift") {
            await hosted(DiffColumn(lines: large, variant: [], eager: false)) })
        scenarios.append(Scenario(name: "textkit/medium", lines: medium.count, note: "Proposed: one NSTextView, non-contiguous layout") {
            let scroll = textKitDiffView(medium, frame: NSRect(x: 0, y: 0, width: 740, height: 620)); let window = plainWindow(scroll)
            try? await Task.sleep(for: .milliseconds(300)); return (window, scroll) })
        scenarios.append(Scenario(name: "textkit/large", lines: large.count, note: "Proposed: one NSTextView, non-contiguous layout") {
            let scroll = textKitDiffView(large, frame: NSRect(x: 0, y: 0, width: 740, height: 620)); let window = plainWindow(scroll)
            try? await Task.sleep(for: .milliseconds(300)); return (window, scroll) })
        // TextKit transcript paths: a ```diff block in a document preview and in a chat answer, and a long code file.
        for file in ["medium.swift", "large.swift"] {
            scenarios.append(Scenario(name: "document/diff-block/\(file)", lines: lineCounts[file] ?? 0,
                                      note: "TranscriptScrollView document mode (DocumentPreview), Markdown with one ```diff block") {
                await transcriptWindow(text: try diffMarkdown(file), document: true, expandBlocks: false) })
        }
        scenarios.append(Scenario(name: "chat/diff-block/medium.swift expanded", lines: medium.count,
                                  note: "TranscriptScrollView chat mode, one answer with a ```diff block, expanded") {
            await transcriptWindow(text: try diffMarkdown("medium.swift"), document: false, expandBlocks: true) })
        scenarios.append(Scenario(name: "document/code/10000 lines", lines: 10_000,
                                  note: "DocumentPreview of a 10 000-line Swift file (highlighted, numbered)") {
            await transcriptWindow(text: codeDocument(10_000), document: true, expandBlocks: false) })

        var results: [[String: Any]] = []
        for scenario in scenarios {
            if let only, !only.contains(where: { scenario.name.hasPrefix($0) }) { continue }
            let setupStart = CACurrentMediaTime()
            let (window, found) = try await scenario.make()
            let setup = (CACurrentMediaTime() - setupStart) * 1000
            guard let scroll = found else { window.close(); results.append(["scenario": scenario.name, "error": "no scroll view"]); continue }
            for mode in modes {
                for speed in speeds {
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(400))
                    let driver = ScrollDriver(scrollView: scroll, mode: mode, speed: CGFloat(speed), frames: frames)
                    meter.reset(); meter.recording = true
                    let cpu0 = cpuSeconds(), t0 = CACurrentMediaTime(), launch0 = secondsSinceLaunch()
                    await driver.run()
                    let wall = CACurrentMediaTime() - t0, cpu = cpuSeconds() - cpu0
                    meter.recording = false
                    let period = driver.period * 1000
                    let intervals = driver.intervals
                    let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
                    let row: [String: Any] = [
                        "scenario": scenario.name, "note": scenario.note, "diff_lines": scenario.lines, "mode": mode.rawValue,
                        "speed_pt_s": speed, "frames": intervals.count, "display_period_ms": period,
                        "setup_ms": setup, "document_height": scroll.documentView?.frame.height ?? 0,
                        "travelled_pt": Double(driver.travelled),
                        "interval_p50_ms": percentile(intervals, 0.5), "interval_p95_ms": percentile(intervals, 0.95),
                        "interval_p99_ms": percentile(intervals, 0.99), "interval_max_ms": intervals.max() ?? 0,
                        "hitches_over_16_7ms": intervals.filter { $0 > 16.7 }.count, "hitches_over_33ms": intervals.filter { $0 > 33.4 }.count,
                        "dropped_frames": dropped,
                        "vsync_dropped_frames": driver.vsyncIntervals.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }, "dropped_percent": 100 * Double(dropped) / Double(max(1, dropped + intervals.count)),
                        "step_p50_ms": percentile(driver.stepTimes, 0.5), "step_max_ms": driver.stepTimes.max() ?? 0,
                        "busy_p50_ms": percentile(meter.busy, 0.5), "busy_p95_ms": percentile(meter.busy, 0.95),
                        "busy_max_ms": meter.busy.max() ?? 0, "busy_total_ms": meter.busy.reduce(0, +),
                        "main_busy_percent": 100 * meter.busy.reduce(0, +) / (wall * 1000),
                        "cpu_percent_one_core": 100 * cpu / wall, "seconds": wall,
                        "since_launch_s": [launch0, secondsSinceLaunch()],
                    ]
                    results.append(row)
                    print(String(format: "%-44@ %-5@ %5.0f pt/s  p50 %5.1f  p95 %5.1f  max %6.1f ms  drop %5.1f%%  busy p95 %5.1f ms  main %5.1f%%  cpu %5.1f%%",
                                 scenario.name as NSString, mode.rawValue as NSString, speed, percentile(intervals, 0.5), percentile(intervals, 0.95),
                                 intervals.max() ?? 0, row["dropped_percent"] as! Double, percentile(meter.busy, 0.95),
                                 row["main_busy_percent"] as! Double, row["cpu_percent_one_core"] as! Double))
                    fflush(stdout)
                }
            }
            window.close()
            try await Task.sleep(for: .milliseconds(300))
        }
        let screen = NSScreen.main
        let report: [String: Any] = [
            "date": Date().description, "scenarios": results,
            "screen": ["max_fps": screen?.maximumFramesPerSecond ?? 0, "scale": screen?.backingScaleFactor ?? 0],
            "scope": "Separate native process with its own windows; synthetic git fixtures; programmatic scrolling from CADisplayLink. CPU and busy time include the harness.",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}
