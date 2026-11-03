#!/usr/bin/env python3
"""Whole-window cost of one streaming chat: model publications and SwiftUI graph updates per 8 s.

Builds the package like profile-transcript-scroll.py (a private source snapshot and scratch directory, release with
testing enabled), links scripts/perf/DeskStreamProbe.swift and runs it: the real DeskView with a synthetic sidebar
and one chat receiving a Claude-like event mix through DeskModel.receive. While it streams, /usr/bin/sample records
the main thread; the report adds the samples (~ms) under SwiftUI's GraphHost.flushTransactions and AppKit's
CA::Transaction::commit per 8 s. Synthetic data only; the running app is untouched.

  python3 -I scripts/perf/profile-desk-stream.py /tmp/desk-stream.json              # HEAD snapshot
  python3 -I scripts/perf/profile-desk-stream.py out.json --worktree --runs 3       # uncommitted sources, 3 runs
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent.parent
_spec = importlib.util.spec_from_file_location('scroll_profile', ROOT / 'scripts/perf/profile-transcript-scroll.py')
scroll = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scroll)

LINE = re.compile(r'^([\s+!:|]*)(\d+)\s+(.*)$')


def sampled(trace, needle):
    """Samples under frames containing `needle`, counting each call path once (nested repeats are not added)."""
    total, stack, in_main = 0, [], False
    for line in Path(trace).read_text(errors='replace').splitlines():
        if 'Thread_' in line or line.startswith('Call graph') or line.startswith('Total number'):
            in_main = 'com.apple.main-thread' in line or 'Main Thread' in line
            stack = []
            continue
        match = LINE.match(line)
        if not match or not in_main:
            continue
        depth, count, frame = len(match.group(1)), int(match.group(2)), match.group(3)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        inside = any(hit for _, hit in stack)
        hit = needle in frame
        if hit and not inside:
            total += count
        stack.append((depth, hit or inside))
    return total


def build(args):
    info = json.loads((ROOT / '.build/local-build/build-info.json').read_text())
    sdk = info['sdk']
    source, scratch = args.work / 'src', args.work / 'build'
    executable = args.work / 'DeskStreamProbe'
    if not args.skip_build:
        scroll.snapshot(source, args.worktree)
        scroll.run(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--scratch-path', scratch, '--force-resolved-versions',
                    '--product', 'ContextDesk', '-Xswiftc', '-enable-testing',
                    '-Xswiftc', '-Xfrontend', '-Xswiftc', '-entry-point-function-name', '-Xswiftc', '-Xfrontend', '-Xswiftc', 'probe_app_main',
                    '-Xlinker', '-alias', '-Xlinker', '_probe_app_main', '-Xlinker', '_main'], cwd=source)
    release = Path(subprocess.check_output(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--scratch-path', scratch,
                                            '--show-bin-path'], cwd=source, text=True).strip())
    if (release / 'ContextCore.o').is_file():
        app = scratch / 'out/Intermediates.noindex/ContextDesk.build/Release/ContextDesk-p.build/Objects-normal/arm64'
        objects = [release / (name + '.o') for name in scroll.MODULES if name != 'ContextDesk'] + sorted(app.glob('*.o'))
        includes = [release, app]
    else:
        objects = [p for name in scroll.MODULES for p in (release / (name + '.build')).glob('*.o')]
        includes = [release / 'Modules']
    missing = [str(p) for p in objects if not p.is_file()]
    if missing or len(objects) < len(scroll.MODULES):
        raise RuntimeError(f'module objects missing {missing}; no measurement was made')
    command = ['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library']
    for include in includes:
        command += ['-I', include]
    scroll.run(command + ['-Xcc', '-fmodule-map-file=' + str(source / 'Sources/CSQLite/module.modulemap'),
                          ROOT / 'scripts/perf/DeskStreamProbe.swift', *objects, '-lsqlite3', '-o', executable])
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--work', type=Path, default=Path('/tmp/switchboard-perf-desk-stream'))
    parser.add_argument('--worktree', action='store_true', help='measure the working tree instead of HEAD')
    parser.add_argument('--runs', type=int, default=1)
    parser.add_argument('--mode', choices=['stream', 'publish'], default='stream',
                        help='publish: no stream, five bare model publications per second')
    parser.add_argument('--skip-build', action='store_true', help='reuse the built package; only link the probe again')
    args = parser.parse_args()
    executable = build(args)
    output = args.output.resolve()
    runs = []
    for index in range(args.runs):
        report_path = output.with_suffix(f'.run{index}.json')
        trace = output.with_suffix(f'.run{index}.sample.txt')
        env = {**os.environ, 'SWITCHBOARD_DESK_STREAM_REPORT': str(report_path), 'SWITCHBOARD_DESK_STREAM_SECONDS': '16',
               'SWITCHBOARD_DESK_STREAM_MODE': args.mode}
        process = subprocess.Popen([str(executable)], env=env)
        time.sleep(6.5)  # window, sidebar expansion, 2 s settle, turn start; streaming runs 16 s from about here
        scroll.run(['/usr/bin/sample', str(process.pid), '8', '1', '-mayDie', '-file', trace])
        if process.wait() != 0:
            raise RuntimeError('probe failed')
        report = json.loads(report_path.read_text())
        report['sample_8s'] = {'flushTransactions': sampled(trace, 'flushTransactions'),
                               'CA_Transaction_commit': sampled(trace, 'CA::Transaction::commit'),
                               'DeskView_body': sampled(trace, 'DeskView.body'),
                               'ChatView_body': sampled(trace, 'ChatView.body'),
                               'trace': str(trace)}
        runs.append(report)
        print(f"run {index}: publications {report['per_8s']['model_publications']:.0f}, "
              f"main CPU {report['per_8s']['main_thread_cpu_ms']:.0f} ms, flushTransactions {report['sample_8s']['flushTransactions']}, "
              f"by name {report['publications_by_name']}", flush=True)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    output.write_text(json.dumps({'runs': runs, 'revision': revision, 'worktree': args.worktree}, indent=2, sort_keys=True) + '\n')
    print(output)


if __name__ == '__main__':
    main()
