#!/usr/bin/env python3
"""Measure synthetic native UI CPU without live agents, credentials or chat history.

Run scripts/build-app.sh first, then this script with an output JSON path. Release
modules are rebuilt with testing access solely to link the standalone harness.
The harness uses NSApplication.run(); Swift Testing CPU is not a UI baseline.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    info = json.loads((ROOT / '.build/local-build/build-info.json').read_text())
    sdk = info['sdk']
    run(['xcrun', 'swift', 'test', '--sdk', sdk, '-c', 'release', '--disable-xctest',
         '--force-resolved-versions', '--filter', '^$'])
    # Xcode's SwiftPM backend emits testable executable objects separately.
    release = ROOT / '.build/out/Products/Release'
    intermediate = ROOT / '.build/out/Intermediates.noindex/ContextDesk.build/Release'
    objects = list(intermediate.glob('ContextDesk--*-testable-t.build/Objects-normal/*/*.o'))
    if objects:
        objects += [release / (name + '.o') for name in
                    ['AgentContract', 'ContextCore', 'ContextTranscript', 'ClaudeAdapter', 'CodexAdapter', 'FringeProtocol', 'TOMLDecoder']]
        includes = [release]
    else:
        # Standard SwiftPM backend.
        bin_path = subprocess.check_output(['xcrun', 'swift', 'build', '--sdk', sdk, '-c', 'release', '--show-bin-path'],
                                           cwd=ROOT, text=True).strip()
        release = Path(bin_path)
        objects = [p for name in ['ContextDesk', 'AgentContract', 'ContextCore', 'ContextTranscript',
                                 'ClaudeAdapter', 'CodexAdapter', 'FringeProtocol', 'TOMLDecoder']
                   for p in (release / (name + '.build')).glob('*.o')]
        includes = [release / 'Modules']
    if not objects or not all(p.is_file() for p in objects):
        raise RuntimeError('Release object layout unavailable; no measurement was made.')
    with tempfile.TemporaryDirectory(prefix='context-desk-cpu-') as directory:
        executable = Path(directory) / 'TranscriptCPUProbe'
        command = ['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library']
        for include in includes:
            command += ['-I', include]
        command += ['-Xcc', '-fmodule-map-file=' + str(ROOT / 'Sources/CSQLite/module.modulemap'),
                    ROOT / 'scripts/TranscriptCPUProbe.swift', *objects, '-lsqlite3', '-o', executable]
        run(command)
        output = args.output.resolve()
        run([executable], env={**os.environ, 'SWITCHBOARD_CPU_REPORT': str(output)})
        report = json.loads(output.read_text())
        digest = hashlib.sha256()
        for source in sorted((ROOT / 'Sources').rglob('*.swift')):
            digest.update(str(source.relative_to(ROOT)).encode())
            digest.update(source.read_bytes())
        report['source_sha256'] = digest.hexdigest()
        report['sdk'] = sdk
        report['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        report['tracked_changes'] = subprocess.check_output(['git', 'diff', 'HEAD', '--stat'], cwd=ROOT, text=True).strip()
        output.write_text(json.dumps(report, indent=2) + '\n')
        for row in report['scenarios']:
            print(f"{row['scenario']}: {row['cpu_percent_one_core']:.2f}% CPU, "
                  f"{row['workspace_publications']} workspace publications, "
                  f"occluded={row['window_occluded']}")
        print(output)


if __name__ == '__main__':
    main()
