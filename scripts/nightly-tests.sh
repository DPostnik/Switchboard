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
(cd "$WORK" && zsh scripts/test.sh --verbose) >>"$log" 2>&1
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
exit $code
