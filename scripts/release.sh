#!/bin/zsh
# Cut a release from main: rotate CHANGELOG.md, write VERSION, commit, build the app
# with the new identity, tag vX.Y.Z and push the branch with the tag.
#
#   zsh scripts/release.sh 1.1.0             # full release
#   zsh scripts/release.sh 1.1.0 --no-push   # commit, build and tag only
#   zsh scripts/release.sh 1.1.0 --dry-run   # checks and the rotated changelog, no changes
#
# Preconditions: on main, clean working tree, "## [Unreleased]" in CHANGELOG.md is not empty,
# the version is greater than VERSION and tag vX.Y.Z does not exist. A failed build leaves the
# release commit in place without a tag or push; fix forward and rerun with the same version
# only after `git reset --soft HEAD~1` (the script refuses an existing VERSION).
set -euo pipefail
cd "$(dirname "$0")/.."

version=""; push=true; dry=false
for arg in "$@"; do
  case "$arg" in
    --no-push) push=false ;;
    --dry-run) dry=true ;;
    -*) print -u2 "release: unknown option $arg"; exit 2 ;;
    *) version="$arg" ;;
  esac
done
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "usage: zsh scripts/release.sh X.Y.Z [--no-push] [--dry-run]"; exit 2
fi
current="$(tr -d '[:space:]' < VERSION)"
if [[ "$version" == "$current" ]]; then print -u2 "release: VERSION is already $version"; exit 1; fi
if [[ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" != "$version" ]]; then
  print -u2 "release: $version is not newer than $current"; exit 1
fi
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then print -u2 "release: switch to main (current branch: $branch)"; exit 1; fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then print -u2 "release: tag v$version already exists"; exit 1; fi
if [[ -n "$(git status --porcelain)" ]]; then print -u2 "release: the working tree is not clean"; exit 1; fi
python3 scripts/changelog.py unreleased >/dev/null || { print -u2 "release: nothing under \"## [Unreleased]\" in CHANGELOG.md"; exit 1; }

if $dry; then
  print "release: dry run for $version (current $current, branch $branch, tag v$version free)"
  python3 scripts/changelog.py rotate "$version" --print | diff -u CHANGELOG.md - || true
  exit 0
fi

python3 scripts/changelog.py rotate "$version"
print "$version" > VERSION
git add VERSION CHANGELOG.md
git commit -q -m "Release $version"
print "release: committed $(git rev-parse --short HEAD) Release $version"

zsh scripts/build-app.sh
git tag -a "v$version" -m "Switchboard $version"
print "release: tagged v$version"
if $push; then
  git push origin main "v$version"
  print "release: pushed main and v$version"
else
  print "release: not pushed (--no-push); run: git push origin main v$version"
fi
