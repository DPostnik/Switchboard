#!/usr/bin/env python3
"""Measure the bytes a command and all its descendants write to disk (build/test scenarios).

  python3 -I scripts/perf/build-writes.py run --label A2 --out /tmp/bw/runs.jsonl \
      [--cwd DIR] [--du DIR] [--log FILE] [--no-wrap] -- python3 scripts/swift-task.py build
  python3 -I scripts/perf/build-writes.py summary /tmp/bw/runs.jsonl

Counters: proc_pid_rusage(RUSAGE_INFO_V4) ri_logical_writes (bytes written through the file system,
what the system's disk-write limit counts) and ri_diskio_byteswritten (bytes sent to the device).
Only the command's own process tree is counted, so builds by other agents running at the same time
do not add to the numbers (they only slow the run down).

How processes are followed:
- Sampling: every --interval s (default 0.01) all pids via libproc; a pid belongs to the run when
  its parent already does or it is in the run's process group. The last values seen are kept, plus
  a kqueue NOTE_EXIT read in the short zombie window when it is won. A sampled process loses what
  it wrote in its last few milliseconds, and processes shorter than the interval can be missed.
- Exact compiler/linker jobs (default, --no-wrap turns it off): SWIFT_DRIVER_SWIFT_FRONTEND_EXEC
  and SWIFT_DRIVER_CLANG_EXEC point the Swift driver at this script under the tool's name; clang
  gets --ld-path to the same wrapper. The wrapper spawns the real tool, waits with WNOWAIT, reads
  the zombie's final counters, then reaps it, so every swift-frontend/clang/ld job is exact. These
  are the jobs that write object files, modules, index data and binaries.
Coverage: CPU seconds accounted (exact + sampled) / CPU seconds the kernel charged to this script's
reaped descendants. du -sk of --du before and after (du counts APFS clones at full size), and a
stat walk of --du before and after: sizes of files created or rewritten (mtime/inode changed), a lower
bound for what the run wrote into that tree.
Under SwiftPM's default Swift Build system the compiler runs inside the build service, which ignores
SWIFT_DRIVER_*_EXEC, so there the frontends are only sampled; the wrapper applies to manifest builds
and to --build-system native, where "sampled_of_exact_mb" shows how much sampling alone would have seen.
"""
import argparse
import collections
import ctypes
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

RUSAGE_INFO_V4 = 4
PROC_ALL_PIDS = 1
PROC_PIDTBSDINFO = 3
TOOLS = ("swift-frontend", "clang", "ld")


class RUsageV4(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time",
        "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
        "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten", "qos_default",
        "qos_maintenance", "qos_background", "qos_utility", "qos_legacy", "qos_user_initiated",
        "qos_user_interactive", "billed_system_time", "serviced_system_time", "logical_writes",
        "lifetime_max_phys_footprint", "instructions", "cycles", "billed_energy", "serviced_energy",
        "interval_max_phys_footprint", "runnable_time")]


class BSDInfo(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32),
                ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
                ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32), ("rgid", ctypes.c_uint32),
                ("svuid", ctypes.c_uint32), ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32),
                ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32), ("nfiles", ctypes.c_uint32),
                ("pgid", ctypes.c_uint32), ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
                ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
                ("start_usec", ctypes.c_uint64)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RUsageV4)]
libc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
libc.waitid.argtypes = [ctypes.c_int, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
_tb = Timebase()
libc.mach_timebase_info(ctypes.byref(_tb))
TICK_S = _tb.numer / _tb.denom / 1e9
_info = BSDInfo()
_ru = RUsageV4()


def all_pids(buf=(ctypes.c_int * 16384)()):
    n = libc.proc_listpids(PROC_ALL_PIDS, 0, buf, ctypes.sizeof(buf)) // ctypes.sizeof(ctypes.c_int)
    return [buf[i] for i in range(n) if buf[i] > 0]


def bsd(pid):
    if libc.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ctypes.byref(_info), ctypes.sizeof(_info)) != ctypes.sizeof(_info):
        return None
    return _info.ppid, _info.pgid, _info.comm.decode(errors="replace"), (_info.start_sec, _info.start_usec)


def rusage(pid):
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(_ru)) != 0:
        return None
    return (_ru.logical_writes, _ru.diskio_byteswritten, (_ru.user_time + _ru.system_time) * TICK_S,
            (_ru.child_user_time + _ru.child_system_time) * TICK_S)


def du_kb(path):
    if not path or not os.path.exists(path):
        return 0
    out = subprocess.run(["du", "-sk", path], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else 0


def walk(root):
    files = {}
    if not root or not os.path.isdir(root):
        return files
    for dirpath, _, names in os.walk(root):
        for name in names:
            try:
                st = os.lstat(os.path.join(dirpath, name))
            except OSError:
                continue
            files[os.path.join(dirpath, name)] = (st.st_size, st.st_mtime_ns, st.st_ino)
    return files


def walk_diff(before, after):
    """Files created or rewritten during the run: their final sizes are a lower bound for logical writes."""
    new = [v[0] for k, v in after.items() if k not in before]
    changed = [v[0] for k, v in after.items() if k in before and before[k] != v]
    return {"new_files": len(new), "new_mb": round(sum(new) / 1e6, 1), "changed_files": len(changed),
            "changed_mb": round(sum(changed) / 1e6, 1), "deleted_files": sum(1 for k in before if k not in after)}


def wrapper(name):
    """Run the real tool as a child, read its final counters as a zombie, reap it, exit with its status."""
    real = os.environ["BW_REAL_" + name.upper().replace("-", "_")]
    args = sys.argv[1:]
    if name == "clang" and "-c" not in args and os.environ.get("BW_LD_WRAPPER"):
        args = ["--ld-path=" + os.environ["BW_LD_WRAPPER"]] + args
    pid = os.posix_spawn(real, [real] + args, os.environ)
    st = bsd(pid)
    siginfo = ctypes.create_string_buffer(128)
    while libc.waitid(1, pid, siginfo, 0x4 | 0x20) != 0:     # P_PID, WEXITED | WNOWAIT
        if ctypes.get_errno() != 4:                          # EINTR
            break
    ru = rusage(pid)
    _, status = os.waitpid(pid, 0)
    if ru and st:
        kind = "compile" if "-c" in args else "emit-module" if "-emit-module" in args else "link" if name != "swift-frontend" else "other"
        module = args[args.index("-module-name") + 1] if "-module-name" in args else ""
        line = json.dumps({"pid": pid, "start": list(st[3]), "tool": name, "kind": kind, "module": module,
                           "primaries": args.count("-primary-file"), "wmo": "-whole-module-optimization" in args,
                           "lw": ru[0], "w": ru[1], "cpu": ru[2]}) + "\n"
        fd = os.open(os.environ["BW_LOG"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        os.write(fd, line.encode())
        os.close(fd)
    sys.exit(os.waitstatus_to_exitcode(status))


def run(args):
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    me = os.getpid()
    base_child_cpu = rusage(me)[3]
    du_before = du_kb(args.du)
    files_before = walk(args.du)
    env = dict(os.environ)
    tmp = tempfile.mkdtemp(prefix="build-writes-")
    jobs_log = os.path.join(tmp, "jobs.jsonl")
    if not args.no_wrap:
        script = os.path.abspath(__file__)
        for tool in TOOLS:
            real = subprocess.run(["xcrun", "--find", tool], capture_output=True, text=True, check=True).stdout.strip()
            env["BW_REAL_" + tool.upper().replace("-", "_")] = real
            os.symlink(script, os.path.join(tmp, tool))
        env.update(BW_LOG=jobs_log, BW_LD_WRAPPER=os.path.join(tmp, "ld"),
                   SWIFT_DRIVER_SWIFT_FRONTEND_EXEC=os.path.join(tmp, "swift-frontend"),
                   SWIFT_DRIVER_CLANG_EXEC=os.path.join(tmp, "clang"))
    log = open(args.log or os.devnull, "w")
    start = time.time()
    proc = subprocess.Popen(command, cwd=args.cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True, text=True, errors="replace")
    os.set_blocking(proc.stdout.fileno(), False)
    pgid = proc.pid
    known = {proc.pid}
    last = {}            # (pid, start) -> [logical, physical, cpu, comm]
    live = {}            # pid -> (start, comm) of tracked processes not yet seen exiting
    kq = select.kqueue()
    steps, compiling, buf = 0, 0, ""
    step = re.compile(r"\[\s*(\d+)\s*/\s*(\d+)\s*\]")

    def drain():
        nonlocal buf, steps, compiling
        while True:
            try:
                chunk = proc.stdout.read()
            except (BlockingIOError, TypeError):
                chunk = None
            if not chunk:
                return
            log.write(chunk)
            buf += chunk
            *lines, buf = buf.split("\n")
            for line in lines:
                for m in step.finditer(line):
                    steps = max(steps, int(m.group(2)))
                if "Compiling" in line:
                    compiling += 1

    while True:
        for pid in all_pids():
            if pid == me:
                continue
            info = bsd(pid)
            if not info:
                continue
            ppid, pg, comm, st = info
            if pid in known or ppid in known or pg == pgid:
                known.add(pid)
                if pid not in live:
                    live[pid] = (st, comm)
                    try:
                        kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                                  select.KQ_NOTE_EXIT)], 0, 0)
                    except OSError:
                        pass
                ru = rusage(pid)
                if ru:
                    last[(pid, st)] = [ru[0], ru[1], ru[2], comm]
        drain()
        if proc.poll() is not None:
            break
        deadline = time.time() + args.interval
        while (left := deadline - time.time()) > 0:
            events = kq.control(None, 64, left)
            if not events:
                break
            for ev in events:
                st, comm = live.pop(ev.ident, (None, None))
                ru = rusage(ev.ident) if st else None
                if ru:
                    last[(ev.ident, st)] = [ru[0], ru[1], ru[2], comm]
    drain()
    log.close()
    wall = time.time() - start
    child_cpu = rusage(me)[3] - base_child_cpu
    jobs = []
    if os.path.exists(jobs_log):
        jobs = [json.loads(line) for line in open(jobs_log)]
    shutil.rmtree(tmp, ignore_errors=True)
    sampled_of_exact = [0, 0]   # what sampling alone saw of the exactly measured jobs (sampling bias)
    for j in jobs:        # exact values replace the sampled ones of the same process
        key = (j["pid"], tuple(j["start"]))
        if key in last:
            sampled_of_exact[0] += last[key][0]
            sampled_of_exact[1] += last[key][1]
        last[key] = [j["lw"], j["w"], j["cpu"], j["tool"]]
    logical = sum(v[0] for v in last.values())
    physical = sum(v[1] for v in last.values())
    cpu = sum(v[2] for v in last.values())
    by = collections.defaultdict(lambda: [0, 0, 0, 0.0])
    for v in last.values():
        e = by[v[3]]
        e[0] += v[0]; e[1] += v[1]; e[2] += 1; e[3] += v[2]
    top = sorted(by.items(), key=lambda kv: -kv[1][0])[:8]
    kinds = collections.Counter(j["kind"] for j in jobs)
    exact_lw = sum(j["lw"] for j in jobs)
    modules = collections.defaultdict(lambda: [0, 0])
    for j in jobs:
        if j["kind"] == "compile":
            modules[j["module"]][0] += max(j["primaries"], 1)
            modules[j["module"]][1] += j["lw"]
    row = {
        "label": args.label, "t": round(start), "cmd": " ".join(command), "exit": proc.returncode,
        "wall_s": round(wall, 1), "logical_mb": round(logical / 1e6, 1), "physical_mb": round(physical / 1e6, 1),
        "exact_logical_mb": round(exact_lw / 1e6, 1), "exact_physical_mb": round(sum(j["w"] for j in jobs) / 1e6, 1),
        "sampled_of_exact_mb": [round(x / 1e6, 1) for x in sampled_of_exact], "processes": len(last),
        "compile_jobs": kinds.get("compile", 0), "emit_module_jobs": kinds.get("emit-module", 0),
        "link_jobs": sum(1 for j in jobs if j["tool"] == "ld"),
        "files_compiled": sum(v[0] for v in modules.values()),
        "swiftpm_steps": steps, "compiling_lines": compiling,
        "cpu_accounted_s": round(cpu, 1), "cpu_children_s": round(child_cpu, 1),
        "coverage": round(cpu / child_cpu, 3) if child_cpu else None,
        "du_before_mb": round(du_before / 1024), "du_after_mb": round(du_kb(args.du) / 1024),
        "walk": walk_diff(files_before, walk(args.du)) if args.du else None,
        "modules": {k: {"files": v[0], "logical_mb": round(v[1] / 1e6, 1)} for k, v in sorted(modules.items())},
        "top": {k: {"logical_mb": round(v[0] / 1e6, 1), "physical_mb": round(v[1] / 1e6, 1), "n": v[2],
                    "cpu_s": round(v[3], 1)} for k, v in top},
    }
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "a") as fh:
            fh.write(json.dumps(row) + "\n")
    print(json.dumps({k: v for k, v in row.items() if k not in ("top", "modules", "cmd")}))
    return proc.returncode


def summary(args):
    print("| label | exit | wall s | logical MB | physical MB | compile jobs | files compiled | coverage | .build MB |")
    print("|---|---|---|---|---|---|---|---|---|")
    for line in open(args.file):
        r = json.loads(line)
        print(f"| {r['label']} | {r['exit']} | {r['wall_s']} | {r['logical_mb']} | {r['physical_mb']} | {r['compile_jobs']} "
              f"| {r['files_compiled']} | {r['coverage']} | {r['du_after_mb']} |")


def main():
    name = os.path.basename(sys.argv[0])
    if name in TOOLS:
        wrapper(name)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("--label", required=True)
    p.add_argument("--out")
    p.add_argument("--cwd")
    p.add_argument("--du", help="directory whose size is recorded before and after")
    p.add_argument("--log", help="file for the command's combined output")
    p.add_argument("--interval", type=float, default=0.01)
    p.add_argument("--no-wrap", action="store_true", help="sample only; do not route compiler/linker jobs through the wrapper")
    p.add_argument("command", nargs=argparse.REMAINDER)
    s = sub.add_parser("summary")
    s.add_argument("file")
    args = parser.parse_args()
    sys.exit(run(args) if args.cmd == "run" else summary(args))


if __name__ == "__main__":
    main()
