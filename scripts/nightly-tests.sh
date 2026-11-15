#!/bin/zsh
# Full test suite against the committed tip of main, in a private worktree so
# uncommitted agent work and the main .build are never touched. Run daily by
# launchd (scripts/install-nightly-tests.sh); safe to run by hand.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${SWITCHBOARD_NIGHTLY_BRANCH:-main}"
WORK="$HOME/Library/Caches/Switchboard/nightly-tests/worktree"
LOGS="$HOME/Library/Logs/Switchboard/nightly-tests"
mkdir -p "$LOGS" "${WORK:h}"
# One line per day of SSD wear counters, before the suite adds its own writes.
zsh "$REPO/scripts/perf/ssd-wear-log.sh"
# On battery macOS keeps the sleeping Mac only in short DarkWake windows: on 2026-11-15
# the build took 2.8 hours and tests with timeouts failed across sleep. Skip such nights
# instead of reporting false failures; keep the previous result in the status line.
if ! pmset -g batt 2>/dev/null | head -1 | grep -q "'AC Power'"; then
  previous=$(head -1 "$LOGS/latest-status" 2>/dev/null)
  [[ $previous == skipped:* ]] && previous=${${(M)previous:#*\| last run: *}#*\| last run: }
  echo "skipped: battery $(date +%Y-%m-%dT%H:%M:%S)${previous:+ | last run: $previous}" >"$LOGS/latest-status"
  exit 0
fi
stamp=$(date +%Y-%m-%d_%H%M)
log="$LOGS/$stamp.log"

{
  if [[ ! -d "$WORK/.git" && ! -f "$WORK/.git" ]]; then
    git -C "$REPO" worktree prune
    git -C "$REPO" worktree add --detach "$WORK" "$BRANCH"
  fi
  git -C "$WORK" checkout --detach --force "$BRANCH" && git -C "$WORK" clean -fdq -e .build
} >"$log" 2>&1
commit=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "Nightly full suite: $BRANCH @ $commit, $(date)" >>"$log"

start=$SECONDS
# caffeinate holds the Mac awake (system sleep is preventable on AC power only) for the suite.
(cd "$WORK" && caffeinate -i -s zsh scripts/test.sh --verbose) >>"$log" 2>&1
code=$?
summary=$(grep -m1 ' Test run with ' "$log" || grep -E '^FAILED|error:' "$log" | tail -1)
flaky=$(grep -m1 '^FLAKY' "$log" | sed 's/\. Not a regression.*//')
if [[ $code != 0 ]]; then result=failed; elif [[ -n $flaky ]]; then result=flaky; else result=passed; fi
[[ -n $flaky ]] && summary="$summary | $flaky"
echo "$result $commit $(date +%Y-%m-%dT%H:%M:%S) $((SECONDS - start))s ${summary}" >"$LOGS/latest-status"
ln -sf "$log" "$LOGS/latest.log"
# Keep two weeks of logs.
ls -1t "$LOGS"/*.log(N) | tail -n +15 | xargs rm -f 2>/dev/null

if [[ $result != passed ]]; then
  # Posted by Switchboard so a click opens latest.log; osascript (opens Script Editor) is the fallback.
  app="$REPO/build/Switchboard.app/Contents/MacOS/Switchboard"
  [[ -x $app ]] && "$app" --nightly-tests-report "$result" "$commit: $summary" >/dev/null 2>&1 ||
  osascript -e "display notification \"$commit: ${summary//\"/}\" with title \"Switchboard: nightly tests $result\"" >/dev/null 2>&1
fi
# Upstream agent CLI check (seconds; skipped on battery). Live no-inference tests only for a newly installed,
# unverified version and only when the suite built and passed. Writes compat-status next to latest-status.
live=(); [[ $result != passed ]] && live=(--no-live)
{ echo; echo "Compatibility check, $(date)"; } >>"$log"
[[ -f "$WORK/scripts/compat-check.py" ]] && python3 -I "$WORK/scripts/compat-check.py" --worktree "$WORK" --app "$REPO/build/Switchboard.app/Contents/MacOS/Switchboard" $live >>"$log" 2>&1
exit $code
