#!/usr/bin/env python3
"""Chat transcript latency probe: chat open/switch, scrolling frame times, streaming into long chats.

Builds the package in release with testing enabled into a separate scratch directory (never the repo's .build),
links scripts/perf/TranscriptScrollProbe.swift against the module objects and runs it. Synthetic transcripts only:
no agents, network, credentials or app state. The probe briefly shows its own window; the running app is untouched.

  python3 scripts/perf/profile-transcript-scroll.py /tmp/transcript-scroll.json            # HEAD snapshot
  python3 scripts/perf/profile-transcript-scroll.py out.json --worktree                    # uncommitted sources
  python3 scripts/perf/profile-transcript-scroll.py out.json --only scroll --seconds 20 --sample
      # one phase in a loop with /usr/bin/sample attached; the call tree goes next to the JSON
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent.parent
MODULES = ['ContextDesk', 'AgentContract', 'ContextCore', 'ContextTranscript', 'ClaudeAdapter', 'CodexAdapter',
           'ACPAdapter', 'FringeProtocol', 'TOMLDecoder']


def run(command, **kwargs):
    print('$', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def snapshot(source, worktree, revision='HEAD'):
    """A private copy of the package: HEAD via git archive, or the working tree's tracked files."""
    if source.exists():
        shutil.rmtree(source)
    source.mkdir(parents=True)
    if worktree:
        files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).split(b'\0')
        for name in filter(None, files):
            path = ROOT / name.decode()
            if path.is_file():
                target = source / name.decode()
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
    else:
        archive = subprocess.Popen(['git', 'archive', revision], cwd=ROOT, stdout=subprocess.PIPE)
        subprocess.run(['tar', '-x', '-C', str(source)], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            raise RuntimeError('git archive failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--work', type=Path, default=Path('/tmp/switchboard-perf-scroll'),
                        help='snapshot and scratch directory (default /tmp/switchboard-perf-scroll)')
    parser.add_argument('--worktree', action='store_true', help='measure the working tree instead of HEAD')
    parser.add_argument('--sizes', default='200,1000')
    parser.add_argument('--phases', default='open,scroll,stream,desk', help='phases of the full run')
    parser.add_argument('--no-text-checking', action='store_true',
                        help='experiment: turn off NSTextView automatic text checking in the probe views')
    parser.add_argument('--only', choices=['open', 'scroll', 'stream', 'scrollidle', 'scrollfull', 'afteropen', 'fill', 'endgap', 'wheelgap', 'switchback'])
    parser.add_argument('--seconds', type=int, default=20)
    parser.add_argument('--sample', action='store_true', help='attach /usr/bin/sample during --only')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--revision', default='HEAD', help='revision to measure (default HEAD; ignored with --worktree)')
    args = parser.parse_args()
    info = json.loads((ROOT / '.build/local-build/build-info.json').read_text())
    sdk = info['sdk']
    source, scratch = args.work / 'src', args.work / 'build'
    executable = args.work / 'TranscriptScrollProbe'
    if not args.skip_build:
        snapshot(source, args.worktree, args.revision)
        # The app's entry point is renamed so its objects link into the probe; the alias keeps the app's own
        # (unused) executable link working.
        run(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--scratch-path', scratch, '--force-resolved-versions',
             '--product', 'ContextDesk', '-Xswiftc', '-enable-testing',
             '-Xswiftc', '-Xfrontend', '-Xswiftc', '-entry-point-function-name', '-Xswiftc', '-Xfrontend', '-Xswiftc', 'probe_app_main',
             '-Xlinker', '-alias', '-Xlinker', '_probe_app_main', '-Xlinker', '_main'],
            cwd=source)
        release = Path(subprocess.check_output(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--scratch-path', scratch,
                                                '--show-bin-path'], cwd=source, text=True).strip())
        if (release / 'ContextCore.o').is_file():
            # Xcode's SwiftPM backend: one prelinked object per library, the executable's objects separately.
            app = scratch / 'out/Intermediates.noindex/ContextDesk.build/Release/ContextDesk-p.build/Objects-normal/arm64'
            objects = [release / (name + '.o') for name in MODULES if name != 'ContextDesk'] + sorted(app.glob('*.o'))
            includes = [release, app]
        else:
            objects = [p for name in MODULES for p in (release / (name + '.build')).glob('*.o')]
            includes = [release / 'Modules']
        missing = [str(p) for p in objects if not p.is_file()]
        if missing or len(objects) < len(MODULES):
            raise RuntimeError(f'module objects missing {missing}; no measurement was made')
        command = ['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library']
        for include in includes:
            command += ['-I', include]
        run(command + ['-Xcc', '-fmodule-map-file=' + str(source / 'Sources/CSQLite/module.modulemap'),
                       ROOT / 'scripts/perf/TranscriptScrollProbe.swift', *objects, '-lsqlite3', '-o', executable])
    output = args.output.resolve()
    env = {**os.environ, 'SWITCHBOARD_SCROLL_REPORT': str(output), 'SWITCHBOARD_SCROLL_PROJECT': str(source),
           'SWITCHBOARD_SCROLL_SIZES': args.sizes, 'SWITCHBOARD_SCROLL_PHASES': args.phases,
           'SWITCHBOARD_SCROLL_NO_TEXT_CHECKING': '1' if args.no_text_checking else '0'}
    if args.only:
        env.update(SWITCHBOARD_SCROLL_ONLY=args.only, SWITCHBOARD_SCROLL_SECONDS=str(args.seconds))
    process = subprocess.Popen([str(executable)], env=env)
    if args.only and args.sample:
        time.sleep(3)  # transcript generation and warm-up
        trace = output.with_suffix(f'.{args.only}.sample.txt')
        run(['/usr/bin/sample', str(process.pid), str(max(1, args.seconds - 5)), '1', '-mayDie', '-file', trace])
        print(trace)
    if process.wait() != 0:
        raise RuntimeError('probe failed')
    report = json.loads(output.read_text())
    digest = hashlib.sha256()
    for path in sorted((source / 'Sources').rglob('*.swift')):
        digest.update(str(path.relative_to(source)).encode()); digest.update(path.read_bytes())
    report.update(source_sha256=digest.hexdigest(), sdk=sdk, worktree=args.worktree,
                  revision=subprocess.check_output(['git', 'rev-parse', 'HEAD' if args.worktree else args.revision], cwd=ROOT, text=True).strip(),
                  machine=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip())
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    for row in report.get('open', []):
        print('open', row['messages'], row['scenario'], {k: row[k] for k in row if k.endswith('_ms')})
    for row in report.get('scroll', []):
        print('scroll', row['messages'], row['scenario'], {k: row.get(k) for k in ('p50_ms', 'p95_ms', 'max_ms', 'hitches', 'over_33ms', 'hitch_ms_per_s', 'ms', 'cpu_percent')})
    for row in report.get('after_open', []):
        print('after open', {k: row.get(k) for k in ('open_total_ms', 'frames', 'hitches', 'over_33ms', 'max_ms', 'backlog_left')})
    for row in report.get('fill', []):
        print('fill', row)
    for row in report.get('end_gap', []):
        print('end gap', row['scenario'], {k: v for k, v in row.items() if k not in ('trace', 'scenario')})
    for row in report.get('streaming', []):
        print('stream', row['messages'], 'tick p50/p95/max', row['tick_total'].get('p50_ms'), row['tick_total'].get('p95_ms'),
              row['tick_total'].get('max_ms'), 'cpu', row['cpu_percent_one_core'], 'finish', row['finish_turn'].get('total_ms'))
    for row in report.get('desk_switch', {}).get('rows', []):
        print('desk', row['messages'], 'first frame', row.get('first_frame_ms'), 'ms, complete', row['total_ms'], 'ms')
    print(output)


if __name__ == '__main__':
    main()
