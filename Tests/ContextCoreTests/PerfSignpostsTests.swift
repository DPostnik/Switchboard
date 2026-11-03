import Foundation
import Testing
@testable import ContextCore

/// A clock the test advances by hand, so the stall detector's measurements are exact.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 1_000_000_000
    func now() -> UInt64 { lock.withLock { nanoseconds } }
    func advance(milliseconds: UInt64) { lock.withLock { nanoseconds += milliseconds * 1_000_000 } }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

private func detector(_ clock: ManualClock, _ reports: Reports) -> (StallDetector, monitored: DispatchQueue, timer: DispatchQueue) {
    let monitored = DispatchQueue(label: "perf-test.monitored"), timer = DispatchQueue(label: "perf-test.timer")
    let detector = StallDetector(monitored: monitored, timerQueue: timer, clock: { clock.now() }) { reports.append($0) }
    return (detector, monitored, timer)
}

@Test func stallDetectorReportsASyntheticThreeHundredMillisecondBlock() {
    let clock = ManualClock(), reports = Reports()
    let (detector, monitored, timer) = detector(clock, reports)
    let release = DispatchSemaphore(value: 0)
    // The monitored queue is busy for 300 ms (by the manual clock) when the heartbeat pings it.
    monitored.async { release.wait(); clock.advance(milliseconds: 300) }
    detector.tick()
    detector.tick() // still in flight: no second ping, so one block is reported once
    release.signal()
    monitored.sync {}
    timer.sync {}
    #expect(reports.all == [0.3])
}

@Test func stallDetectorIgnoresPromptPingsAndStopsCleanly() {
    let clock = ManualClock(), reports = Reports()
    let (detector, monitored, timer) = detector(clock, reports)
    monitored.async { clock.advance(milliseconds: 200) }
    detector.tick()
    monitored.sync {}
    detector.tick() // the earlier ping landed, so this one is sent and answers at once
    monitored.sync {}
    timer.sync {}
    #expect(reports.all.isEmpty)
    detector.start()
    #expect(detector.isRunning)
    detector.stop()
    #expect(!detector.isRunning)
}

@Test func hitchLatenessCountsDroppedFramesOnly() {
    let frame = 1.0 / 60
    #expect(HitchDetector.lateness(gap: frame, frame: frame) == nil)
    #expect(HitchDetector.lateness(gap: frame * 1.4, frame: frame) == nil)
    #expect(abs((HitchDetector.lateness(gap: frame * 3, frame: frame) ?? 0) - frame * 2) < 1e-9)
    #expect(HitchDetector.lateness(gap: 0.5, frame: 0) == nil)
}

@Test(.enabled(if: !Perf.enabled)) @MainActor func disabledPerfIsANoOp() async {
    var runs = 0
    #expect(Perf.interval("test.interval", id: "x") { runs += 1; return 42 } == 42)
    #expect(await Perf.interval("test.async") { () async -> Int in runs += 1; return 7 } == 7)
    #expect(runs == 2)
    let span = Perf.span("test.span", id: "y")
    #expect(!span.isActive)
    span.end("done")
    Perf.begin("test.open", id: "chat")
    #expect(Perf.openIntervalCount == 0)
    #expect(!Perf.end("test.open", id: "chat"))
    Perf.event("test.event", "z")
    Perf.start()
    #expect(!Perf.heartbeatRunning)
}
