import Foundation
import Darwin

/// A process started by an agent that listens on a TCP port: a dev server, a preview, a debugger.
public struct AgentServer: Identifiable, Sendable, Equatable {
    public var record: ProcessRecord
    /// Listening ports, ascending; the first one is the server's address.
    public var ports: [UInt16]
    /// Working directory of the process; attributes servers of agents that do not label chats (Codex).
    public var directory: String?
    public init(record: ProcessRecord, ports: [UInt16], directory: String? = nil) {
        self.record = record; self.ports = ports; self.directory = directory
    }
    public var id: String { "\(record.pid)-\(record.started.timeIntervalSince1970)" }
    public var port: UInt16 { ports.first ?? 0 }
    public static func url(_ port: UInt16) -> URL { URL(string: "http://localhost:\(port)")! }
    public var url: URL { Self.url(port) }
    /// Short name: the script for an interpreter (`node …/next dev` -> `next`), otherwise the executable.
    public var name: String { AgentServers.name(command: record.command, path: record.path) }
}

public enum AgentServers {
    /// Labelled processes of this app instance with listening ports. The agent CLIs themselves (children of the app)
    /// and Chrome for Testing are not servers the user started.
    public static func select(_ candidates: [(record: ProcessRecord, ports: [UInt16], directory: String?)],
                              instance: String = ProcessLabels.instance,
                              selfPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> [AgentServer] {
        candidates.compactMap { candidate in
            let record = candidate.record
            guard !candidate.ports.isEmpty, record.labelsRead, record.instance == instance, record.parent != selfPID,
                  !ProcessSelection.excluded(record, selfPID: selfPID) else { return nil }
            return AgentServer(record: record, ports: Array(Set(candidate.ports)).sorted(), directory: candidate.directory)
        }
        .sorted { ($0.port, $0.record.pid) < ($1.port, $1.record.pid) }
    }

    /// Servers of one chat: the ones labelled with its agent session, and unlabelled ones (Codex runs every chat in
    /// one process) that work inside the chat's folder.
    public static func servers(_ all: [AgentServer], chat label: String?, folder: String?) -> [AgentServer] {
        all.filter { server in
            if let chat = server.record.chat { return chat == label }
            guard let folder, let directory = server.directory else { return false }
            let root = URL(fileURLWithPath: folder).standardizedFileURL.pathComponents
            let path = URL(fileURLWithPath: directory).standardizedFileURL.pathComponents
            return root.count > 1 && path.count >= root.count && Array(path.prefix(root.count)) == root
        }
    }

    /// The server and its descendants (workers, watchers), stopped together.
    public static func tree(of server: ProcessRecord, in table: [ProcessRecord]) -> [ProcessRecord] {
        var children: [Int32: [ProcessRecord]] = [:]
        for record in table { children[record.parent, default: []].append(record) }
        var result = [server], queue = [server.pid], seen: Set<Int32> = [server.pid]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where seen.insert(child.pid).inserted {
                result.append(child); queue.append(child.pid)
            }
        }
        return result
    }

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "php", "java", "npx", "uv", "uvx"]

    public static func name(command: String, path: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        let executable = URL(fileURLWithPath: words.first ?? path).lastPathComponent
        let base = executable.split(separator: ".").first.map(String.init) ?? executable
        if interpreters.contains(base) || base.hasPrefix("python"),
           let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            let file = URL(fileURLWithPath: script).lastPathComponent
            for suffix in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"] where file.hasSuffix(suffix) {
                return String(file.dropLast(suffix.count))
            }
            return file
        }
        return executable.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : executable
    }

    /// Scans this user's processes: listening sockets first (cheap), labels only for processes that have them.
    public static func current() -> [AgentServer] {
        let uid = getuid()
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 64)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var buffer: [UInt8] = []
        var candidates: [(record: ProcessRecord, ports: [UInt16], directory: String?)] = []
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard let info = ProcessTable.info(pid), info.uid == uid, !info.zombie else { continue }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { continue }
            if buffer.isEmpty { buffer = [UInt8](repeating: 0, count: ProcessTable.argmax) }
            let labels = ProcessTable.arguments(pid, buffer: &buffer)
            var record = ProcessRecord(pid: pid, parent: info.parent, started: info.started,
                                       path: ProcessTable.executablePath(pid) ?? labels?.path ?? "",
                                       command: labels?.command ?? "", labelsRead: labels != nil)
            record.chat = labels?.environment[ProcessLabels.chatKey]
            record.instance = labels?.environment[ProcessLabels.instanceKey]
            record.owner = labels?.environment[ProcessLabels.ownerKey].flatMap { Int32($0) }
            candidates.append((record, ports, directory(pid)))
        }
        return select(candidates)
    }

    /// TCP ports the process listens on (IPv4 and IPv6).
    public static func listeningPorts(_ pid: pid_t) -> [UInt16] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var ports: Set<UInt16> = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, length) == length,
                  socket.psi.soi_kind == SOCKINFO_TCP, socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func directory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let length = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, length) == length else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
