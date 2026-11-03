#!/usr/bin/env python3
"""Measure context-menu cost with a standalone AppKit/SwiftUI probe (no app modules, no agents, no app state).

Builds scripts/perf/ContextMenuProbe.swift with swiftc -O into its own temporary directory (never .build/ or
build/), runs it and writes a JSON report. It briefly shows its own window and pops (and immediately cancels)
its own context menus; it does not touch a running Switchboard.

Usage: python3 scripts/perf/profile-context-menus.py OUTPUT.json [--only builders|transcript|sidebar|rows] [--lang en|ru]
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--only', choices=['builders', 'transcript', 'sidebar', 'rows'])
    parser.add_argument('--lang', choices=['ru', 'en'], default='ru')
    args = parser.parse_args()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='switchboard-menu-probe-') as directory:
        executable = Path(directory) / 'ContextMenuProbe'
        subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library', '-swift-version', '5',
                        str(ROOT / 'scripts/perf/ContextMenuProbe.swift'), '-o', str(executable)], check=True)
        output = args.output.resolve()
        env = {**os.environ, 'SWITCHBOARD_MENU_REPORT': str(output), 'PROBE_LANG': args.lang}
        if args.only:
            env['PROBE_ONLY'] = args.only
        subprocess.run([str(executable)], env=env, check=True, cwd=directory)
    report = json.loads(output.read_text())
    report['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    report['compiler'] = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True, stderr=subprocess.STDOUT).strip()
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    for row in report['results']:
        print(json.dumps(row, ensure_ascii=False))
    print(output)


if __name__ == '__main__':
    main()
