#!/usr/bin/env python3
"""Option 1 runtime gate for the pinned nono helper, without Codex.

Session sandbox = project + toolchain caches (union); command mediation only for commands that need
the Keychain, a browser or loopback network. Each check prints PASS/FAIL and the summary is written to
docs/handoffs/permission-runtime-2026-11-11/nono-runtime-results.json. Run outside an enclosing
Seatbelt sandbox; it creates disposable folders under .build (not /tmp) and removes them.
"""
import argparse
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import signal
import subprocess
import tempfile
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import nono_git_policy  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--nono', required=True, help='Verified helper from prepare-nono.py')
parser.add_argument('--skip-chrome', action='store_true')
parser.add_argument('--skip-swiftpm', action='store_true')
parser.add_argument('--skip-network', action='store_true')
args = parser.parse_args()

ROOT = pathlib.Path(__file__).resolve().parent.parent
NONO = str(pathlib.Path(args.nono).resolve())
OUT = ROOT / 'docs/handoffs/permission-runtime-2026-11-11'
OUT.mkdir(parents=True, exist_ok=True)
HOME = pathlib.Path.home()
DEVELOPER = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
TOOLCHAIN = DEVELOPER / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
SWIFTPM_CACHES = [HOME / 'Library/Caches/org.swift.swiftpm', HOME / 'Library/org.swift.swiftpm', HOME / '.swiftpm']
PATH = '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin'
REPO = ROOT
GIT_EXEC = subprocess.check_output(['/opt/homebrew/bin/git', '--exec-path'], text=True).strip()
GH = shutil.which('gh', path=PATH)
# The user's commit identity, compared by hash inside the sandbox: never printed. Empty when no global name is set.
_name = subprocess.run(['/opt/homebrew/bin/git', 'config', '--global', 'user.name'], capture_output=True, text=True).stdout.strip()
NAME_HASH = hashlib.sha256((_name + '\n').encode()).hexdigest() if _name else ''
ORIGIN = subprocess.run(['/opt/homebrew/bin/git', '-C', str(REPO), 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout.strip()
# /usr/bin/python3 is a stub that execs the selected developer-tools interpreter by absolute path; a command
# policy must pin that real file (macOS has no exec_paths) and allow its direct execution from the session.
PYTHON = subprocess.check_output(['/usr/bin/python3', '-c', 'import os,sys;print(os.path.realpath(sys.executable))'], text=True).strip()
# A framework build's bin/python3.X re-execs Resources/Python.app/Contents/MacOS/Python; the command sandbox allows only
# the pinned file, so the policy pins that final binary (it runs scripts directly).
_app = pathlib.Path(PYTHON).parent.parent / 'Resources/Python.app/Contents/MacOS/Python'
if _app.is_file():
    PYTHON = str(_app)
# nono forwards SIGTERM to its direct child only. The launcher puts the whole tree in its own process group so
# revocation can signal the group (the app does the same through a setsid launcher).
SETSID = ['/usr/bin/python3', '-I', '-c', 'import os,sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])']

(ROOT / '.build/nono-integration').mkdir(parents=True, exist_ok=True)
fixture = pathlib.Path(tempfile.mkdtemp(prefix='runtime-', dir=ROOT / '.build/nono-integration')).resolve()
results = {}
checks = []
STATE_DIRS = []
# A throwaway generic-password item for the named-item checks (`KeychainItemRule`). Created and deleted outside the sandbox by
# `security` itself, so its ACL trusts `/usr/bin/security`. The value is random; only its SHA-256 enters the sandboxed script,
# and the probe prints yes/no, never the value.
PROBE_SERVICE = 'switchboard-probe-' + secrets.token_hex(6)
PROBE_ACCOUNT = 'switchboard-probe'
PROBE_SECRET = secrets.token_hex(16)
PROBE_HASH = hashlib.sha256(PROBE_SECRET.encode()).hexdigest()


def check(name, ok, detail=''):
    checks.append({'name': name, 'ok': bool(ok), 'detail': detail})
    print(('PASS ' if ok else 'FAIL ') + name + (': ' + detail if detail else ''), flush=True)


def environment(case):
    # nono refuses a grant that contains its own state root, so its XDG folders live outside every granted tree.
    state_root = HOME / 'Library/Application Support/Switchboard/nono'
    state_root.mkdir(parents=True, exist_ok=True)
    state = pathlib.Path(tempfile.mkdtemp(prefix='probe-state-', dir=str(state_root)))
    env = {'HOME': str(HOME), 'PATH': PATH, 'TMPDIR': str(case / 'tmp'), 'XDG_CONFIG_HOME': str(state / 'config'),
           'XDG_STATE_HOME': str(state / 'state'), 'XDG_CACHE_HOME': str(state / 'xdg-cache'), 'LANG': 'en_US.UTF-8', 'TERM': 'dumb'}
    for key in ['config', 'state', 'xdg-cache']:
        (state / key).mkdir(exist_ok=True)
    (case / 'tmp').mkdir(exist_ok=True)
    STATE_DIRS.append(state)
    return env


def make_case(name):
    case = fixture / name
    for sub in ['project', 'other', 'cache', 'profiles', 'resources']:
        (case / sub).mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(case / 'project')], check=True)
    subprocess.run(['git', 'init', '-q', str(case / 'other')], check=True)
    return case


def GIT_FS(case):
    return {'fs_read': [str(case / 'project'), str(case / 'tmp'), str(REPO), str(HOME / '.config/git'), '/opt/homebrew'],
            'fs_read_file': [str(HOME / '.gitconfig')], 'fs_write': [str(case / 'project'), str(case / 'tmp')], 'fs_write_file': []}


def policy(case, browser_port):
    """Command mediation: keychain for `security`, a browser command for the app's MCP server, Xcode tools by absolute path."""
    profiles = case / 'profiles'
    return {
        'meta': {'name': 'switchboard-runtime-probe', 'version': '1'},
        'workdir': {'access': 'none'},
        'command_policies': {
            'executable_dirs': [str(TOOLCHAIN), str(DEVELOPER / 'usr/bin')],
            'commands': {
                # The app's narrowed shape (`ExternalSandboxPlanner.gitCommand`): local work without Keychain or network,
                # `push`/`fetch`/`ls-remote` (also after `-C <root>`) with them; HOME forced to the real home as the app does.
                'git': nono_git_policy.git_policy(GIT_FS(case), HOME, [case / 'project', REPO]),
                **({'gh': nono_git_policy.gh_policy(GIT_FS(case), HOME, GH)} if GH else {}),
                # The app's shape (`ExternalSandboxPlan.policyDocument`): the sandbox in the session edge plus an argument
                # allow-list, default deny. Signing lists identities only; a listed item gets its exact secret reads.
                'security': {'executable': '/usr/bin/security',
                             'from': {'session': {
                                 'sandbox': {'keychain_access': 'read', 'fs_read': [str(case / 'project')], 'network': {'allow_all': False}},
                                 'invocation_policy': {'default': 'deny', 'allow': [
                                     {'argv': {'prefix': ['find-identity']}},
                                     {'argv': {'exact': ['find-generic-password', '-s', PROBE_SERVICE, '-w']}},
                                     {'argv': {'exact': ['find-generic-password', '-w', '-s', PROBE_SERVICE]}}]}}}},
                'switchboard-browser': {'executable': PYTHON, 'allow_direct_exec_bypass': [PYTHON],
                                        'sandbox': {'fs_read': [str(case / 'resources'), str(case / 'project'), str(DEVELOPER)], 'fs_write': [str(profiles), str(case / 'tmp')],
                                                    'network': {'allow_all': False, 'open_port': [browser_port]},
                                                    # macOS has no exec_paths: the browser the server forks needs explicit exec/read rules.
                                                    'unsafe_macos_seatbelt_rules': [
                                                        '(allow process-exec* (subpath "/Applications/Google Chrome.app"))',
                                                        '(allow file-read* (subpath "/Applications/Google Chrome.app"))',
                                                        '(allow file-map-executable (subpath "/Applications/Google Chrome.app"))']}},
            },
        },
    }


def run_nono(case, grants, script, env, timeout=120, profile=None, extra=()):
    command = [NONO, 'run', '--silent', '--no-audit', '--no-diagnostics', '--no-rollback', *extra]
    if profile:
        command += ['--profile', str(profile)]
    for mode, path in grants:
        command += [mode, str(path)]
    command += ['--', '/bin/zsh', '-c', script]
    proc = subprocess.Popen(command, env=env, cwd=str(case / 'project'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, err = proc.communicate()
        out += '\nTIMEOUT'
    return proc.returncode, out, err


def lines(out):
    return {line.split(' ', 2)[1]: line.split(' ', 2)[2] if len(line.split(' ', 2)) > 2 else '' for line in out.splitlines() if line.startswith('CHECK ')}


try:
    # The value travels in argv for a moment here; it is random and deleted at the end.
    subprocess.run(['/usr/bin/security', 'add-generic-password', '-U', '-s', PROBE_SERVICE, '-a', PROBE_ACCOUNT, '-w', PROBE_SECRET],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # ---- developer: union session + mediated commands --------------------------------------------------------
    case = make_case('developer')
    env = environment(case)
    # The fixture repository talks to this checkout's own remote; its hooks folder logs what runs and whether the Keychain
    # file was readable there (yes/no files, never content).
    if ORIGIN:
        subprocess.run(['/opt/homebrew/bin/git', '-C', str(case / 'project'), 'remote', 'add', 'origin', ORIGIN], check=True)
    hooks = case / 'project/probe-hooks'
    hooks.mkdir()
    (hooks / 'reference-transaction').write_text('#!/bin/sh\ncat > /dev/null\ntouch "%s/hook-ran"\n'
                                                 'test -r "%s/Library/Keychains/login.keychain-db" && touch "%s/hook-keychain"\nexit 0\n'
                                                 % (case / 'tmp', HOME, case / 'tmp'))
    os.chmod(hooks / 'reference-transaction', 0o755)
    browser_port = 39577
    profile = case / 'policy.json'
    profile.write_text(json.dumps(policy(case, browser_port), indent=1))
    (case / 'resources/chrome_probe.py').write_text(r'''
import subprocess, sys, time, urllib.request
chrome, profile, port, mode = sys.argv[1:5]
if mode == 'headless':
    r = subprocess.run([chrome, '--headless=new', '--user-data-dir=' + profile, '--no-first-run', '--dump-dom', 'about:blank'],
                       capture_output=True, text=True, timeout=60)
    print('HEADLESS', r.returncode, '<html' in r.stdout, r.stderr.strip().splitlines()[-1:] if r.returncode else '')
    sys.exit(0)
p = subprocess.Popen([chrome, '--user-data-dir=' + profile, '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=' + port,
                      '--no-first-run', '--no-default-browser-check', '--window-size=400,300', 'about:blank'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
ok = False
for _ in range(40):
    time.sleep(0.5)
    if p.poll() is not None:
        break
    try:
        urllib.request.urlopen('http://127.0.0.1:%s/json/version' % port, timeout=1).read(); ok = True; break
    except Exception:
        pass
print('HEADED', p.poll(), ok)
p.terminate()
try:
    p.wait(5)
except Exception:
    p.kill()
''')
    grants = [('--allow', case / 'project'), ('--allow', case / 'cache'), ('--read', case / 'other'), ('--allow', case / 'tmp'), ('--read', DEVELOPER), ('--read', REPO), ('--read', '/opt/homebrew'), ('--read-file', HOME / '.gitconfig')]
    grants += [('--allow', p) for p in SWIFTPM_CACHES if p.exists()]
    chrome_part = '' if args.skip_chrome else f'''
echo "CHECK chrome-headless $(switchboard-browser -I "{case}/resources/chrome_probe.py" "{CHROME}" "{case}/profiles/headless" {browser_port} headless 2>&1 | tail -1)"
echo "CHECK chrome-headed $(switchboard-browser -I "{case}/resources/chrome_probe.py" "{CHROME}" "{case}/profiles/headed" {browser_port} headed 2>&1 | tail -1)"
'''
    swiftpm_part = '' if args.skip_swiftpm else f'''
mkdir -p "{case}/project/pkg/Sources/probe"
printf '// swift-tools-version:5.9\\nimport PackageDescription\\nlet package = Package(name: "probe", targets: [.executableTarget(name: "probe")])\\n' > "{case}/project/pkg/Package.swift"
printf 'print(1)\\n' > "{case}/project/pkg/Sources/probe/main.swift"
cd "{case}/project/pkg"
swift build > /dev/null 2> "{case}/tmp/swiftpm-default.err"; echo "CHECK swiftpm-default $? $(tail -c 200 "{case}/tmp/swiftpm-default.err" | tr '\\n' ' ')"
swift build --disable-sandbox > /dev/null 2> "{case}/tmp/swiftpm-nosandbox.err"; echo "CHECK swiftpm-disable-sandbox $? $(tail -c 200 "{case}/tmp/swiftpm-nosandbox.err" | tr '\\n' ' ')"
cd "{case}/project"
'''
    script = f'''
set +e
setopt NO_BG_NICE
cd "{case}/project"
printf WRITE > marker; echo "CHECK project-write $? $(cat marker 2>/dev/null)"
printf CACHE > "{case}/cache/marker"; echo "CHECK cache-write $? $(cat "{case}/cache/marker" 2>/dev/null)"
printf X > "{case}/other/marker" 2>/dev/null; echo "CHECK other-write $?"
cd "{case}/other" && printf X > marker 2>/dev/null; echo "CHECK other-cwd-write $?"; cd "{case}/project"
"{TOOLCHAIN}/swiftc" --version > /dev/null 2>&1; echo "CHECK toolchain-absolute-exec $?"
"{TOOLCHAIN}/swift" --version > /dev/null 2>&1; echo "CHECK toolchain-swift-exec $?"
xcrun --find swiftc > /dev/null 2>&1; echo "CHECK xcrun-find $?"
n=$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Apple Development'); echo "CHECK security-shim $? identities=$n"
/usr/bin/security find-identity -v -p codesigning > /dev/null 2>&1; echo "CHECK security-direct-denied $?"
security dump-keychain > /dev/null 2>&1; echo "CHECK security-dump-denied $?"
security dump-keychain -d > /dev/null 2>&1; echo "CHECK security-dump-d-denied $?"
security -i < /dev/null > /dev/null 2>&1; echo "CHECK security-interactive-denied $?"
security find-internet-password -s github.com -w > /dev/null 2>&1; echo "CHECK security-internet-denied $?"
security find-generic-password -s switchboard-probe-unlisted -w > /dev/null 2>&1; echo "CHECK security-unlisted-denied $?"
security < /dev/null > /dev/null 2>&1; echo "CHECK security-empty-denied $?"
h=$(security find-generic-password -s "{PROBE_SERVICE}" -w 2>/dev/null | /usr/bin/shasum -a 256 | cut -c1-64); [ "$h" = "{PROBE_HASH}" ]; echo "CHECK security-listed-item $?"
h=$(security find-generic-password -w -s "{PROBE_SERVICE}" 2>/dev/null | /usr/bin/shasum -a 256 | cut -c1-64); [ "$h" = "{PROBE_HASH}" ]; echo "CHECK security-listed-item-other-order $?"
security find-generic-password -s "{PROBE_SERVICE}" -w -g > /dev/null 2>&1; echo "CHECK security-listed-extra-flag-denied $?"
security find-generic-password -s "{PROBE_SERVICE}" > /dev/null 2>&1; echo "CHECK security-listed-attributes-denied $?"
security find-generic-password -s "{PROBE_SERVICE}" -a "{PROBE_ACCOUNT}" -w > /dev/null 2>&1; echo "CHECK security-listed-with-account-denied $?"
/usr/bin/security find-generic-password -s "{PROBE_SERVICE}" -w > /dev/null 2>&1; echo "CHECK security-listed-absolute $?"
security find-generic-password -s switchboard-probe-unlisted -w > /dev/null 2> "{case}/tmp/deny.err"; echo "CHECK security-unlisted-stderr $? $(head -c 240 "{case}/tmp/deny.err" | tr '\\n' ' ')"
/usr/bin/python3 -c 'print(1)' > /dev/null 2>&1; echo "CHECK python-direct-bypass $?"
echo "CHECK python-stub-session $(/usr/bin/python3 -c 'import sys;print(sys.executable)' 2>&1)"
echo "CHECK python-mediated $(switchboard-browser -c 'import sys;print(sys.executable)' 2>&1)"
switchboard-browser -c 'import os,sys; sys.exit(0 if os.access(sys.argv[1], os.W_OK) else 3)' "{case}/profiles"; echo "CHECK browser-command-profiles-write $?"
test -w "{case}/profiles"; echo "CHECK session-profiles-hidden $?"
git -C "{case}/project" status --short > /dev/null 2>&1; echo "CHECK git-status-shim $?"
git -C "{case}/project" -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe > /dev/null 2>&1; echo "CHECK git-commit-shim $?"
git -C "{REPO}" ls-remote --exit-code origin HEAD > /dev/null 2>&1; echo "CHECK git-ls-remote $?"
git -C "{REPO}" push --dry-run origin HEAD > "{case}/tmp/push.out" 2>&1; echo "CHECK git-push-dry-run $? $(tail -c 120 "{case}/tmp/push.out" | tr '\\n' ' ')"
git -C "{REPO}" ls-remote --refs origin refs/heads/main > /dev/null 2>&1; echo "CHECK git-ls-remote-queue-shape $?"
KC="{HOME}/Library/Keychains/login.keychain-db"
P="{case}/project"
git -C "$P" commit -q --allow-empty -m identity > /dev/null 2>&1; echo "CHECK git-commit-own-identity $?"
h=$(git -C "$P" log -1 --format=%an 2>/dev/null | /usr/bin/shasum -a 256 | cut -c1-64); [ -n "{NAME_HASH}" ] && [ "$h" = "{NAME_HASH}" ]; echo "CHECK git-identity-kept $?"
printf '[user]\\n\\tname = injected\\n' > "{case}/tmp/evil.gitconfig"
GIT_CONFIG_GLOBAL="{case}/tmp/evil.gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=injected HOME="{case}/tmp" git -C "$P" commit -q --allow-empty -m injected > /dev/null 2>&1
h=$(git -C "$P" log -1 --format=%an 2>/dev/null | /usr/bin/shasum -a 256 | cut -c1-64); [ -n "{NAME_HASH}" ] && [ "$h" = "{NAME_HASH}" ]; echo "CHECK git-identity-injection-ignored $?"
GIT_EDITOR=true git -C "$P" commit -q --amend --allow-empty > /dev/null 2>&1; echo "CHECK git-editor-true $?"
GIT_EDITOR=: git -C "$P" commit -q --amend --allow-empty > /dev/null 2>&1; echo "CHECK git-editor-colon $?"
git -c "alias.kc=!test -r '$KC'" kc > /dev/null 2>&1; echo "CHECK git-alias-keychain $?"
git -c "alias.kc=!test -r '$KC'" kc push > /dev/null 2>&1; echo "CHECK git-alias-push-keychain $?"
git -C "$P" config alias.pk "!test -r '$KC'"; git -C "$P" pk > /dev/null 2>&1; echo "CHECK git-repo-alias-keychain $?"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.inj GIT_CONFIG_VALUE_0='!touch "{case}/tmp/injected"' git inj > /dev/null 2>&1; test -e "{case}/tmp/injected"; echo "CHECK git-config-count-alias $?"
git -C "$P" ls-remote 'ext::sh -c touch% {case}/tmp/ext-ran' > /dev/null 2>&1; echo "CHECK git-ext-exit $?"; test -e "{case}/tmp/ext-ran"; echo "CHECK git-ext-ran $?"
git credential fill < /dev/null > /dev/null 2>&1; echo "CHECK git-credential-refused $?"
git -C "$P" pull > /dev/null 2> "{case}/tmp/pull.err"; echo "CHECK git-pull-refused $? $(head -c 160 "{case}/tmp/pull.err" | tr '\\n' ' ')"
git -C "$P" config core.hooksPath "$P/probe-hooks"
git -C "$P" config credential.helper '!touch "{case}/tmp/repo-helper-ran"; true'
git -C "$P" update-ref refs/probe/local HEAD > /dev/null 2>&1; echo "CHECK git-local-hook-runs $(test -e "{case}/tmp/hook-ran"; echo $?) keychain $(test -e "{case}/tmp/hook-keychain"; echo $?)"
rm -f "{case}/tmp/hook-ran" "{case}/tmp/hook-keychain"
git -C "$P" fetch -q origin main > /dev/null 2>&1; echo "CHECK git-fetch-project $?"
echo "CHECK git-fetch-hooks-off $(test -e "{case}/tmp/hook-ran"; echo $?) keychain $(test -e "{case}/tmp/hook-keychain"; echo $?) helper $(test -e "{case}/tmp/repo-helper-ran"; echo $?)"
gh auth token > /dev/null 2> "{case}/tmp/gh.err"; echo "CHECK gh-token-refused $? $(grep -c 'command policy' "{case}/tmp/gh.err")"
gh auth status -t > /dev/null 2>&1; echo "CHECK gh-show-token-refused $?"
gh pr list --limit 1 > /dev/null 2>&1; echo "CHECK gh-pr-list $?"
printf 'protocol=https\\nhost=github.com\\n' | "{GIT_EXEC}/git-credential-osxkeychain" get 2>/dev/null | grep -q '^password=' ; echo "CHECK git-helper-direct-no-secret $?"
ls "{HOME}/Library/Keychains" > /dev/null 2>&1; echo "CHECK session-keychain-hidden $?"
echo "CHECK proxy-env ${{HTTPS_PROXY:-unset}}"
{chrome_part}
{swiftpm_part}
sleep 300 &
switchboard-browser -c 'import time; time.sleep(300)' &
echo "CHECK ready $$"
wait
'''
    command = SETSID + [NONO, 'run', '--silent', '--no-audit', '--no-diagnostics', '--no-rollback', '--profile', str(profile)]
    for mode, path in grants:
        command += [mode, str(path)]
    command += ['--', '/bin/zsh', '-c', script]
    # No start_new_session: the launcher itself becomes the group leader, as it will under the app's Process.
    proc = subprocess.Popen(command, env=env, cwd=str(case / 'project'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    out_lines = []
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        out_lines.append(line.rstrip('\n'))
        print('  ' + line.rstrip('\n'), flush=True)
        if line.startswith('CHECK ready'):
            break
    found = lines('\n'.join(out_lines))
    results['developer'] = {'checks': found, 'exit': proc.poll()}
    exp = {'project-write': '0', 'cache-write': '0', 'toolchain-absolute-exec': '0', 'toolchain-swift-exec': '0', 'xcrun-find': '0',
           'python-direct-bypass': '0', 'browser-command-profiles-write': '0'}
    exp.update({'git-status-shim': '0', 'git-commit-shim': '0', 'git-ls-remote': '0', 'git-push-dry-run': '0', 'git-ls-remote-queue-shape': '0',
                'git-commit-own-identity': '0', 'git-identity-kept': '0', 'git-identity-injection-ignored': '0', 'git-editor-true': '0',
                'git-editor-colon': '0', 'git-fetch-project': '0'})
    # Narrowed git (2026-11-13): code an agent controls never runs with the Keychain; refused forms stay refused.
    for name in ['git-alias-keychain', 'git-alias-push-keychain', 'git-repo-alias-keychain', 'git-config-count-alias', 'git-ext-exit',
                 'git-ext-ran', 'git-credential-refused', 'git-pull-refused', 'gh-show-token-refused']:
        check('developer/' + name, found.get(name, '0').split(' ')[0] not in ('0', ''), found.get(name, 'missing'))
    check('developer/git-local-hook-runs-without-keychain', found.get('git-local-hook-runs', '') == '0 keychain 1', found.get('git-local-hook-runs', 'missing'))
    check('developer/git-fetch-runs-no-repo-code', found.get('git-fetch-hooks-off', '') == '1 keychain 1 helper 1', found.get('git-fetch-hooks-off', 'missing'))
    if GH:
        token = found.get('gh-token-refused', '0 0').split(' ')
        check('developer/gh-token-refused-by-policy', token[0] not in ('0', '') and token[-1] != '0', ' '.join(token))
        check('developer/gh-pr-list (informational)', True, found.get('gh-pr-list', 'missing'))
    for name, code in exp.items():
        check('developer/' + name, found.get(name, '').split(' ')[0] == code, found.get(name, 'missing'))
    for name in ['other-write', 'other-cwd-write', 'security-direct-denied', 'session-profiles-hidden', 'session-keychain-hidden', 'git-helper-direct-no-secret',
                 'security-dump-denied', 'security-dump-d-denied', 'security-interactive-denied', 'security-internet-denied',
                 'security-unlisted-denied', 'security-empty-denied', 'security-listed-extra-flag-denied',
                 'security-listed-attributes-denied', 'security-listed-with-account-denied']:
        check('developer/' + name, found.get(name, '0').split(' ')[0] not in ('0', ''), found.get(name, 'missing'))
    # A listed item reads through the shim in both orders, the value matches (compared by hash, never printed); by absolute
    # path `security` is not the shim and exits 127. The refusal text of an unlisted item is recorded for the agent instructions.
    for name in ['security-listed-item', 'security-listed-item-other-order']:
        check('developer/' + name, found.get(name, '') == '0', 'yes' if found.get(name, '') == '0' else 'no')
    check('developer/security-listed-absolute-127', found.get('security-listed-absolute', '') == '127', found.get('security-listed-absolute', 'missing'))
    check('developer/security-unlisted-stderr (informational)', True, found.get('security-unlisted-stderr', 'missing'))
    sec = found.get('security-shim', '')
    check('developer/security-shim', sec.startswith('0 ') and not sec.endswith('identities=0'), sec)
    if not args.skip_chrome:
        check('developer/chrome-headless', 'HEADLESS 0 True' in found.get('chrome-headless', ''), found.get('chrome-headless', 'missing'))
        check('developer/chrome-headed', 'HEADED None True' in found.get('chrome-headed', ''), found.get('chrome-headed', 'missing'))
    if not args.skip_swiftpm:
        check('developer/swiftpm-disable-sandbox', found.get('swiftpm-disable-sandbox', '').startswith('0'), found.get('swiftpm-disable-sandbox', 'missing'))
        check('developer/swiftpm-default (informational)', True, found.get('swiftpm-default', 'missing'))
    # ---- revocation: terminating the supervisor must end session and mediated descendants -----------------------
    ready = proc.poll() is None and 'ready' in found
    check('developer/session-alive-before-stop', ready)
    if ready:
        before = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
        has_sleep = 'sleep 300' in before and 'time.sleep(300)' in before
        check('revocation/descendants-running', has_sleep)
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
        time.sleep(2)
        after = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
        leftover = [l for l in after.splitlines() if 'sleep 300' in l or 'time.sleep(300)' in l or str(case / 'profiles') in l]
        check('revocation/descendants-stopped-after-group-sigterm', not leftover, '; '.join(leftover)[:300])
        for l in leftover:
            try:
                os.kill(int(l.split()[0]), signal.SIGKILL)
            except Exception:
                pass
        results['revocation'] = {'leftover': leftover, 'nono_exit': proc.returncode}
    err = proc.stderr.read() if proc.poll() is not None else ''
    results['developer']['stderr_tail'] = err[-2000:]
    if err.strip():
        print('  stderr: ' + err.strip()[-600:], flush=True)

    # ---- reader: read-only session ------------------------------------------------------------------------------
    case = make_case('reader')
    env = environment(case)
    (case / 'project/existing').write_text('ok')
    code, out, err = run_nono(case, [('--read', case / 'project'), ('--read', case / 'cache'), ('--read', case / 'other')], f'''
set +e
cat "{case}/project/existing" > /dev/null; echo "CHECK read $?"
printf X > "{case}/project/marker" 2>/dev/null; echo "CHECK write $?"
printf X > "{case}/cache/marker" 2>/dev/null; echo "CHECK cache-write $?"
''', env)
    found = lines(out)
    results['reader'] = {'checks': found, 'exit': code, 'stderr_tail': err[-800:]}
    check('reader/read', found.get('read') == '0', found.get('read', 'missing'))
    check('reader/write-denied', found.get('write', '0') != '0', found.get('write', 'missing'))
    check('reader/cache-write-denied', found.get('cache-write', '0') != '0', found.get('cache-write', 'missing'))
    check('reader/no-marker', not (case / 'project/marker').exists() and not (case / 'cache/marker').exists())

    # ---- network: domain allowlist through the supervisor proxy ---------------------------------------------------
    if not args.skip_network:
        case = make_case('network')
        env = environment(case)
        code, out, err = run_nono(case, [('--allow', case / 'project')], '''
set +e
echo "CHECK proxy-env ${HTTPS_PROXY:+set}"
echo "CHECK allowed $(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.openai.com/v1/models 2>&1 | tail -c 60)"
echo "CHECK denied $(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com 2>&1 | tail -c 80)"
''', env, extra=['--allow-domain', 'api.openai.com'])
        found = lines(out)
        results['network'] = {'checks': found, 'exit': code, 'stderr_tail': err[-800:]}
        check('network/proxy-env-set', found.get('proxy-env') == 'set', found.get('proxy-env', 'missing'))
        check('network/allowed-domain-reaches-upstream', found.get('allowed', '').strip() in ('401', '200'), found.get('allowed', 'missing'))
        check('network/other-domain-blocked', found.get('denied', '000').strip() not in ('200', '301', '302'), found.get('denied', 'missing'))
        case = make_case('network-blocked')
        env = environment(case)
        code, out, err = run_nono(case, [('--allow', case / 'project')], '''
echo "CHECK blocked $(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://api.openai.com/v1/models 2>&1 | tail -c 80)"
''', env, extra=['--block-net'])
        found = lines(out)
        results['network-blocked'] = {'checks': found, 'exit': code}
        check('network/block-net', found.get('blocked', '200').strip() not in ('200', '401'), found.get('blocked', 'missing'))
finally:
    subprocess.run(['/usr/bin/security', 'delete-generic-password', '-s', PROBE_SERVICE, '-a', PROBE_ACCOUNT],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results['checks'] = checks
    (OUT / 'nono-runtime-results.json').write_text(json.dumps(results, indent=2))
    shutil.rmtree(fixture, ignore_errors=True)
    for state in STATE_DIRS:
        shutil.rmtree(state, ignore_errors=True)
failed = [c['name'] for c in checks if not c['ok']]
print('SUMMARY', len(checks) - len(failed), 'passed,', len(failed), 'failed', failed)
