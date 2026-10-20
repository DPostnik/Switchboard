import Foundation
import Darwin

/// Environment labels every provider process starts with. Children inherit them, and they survive a `setsid`
/// and the reparent to launchd, so the sweeper can find a chat's leftovers after the CLI is gone.
public enum ProcessLabels {
    public static let instanceKey = "SWITCHBOARD_INSTANCE"
    public static let chatKey = "SWITCHBOARD_CHAT_ID"
    public static let ownerKey = "SWITCHBOARD_OWNER_PID"
    /// One value per app (or test) process.
    public static let instance = UUID().uuidString.lowercased()
    /// Labels for a launch; `chat` is the chat's native session ID or `scheduled-<run id>` for a print run.
    public static func environment(chat: String? = nil, instance: String = ProcessLabels.instance) -> [String: String] {
        var result = [instanceKey: instance, ownerKey: String(ProcessInfo.processInfo.processIdentifier)]
        if let chat, !chat.isEmpty { result[chatKey] = chat }
        return result
    }
}

/// One process of the current user as seen by the sweeper.
public struct ProcessRecord: Sendable, Equatable {
    public var pid: Int32
    public var parent: Int32
    /// Process start time; with the PID it identifies one process even after PID reuse.
    public var started: Date
    public var path: String
    /// argv joined by spaces, bounded for logging.
    public var command: String
    public var chat: String?
    public var instance: String?
    public var owner: Int32?
    /// nil when the environment could not be read (the PPID fallback applies).
    public var labelsRead: Bool
    public var cpuSeconds: Double
    public init(pid: Int32, parent: Int32, started: Date, path: String, command: String, chat: String? = nil, instance: String? = nil,
                owner: Int32? = nil, labelsRead: Bool = true, cpuSeconds: Double = 0) {
        self.pid = pid; self.parent = parent; self.started = started; self.path = path; self.command = command
        self.chat = chat; self.instance = instance; self.owner = owner; self.labelsRead = labelsRead; self.cpuSeconds = cpuSeconds
    }
}

/// Which labelled processes a pass selects.
public enum SweepScope: Sendable, Equatable {
    /// Leftovers of one chat whose CLI ended at `before`; a CLI restarted for the same chat after that moment is kept.
    case chat(String, before: Date)
    /// Processes of this instance whose chat is no longer active, plus processes of a dead instance (any chat).
    case inactive(active: Set<String>)
    /// Every process of this instance (app exit).
    case instance
}

public enum ProcessSelection {
    /// Pure selection over a snapshot. Never selects unlabelled processes, the caller itself, another Switchboard,
    /// or a Chrome for Testing (the browser gate owns that lifecycle). With `.inactive`, a foreign instance is selected
    /// only when its owner process is gone, so a second running Switchboard or a test run keeps its processes.
    public static func targets(in table: [ProcessRecord], scope: SweepScope, instance: String = ProcessLabels.instance,
                               selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                               ownerAlive: (Int32) -> Bool = ProcessSelection.processExists) -> [ProcessRecord] {
        var selected: [Int32: ProcessRecord] = [:]
        for record in table where record.labelsRead && !excluded(record, selfPID: selfPID) {
            switch scope {
            case .chat(let chat, let before):
                guard record.chat == chat, record.instance == instance, record.started < before else { continue }
            case .inactive(let active):
                guard let recordInstance = record.instance else { continue }
                if recordInstance == instance {
                    guard let chat = record.chat, !active.contains(chat) else { continue }
                } else {
                    guard record.owner.map({ $0 != selfPID && !ownerAlive($0) }) ?? true else { continue }
                }
            case .instance:
                guard record.instance == instance else { continue }
            }
            selected[record.pid] = record
        }
        // Unreadable environment: a descendant of a selected process still attached to it goes with it.
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for record in table where !record.labelsRead && !excluded(record, selfPID: selfPID) {
            var cursor = record.parent, depth = 0
            while cursor > 1, depth < 64, let parent = byPID[cursor] {
                if selected[cursor] != nil { selected[record.pid] = record; break }
                cursor = parent.parent; depth += 1
            }
        }
        return selected.values.sorted { $0.pid < $1.pid }
    }
    static func excluded(_ record: ProcessRecord, selfPID: Int32) -> Bool {
        record.pid == selfPID || record.pid <= 1
            || record.path.contains("/Google Chrome for Testing.app/")
            || record.path.hasSuffix("/Contents/MacOS/Switchboard")
    }
    public static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// Reads the live process table of the current user (`proc_listpids`, `KERN_PROC_PID`, `KERN_PROCARGS2`).
public enum ProcessTable {
    public static func current(argmax: Int = ProcessTable.argmax) -> [ProcessRecord] {
        let uid = getuid()
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 64)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        pids = Array(pids.prefix(Int(count) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
        var buffer = [UInt8](repeating: 0, count: argmax)
        var records: [ProcessRecord] = []
        records.reserveCapacity(pids.count)
        for pid in pids {
            guard let info = info(pid), info.uid == uid, !info.zombie else { continue }
            let labels = arguments(pid, buffer: &buffer)
            var record = ProcessRecord(pid: pid, parent: info.parent, started: info.started, path: executablePath(pid) ?? "",
                                       command: labels?.command ?? "", labelsRead: labels != nil, cpuSeconds: cpuSeconds(pid))
            if let labels {
                record.chat = labels.environment[ProcessLabels.chatKey]
                record.instance = labels.environment[ProcessLabels.instanceKey]
                record.owner = labels.environment[ProcessLabels.ownerKey].flatMap { Int32($0) }
                if record.path.isEmpty { record.path = labels.path }
            }
            records.append(record)
        }
        return records
    }
    public static let argmax: Int = {
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()
    struct Info { let parent: Int32; let uid: uid_t; let started: Date; let zombie: Bool }
    static func info(_ pid: pid_t) -> Info? {
        var proc = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size, proc.kp_proc.p_pid == pid else { return nil }
        let start = proc.kp_proc.p_starttime
        let started = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        // p_stat 5 is SZOMB (sys/proc.h).
        return Info(parent: proc.kp_eproc.e_ppid, uid: proc.kp_eproc.e_ucred.cr_uid, started: started, zombie: proc.kp_proc.p_stat == 5)
    }
    /// The identity (PID + start time) is still the same live process.
    public static func isAlive(_ record: ProcessRecord) -> Bool {
        guard let info = info(record.pid), !info.zombie else { return false }
        return abs(info.started.timeIntervalSince(record.started)) < 0.001
    }
    struct Arguments { let path: String; let command: String; let environment: [String: String] }
    /// KERN_PROCARGS2 layout: argc, executable path, padding, argv strings, then `KEY=VALUE` strings.
    static func arguments(_ pid: pid_t, buffer: inout [UInt8]) -> Arguments? {
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parse(buffer[0..<size])
    }
    static func parse(_ bytes: ArraySlice<UInt8>) -> Arguments? {
        let data = Array(bytes)
        guard data.count > 4 else { return nil }
        let argc = Int(UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24)
        var offset = 4
        func string(from start: Int) -> (String, Int)? {
            guard start < data.count, let end = data[start...].firstIndex(of: 0) else { return nil }
            return (String(decoding: data[start..<end], as: UTF8.self), end + 1)
        }
        guard let (path, afterPath) = string(from: offset) else { return nil }
        offset = afterPath
        while offset < data.count, data[offset] == 0 { offset += 1 }
        var argv: [String] = []
        for _ in 0..<min(argc, 4096) {
            guard let (value, next) = string(from: offset) else { break }
            argv.append(value); offset = next
        }
        var environment: [String: String] = [:]
        while let (entry, next) = string(from: offset), !entry.isEmpty {
            offset = next
            guard entry.hasPrefix("SWITCHBOARD_"), let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        let command = String(argv.joined(separator: " ").prefix(240)).replacingOccurrences(of: "\n", with: " ")
        return Arguments(path: path, command: command, environment: environment)
    }
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
    }()
    static func cpuSeconds(_ pid: pid_t) -> Double {
        var usage = rusage_info_v2()
        // The C API takes `rusage_info_t *` (a `void **`) that callers point at the struct itself.
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return 0 }
        let ticks = Double(usage.ri_user_time) + Double(usage.ri_system_time)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

/// Stops processes left behind by chats: SIGTERM, then SIGKILL after `grace` for the ones still alive.
/// Launch sites register a chat while its CLI runs (`begin`/`end`); `end` sweeps that chat's leftovers at once.
/// Sweeps run only after `start`, so tests that launch fixture CLIs never kill each other's processes.
public final class ProcessSweeper: @unchecked Sendable {
    public static let shared = ProcessSweeper()
    public struct Outcome: Sendable, Equatable {
        public var record: ProcessRecord
        /// "terminated" (left after SIGTERM), "killed" (needed SIGKILL) or "survived".
        public var result: String
    }
    public let instance: String
    public var grace: Duration = .seconds(2)
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var enabled = false
    private var log: @Sendable (String) -> Void = { _ in }
    private var table: @Sendable () -> [ProcessRecord]
    /// A sweep in flight; `shutdown` waits for it so a quit never leaves a half-finished pass.
    private var pending: [UUID: Task<[Outcome], Never>] = [:]

    public init(instance: String = ProcessLabels.instance, table: @escaping @Sendable () -> [ProcessRecord] = { ProcessTable.current() }) {
        self.instance = instance; self.table = table
    }
    /// Turns sweeping on (the app does this at boot).
    public func start(log: @escaping @Sendable (String) -> Void) {
        lock.withLock { enabled = true; self.log = log }
    }
    public var isEnabled: Bool { lock.withLock { enabled } }
    /// Chats whose CLI is running now.
    public var active: Set<String> { lock.withLock { Set(counts.filter { $0.value > 0 }.keys) } }
    public func begin(chat: String) {
        lock.withLock { counts[chat, default: 0] += 1 }
    }
    /// The chat's CLI ended: its remaining processes started before now are stopped in the background.
    @discardableResult public func end(chat: String) -> Task<[Outcome], Never>? {
        let now = Date()
        let run: Bool = lock.withLock {
            let left = max(0, (counts[chat] ?? 0) - 1)
            if left == 0 { counts.removeValue(forKey: chat) } else { counts[chat] = left }
            return enabled
        }
        guard run else { return nil }
        return sweep(.chat(chat, before: now), reason: "chat ended")
    }
    /// Processes of a Switchboard that is no longer running (previous launch, crash, force quit).
    @discardableResult public func sweepForeignInstances() -> Task<[Outcome], Never>? {
        sweep(.inactive(active: active), reason: "startup", foreignOnly: true)
    }
    /// Periodic pass and the Settings button: leftovers of inactive chats and of dead instances.
    @discardableResult public func sweepInactive() -> Task<[Outcome], Never>? {
        sweep(.inactive(active: active), reason: "inactive")
    }
    /// Leftovers alive right now, for the Settings counter. Read-only.
    public func orphans() -> [ProcessRecord] {
        ProcessSelection.targets(in: table(), scope: .inactive(active: active), instance: instance)
    }
    /// App exit: every process of this instance, waited for.
    public func shutdown() async -> [Outcome] {
        let waiting = lock.withLock { Array(pending.values) }
        for task in waiting { _ = await task.value }
        guard isEnabled, let task = sweep(.instance, reason: "quit") else { return [] }
        return await task.value
    }
    private func sweep(_ scope: SweepScope, reason: String, foreignOnly: Bool = false) -> Task<[Outcome], Never>? {
        guard isEnabled else { return nil }
        let id = UUID()
        let task = Task.detached(priority: .utility) { [self] () -> [Outcome] in
            defer { _ = lock.withLock { pending.removeValue(forKey: id) } }
            var targets = ProcessSelection.targets(in: table(), scope: scope, instance: instance)
            if foreignOnly { targets = targets.filter { $0.instance != instance } }
            return await terminate(targets, reason: reason)
        }
        lock.withLock { pending[id] = task }
        return task
    }
    /// SIGTERM to the snapshot, then SIGKILL to the same processes (PID and start time) still alive after `grace`.
    public func terminate(_ targets: [ProcessRecord], reason: String) async -> [Outcome] {
        guard !targets.isEmpty else { return [] }
        let log = lock.withLock { self.log }
        for record in targets where ProcessTable.isAlive(record) { kill(record.pid, SIGTERM) }
        try? await Task.sleep(for: grace)
        var outcomes: [Outcome] = []
        for record in targets {
            var result = "terminated"
            if ProcessTable.isAlive(record) {
                kill(record.pid, SIGKILL)
                try? await Task.sleep(for: .milliseconds(100))
                result = ProcessTable.isAlive(record) ? "survived" : "killed"
            }
            outcomes.append(Outcome(record: record, result: result))
            log("Orphan process \(result) (\(reason)): pid \(record.pid), chat \(record.chat ?? "-"), instance \(record.instance ?? "-"), "
                + "cpu \(String(format: "%.1f", record.cpuSeconds)) s, command \(record.command.isEmpty ? record.path : record.command)")
        }
        return outcomes
    }
}
