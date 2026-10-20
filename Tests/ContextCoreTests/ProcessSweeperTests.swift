import Foundation
import Darwin
import Testing
@testable import ContextCore
@testable import ClaudeAdapter

private let now = Date()
private func record(_ pid: Int32, parent: Int32 = 1, chat: String? = nil, instance: String? = "me", owner: Int32? = 100,
                    path: String = "/usr/bin/python3", labelsRead: Bool = true, started: Date = now) -> ProcessRecord {
    ProcessRecord(pid: pid, parent: parent, started: started, path: path, command: path, chat: chat, instance: instance,
                  owner: owner, labelsRead: labelsRead)
}

@Test func selectionTargetsOnlyLabelledLeftoversOfInactiveChats() {
    let table = [
        record(10, chat: "a"), record(11, chat: "b"), record(12), record(13, chat: nil, instance: nil),
        record(14, chat: "a", path: "/x/chrome-for-testing/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
        record(15, chat: "a", path: "/Applications/Switchboard.app/Contents/MacOS/Switchboard"),
        record(16, chat: "a", instance: "old", owner: 999), record(17, chat: "z", instance: "old", owner: 998),
        record(18, chat: "a", instance: "old", owner: 100), record(100, chat: nil)
    ]
    let alive: Set<Int32> = [998]
    let selected = ProcessSelection.targets(in: table, scope: .inactive(active: ["b"]), instance: "me", selfPID: 100) { alive.contains($0) }
    // Chat a is inactive (10); b is active; 12 has no chat; 13 has no label; 14 is Chrome; 15 is another Switchboard;
    // 16's owner is dead; 17's owner lives; 18 belongs to this very process under another instance (a test sweeper).
    #expect(selected.map(\.pid) == [10, 16])
}

@Test func selectionForEndedChatKeepsProcessesStartedAfterTheEnd() {
    let later = now.addingTimeInterval(1)
    let table = [record(10, chat: "a", started: now.addingTimeInterval(-5)), record(11, chat: "a", started: later.addingTimeInterval(1)),
                 record(12, chat: "b", started: now.addingTimeInterval(-5)), record(13, chat: "a", instance: "old", started: now.addingTimeInterval(-5))]
    let selected = ProcessSelection.targets(in: table, scope: .chat("a", before: later), instance: "me", selfPID: 100)
    #expect(selected.map(\.pid) == [10])
    #expect(ProcessSelection.targets(in: table, scope: .instance, instance: "me", selfPID: 100).map(\.pid) == [10, 11, 12])
}

@Test func selectionFollowsParentChainWhenEnvironmentIsUnreadable() {
    let table = [record(10, chat: "a"), record(20, parent: 10, labelsRead: false), record(30, parent: 20, labelsRead: false),
                 record(40, parent: 1, labelsRead: false), record(50, parent: 100, labelsRead: false), record(100)]
    let selected = ProcessSelection.targets(in: table, scope: .inactive(active: []), instance: "me", selfPID: 100)
    #expect(selected.map(\.pid) == [10, 20, 30])
}

@Test func procargsParserReadsOnlySwitchboardLabels() throws {
    var bytes: [UInt8] = [3, 0, 0, 0]
    bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0]
    for argument in ["python3", "-c", "pass"] { bytes += Array(argument.utf8) + [0] }
    for entry in ["HOME=/Users/x", "SWITCHBOARD_CHAT_ID=chat-1", "SWITCHBOARD_INSTANCE=inst", "SWITCHBOARD_OWNER_PID=42", "PATH=/bin"] {
        bytes += Array(entry.utf8) + [0]
    }
    bytes += [0, 0]
    let parsed = try #require(ProcessTable.parse(bytes[...]))
    #expect(parsed.path == "/usr/bin/python3")
    #expect(parsed.command == "python3 -c pass")
    #expect(parsed.environment == ["SWITCHBOARD_CHAT_ID": "chat-1", "SWITCHBOARD_INSTANCE": "inst", "SWITCHBOARD_OWNER_PID": "42"])
}

@Test func liveTableSeesThisProcessAndItsLabelledChild() throws {
    let instance = "test-" + UUID().uuidString.lowercased()
    let child = try detachedSleeper(chat: "chat-live", instance: instance, owner: 1)
    defer { kill(child.pid, SIGKILL) }
    let table = ProcessTable.current()
    let me = try #require(table.first { $0.pid == ProcessInfo.processInfo.processIdentifier })
    #expect(me.labelsRead)
    #expect(me.started <= Date())
    let found = try #require(table.first { $0.pid == child.pid })
    #expect(found.chat == "chat-live" && found.instance == instance && found.owner == 1)
    #expect(found.parent != ProcessInfo.processInfo.processIdentifier) // the shell exited; Python was reparented
    #expect(found.command.contains("os.setsid()") && !found.command.contains("\n"))
    #expect(ProcessTable.isAlive(found))
}

/// The case from the battery audit: a `setsid` + `nohup` grandchild outlives its CLI. Ending the chat must stop it within 3 s.
@Test func endingAChatStopsItsDetachedDescendantWithinThreeSeconds() async throws {
    let sweeper = ProcessSweeper(instance: "test-" + UUID().uuidString.lowercased())
    let messages = LogSink()
    sweeper.start { message in messages.append(message) }
    let chat = "chat-" + UUID().uuidString.lowercased()
    sweeper.begin(chat: chat)
    #expect(sweeper.active == [chat])
    let orphan = try detachedSleeper(chat: chat, instance: sweeper.instance, owner: ProcessInfo.processInfo.processIdentifier)
    defer { kill(orphan.pid, SIGKILL) }
    #expect(!sweeper.orphans().contains { $0.pid == orphan.pid }) // still active: the counter never shows a running chat's processes
    let started = ContinuousClock.now
    let outcomes = try await #require(sweeper.end(chat: chat)).value
    #expect(sweeper.active.isEmpty)
    #expect(outcomes.map(\.record.pid) == [orphan.pid])
    #expect(outcomes.first?.result == "terminated")
    #expect(started.duration(to: .now) < .seconds(3))
    #expect(!ProcessSelection.processExists(orphan.pid) || ProcessTable.info(orphan.pid)?.zombie == true)
    #expect(messages.all.contains { $0.contains("pid \(orphan.pid)") && $0.contains("chat \(chat)") && $0.contains("cpu ") })
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Test func processIgnoringSIGTERMIsKilledAfterTheGracePeriod() async throws {
    let sweeper = ProcessSweeper(instance: "test-" + UUID().uuidString.lowercased())
    sweeper.grace = .milliseconds(500)
    sweeper.start { _ in }
    let chat = "chat-" + UUID().uuidString.lowercased()
    sweeper.begin(chat: chat)
    let stubborn = try detachedSleeper(chat: chat, instance: sweeper.instance, owner: ProcessInfo.processInfo.processIdentifier, ignoreTerm: true)
    defer { kill(stubborn.pid, SIGKILL) }
    let outcomes = try await #require(sweeper.end(chat: chat)).value
    #expect(outcomes.map(\.result) == ["killed"])
    #expect(!ProcessSelection.processExists(stubborn.pid) || ProcessTable.info(stubborn.pid)?.zombie == true)
}

@Test func startupSweepStopsDeadInstancesButKeepsLiveOnesAndUnlabelledProcesses() async throws {
    let sweeper = ProcessSweeper(instance: "test-" + UUID().uuidString.lowercased())
    sweeper.grace = .milliseconds(300)
    sweeper.start { _ in }
    let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
    let dead = try detachedSleeper(chat: "chat-old", instance: "dead-" + UUID().uuidString.lowercased(), owner: gone.processIdentifier)
    let live = try detachedSleeper(chat: "chat-other", instance: "live-" + UUID().uuidString.lowercased(), owner: ProcessInfo.processInfo.processIdentifier)
    let plain = try detachedSleeper(chat: nil, instance: nil, owner: nil)
    defer { for pid in [dead.pid, live.pid, plain.pid] { kill(pid, SIGKILL) } }
    // Other tests run in parallel; only this test's processes are asserted.
    let mine: Set<Int32> = [dead.pid, live.pid, plain.pid]
    #expect(sweeper.orphans().map(\.pid).filter(mine.contains) == [dead.pid])
    let outcomes = try await #require(sweeper.sweepForeignInstances()).value
    #expect(outcomes.map(\.record.pid).filter(mine.contains) == [dead.pid])
    #expect(ProcessSelection.processExists(live.pid) && ProcessSelection.processExists(plain.pid))
    // A disabled sweeper (tests, before boot) tracks activity but never signals anything.
    let idle = ProcessSweeper(instance: sweeper.instance)
    idle.begin(chat: "x"); #expect(idle.end(chat: "x") == nil); #expect(idle.sweepInactive() == nil)
    #expect(await idle.shutdown().isEmpty)
}

@Test func instanceSweepAtQuitStopsEveryProcessOfTheInstance() async throws {
    let sweeper = ProcessSweeper(instance: "test-" + UUID().uuidString.lowercased())
    sweeper.grace = .milliseconds(300)
    sweeper.start { _ in }
    sweeper.begin(chat: "chat-running")
    let running = try detachedSleeper(chat: "chat-running", instance: sweeper.instance, owner: ProcessInfo.processInfo.processIdentifier)
    let server = try detachedSleeper(chat: nil, instance: sweeper.instance, owner: ProcessInfo.processInfo.processIdentifier)
    defer { for pid in [running.pid, server.pid] { kill(pid, SIGKILL) } }
    // Instance-only labels (Codex server, plugins) are never counted as orphans.
    #expect(!sweeper.orphans().contains { [running.pid, server.pid].contains($0.pid) })
    let outcomes = await sweeper.shutdown()
    #expect(Set(outcomes.map(\.record.pid)).intersection([running.pid, server.pid]) == [running.pid, server.pid])
    #expect(outcomes.allSatisfy { $0.record.instance == sweeper.instance })
}

/// `sh -c 'nohup python3 … &'`: the shell exits at once, Python calls `setsid` and is reparented to launchd,
/// exactly like a Claude Code background Bash task. Returns the Python PID from its pid file.
private func detachedSleeper(chat: String?, instance: String?, owner: Int32?, ignoreTerm: Bool = false) throws -> (pid: Int32, file: URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sweeper-" + UUID().uuidString + ".pid")
    let script = "import os, signal, time\n" + (ignoreTerm ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" : "")
        + "os.setsid()\nopen(\(quoted(file.path)), 'w').write(str(os.getpid()))\ntime.sleep(600)\n"
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "nohup \(fixturePython) -c \(quoted(script)) >/dev/null 2>&1 &"]
    var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    if let instance { environment[ProcessLabels.instanceKey] = instance }
    if let chat { environment[ProcessLabels.chatKey] = chat }
    if let owner { environment[ProcessLabels.ownerKey] = String(owner) }
    shell.environment = environment
    shell.standardInput = FileHandle.nullDevice; shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
    try shell.run(); shell.waitUntilExit()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try? FileManager.default.removeItem(at: file)
            return (pid, file)
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    throw ClientFailure("detached sleeper did not start")
}
private func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Launch sites: the interactive CLI carries the chat label and is registered while its stream is open.
@Test func claudeWireRegistersTheChatLabelWhileItsProcessRuns() async throws {
    let chat = "chat-" + UUID().uuidString.lowercased()
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    var environment = ClaudeProfile.environment(home: home)
    #expect(environment[ProcessLabels.instanceKey] == ProcessLabels.instance)
    #expect(environment[ProcessLabels.ownerKey] == String(ProcessInfo.processInfo.processIdentifier))
    environment.merge(ProcessLabels.environment(chat: chat)) { _, new in new }
    let wire = ClaudeWire()
    try await wire.start(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: environment, cwd: home)
    #expect(ProcessSweeper.shared.active.contains(chat))
    await wire.close()
    #expect(!ProcessSweeper.shared.active.contains(chat))
    // The shared sweeper is off outside the app, so closing a wire never signals anything in tests.
    #expect(!ProcessSweeper.shared.isEnabled)
}

/// The print runner labels only the execution run (not the version probe) with `scheduled-<run id>`.
@Test func claudeJobRunnerLabelsTheRunAndReleasesItAfterwards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("claude.py")
    try Data("""
    #!\(fixturePython)
    import sys, json, os, pathlib
    labels = {k: v for k, v in os.environ.items() if k.startswith('SWITCHBOARD_')}
    if '--version' in sys.argv:
        pathlib.Path('version-labels').write_text(json.dumps(labels)); print('\(ClaudeJobRunner.version) (Claude Code)'); sys.exit(0)
    pathlib.Path('run-labels').write_text(json.dumps(labels))
    print(json.dumps({'type': 'result', 'is_error': False, 'result': 'done'}))

    """.utf8).write(to: file)
    try installFixtureExecutable(at: file)
    let runID = UUID()
    let (status, _) = try await ClaudeJobRunner(executable: file).run(prompt: "hello", model: "", cwd: root, executable: file, runID: runID)
    #expect(status == .completed)
    let decode = { (name: String) throws -> [String: String] in
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    let probe = try decode("version-labels"), run = try decode("run-labels")
    #expect(probe[ProcessLabels.instanceKey] == ProcessLabels.instance && probe[ProcessLabels.chatKey] == nil)
    #expect(run[ProcessLabels.chatKey] == "scheduled-" + runID.uuidString.lowercased())
    #expect(run[ProcessLabels.instanceKey] == ProcessLabels.instance)
    #expect(!ProcessSweeper.shared.active.contains("scheduled-" + runID.uuidString.lowercased()))
}
