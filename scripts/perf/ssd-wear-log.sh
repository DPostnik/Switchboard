#!/bin/zsh
# Append one line of SSD wear and swap counters to ~/Library/Logs/Switchboard/ssd-wear.log.
# Daily deltas of "written" show the whole machine's SSD writes (builds, swap, apps).
# Called by scripts/nightly-tests.sh; safe to run by hand. Needs smartctl (Homebrew
# smartmontools); without it the script does nothing.
set -uo pipefail
smartctl=$(command -v smartctl || ls /opt/homebrew/bin/smartctl /usr/local/bin/smartctl 2>/dev/null | head -1)
[[ -x ${smartctl:-} ]] || exit 0
log="$HOME/Library/Logs/Switchboard/ssd-wear.log"
mkdir -p "${log:h}"
attributes=$("$smartctl" -A disk0 2>/dev/null) || exit 0
value() { print -r -- "$attributes" | awk -F: -v key="$1" '$1 == key { gsub(/[ ,%]|\[.*/, "", $2); print $2 }'; }
# One NVMe data unit is 512,000 bytes.
units=$(value 'Data Units Written')
[[ -n $units ]] || exit 0
swapouts=$(vm_stat | awk -F: '/Swapouts/ { gsub(/[ .]/, "", $2); print $2 }')
swap=$(sysctl -n vm.swapusage | awk '{ print $6 }')
print -r -- "$(date +%Y-%m-%dT%H:%M:%S) written_gb=$(( units * 512000 / 1000000000 )) used_pct=$(value 'Percentage Used') power_on_h=$(value 'Power On Hours') critical_warning=$(value 'Critical Warning') media_errors=$(value 'Media and Data Integrity Errors') spare_pct=$(value 'Available Spare') swap_used=$swap swapouts_pages=$swapouts" >>"$log"
