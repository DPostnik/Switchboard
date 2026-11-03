#!/usr/bin/env python3
"""Search latency benchmark: synthetic corpus plus a read-only COPY of the app's search and metadata databases.

Builds scripts/perf/SearchProbe.swift against the committed sources (git archive HEAD) in a throwaway package
copy with its own scratch directory, so neither Sources/, .build/ nor the installed app is touched. The live
database files are only read by `cp`; the probe opens the copies. Copies are deleted afterwards. The report
contains timings and counts only.

    python3 -I scripts/perf/search-bench.py docs/perf-2026-11-03/search-results.json
    python3 -I scripts/perf/search-bench.py out.json --no-real --chats 200 --messages 100
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent.parent
APP_DATA = Path.home() / 'Library/Application Support/Switchboard'
DATABASES = ['chat-index.sqlite', 'metadata.sqlite']
CACHE = Path.home() / 'Library/Caches/switchboard-search-bench'

PROBE_TARGET = '''
package.targets.append(.executableTarget(name: "SearchProbe", dependencies: ["AgentContract", "ContextCore", "CSQLite"], path: "Probe"))
'''


def run(command, **kwargs):
    print('$', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def sdk_path():
    info = ROOT / '.build/local-build/build-info.json'
    if info.is_file():
        return json.loads(info.read_text())['sdk']
    return subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()


def copy_databases(destination: Path):
    """cp of each database with its -wal/-shm; a torn copy fails quick_check on the copy and is copied again."""
    for name in DATABASES:
        source = APP_DATA / name
        if not source.is_file():
            continue
        for attempt in range(3):
            for suffix in ['', '-wal', '-shm']:
                target = destination / (name + suffix)
                target.unlink(missing_ok=True)
                if (APP_DATA / (name + suffix)).is_file():
                    shutil.copyfile(APP_DATA / (name + suffix), target)
                    os.chmod(target, 0o600)
            try:
                with sqlite3.connect(destination / name) as copy:
                    if copy.execute('PRAGMA quick_check').fetchone()[0] == 'ok':
                        break
            except sqlite3.DatabaseError:
                pass
        else:
            raise RuntimeError(f'Could not take a consistent copy of {name}')


UI_MODULES = ['ContextDesk', 'AgentContract', 'ContextCore', 'ContextTranscript', 'ClaudeAdapter', 'CodexAdapter',
              'ACPAdapter', 'FringeProtocol', 'TOMLDecoder']


def build_ui_probe(source: Path, scratch: Path, output: Path):
    """Testable release objects (the test build renames the app's entry point) linked with SearchUIProbe.swift."""
    sdk = sdk_path()
    run(['xcrun', 'swift', 'build', '--package-path', source, '--scratch-path', scratch, '--sdk', sdk,
         '-c', 'release', '-Xswiftc', '-enable-testing', '--build-tests'])
    # Xcode's SwiftPM backend emits the testable app objects separately (as in profile-transcript.py).
    release = scratch / 'out/Products/Release'
    intermediate = scratch / 'out/Intermediates.noindex/ContextDesk.build/Release'
    objects = list(intermediate.glob('ContextDesk--*-testable-t.build/Objects-normal/*/*.o'))
    if objects:
        objects += [release / (name + '.o') for name in UI_MODULES[1:]]
        include = release
    else:
        release = scratch / 'release'
        objects = [p for name in UI_MODULES for p in (release / (name + '.build')).glob('*.o')]
        include = release / 'Modules'
    if not objects or not all(p.is_file() for p in objects):
        raise RuntimeError('Release object layout unavailable; no UI measurement was made.')
    executable = scratch / 'SearchUIProbe'
    run(['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library', '-I', include,
         '-Xcc', '-fmodule-map-file=' + str(source / 'Sources/CSQLite/module.modulemap'),
         ROOT / 'scripts/perf/SearchUIProbe.swift', *objects, '-lsqlite3', '-o', executable])
    with tempfile.TemporaryDirectory(prefix='switchboard-search-ui-') as directory:
        output.parent.mkdir(parents=True, exist_ok=True)
        run([executable], env={**os.environ, 'SEARCH_UI_REPORT': str(output), 'TMPDIR': directory})
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--no-real', action='store_true', help='synthetic corpus only')
    parser.add_argument('--no-synthetic', action='store_true', help='real copy only')
    parser.add_argument('--chats', type=int, default=500)
    parser.add_argument('--messages', type=int, default=200)
    parser.add_argument('--repeats', type=int, default=20)
    parser.add_argument('--ui', type=Path, metavar='JSON',
                        help='also build SearchUIProbe (sidebar, palette and archive typing in a hosted DeskView) and write its report here')
    parser.add_argument('--ui-only', action='store_true', help='skip SearchProbe')
    args = parser.parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    CACHE.mkdir(parents=True, exist_ok=True)
    source = CACHE / 'src'
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir()
    archive = subprocess.run(['git', 'archive', 'HEAD'], cwd=ROOT, check=True, capture_output=True).stdout
    subprocess.run(['tar', '-x', '-C', source], input=archive, check=True)
    (source / 'Probe').mkdir()
    # Not main.swift: that name may not hold @main.
    shutil.copyfile(ROOT / 'scripts/perf/SearchProbe.swift', source / 'Probe/SearchProbe.swift')
    with open(source / 'Package.swift', 'a') as package:
        package.write(PROBE_TARGET)

    scratch = CACHE / 'scratch'
    if args.ui:
        build_ui_probe(source, scratch, args.ui.resolve())
    if args.ui_only:
        return
    run(['xcrun', 'swift', 'build', '--package-path', source, '--scratch-path', scratch, '--sdk', sdk_path(),
         '-c', 'release', '-Xswiftc', '-enable-testing', '--product', 'SearchProbe'])
    binary = scratch / 'release/SearchProbe'

    with tempfile.TemporaryDirectory(prefix='switchboard-search-bench-') as directory:
        work = Path(directory)
        os.chmod(work, 0o700)
        env = {**os.environ, 'SEARCH_PROBE_REPORT': str(output), 'SEARCH_PROBE_CHATS': str(args.chats),
               'SEARCH_PROBE_MESSAGES': str(args.messages), 'SEARCH_PROBE_REPEATS': str(args.repeats),
               'TMPDIR': str(work)}
        paths = work / 'repo-paths.txt'
        paths.write_text(subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True))
        env['SEARCH_PROBE_REPO_PATHS'] = str(paths)
        if args.no_synthetic:
            env['SEARCH_PROBE_SKIP_SYNTHETIC'] = '1'
        if not args.no_real:
            real = work / 'real'
            real.mkdir(mode=0o700)
            copy_databases(real)
            env['SEARCH_PROBE_REAL_DIR'] = str(real)
        run(['/usr/bin/time', '-l', binary], env=env)
    report = json.loads(output.read_text())
    report['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(output)


if __name__ == '__main__':
    main()
