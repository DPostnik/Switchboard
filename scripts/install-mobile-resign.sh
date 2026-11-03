#!/bin/zsh
# Install (or with --uninstall remove) the launchd job that keeps the iPhone app signed: every 6 hours
# it runs install-mobile.sh --scheduled, which only builds when the profile has under 3 days left.
# A Mac asleep at the scheduled time runs the job on wake.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=local.daniil.switchboard.mobile-resign
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == --uninstall ]]; then rm -f "$PLIST"; echo "Removed $LABEL"; exit 0; fi
mkdir -p "${PLIST:h}" "$HOME/Library/Logs/Switchboard/mobile-install"
cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$REPO/scripts/install-mobile.sh</string><string>--scheduled</string></array>
  <key>StartInterval</key><integer>21600</integer>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string></dict>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Switchboard/mobile-install/launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Switchboard/mobile-install/launchd.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL: every 6 hours. Status: ~/Library/Logs/Switchboard/mobile-install/latest-status"
