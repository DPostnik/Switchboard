#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/swift-task.py build "$@"
zsh scripts/build-icon.sh
staging="$(mktemp -d "$PWD/build/app-stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Switchboard.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/local-build/ContextDesk "$app/Contents/MacOS/Switchboard"
cp .build/local-build/build-info.json "$app/Contents/Resources/build-info.json"
cp Assets/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
mkdir -p "$app/Contents/Resources/BrowserRuntime"
cp BrowserRuntime/{server.py,broker.py,transport.py,chrome_host.py,profiles.py,cdp.py,page_input.py,install.py,cards.js,page_read.js,page_tree.js,runtime.lock.json,README.md} "$app/Contents/Resources/BrowserRuntime/"
cp -R Skills "$app/Contents/Resources/Skills"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Switchboard</string>
<key>CFBundleDisplayName</key><string>Switchboard</string>
<key>CFBundleIdentifier</key><string>local.daniil.switchboard</string>
<key>CFBundleExecutable</key><string>Switchboard</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.daniil.switchboard.project-order</string>
<key>UTTypeDescription</key><string>Switchboard project order</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict><dict>
<key>UTTypeIdentifier</key><string>local.daniil.switchboard.chat-order</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
# A stable identity keeps the designated requirement unchanged across builds, so macOS
# privacy grants (Screen Recording, Accessibility, Keychain "Always Allow") survive rebuilds.
# Ad-hoc signatures pin grants to the cdhash, which changes on every build.
identity="${SWITCHBOARD_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk '/"Apple Development: /{print $2; exit}')"
fi
if [[ -n "$identity" && "$identity" != "-" ]]; then
  codesign --force --timestamp=none --sign "$identity" "$app"
else
  print -u2 "warning: no Apple Development identity; signing ad-hoc, so macOS privacy grants reset on every build"
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
python3 - "$app" <<'PY'
from pathlib import Path
import ctypes
import os
import shutil
import subprocess
import sys
import time

staged = Path(sys.argv[1])
destination = Path('build/Switchboard.app')
# A running app keeps its replaced bundle until it exits: system services (the
# open panel among them) validate the host's code signature from disk and fail
# once the executable is deleted, which hangs NSOpenPanel.runModal.
replaced = Path('build/.replaced')
backup = replaced / f'Switchboard-{time.time_ns()}.app'

def running_executables():
    # Not pgrep: it skips its own ancestors, and agents run this script under Switchboard.
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    pids = subprocess.run(['/bin/ps', '-axo', 'pid='], capture_output=True, text=True, check=True).stdout.split()
    paths = set()
    for pid in pids:
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(pid), buffer, len(buffer)) > 0:
            paths.add(os.path.realpath(buffer.value.decode()))
    return paths

if destination.exists():
    replaced.mkdir(parents=True, exist_ok=True)
    destination.rename(backup)
try:
    staged.rename(destination)
except BaseException:
    if backup.exists():
        backup.rename(destination)
    raise
if replaced.exists():
    in_use = running_executables()
    for bundle in replaced.iterdir():
        prefix = os.path.realpath(bundle) + os.sep
        if not any(path.startswith(prefix) for path in in_use):
            shutil.rmtree(bundle, ignore_errors=True)
print(f'Updated: {destination.resolve()}')
print('Quit the running app with Cmd+Q and reopen it to load this build.')
PY
