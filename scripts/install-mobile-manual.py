#!/usr/bin/env python3
"""Build without account access, then sign using the existing codesign mediator.

Uses an already-issued device profile. Does not renew profiles or export keys.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import subprocess


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=repo)
    parser.add_argument('--udid', default='00008140-0016658A0E13001C')
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--sign-only', action='store_true', help='build and verify the signature without device installation')
    args = parser.parse_args()
    if args.sign_only and args.launch:
        parser.error('--sign-only cannot be combined with --launch')
    if os.environ.get('SWITCHBOARD_EXTERNAL_SANDBOX') == '1' and not args.sign_only:
        parser.error('Inside the external boundary use --sign-only, then the app-owned install_mobile_app tool.')
    source = args.source.resolve(strict=True)
    derived = repo / '.build/mobile-device'
    logs = repo / '.build/mobile-manual-signing'
    logs.mkdir(parents=True, exist_ok=True)
    load = runpy.run_path(str(repo / 'scripts/mobile-profile.py'))['load']
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    available = set(re.findall(r'\b[0-9A-F]{40}\b', identities))
    # Entitlements the source requires (Mobile/ContextMobile.entitlements, e.g. aps-environment). The signature still
    # takes its entitlements from the profile, so an older profile without them would silently sign an app without push.
    required_path = source / 'Mobile/ContextMobile.entitlements'
    required = plistlib.loads(required_path.read_bytes()) if required_path.exists() else {}
    profiles, lacking = [], set()
    for path in (Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles').glob('*.mobileprovision'):
        profile = load(path)
        entitlements = profile.get('Entitlements', {})
        if (entitlements.get('application-identifier') != '4M74WJDNSW.com.contextdesk.mobile'
                or args.udid not in profile.get('ProvisionedDevices', [])
                or profile['ExpirationDate'].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)):
            continue
        missing = sorted(key for key, value in required.items() if entitlements.get(key) != value)
        if missing:
            lacking.update(missing)
            continue
        matching = sorted({hashlib.sha1(cert).hexdigest().upper()
                           for cert in profile.get('DeveloperCertificates', [])} & available)
        if matching:
            profiles.append((profile['ExpirationDate'], path, profile, matching[0]))
    if not profiles and lacking:
        raise SystemExit('The device profile lacks entitlements required by Mobile/ContextMobile.entitlements: '
                         + ', '.join(sorted(lacking)) + '. Enable the capabilities for the App ID and refresh the profile through Xcode.')
    if not profiles:
        raise SystemExit('No valid device profile and matching signing identity. Provision through Xcode first.')
    _, profile_path, profile, identity = max(profiles, key=lambda item: item[0])
    entitlements = dict(profile['Entitlements'])
    entitlements['keychain-access-groups'] = [group.replace('*', 'com.contextdesk.mobile')
                                             for group in entitlements.get('keychain-access-groups', [])]
    if any('*' in str(value) for value in entitlements.values()):
        raise SystemExit('Unsupported wildcard entitlement; refusing to invent app permissions.')
    entitlements_path = logs / 'entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    lock = Path.home() / 'Library/Caches/Switchboard/build.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    # Both compilation and macro execution stay inside the caller's boundary.
    # Only the compiler's nested sandbox is disabled (PERMISSIONS.md invariant 8).
    command = ['lockf', str(lock), 'xcodebuild', '-project', str(source / 'Mobile/ContextMobile.xcodeproj'),
               '-scheme', 'ContextMobile', '-configuration', 'Debug',
               '-destination', 'generic/platform=iOS', '-derivedDataPath', str(derived),
               'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
               'OTHER_SWIFT_FLAGS=-Xfrontend -disable-sandbox', 'clean', 'build']
    print('Building unsigned iPhone app; log: .build/mobile-manual-signing/build.log', flush=True)
    with (logs / 'build.log').open('w') as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    app = derived / 'Build/Products/Debug-iphoneos/ContextMobile.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'com.contextdesk.mobile':
        raise SystemExit('Unexpected bundle identifier.')
    shutil.copyfile(profile_path, app / 'embedded.mobileprovision')
    # Deliberately use PATH, not /usr/bin/codesign: Developer uses nono's broker shim.
    nested = list(app.rglob('*.dylib')) + list(app.rglob('*.framework'))
    if list(app.rglob('*.appex')) or list(app.rglob('*.app')):
        raise SystemExit('Nested app/extension requires its own profile; refusing to reuse the main profile.')
    for item in sorted(nested, key=lambda item: len(item.parts), reverse=True):
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(item)], check=True)
    subprocess.run(['codesign', '--force', '--sign', identity, '--entitlements', str(entitlements_path),
                    '--generate-entitlement-der', '--timestamp=none', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    if args.sign_only:
        print('Signature verified. Device installation was not requested.', flush=True)
        return
    print('Signature verified. Installing once; no automatic retries.', flush=True)
    subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.udid, str(app)], env=env, check=True)
    if args.launch:
        subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.udid,
                        'com.contextdesk.mobile'], env=env, check=True)
    print('iPhone installation completed.', flush=True)


if __name__ == '__main__':
    main()
