"""Read Personal Team provisioning profiles for scripts/install-mobile.sh.

  expiry PROFILE            print the expiry as epoch seconds
  has-device PROFILE UDID   exit 0 when the profile lists the device
  cached APP_ID             print "epoch path" for each cached Xcode profile of APP_ID
"""
import plistlib
import sys
from datetime import timezone
from pathlib import Path

CACHE = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'


def load(path):
    # The profile is a CMS envelope around a plain XML plist; no `security` call is needed.
    data = Path(path).read_bytes()
    start, end = data.find(b'<?xml'), data.find(b'</plist>')
    if start < 0 or end < 0:
        raise SystemExit(f'not a provisioning profile: {path}')
    return plistlib.loads(data[start:end + len(b'</plist>')])


def epoch(profile):
    # plistlib returns naive UTC datetimes; timestamp() alone would read them as local time.
    return int(profile['ExpirationDate'].replace(tzinfo=timezone.utc).timestamp())


def main(argv):
    command, *args = argv
    if command == 'expiry':
        print(epoch(load(args[0])))
    elif command == 'has-device':
        return 0 if args[1] in load(args[0]).get('ProvisionedDevices', []) else 1
    elif command == 'cached':
        for path in sorted(CACHE.glob('*.mobileprovision')):
            profile = load(path)
            if profile.get('Entitlements', {}).get('application-identifier') == args[0]:
                print(epoch(profile), path)
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
