#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Switchboard.app"
codesign --verify --deep --strict "$app"
python3 - "$app" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path.cwd()
app = pathlib.Path(sys.argv[1])
metadata = json.loads((app / 'Contents/Resources/build-info.json').read_text())
digest = hashlib.sha256()
browser_resources = [root / 'BrowserRuntime' / name for name in
                     ('server.py', 'broker.py', 'transport.py', 'chrome_host.py', 'cdp.py', 'page_input.py', 'install.py', 'cards.js', 'page_read.js', 'page_tree.js', 'runtime.lock.json', 'README.md')]
for path in sorted([root / 'Package.swift', root / 'Package.resolved'] + list((root / 'Sources').rglob('*')) + browser_resources):
    if path.is_file():
        digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes())
if digest.hexdigest() != metadata['sourceSHA256']:
    sys.exit('App does not match current sources. Run zsh scripts/build-app.sh --release first.')
if metadata.get('configuration', 'release') != 'release':
    sys.exit('App is a debug build. Run zsh scripts/build-app.sh --release first.')
PY
mkdir -p dist
archive="$PWD/dist/Switchboard-macOS.zip"
staging="$(mktemp -d "$PWD/dist/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/Switchboard-macOS.zip"
unzip -tq "$staging/Switchboard-macOS.zip"
mv "$staging/Switchboard-macOS.zip" "$archive"
shasum -a 256 "$archive"
