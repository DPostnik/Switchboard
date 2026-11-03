#!/usr/bin/env python3
"""Chat memory probe: phys_footprint after opening, switching, streaming into and closing synthetic chats.

Builds the package in release with testing enabled into a separate scratch directory (never the repo's .build),
links scripts/perf/MemoryProbe.swift against the module objects and runs one process per scenario, so every
scenario starts from a clean baseline. The chats go through the app's own path (DeskView, DeskModel.openChat,
AppStore in a temporary directory). Synthetic transcripts only: no agents, network, credentials or app state.
The probe briefly shows its own window; the running app is untouched.

  python3 scripts/perf/profile-memory.py /tmp/memory.json                       # all scenarios, about 20 minutes
  python3 scripts/perf/profile-memory.py /tmp/m.json --scenarios open:200,switch:200 --skip-build
  python3 scripts/perf/profile-memory.py /tmp/m.json --stream-seconds 60 --worktree
Scenarios are name:messages; names: open (1/5/N chats), switch (N switches between two chats), stream, views
(rendered transcript views kept alive, the cost of caching rendered chats).
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


def snapshot(source, worktree):
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
        archive = subprocess.Popen(['git', 'archive', 'HEAD'], cwd=ROOT, stdout=subprocess.PIPE)
        subprocess.run(['tar', '-x', '-C', str(source)], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            raise RuntimeError('git archive failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--work', type=Path, default=Path('/tmp/switchboard-perf-memory'),
                        help='snapshot and scratch directory (default /tmp/switchboard-perf-memory)')
    parser.add_argument('--worktree', action='store_true', help='measure the working tree instead of HEAD')
    parser.add_argument('--scenarios', default='open:200,open:1000,switch:200,switch:1000,stream:200,views:1000')
    parser.add_argument('--chats', type=int, default=20)
    parser.add_argument('--switches', type=int, default=50)
    parser.add_argument('--stream-seconds', type=int, default=300)
    parser.add_argument('--views', type=int, default=3)
    parser.add_argument('--hold', type=int, default=0, help='seconds to keep each probe alive after closing (for heap)')
    parser.add_argument('--no-text-checking', action='store_true',
                        help='experiment: turn off automatic text checking on the opened transcript views')
    parser.add_argument('--find-bar', action='store_true',
                        help='"views": configure the find bar and incremental search like the app\'s chat transcript')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--skip-package', action='store_true', help='reuse the package build, recompile the probe only')
    args = parser.parse_args()
    info = json.loads((ROOT / '.build/local-build/build-info.json').read_text())
    sdk = info['sdk']
    source, scratch = args.work / 'src', args.work / 'build'
    executable = args.work / 'MemoryProbe'
    if not args.skip_build:
        if not args.skip_package:
            snapshot(source, args.worktree)
        # The app's entry point is renamed so its objects link into the probe; the alias keeps the app's own
        # (unused) executable link working.
        if not args.skip_package:
            run(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--scratch-path', scratch, '--force-resolved-versions',
                 '--product', 'ContextDesk', '-Xswiftc', '-enable-testing',
                 '-Xswiftc', '-Xfrontend', '-Xswiftc', '-entry-point-function-name', '-Xswiftc', '-Xfrontend', '-Xswiftc',
                 'probe_app_main', '-Xlinker', '-alias', '-Xlinker', '_probe_app_main', '-Xlinker', '_main'],
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
                       ROOT / 'scripts/perf/MemoryProbe.swift', *objects, '-lsqlite3', '-o', executable])
    report = {'scenarios': []}
    for spec in args.scenarios.split(','):
        name, _, size = spec.partition(':')
        path = args.work / f'{name}-{size}.json'
        env = {**os.environ, 'SWITCHBOARD_MEMORY_REPORT': str(path), 'SWITCHBOARD_SCROLL_PROJECT': str(source),
               'SWITCHBOARD_MEMORY_SCENARIO': name, 'SWITCHBOARD_MEMORY_SIZE': size or '200',
               'SWITCHBOARD_MEMORY_CHATS': str(args.chats), 'SWITCHBOARD_MEMORY_SWITCHES': str(args.switches),
               'SWITCHBOARD_MEMORY_SECONDS': str(args.stream_seconds), 'SWITCHBOARD_MEMORY_VIEWS': str(args.views),
               'SWITCHBOARD_MEMORY_HOLD': str(args.hold), 'SWITCHBOARD_MEMORY_NO_TEXT_CHECKING': '1' if args.no_text_checking else '0',
               'SWITCHBOARD_MEMORY_FIND_BAR': '1' if args.find_bar else '0'}
        started = time.time()
        if subprocess.run([str(executable)], env=env).returncode != 0:
            raise RuntimeError(f'probe failed in {spec}')
        row = json.loads(path.read_text())
        row['wall_s'] = round(time.time() - started)
        report['scenarios'].append(row)
        for point in row['checkpoints']:
            relief = point.get('after_relief', {})
            print(f"{spec:12} {point['label'][:48]:48} footprint {point['footprint_mb']:7.1f} MB  malloc in use "
                  f"{point['malloc_in_use_mb']:7.1f}  peak {point['peak_mb']:7.1f}"
                  + (f"  after relief {relief.get('footprint_mb')}" if relief else ''), flush=True)
    digest = hashlib.sha256()
    for path in sorted((source / 'Sources').rglob('*.swift')):
        digest.update(str(path.relative_to(source)).encode()); digest.update(path.read_bytes())
    report.update(source_sha256=digest.hexdigest(), sdk=sdk, worktree=args.worktree,
                  revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  machine=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip())
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()
