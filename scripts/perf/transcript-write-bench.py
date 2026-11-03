#!/usr/bin/env python3
"""Reproduce AppStore.writeTranscript's write pattern against a temporary SQLite file and compare variants.

Never touches the app's databases. Synthetic transcript JSON, no user content.

  python3 -I scripts/perf/transcript-write-bench.py                      # default matrix
  python3 -I scripts/perf/transcript-write-bench.py --base-kb 1024 --turn-s 300 --new-kb 80

Model of one streamed turn (AppStore.swift:431-536): the chat already stores a transcript of --base-kb; during a
turn of --turn-s seconds the answer adds --new-kb of items (text deltas merge into the last item, tool items arrive
whole). The current code re-encodes the whole snapshot and replaces the `transcript:<id>` blob plus the
`transcript-revision:<id>` stamp in one transaction about once a second while items arrive (flushDelay = 1 s).
Time is simulated (one loop step = one second); fsync behaviour is real.

Measured per variant with proc_pid_rusage of this process: ri_logical_writes (bytes written through the file
system, what the disk-writes diagnostic counts) and ri_diskio_byteswritten (bytes sent to the device).
"""
import argparse
import ctypes
import json
import os
import random
import shutil
import sqlite3
import tempfile
import time
import zlib


class RUsageV4(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(f"f{i}", ctypes.c_uint64) for i in range(35)]


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
IDX_DISK_W, IDX_LOGICAL = 17, 27  # ri_diskio_byteswritten, ri_logical_writes


def io():
    r = RUsageV4()
    libc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(r))
    return getattr(r, f"f{IDX_DISK_W}"), getattr(r, f"f{IDX_LOGICAL}")


WORDS = ("the of and to in is that for it with as on was by this be are or from at which have an not but "
         "function return value error file test build swift struct let var self chat agent turn item text "
         "tool call output diff line commit model store write read index search view layout").split()


def text(rng, n):
    out, size = [], 0
    while size < n:
        w = rng.choice(WORDS)
        out.append(w)
        size += len(w) + 1
    return " ".join(out)[:n]


def make_item(rng, i, size):
    return {"id": f"item-{i:06d}", "kind": rng.choice(["agentMessage", "commandExecution", "fileChange", "reasoning"]),
            "createdAt": 1762160000 + i, "text": text(rng, size), "status": "completed"}


def snapshot(items):
    return {"version": 7, "conversation": "bench", "source": {"engine": "claude", "id": "s"},
            "completeness": "partial", "capturedAt": time.time(), "revision": f"r{len(items)}", "items": items}


def open_db(path, sync, ckpt, journal="wal"):
    db = sqlite3.connect(path, isolation_level=None)
    db.execute(f"PRAGMA journal_mode={journal}")
    db.execute(f"PRAGMA synchronous={sync}")
    db.execute(f"PRAGMA wal_autocheckpoint={ckpt}")
    db.execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS tail (conv TEXT, seq INTEGER, value BLOB, PRIMARY KEY (conv, seq))")
    return db


def put(db, key, value):
    db.execute("INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))


def run(variant, args, workdir):
    rng = random.Random(42)
    path = os.path.join(workdir, f"{variant['name']}.sqlite")
    db = open_db(path, variant.get("sync", "NORMAL"), variant.get("ckpt", 1000), variant.get("journal", "wal"))
    # Other app state so the file is not just the transcript (other chats' blobs, ~ real 120 MB file scaled down).
    for k in range(args.other_chats):
        put(db, f"transcript:other{k}", json.dumps(snapshot([make_item(rng, j, 600) for j in range(200)])).encode())
    items = []
    while len(json.dumps(snapshot(items))) < args.base_kb * 1024:
        items.append(make_item(rng, len(items), rng.choice([300, 800, 2000, 4000])))
    compress = variant.get("compress")
    encode = (lambda b: zlib.compress(b, 1)) if compress else (lambda b: b)
    put(db, "transcript:bench", encode(json.dumps(snapshot(items)).encode()))
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)") if variant.get("journal", "wal") == "wal" else None
    d0, l0 = io()
    t0 = time.time()

    per_second = args.new_kb * 1024 / args.turn_s
    interval = variant.get("interval", 1)
    delta = variant.get("delta", False)
    written_blob = 0
    flushes = 0
    seq = 0
    pending_new = []  # items changed since last flush (delta variant)
    for second in range(1, args.turn_s + 1):
        # One second of streaming: grow the last agent message, sometimes add a tool item.
        if not items or items[-1]["kind"] != "agentMessage" or rng.random() < 0.08:
            items.append(make_item(rng, len(items), 50))
            items[-1]["kind"] = "agentMessage" if rng.random() < 0.6 else "commandExecution"
        items[-1]["text"] += " " + text(rng, int(per_second))
        if not any(x is items[-1] for x in pending_new):
            pending_new.append(items[-1])
        last = second == args.turn_s
        if second % interval and not last:
            continue
        flushes += 1
        db.execute("BEGIN IMMEDIATE")
        if delta and not last:
            # Append-only: one row with the items changed since the previous flush.
            seq += 1
            blob = encode(json.dumps(pending_new).encode())
            db.execute("INSERT INTO tail(conv,seq,value) VALUES('bench',?,?)", (seq, blob))
        else:
            blob = encode(json.dumps(snapshot(items)).encode())
            put(db, "transcript:bench", blob)
            if delta:
                db.execute("DELETE FROM tail WHERE conv='bench'")
        put(db, "transcript-revision:bench", json.dumps({"revision": f"r{len(items)}-{second}"}).encode())
        db.execute("COMMIT")
        written_blob += len(blob)
        pending_new = []
    db.close()
    d1, l1 = io()
    size = sum(os.path.getsize(os.path.join(workdir, f)) for f in os.listdir(workdir) if f.startswith(variant["name"] + "."))
    final_json = len(json.dumps(snapshot(items)))
    for f in list(os.listdir(workdir)):
        if f.startswith(variant["name"] + "."):
            os.remove(os.path.join(workdir, f))
    return {"name": variant["name"], "flushes": flushes, "blob_bytes": written_blob, "logical": l1 - l0, "disk": d1 - d0,
            "final_json": final_json, "secs": time.time() - t0, "file": size}


VARIANTS = [
    {"name": "current 1 s (WAL, sync NORMAL)"},
    {"name": "current 1 s, sync FULL", "sync": "FULL"},
    {"name": "current 1 s, autocheckpoint 10000", "ckpt": 10000},
    {"name": "coalesced 5 s", "interval": 5},
    {"name": "coalesced 10 s", "interval": 10},
    {"name": "coalesced 30 s", "interval": 30},
    {"name": "compressed blob 1 s", "compress": True},
    {"name": "compressed blob 10 s", "interval": 10, "compress": True},
    {"name": "append-only delta 1 s + compact at end", "delta": True},
    {"name": "append-only delta 5 s + compact at end", "delta": True, "interval": 5},
]


def fmt(n):
    return f"{n/1048576:8.1f} MB" if n >= 1048576 else f"{n/1024:8.0f} KB"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-kb", type=int, action="append", help="stored transcript size before the turn (repeatable)")
    ap.add_argument("--turn-s", type=int, default=300)
    ap.add_argument("--new-kb", type=int, default=60, help="items added by the turn")
    ap.add_argument("--other-chats", type=int, default=20)
    ap.add_argument("--only", help="substring filter on variant names")
    args = ap.parse_args()
    bases = args.base_kb or [135, 1024, 4096]
    workdir = tempfile.mkdtemp(prefix="sb-transcript-bench-")
    try:
        for base in bases:
            args.base_kb = base
            print(f"\nstored transcript {base} KB, turn {args.turn_s} s adding {args.new_kb} KB")
            print(f"  {'variant':42} {'flushes':>7} {'blob bytes':>11} {'logical':>11} {'disk':>11} {'x new KB':>9} {'x blob':>7}")
            for v in VARIANTS:
                if args.only and args.only not in v["name"]:
                    continue
                r = run(v, args, workdir)
                amp_new = r["logical"] / (args.new_kb * 1024)
                amp_blob = r["logical"] / max(1, r["blob_bytes"])
                print(f"  {r['name']:42} {r['flushes']:7} {fmt(r['blob_bytes'])} {fmt(r['logical'])} {fmt(r['disk'])} {amp_new:9.0f} {amp_blob:7.2f}")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
