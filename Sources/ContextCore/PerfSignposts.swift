import AppKit
import Foundation
import QuartzCore
import os

/// Developer performance instrumentation, off unless `defaults write local.daniil.switchboard PerfSignposts -bool YES`
/// was set before launch. Intervals and events go to the Points of Interest signpost category (Instruments, `log show
/// --signpost`); stalls, long hitches and scroll summaries go to the `perf` log category. Details are counts, sizes and
/// IDs only, never message text. With the default off every call returns after one Bool check.
public enum Perf {
    public static let enabled = UserDefaults.standard.bool(forKey: "PerfSignposts")
    public static let subsystem = "local.daniil.switchboard"
    public static let signposter = enabled ? OSSignposter(subsystem: subsystem, category: .pointsOfInterest) : .disabled
    public static let log = Logger(subsystem: subsystem, category: "perf")

    /// Measures `body` as one interval named `name`; `id` is metadata (a chat ID, a count).
    @discardableResult
    public static func interval<T>(_ name: StaticString, id: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let active = span(name, id: id())
        defer { active.end() }
        return try body()
    }

    @discardableResult
    public static func interval<T>(_ name: StaticString, id: @autoclosure () -> String = "", isolation: isolated (any Actor)? = #isolation,
                                   _ body: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await body() }
        let active = span(name, id: id())
        defer { active.end() }
        return try await body()
    }

    /// An interval begun here and ended by `Span.end`, for bodies a closure would reindent:
    /// `let span = Perf.span("x", id: id); defer { span.end() }`.
    public static func span(_ name: StaticString, id: @autoclosure () -> String = "") -> Span {
        guard enabled else { return Span(name: name, state: nil) }
        let text = id()
        return Span(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(text, privacy: .public)"))
    }

    public struct Span: @unchecked Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState?
        public var isActive: Bool { state != nil }
        public func end(_ detail: @autoclosure () -> String = "") {
            guard let state else { return }
            let text = detail()
            Perf.signposter.endInterval(name, state, "\(text, privacy: .public)")
        }
    }

    /// A point event (`hitch`, `stall`).
    public static func event(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        let text = detail()
        signposter.emitEvent(name, "\(text, privacy: .public)")
    }

    // MARK: Intervals across functions

    nonisolated(unsafe) private static var openIntervals: [String: (id: String, span: Span)] = [:]
    private static let openLock = NSLock()

    /// Begins `name` for `id` (`chat.open` in `DeskModel.openChat`); a second begin of the same name supersedes the first.
    public static func begin(_ name: StaticString, id: String) {
        guard enabled else { return }
        let span = span(name, id: id)
        let previous = openLock.withLock { openIntervals.updateValue((id, span), forKey: "\(name)") }
        previous?.span.end("superseded")
    }

    /// Ends `name` if it was begun for `id`; returns whether it was (`chat.open` ends at the transcript's first layout).
    @discardableResult
    public static func end(_ name: StaticString, id: String?, _ detail: @autoclosure () -> String = "") -> Bool {
        guard enabled, let id else { return false }
        let key = "\(name)"
        let entry: (id: String, span: Span)? = openLock.withLock {
            guard openIntervals[key]?.id == id else { return nil }
            return openIntervals.removeValue(forKey: key)
        }
        guard let entry else { return false }
        entry.span.end(detail())
        return true
    }

    static var openIntervalCount: Int { openLock.withLock { openIntervals.count } }

    // MARK: Watchdogs

    private static let heartbeat = StallDetector(monitored: .main, timerQueue: DispatchQueue(label: "local.daniil.switchboard.perf", qos: .utility)) { seconds in
        let ms = Int((seconds * 1000).rounded())
        Perf.event("stall", "\(ms) ms")
        Perf.log.notice("stall: main thread blocked \(ms, privacy: .public) ms")
    }

    /// Starts the main-thread heartbeat and the live-scroll hitch detector. Call once at launch; a no-op when disabled.
    @MainActor public static func start() {
        guard enabled, !heartbeat.isRunning else { return }
        heartbeat.start()
        HitchDetector.shared.observeLiveScroll()
        log.notice("perf signposts on: heartbeat 250 ms, hitch detector during live scroll and after chat.open")
    }

    static var heartbeatRunning: Bool { heartbeat.isRunning }

    /// Runs the hitch detector on `view`'s window for `seconds` (after `chat.open`).
    @MainActor public static func watchHitches(in view: NSView, for seconds: CFTimeInterval, label: String = "chat.open") {
        guard enabled else { return }
        HitchDetector.shared.watch(view, for: seconds, label: label)
    }
}

/// Pings `monitored` every `interval` from `timerQueue` and reports how long a ping waited when that is at least
/// `threshold`. One ping is in flight at a time, so a long block is reported once, with its whole wait.
/// The duration is a lower bound of the block: a block that began before the ping was posted ran longer.
public final class StallDetector: @unchecked Sendable {
    public typealias Clock = @Sendable () -> UInt64

    private let monitored: DispatchQueue
    private let timerQueue: DispatchQueue
    private let interval: DispatchTimeInterval
    private let threshold: UInt64
    private let clock: Clock
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var pinging = false
    private var timer: DispatchSourceTimer?

    public init(monitored: DispatchQueue, timerQueue: DispatchQueue, interval: DispatchTimeInterval = .milliseconds(250),
                thresholdNanoseconds: UInt64 = 250_000_000, clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
                report: @escaping @Sendable (Double) -> Void) {
        self.monitored = monitored; self.timerQueue = timerQueue; self.interval = interval
        self.threshold = thresholdNanoseconds; self.clock = clock; self.report = report
    }

    public var isRunning: Bool { lock.withLock { timer != nil } }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        lock.withLock { timer?.cancel(); timer = nil }
    }

    /// One heartbeat; the timer calls it, tests call it directly.
    public func tick() {
        let busy = lock.withLock { () -> Bool in
            if pinging { return true }
            pinging = true
            return false
        }
        guard !busy else { return }
        let sent = clock()
        monitored.async { [self] in
            let waited = clock() &- sent
            lock.withLock { pinging = false }
            guard waited >= threshold else { return }
            let seconds = Double(waited) / 1_000_000_000
            timerQueue.async { [report] in report(seconds) }
        }
    }
}

/// Watches display-link frames of a window while a scroll view is live-scrolling and for a while after `chat.open`.
/// A frame that arrives at least half an interval later than expected (one dropped frame or more) emits a `hitch`
/// event; gaps over 100 ms are also logged. Each watch ends with one summary line in the `perf` category.
@MainActor final class HitchDetector: NSObject {
    static let shared = HitchDetector()

    private var link: CADisplayLink?
    private weak var view: NSView?
    private var scrolling = false
    private var watchUntil: CFTimeInterval = 0
    private var label = ""
    private var last: CFTimeInterval?
    private var frames = 0, hitches = 0, worst: CFTimeInterval = 0
    private var observing = false

    func observeLiveScroll() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted(_:)), name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded(_:)), name: NSScrollView.didEndLiveScrollNotification, object: nil)
    }

    @objc private func liveScrollStarted(_ note: Notification) {
        guard let view = note.object as? NSView else { return }
        scrolling = true
        attach(view, label: "scroll")
    }

    @objc private func liveScrollEnded(_ note: Notification) {
        scrolling = false
        if CACurrentMediaTime() >= watchUntil { detach() }
    }

    func watch(_ view: NSView, for seconds: CFTimeInterval, label: String) {
        watchUntil = max(watchUntil, CACurrentMediaTime() + seconds)
        attach(view, label: label)
    }

    private func attach(_ view: NSView, label: String) {
        guard let content = view.window?.contentView else { return }
        if link != nil, self.view === content { return }
        detach()
        self.view = content; self.label = label
        let link = content.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let frame = link.targetTimestamp - link.timestamp
        if let last, let late = Self.lateness(gap: link.timestamp - last, frame: frame) {
            hitches += 1
            worst = max(worst, late)
            let ms = Int((late * 1000).rounded())
            Perf.event("hitch", "\(label) \(ms) ms late")
            if late > 0.1 { Perf.log.notice("hitch: \(self.label, privacy: .public) frame \(ms, privacy: .public) ms late") }
        }
        last = link.timestamp
        frames += 1
        if !scrolling && CACurrentMediaTime() >= watchUntil { detach() }
    }

    private func detach() {
        guard let link else { return }
        link.invalidate()
        self.link = nil; view = nil; last = nil
        if frames > 0 {
            let worstMs = Int((worst * 1000).rounded())
            Perf.log.notice("hitches: \(self.label, privacy: .public) \(self.frames, privacy: .public) frames, \(self.hitches, privacy: .public) hitches, worst \(worstMs, privacy: .public) ms late")
        }
        frames = 0; hitches = 0; worst = 0
    }

    /// How late a frame is past its expected time, when that is at least half a frame interval; nil for an on-time frame.
    nonisolated static func lateness(gap: CFTimeInterval, frame: CFTimeInterval) -> CFTimeInterval? {
        guard frame > 0, gap > frame * 1.5 else { return nil }
        return gap - frame
    }
}
