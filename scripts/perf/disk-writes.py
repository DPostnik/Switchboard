#!/usr/bin/env python3
"""Measure how much Switchboard and its child processes write to disk, and where.

Read-only: it never opens app databases, never signals or attaches to processes, and prints only
sizes, counts, process names and file names (no file contents).

  python3 -I scripts/perf/disk-writes.py record --duration 900 --out /tmp/sb-disk/run.jsonl
  python3 -I scripts/perf/disk-writes.py summary /tmp/sb-disk/run.jsonl
  python3 -I scripts/perf/disk-writes.py reports      # system disk-write reports, stacks by app frame

record:
  every --interval s (default 5): proc_pid_rusage(RUSAGE_INFO_V4) of Switchboard and all descendants
    (ri_diskio_byteswritten = bytes the process sent to the block device, ri_logical_writes = bytes
    written through the file system including later-overwritten pages, CPU time) and size/mtime of the
    SQLite files (+ -wal/-shm) in the app home.
  every --walk-interval s (default 60): stat of every file under the watched trees; the summary turns
    consecutive walks into per-directory "grown bytes" and "rewritten bytes" (size of files whose mtime
    changed, an upper bound for a rewrite, a lower bound when a file was rewritten more than once).
"""
import argparse
import collections
import ctypes
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
APP = os.path.join(HOME, "Library/Application Support/Switchboard")
WATCH = [
    APP,
    os.path.join(HOME, "Library/Logs/Switchboard"),
    os.path.join(HOME, "Library/Caches/Switchboard"),
    os.path.join(HOME, "Library/Caches/local.daniil.switchboard"),
    os.path.join(HOME, "Library/Caches/claude-cli-nodejs"),
    os.path.join(HOME, "Library/Caches/ms-playwright"),
    os.path.join(HOME, "Library/HTTPStorages/local.daniil.switchboard"),
    os.path.join(HOME, "Library/Saved Application State/local.daniil.switchboard.savedState"),
    os.path.join(HOME, "Library/Preferences/local.daniil.switchboard.plist"),
    os.path.join(HOME, ".claude"),
    os.path.join(HOME, ".codex"),
    os.environ.get("TMPDIR", "/tmp"),
]
DBS = ["metadata.sqlite", "chat-index.sqlite", "capability-ledger.sqlite"]

RUSAGE_INFO_V4 = 4


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


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RUsageV4)]
_tb = Timebase()
libc.mach_timebase_info(ctypes.byref(_tb))
TICK_NS = _tb.numer / _tb.denom


def rusage(pid):
    r = RUsageV4()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(r)) != 0:
        return None
    return {
        "w": r.diskio_byteswritten, "lw": r.logical_writes, "r": r.diskio_bytesread,
        "cpu": round((r.user_time + r.system_time) * TICK_NS / 1e9, 3), "start": r.proc_start_abstime,
    }


def process_table():
    out = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            table[int(parts[0])] = (int(parts[1]), parts[2])
    return table


def app_pid(table):
    for pid, (_, comm) in table.items():
        if comm.endswith("/Switchboard.app/Contents/MacOS/Switchboard"):
            return pid
    return None


def descendants(table, root):
    children = collections.defaultdict(list)
    for pid, (ppid, _) in table.items():
        children[ppid].append(pid)
    seen, stack = [], [root]
    while stack:
        p = stack.pop()
        seen.append(p)
        stack.extend(children.get(p, []))
    return seen


def own_agent(table, root, me):
    """The direct child of the app whose subtree runs this script (the chat doing the measuring)."""
    p = me
    while p in table and table[p][0] not in (root, 0, 1):
        p = table[p][0]
    return p if p in table and table[p][0] == root else None


def short_name(comm):
    base = os.path.basename(comm)
    if "Chrome" in comm or "Chromium" in comm:
        return "Chrome for Testing" + (" helper" if "Helper" in comm else "")
    if base.lower().startswith("python"):
        return "python"
    return base


def walk(roots):
    files = {}
    for root in roots:
        if os.path.isfile(root):
            try:
                st = os.stat(root)
                files[root] = (st.st_size, st.st_mtime_ns)
            except OSError:
                pass
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            for name in filenames:
                path = os.path.join(dirpath, name)
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                files[path] = (st.st_size, st.st_mtime_ns)
    return files


def db_stat():
    out = {}
    for db in DBS:
        for suffix in ("", "-wal", "-shm"):
            path = os.path.join(APP, db + suffix)
            try:
                st = os.stat(path)
                out[db + suffix] = [st.st_size, st.st_mtime_ns]
            except OSError:
                pass
    return out


def record(args):
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    me = os.getpid()
    end = time.time() + args.duration
    last_walk = 0.0
    prev_files = None
    with open(args.out, "w") as fh:
        while time.time() < end:
            t = time.time()
            table = process_table()
            root = app_pid(table)
            procs = {}
            if root:
                for pid in descendants(table, root):
                    if pid == me or args.exclude and any(x in table.get(pid, (0, ""))[1] for x in args.exclude):
                        continue
                    ru = rusage(pid)
                    if ru:
                        ru["name"] = short_name(table[pid][1])
                        ru["ppid"] = table[pid][0]
                        procs[pid] = ru
                mine = own_agent(table, root, me)
                if mine:
                    for pid in descendants(table, mine):
                        if pid in procs:
                            procs[pid]["name"] += " [measuring chat]"
            row = {"t": round(t, 2), "root": root, "procs": procs, "db": db_stat()}
            if t - last_walk >= args.walk_interval:
                files = walk(WATCH + args.watch)
                if prev_files is not None:
                    row["walk"] = diff_walk(prev_files, files)
                prev_files, last_walk = files, t
            fh.write(json.dumps(row) + "\n")
            fh.flush()
            time.sleep(max(0.0, args.interval - (time.time() - t)))


def bucket(path):
    """Directory bucket for attribution: two levels below the watched root."""
    for root in sorted(WATCH, key=len, reverse=True):
        if path.startswith(root):
            rel = os.path.relpath(path, root)
            parts = rel.split(os.sep)
            tail = os.sep.join(parts[:2]) if len(parts) > 2 else (parts[0] if len(parts) > 1 else parts[0])
            return os.path.basename(root.rstrip("/")) + "/" + tail
    return "other"


def diff_walk(prev, cur):
    agg = collections.defaultdict(lambda: [0, 0, 0, 0])  # grown, rewritten(size of mtime-changed), changed files, new files
    files = collections.defaultdict(lambda: [0, 0, 0])  # per-file: grown, size, changes
    for path, (size, mtime) in cur.items():
        old = prev.get(path)
        if old is None:
            a = agg[bucket(path)]
            a[0] += size; a[1] += size; a[2] += 1; a[3] += 1
        elif old[1] != mtime:
            a = agg[bucket(path)]
            a[0] += max(0, size - old[0]); a[1] += size; a[2] += 1
        else:
            continue
        f = files[path.replace(HOME, "~")]
        f[0] += max(0, size - (old[0] if old else 0)); f[1] = size; f[2] += 1
    top = dict(sorted(files.items(), key=lambda kv: -kv[1][1])[:25])
    return {"dirs": dict(agg), "files": top}


def fmt(n):
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.2f} TB"


def summary(args):
    rows = [json.loads(l) for l in open(args.file)]
    if len(rows) < 2:
        sys.exit("need at least two samples")
    span = rows[-1]["t"] - rows[0]["t"]
    first, last = {}, {}
    for row in rows:
        for pid, ru in row["procs"].items():
            key = (pid, ru["start"])
            first.setdefault(key, (row["t"], ru))
            last[key] = (row["t"], ru)
    by_name = collections.defaultdict(lambda: [0, 0, 0.0, 0])
    t0 = rows[0]["t"]
    for key, (tf, ruf) in first.items():
        _, rul = last[key]
        base = ruf if tf == t0 else {"w": 0, "lw": 0, "cpu": 0.0}  # new process: count everything since start
        a = by_name[ruf["name"]]
        a[0] += rul["w"] - base["w"]; a[1] += rul["lw"] - base["lw"]; a[2] += rul["cpu"] - base["cpu"]; a[3] += 1
    hours = span / 3600
    print(f"window {span/60:.1f} min, {len(rows)} samples")
    print(f"{'process':28} {'n':>3} {'disk written':>13} {'/h':>11} {'logical':>11} {'/h':>11} {'cpu s':>8}")
    tw = tl = 0
    for name, (w, lw, cpu, n) in sorted(by_name.items(), key=lambda kv: -kv[1][1]):
        tw += w; tl += lw
        print(f"{name[:28]:28} {n:3} {fmt(w):>13} {fmt(w/hours):>11} {fmt(lw):>11} {fmt(lw/hours):>11} {cpu:8.1f}")
    print(f"{'total':28} {'':3} {fmt(tw):>13} {fmt(tw/hours):>11} {fmt(tl):>11} {fmt(tl/hours):>11}")
    print(f"  -> per day at this rate: disk {fmt(tw/hours*24)}, logical {fmt(tl/hours*24)}")

    # Switchboard process alone over time (per-minute rate)
    root_series = [(r["t"], r["procs"].get(str(r["root"]))) for r in rows if r["root"]]
    root_series = [(t, ru) for t, ru in root_series if ru]
    if len(root_series) > 1:
        print("\nSwitchboard per ~60 s: logical KB/s, disk KB/s, cpu %")
        step = max(1, int(60 / max(1e-3, (root_series[-1][0] - root_series[0][0]) / (len(root_series) - 1))))
        for i in range(0, len(root_series) - step, step):
            (ta, a), (tb, b) = root_series[i], root_series[i + step]
            dt = tb - ta
            print(f"  +{(ta-t0)/60:5.1f} min  {(b['lw']-a['lw'])/dt/1024:8.1f}  {(b['w']-a['w'])/dt/1024:8.1f}  {100*(b['cpu']-a['cpu'])/dt:5.1f}")

    # SQLite files
    print("\nSQLite files: size first -> last, max, mtime changes")
    names = sorted({k for r in rows for k in r["db"]})
    for n in names:
        series = [r["db"][n] for r in rows if n in r["db"]]
        changes = sum(1 for a, b in zip(series, series[1:]) if a[1] != b[1])
        shrinks = sum(1 for a, b in zip(series, series[1:]) if b[0] < a[0])
        print(f"  {n:30} {fmt(series[0][0]):>10} -> {fmt(series[-1][0]):>10}  max {fmt(max(s[0] for s in series)):>10}  "
              f"mtime changes {changes:4}  shrinks {shrinks}")

    agg = collections.defaultdict(lambda: [0, 0, 0, 0])
    files = collections.defaultdict(lambda: [0, 0, 0])
    for r in rows:
        w = r.get("walk", {})
        for k, v in w.get("dirs", {}).items():
            a = agg[k]
            for i in range(4):
                a[i] += v[i]
        for k, v in w.get("files", {}).items():
            f = files[k]
            f[0] += v[0]; f[1] += v[1]; f[2] += v[2]
    if agg:
        print("\nfile tree changes (sum over walks): grown, size of rewritten/new files, changed files, new files")
        for k, (g, rw, c, nnew) in sorted(agg.items(), key=lambda kv: -kv[1][1])[: args.top]:
            print(f"  {k[:70]:70} {fmt(g):>10} {fmt(rw):>10} {c:6} {nnew:6}")
        print("\nfiles rewritten most (sum of sizes at each walk where the mtime changed), grown, walks changed")
        for k, (g, rw, c) in sorted(files.items(), key=lambda kv: -kv[1][1])[: args.top]:
            print(f"  {k[-90:]:90} {fmt(rw):>10} {fmt(g):>10} {c:4}")


def reports(args):
    """Disk-write diagnostic reports: header numbers and the deepest Switchboard frame of each sampled leaf."""
    import glob
    import re
    for f in sorted(glob.glob(args.glob)):
        lines = open(f, errors="replace").read().splitlines()
        start = next((i for i, l in enumerate(lines) if l.startswith("Powerstats for:")), None)
        if start is None:
            continue
        hdr = {l.split(":", 1)[0]: l.split(":", 1)[1].strip() for l in lines[:40] if ":" in l}
        if hdr.get("Event") != "disk writes":
            continue
        nodes = []
        for l in lines[start:]:
            m = re.match(r"^(\s+)\*?(\d+)\s+(.*)$", l)
            if m:
                nodes.append((len(m.group(1)), int(m.group(2)), m.group(3)))
        res, stack = collections.Counter(), []
        for i, (ind, cnt, txt) in enumerate(nodes):
            while stack and stack[-1][0] >= ind:
                stack.pop()
            stack.append((ind, cnt, txt))
            if i + 1 == len(nodes) or nodes[i + 1][0] <= ind:
                sb = [t for _, _, t in stack if "(Switchboard +" in t or ".swift:" in t]
                key = " <- ".join(re.sub(r" \+ \d+.*", "", t).strip() for t in sb[::-1][:2]) if sb else "(no app frame)"
                res[key] += cnt
        print(os.path.basename(f), hdr.get("Version"), hdr.get("Writes caused"), hdr.get("Duration"))
        for k, v in res.most_common(args.top):
            print(f"   {v:4} {k[:160]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--duration", type=float, default=900)
    r.add_argument("--interval", type=float, default=5)
    r.add_argument("--walk-interval", type=float, default=60)
    r.add_argument("--out", default="/tmp/sb-disk/run.jsonl")
    r.add_argument("--watch", action="append", default=[], help="extra file or directory to walk")
    r.add_argument("--exclude", action="append", default=[], help="skip processes whose path contains this")
    s = sub.add_parser("summary")
    s.add_argument("file")
    s.add_argument("--top", type=int, default=30)
    d = sub.add_parser("reports")
    d.add_argument("--glob", default="/Library/Logs/DiagnosticReports/Switchboard_*.diag")
    d.add_argument("--top", type=int, default=8)
    args = ap.parse_args()
    {"record": record, "summary": summary, "reports": reports}[args.cmd](args)


if __name__ == "__main__":
    main()
