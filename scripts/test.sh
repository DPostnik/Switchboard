#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-agent-boundary.py
for check in scripts/test-changelog.py scripts/test-schedule-control.py scripts/test-job-browser-import.py scripts/test-compat-check.py scripts/test-access-review.py scripts/test-project-diagnostics.py; do
  python3 -B "$check" >/dev/null 2>&1 || { print -u2 "$check failed; rerun: python3 $check"; exit 1; }
done
python3 scripts/swift-task.py test "$@"
