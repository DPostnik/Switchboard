#!/usr/bin/env python3
"""Run the fixed lightweight verification workflow suites; never build the app."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SUITES = (
    'scripts/test-verification-queue.py',
    'scripts/test-verification-snapshot.py',
    'scripts/test-verify-project.py',
    'scripts/test-verification-integration.py',
)


def main():
    for suite in SUITES:
        print(f'Checking {suite}', flush=True)
        result = subprocess.run([sys.executable, '-B', suite], cwd=ROOT)
        if result.returncode:
            return result.returncode
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
