#!/bin/zsh
# Build, sign and install the iPhone app over Wi-Fi. A Personal Team profile lasts 7 days and Xcode reuses
# a cached one until it expires, so a profile with under 3 days left is moved aside first: Xcode then
# fetches a fresh one (restored if the build fails).
#   zsh scripts/install-mobile.sh               the working copy, always installs
#   zsh scripts/install-mobile.sh --scheduled   committed main in a private worktree, only when the last
#                                               installed profile has under 3 days left (launchd job,
#                                               scripts/install-mobile-resign.sh); add --force to install anyway
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${SWITCHBOARD_IPHONE_UDID:-00008140-0016658A0E13001C}"
APP_ID=4M74WJDNSW.com.contextdesk.mobile
RENEW_BELOW=$((3 * 86400))
LOGS="$HOME/Library/Logs/Switchboard/mobile-install"
STATE="$LOGS/installed-expiry"
CACHE="$HOME/Library/Caches/Switchboard/mobile-install"
scheduled=0 force=0
for arg in "$@"; do
  case $arg in
    --scheduled) scheduled=1 ;;
    --force) force=1 ;;
    *) print -u2 "usage: install-mobile.sh [--scheduled [--force]]"; exit 2 ;;
  esac
done
mkdir -p "$LOGS"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
profile() { python3 -I "$REPO/scripts/mobile-profile.py" "$@"; }
log() { print -r -- "$(date +%Y-%m-%dT%H:%M:%S) $*"; }
day() { date -r "$1" '+%Y-%m-%d %H:%M'; }
notify() {
  osascript -e "display notification \"${2//\"/}\" with title \"Switchboard iPhone: $1\"" >/dev/null 2>&1
}
fail() {
  log "failed: $1"
  print -r -- "failed $(date +%Y-%m-%dT%H:%M:%S) $1" >"$LOGS/latest-status"
  (( scheduled )) && notify "re-sign failed" "$1"
  exit 1
}

now=$(date +%s)
if (( scheduled && !force )) && [[ -s $STATE ]]; then
  left=$(( $(<"$STATE") - now ))
  if (( left >= RENEW_BELOW )); then
    log "not due: installed profile valid until $(day $(<"$STATE"))"
    exit 0
  fi
fi

if ! xcrun devicectl list devices 2>/dev/null | grep -F "$UDID" | grep -q 'available'; then
  # Not reachable over Wi-Fi now; launchd tries again later. Warn once the app is about to stop opening.
  log "skipped: iPhone $UDID is not available"
  if (( scheduled )) && [[ -s $STATE ]] && (( $(<"$STATE") - now < 86400 )); then
    notify "re-sign pending" "The iPhone is not reachable; the app stops opening at $(day $(<"$STATE"))."
  fi
  (( scheduled )) && exit 0 || exit 1
fi

if (( scheduled )); then
  SRC="$CACHE/worktree"
  mkdir -p "$CACHE"
  if [[ ! -e "$SRC/.git" ]]; then
    git -C "$REPO" worktree prune
    git -C "$REPO" worktree add --detach "$SRC" main || fail "worktree setup"
  fi
  git -C "$SRC" checkout --detach --force main && git -C "$SRC" clean -fdq || fail "worktree checkout"
  DERIVED="$CACHE/DerivedData"
else
  SRC="$REPO"
  DERIVED="$REPO/.build/mobile-device"
fi
APP="$DERIVED/Build/Products/Debug-iphoneos/ContextMobile.app"
log "source $SRC @ $(git -C "$SRC" rev-parse --short HEAD)"

# Move near-expiry cached profiles aside so Xcode requests a fresh 7-day one.
backup="$CACHE/profile-backup"
moved=()
profile cached "$APP_ID" | while read -r expiry file; do
  if (( expiry - now < RENEW_BELOW )); then
    mkdir -p "$backup" && mv "$file" "$backup/" && moved+=("${file:t}")
    log "renewing: cached profile ${file:t} expires $(day $expiry)"
  fi
done
restore() { for name in $moved; do mv "$backup/$name" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/" 2>/dev/null; done; }

action=(build)
(( ${#moved} )) && action=(clean build)  # an incremental build after renewal left an invalid seal before
log "xcodebuild ${action[*]}"
# The shared build lock keeps this from competing with other agents' builds and test runs.
mkdir -p "$HOME/Library/Caches/Switchboard"
if ! (cd "$SRC" && lockf "$HOME/Library/Caches/Switchboard/build.lock" \
    xcodebuild -project Mobile/ContextMobile.xcodeproj -scheme ContextMobile -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration $action) >"$LOGS/xcodebuild.log" 2>&1; then
  restore
  fail "xcodebuild failed, see $LOGS/xcodebuild.log ($(grep -m1 -E 'error:' "$LOGS/xcodebuild.log"))"
fi
codesign --verify --deep --strict "$APP" 2>>"$LOGS/xcodebuild.log" || fail "codesign verification failed"
profile has-device "$APP/embedded.mobileprovision" "$UDID" || fail "profile does not include iPhone $UDID"
expiry=$(profile expiry "$APP/embedded.mobileprovision") || fail "cannot read the embedded profile"
(( expiry - now >= RENEW_BELOW )) || { restore; fail "Xcode did not renew the profile (expires $(day $expiry)); check Xcode -> Settings -> Accounts"; }
rm -rf "$backup"

# A first attempt can fail before the network tunnel is up; replacing the app is safe to try once more.
installed=0
for attempt in 1 2; do
  if xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOGS/xcodebuild.log" 2>&1; then installed=1; break; fi
  log "install attempt $attempt failed"
  sleep 20
done
(( installed )) || fail "devicectl install failed, see $LOGS/xcodebuild.log"
print -r -- "$expiry" >"$STATE"
print -r -- "installed $(date +%Y-%m-%dT%H:%M:%S) valid until $(day $expiry)" >"$LOGS/latest-status"
log "installed com.contextdesk.mobile; profile valid until $(day $expiry)"
(( scheduled )) && notify "re-signed" "The app is installed and works until $(day $expiry)."
exit 0
