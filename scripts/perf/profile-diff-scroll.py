#!/usr/bin/env python3
"""Measure diff scrolling in a standalone process that hosts Switchboard's real diff views.

Builds release modules with testable imports into a separate scratch directory (never .build or the app bundle),
links scripts/perf/DiffScrollProbe.swift against them and runs it. The probe opens its own windows, creates a
temporary git repository with synthetic diffs, scrolls each diff view from a CADisplayLink and writes JSON.
It never talks to a running Switchboard and never touches the user's data (SWITCHBOARD_DATA_ROOT is a temp dir).

  python3 scripts/perf/profile-diff-scroll.py /tmp/diff-scroll.json
  python3 scripts/perf/profile-diff-scroll.py out.json --only turn-window/large.swift --trace /tmp/diff.trace
Environment passed through: DIFF_PROBE_FRAMES (default 300), DIFF_PROBE_SPEEDS (pt/s, default 2400),
DIFF_PROBE_MODES (clip,wheel; default clip).
"""
import argparse
import collections
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent.parent
SCRATCH = Path(os.environ.get('DIFF_PROBE_SCRATCH', '/private/tmp/sb-diff-probe/build'))
MODULES = ['ContextDesk', 'AgentContract', 'ContextCore', 'ContextTranscript', 'ClaudeAdapter', 'CodexAdapter',
           'ACPAdapter', 'FringeProtocol', 'TOMLDecoder']


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True, **kwargs)


def sdk_path():
    info = ROOT / '.build/local-build/build-info.json'
    if info.is_file():
        return json.loads(info.read_text())['sdk']
    return subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()


def build(sdk):
    # --build-tests makes SwiftPM rename the ContextDesk executable's entry point, so the probe can supply main.
    run(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--scratch-path', SCRATCH, '--build-tests',
         '-Xswiftc', '-enable-testing'])
    release = SCRATCH / 'release'
    intermediate = SCRATCH / 'out/Intermediates.noindex/ContextDesk.build/Release'
    testable = sorted(intermediate.glob('ContextDesk--*-testable-t.build/Objects-normal/*/*.o'))
    if testable:
        # Xcode build-system backend: one merged object per library module, the app module's testable objects apart.
        objects = testable + [release / (name + '.o') for name in MODULES if name != 'ContextDesk']
        include = release
    else:
        # Classic SwiftPM backend.
        objects = [p for name in MODULES for p in sorted((release / (name + '.build')).glob('*.o'))]
        include = release / 'Modules'
    if not objects or not all(p.is_file() for p in objects):
        raise RuntimeError('Release object layout unavailable under ' + str(SCRATCH))
    executable = SCRATCH / 'DiffScrollProbe'
    run(['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library', '-I', include,
         '-Xcc', '-fmodule-map-file=' + str(ROOT / 'Sources/CSQLite/module.modulemap'),
         ROOT / 'scripts/perf/DiffScrollProbe.swift', *objects, '-lsqlite3', '-o', executable])
    return executable


def summarize_trace(trace, windows, top=40):
    """Aggregate a Time Profiler trace: self and inclusive time per symbol on the main thread, during scroll runs only.

    `windows` are (start, end) seconds since the probe's launch; the probe's first sample marks the launch."""
    xml = subprocess.check_output(['xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
                                   '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'])
    root = ET.fromstring(xml)
    ids = {}

    def resolve(node):
        ref = node.get('ref')
        if ref is not None:
            return ids[ref]
        if node.get('id') is not None:
            ids[node.get('id')] = node
        for child in node:
            resolve(child)
        return node

    selfs, inclusive, total = collections.Counter(), collections.Counter(), 0
    libraries, launch = collections.Counter(), None
    for row in root.iter('row'):
        resolve(row)  # registers every id the row defines, also for rows skipped below
        stamp = row.find('sample-time')
        stamp = int(resolve(stamp).text) / 1e9 if stamp is not None else 0
        launch = stamp if launch is None else launch
        if windows and not any(start <= stamp - launch <= end for start, end in windows):
            continue
        thread = row.find('thread')
        if thread is None:
            continue
        thread = resolve(thread)
        name = thread.get('fmt', '')
        weight = row.find('weight')
        weight = resolve(weight) if weight is not None else None
        value = int(weight.text) if weight is not None and weight.text else 1
        if 'Main Thread' not in name and 'com.apple.main-thread' not in name:
            continue
        backtrace = row.find('tagged-backtrace')
        if backtrace is None:
            backtrace = row.find('backtrace')
        if backtrace is None:
            continue
        backtrace = resolve(backtrace)
        frames, binaries = [], []
        for frame in backtrace.findall('frame'):
            frame = resolve(frame)
            frames.append(frame.get('name') or frame.get('addr') or '?')
            binary = frame.find('binary')
            binaries.append(resolve(binary).get('name') if binary is not None else '?')
        if not frames:
            continue
        total += value
        selfs[frames[0]] += value
        libraries[binaries[0]] += value
        for symbol in set(frames):
            inclusive[symbol] += value
    return {'main_thread_ms': total / 1e6,
            'self_by_library': [(s, round(100 * v / total, 2)) for s, v in libraries.most_common(15)] if total else [],
            'self': [(s, round(100 * v / total, 2)) for s, v in selfs.most_common(top)] if total else [],
            'inclusive': [(s, round(100 * v / total, 2)) for s, v in inclusive.most_common(top * 8)] if total else []}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--only', help='comma-separated scenario name prefixes')
    parser.add_argument('--no-build', action='store_true', help='reuse the last linked probe')
    parser.add_argument('--trace', type=Path, help='record a Time Profiler trace to this .trace path')
    parser.add_argument('--summarize', type=Path, help='only summarize an existing trace against the report in output')
    args = parser.parse_args()
    if args.summarize:
        report = json.loads(args.output.read_text())
        windows = [tuple(row['since_launch_s']) for row in report['scenarios'] if 'since_launch_s' in row]
        report['time_profile'] = summarize_trace(args.summarize, windows)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        return
    sdk = sdk_path()
    executable = SCRATCH / 'DiffScrollProbe' if args.no_build else build(sdk)
    output = args.output.resolve()
    with tempfile.TemporaryDirectory(prefix='diff-probe-data-') as data:
        env = {**os.environ, 'DIFF_PROBE_REPORT': str(output), 'SWITCHBOARD_DATA_ROOT': data}
        if args.only:
            env['DIFF_PROBE_ONLY'] = args.only
        if args.trace:
            command = ['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--output', str(args.trace), '--no-prompt']
            for key in ['DIFF_PROBE_REPORT', 'SWITCHBOARD_DATA_ROOT', 'DIFF_PROBE_ONLY', 'DIFF_PROBE_FRAMES',
                        'DIFF_PROBE_SPEEDS', 'DIFF_PROBE_MODES']:
                if key in env:
                    command += ['--env', f'{key}={env[key]}']
            run(command + ['--launch', '--', executable])
        else:
            run([executable], env=env)
    report = json.loads(output.read_text())
    report['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    report['tracked_changes'] = subprocess.check_output(['git', 'diff', 'HEAD', '--stat'], cwd=ROOT, text=True).strip()
    report['sdk'] = sdk
    if args.trace:
        windows = [tuple(row['since_launch_s']) for row in report['scenarios'] if 'since_launch_s' in row]
        report['time_profile'] = summarize_trace(args.trace, windows)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
