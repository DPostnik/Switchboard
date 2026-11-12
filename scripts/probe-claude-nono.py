#!/usr/bin/env python3
"""Claude Code CLI under the pinned nono helper (plan B1 of docs/handoffs/claude-boundary-2026-11-12).

Runs the pinned CLI with the app profile (CLAUDE_CONFIG_DIR = ~/Library/Application Support/Switchboard/claude, signed
in; ~/.claude is never used) in the app's stream-json mode (`--permission-prompt-tool stdio`, `--setting-sources ""`,
a settings file with the CLI's own `sandbox` off) inside a nono session sandbox compiled like the Codex one: project
root + preset trees, mediated commands, app-owned MCP servers outside the boundary behind SandboxRuntime/mcp_host.py
and mcp_relay.py. Checks (one JSON line each in .build/verification/claude-nono/<timestamp>/results.jsonl, plus
summary.json):

1. credentials: (a) mediated `security` with keychain_access read, (b) `.credentials.json` in the config dir,
   (c) CLAUDE_CODE_OAUTH_TOKEN, (d) CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR (a pipe the app fills) with
   CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH, (e) like (d) with a stale token so the CLI must ask the host for a fresh one
   over stdio (`oauth_token_refresh`). Per option: a "reply pong" turn, and whether a Bash command sees the token
   (Keychain item, credentials file, environment, ancestors' environment, inherited descriptors). Yes/no only.
2. CLI runtime tree: Bash `echo`, Read of a project file, skills plugins, /usr/bin/python3, nono's denial list.
3. MCP: an app-owned stdio server through the relay and a project `.mcp.json` server inside the boundary.
4. Process information: pgrep, lsof, sysctl, ps, `log show` as mediated commands; pkill and screencapture refused;
   osascript only with --osascript.
5. Nested sandbox: CLI sandbox off, `swift --version`, SWITCHBOARD_EXTERNAL_SANDBOX=1 visible to Bash.
6. Teardown: SIGTERM to the process group ends the CLI, a background sub-agent and mediated children; the relay
   host exits; socket and worker folder are removed.
Secrets: the token is read once from the app profile's Keychain item by this script (outside the boundary) and kept
in memory; output, host logs, the unified log and new shell snapshots are scanned for it; nothing prints it. Options
that could refresh (and so rotate) the stored login are skipped when the token expires within 30 minutes; the
Keychain is never written. Run outside any enclosing sandbox and outside builds; exits non-zero when a required
check fails.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOME = pathlib.Path.home()
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--nono', help='Verified helper; default: staged by prepare-nono.py into .build/claude-nono-helper')
parser.add_argument('--archive', help='nono archive for prepare-nono.py (default: .build/nono-cache, then the main checkout cache)')
parser.add_argument('--claude', default=str(HOME / '.local/bin/claude'))
parser.add_argument('--profile', default=str(HOME / 'Library/Application Support/Switchboard/claude'))
parser.add_argument('--model', default='haiku')
parser.add_argument('--only', default='1,2,3,4,5,6', help='Comma-separated check groups')
parser.add_argument('--options', default='a,b,c,d,e', help='Credential options for check 1')
parser.add_argument('--main-option', default='', help='Credential option for checks 2-6 (default: first qualifying, else a)')
parser.add_argument('--osascript', action='store_true', help='Also mediate osascript with (allow appleevent-send)')
parser.add_argument('--turn-timeout', type=int, default=240)
parser.add_argument('--keep', action='store_true', help='Keep fixture folders (never the token files)')
args = parser.parse_args()
GROUPS = set(args.only.split(','))

STAMP = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
OUT = ROOT / '.build/verification/claude-nono' / STAMP
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'sessions').mkdir()
WORK = pathlib.Path(tempfile.mkdtemp(prefix='claude-nono-', dir=str(ROOT / '.build'))).resolve()
SANDBOX_ROOT = HOME / 'Library/Application Support/Switchboard-sandbox'
DATA_ROOT = HOME / 'Library/Application Support/Switchboard'
PROFILE = pathlib.Path(args.profile)
CLAUDE = pathlib.Path(os.path.realpath(args.claude))
RELAY = ROOT / 'SandboxRuntime/mcp_relay.py'
HOST = ROOT / 'SandboxRuntime/mcp_host.py'
DEVELOPER = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
TOOLCHAIN_TREES = ['/Applications/Xcode.app/Contents/Developer', '/Library/Developer/CommandLineTools', '/opt/homebrew']
LAUNCHER = ['/usr/bin/python3', '-I', '-c', 'import os,sys\ntry:\n    os.setsid()\nexcept PermissionError:\n    pass\nos.execv(sys.argv[1], sys.argv[1:])']
# nono 0.81.0 closes every inherited descriptor above 2 (the CLI saw EBADF on /dev/fd/N). Inside the sandbox this launcher
# reads the token as the first stdin line, hands it to the CLI on fd 3 through a pipe (zsh process substitution, nothing
# on disk, nothing in argv or the environment) and execs the CLI, which then reads the stream-json protocol from stdin.
FD_LAUNCHER = ['/bin/zsh', '-f', '-c', 'IFS= read -r t; exec 3< <(print -r -- "$t"); unset t; exec "$@"', 'zsh']
PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
STARTED = time.time()
START_TEXT = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
results = []
transcripts = []
host_logs = []


def record(check, status, required, **facts):
    entry = {'check': check, 'status': status, 'required': required, 'facts': facts, 'at': round(time.time() - STARTED, 1)}
    results.append(entry)
    with (OUT / 'results.jsonl').open('a') as handle:
        handle.write(json.dumps(entry, sort_keys=True) + '\n')
    print('%-5s %s%s %s' % (status.upper(), check, '' if required else ' (info)', json.dumps(facts, sort_keys=True)[:400]), flush=True)


def load():
    return subprocess.run(['/usr/sbin/sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()


def processes():
    rows = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='], capture_output=True, text=True).stdout.splitlines()
    result = []
    for row in rows:
        parts = row.split(None, 3)
        if len(parts) == 4:
            result.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3]))
    return result


# ---- the helper ---------------------------------------------------------------------------------------------------
def stage_nono():
    if args.nono:
        return str(pathlib.Path(args.nono).resolve())
    target = ROOT / '.build/claude-nono-helper'
    archive = args.archive
    if not archive:
        lock = json.loads((ROOT / 'NonoRuntime/runtime.lock.json').read_text())
        name = pathlib.Path(lock['url']).name
        for candidate in [ROOT / '.build/nono-cache' / name, ROOT.parent.parent.parent / '.build/nono-cache' / name]:
            if candidate.exists():
                archive = str(candidate)
                break
    command = [sys.executable, '-I', str(ROOT / 'scripts/prepare-nono.py'), str(target)] + (['--archive', archive] if archive else [])
    subprocess.run(command, check=True)
    return str(target / 'nono')


NONO = stage_nono()


# ---- the secret (kept in memory, never printed) -------------------------------------------------------------------
class Secret:
    def __init__(self):
        self.item = 'Claude Code-credentials-' + hashlib.sha256(str(PROFILE).encode()).hexdigest()[:8]
        self.reason = None
        self.token = None
        self.document = None
        self.minutes = None
        if not PROFILE.is_dir():
            self.reason = 'app profile folder missing'
            return
        user = os.environ.get('USER') or subprocess.check_output(['/usr/bin/id', '-un'], text=True).strip()
        found = subprocess.run(['/usr/bin/security', 'find-generic-password', '-a', user, '-w', '-s', self.item], capture_output=True, text=True)
        if found.returncode != 0:
            self.reason = 'Keychain item %s not found (app profile not signed in)' % self.item
            return
        try:
            self.document = json.loads(found.stdout)
            oauth = self.document['claudeAiOauth']
            self.token = oauth['accessToken']
            self.minutes = round((oauth['expiresAt'] / 1000 - time.time()) / 60, 1)
        except (ValueError, KeyError, TypeError):
            self.reason = 'Keychain item is not a Claude OAuth document'
            self.token = None

    @property
    def ready(self):
        return bool(self.token)

    @property
    def ident(self):
        return hashlib.sha256(self.token.encode()).hexdigest()[:12] if self.token else None

    def found_in(self, data):
        if not self.token:
            return False
        if isinstance(data, str):
            data = data.encode('utf-8', 'replace')
        return self.token.encode() in data or self.token[20:60].encode() in data

    def file_document(self):
        """The credentials file of option b, without the refresh token: a CLI that cannot refresh cannot rotate the login."""
        oauth = dict(self.document['claudeAiOauth'])
        oauth.pop('refreshToken', None)
        oauth.pop('refreshTokenExpiresAt', None)
        return json.dumps({'claudeAiOauth': oauth})


SECRET = Secret()

# ---- fixture ------------------------------------------------------------------------------------------------------
INNER_SERVER = r'''
import json, os, sys
def reply(i, result): sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'result': result}) + '\n'); sys.stdout.flush()
def where():
    try:
        os.listdir(os.path.expanduser('~/Library/Keychains')); return 'keychains_listable=1'
    except OSError:
        return 'keychains_listable=0'
NAME, TOOL = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    m = json.loads(line)
    if m.get('method') == 'initialize':
        reply(m['id'], {'protocolVersion': m['params'].get('protocolVersion', '2025-03-26'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': NAME, 'version': '1'}})
    elif m.get('method') == 'tools/list':
        reply(m['id'], {'tools': [{'name': TOOL, 'description': 'Returns a fixed probe string.', 'inputSchema': {'type': 'object', 'properties': {}}}]})
    elif m.get('method') == 'tools/call':
        reply(m['id'], {'content': [{'type': 'text', 'text': '%s-%s %s' % (NAME, TOOL, where())}]})
    elif 'id' in m:
        reply(m['id'], {})
'''

PROC_HELPER = r'''
import ctypes, json, os, stat, sys
libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
marker = sys.argv[1].encode() if len(sys.argv) > 1 else b'\0none'
def info(pid):
    buf = ctypes.create_string_buffer(136)
    if libc.proc_pidinfo(pid, 3, 0, buf, 136) <= 0:
        return None
    return int.from_bytes(buf.raw[16:20], 'little'), buf.raw[48:64].split(b'\0')[0].decode('utf-8', 'replace')
def procargs(pid):
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return None
    return buf.raw[:size.value]
chain, pid = [], os.getppid()
while pid > 1 and len(chain) < 10:
    got = info(pid)
    if not got:
        chain.append({'comm': '?', 'info': False}); break
    raw = procargs(pid)
    chain.append({'comm': got[1], 'args_readable': raw is not None,
                  'token': bool(raw and b'sk-ant-' in raw), 'marker': bool(raw and marker in raw)})
    pid = got[0]
fds = {'open': 0, 'token': 0}
for fd in range(3, 256):
    try:
        mode = os.fstat(fd).st_mode
    except OSError:
        continue
    fds['open'] += 1
    try:
        if stat.S_ISREG(mode):
            data = os.pread(fd, 65536, 0)
        elif stat.S_ISFIFO(mode):
            os.set_blocking(fd, False); data = os.read(fd, 65536)
        else:
            continue
        if b'sk-ant-' in data:
            fds['token'] += 1
    except OSError:
        pass
print(json.dumps({'ancestors': [c['comm'] for c in chain], 'ancestor_args_readable': sum(c.get('args_readable', False) for c in chain),
                  'ancestor_env_token': sum(c.get('token', False) for c in chain), 'ancestor_env_marker': sum(c.get('marker', False) for c in chain),
                  'fds_open': fds['open'], 'fds_token': fds['token']}))
'''

BOUNDARY_SCRIPT = r'''#!/bin/zsh
# Credential visibility from a Bash command: prints key=value with yes/no or counts only, never a value.
out="${0:A:h}/../.probe-out"; mkdir -p "$out"; f="$out/boundary.txt"; : > "$f"
item=%(item)s
n=$(security find-generic-password -a "$USER" -w -s "$item" 2>/dev/null | grep -c accessToken); echo "keychain_item_secret=$n" >> "$f"
n=$(/usr/bin/security find-generic-password -a "$USER" -w -s "$item" 2>/dev/null | grep -c accessToken); echo "keychain_item_secret_absolute=$n" >> "$f"
security find-generic-password -s "Claude Code-credentials" > /dev/null 2>&1; echo "keychain_other_item_attributes_rc=$?" >> "$f"
n=$(security dump-keychain 2>/dev/null | grep -c '"svce"'); echo "keychain_items_listed=$n" >> "$f"
if [[ -r "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then n=$(grep -c accessToken "$CLAUDE_CONFIG_DIR/.credentials.json"); else n=unreadable; fi; echo "credentials_file=$n" >> "$f"
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && echo "env_oauth_token=yes" >> "$f" || echo "env_oauth_token=no" >> "$f"
echo "env_sk_values=$(env | grep -c 'sk-ant-')" >> "$f"
echo "env_oauth_names=$(env | cut -d= -f1 | grep -ci oauth)" >> "$f"
echo "proc=$(python3 -I "${0:A:h}/proc.py" "%(marker)s" 2>&1 | tail -1)" >> "$f"
echo "bash_fd_list=$(ls /dev/fd 2>/dev/null | tr '\n' ' ')" >> "$f"
cli=$(pgrep -f -- "--session-id" 2>/dev/null | head -1)
echo "lsof_cli_fd3=$(lsof -a -p "${cli:-0}" -d 3 2>/dev/null | tail -n +2 | awk '{print $5}' | head -1)" >> "$f"
echo "boundary-done"
'''

RUNTIME_SCRIPT = r'''#!/bin/zsh
# Runtime, process information and nested-sandbox facts; key=value lines, exit codes only where output could be large.
out="${0:A:h}/../.probe-out"; mkdir -p "$out"; f="$out/runtime.txt"; : > "$f"
target=%(target)s
echo "external_env=${SWITCHBOARD_EXTERNAL_SANDBOX:-unset}" >> "$f"
echo "tmpdir_is_worker=$([[ "$TMPDIR" == *Switchboard-sandbox/workers/* ]] && echo yes || echo no)" >> "$f"
print -r -- probe > "$TMPDIR/probe-write" 2>/dev/null; echo "tmpdir_write_rc=$?" >> "$f"
echo "python_usr_bin=$(/usr/bin/python3 -I -c 'print(42)' 2>&1 | tail -1)" >> "$f"
swift --version > /dev/null 2>&1; echo "swift_version_rc=$?" >> "$f"
xcrun --find swiftc > /dev/null 2>&1; echo "xcrun_find_rc=$?" >> "$f"
echo "pgrep_target=$(pgrep -f "$target" 2>/dev/null | wc -l | tr -d ' ')" >> "$f"
echo "pgrep_lf_target=$(pgrep -lf "$target" 2>/dev/null | grep -c "$target")" >> "$f"
lsof -nP -iTCP -sTCP:LISTEN > "$TMPDIR/lsof.out" 2>&1; echo "lsof_listen_rc=$? lines=$(wc -l < "$TMPDIR/lsof.out" | tr -d ' ')" >> "$f"
tpid=$(pgrep -f "$target" 2>/dev/null | head -1)
lsof -p "${tpid:-1}" > "$TMPDIR/lsofp.out" 2>&1; echo "lsof_pid_rc=$? lines=$(wc -l < "$TMPDIR/lsofp.out" | tr -d ' ')" >> "$f"
echo "sysctl_loadavg=$(sysctl -n vm.loadavg > /dev/null 2>&1; echo $?)" >> "$f"
ps -axo pid= > "$TMPDIR/ps.out" 2>&1; echo "ps_rc=$? lines=$(wc -l < "$TMPDIR/ps.out" | tr -d ' ') err=$(grep -v '^ *[0-9]' "$TMPDIR/ps.out" | head -1 | tr -cd '[:alnum:] :._-' | cut -c1-80)" >> "$f"
log show --last 1m > /dev/null 2>&1; echo "zsh_builtin_log_rc=$?" >> "$f"
command log show --last 1m --style compact > "$TMPDIR/log.out" 2>&1; echo "log_show_rc=$? lines=$(wc -l < "$TMPDIR/log.out" | tr -d ' ') first=$(head -1 "$TMPDIR/log.out" | tr -cd '[:alnum:] :._-' | cut -c1-60)" >> "$f"
/usr/bin/log show --last 1m --style compact > "$TMPDIR/log2.out" 2>&1; echo "log_show_absolute_rc=$? first=$(head -1 "$TMPDIR/log2.out" | tr -cd '[:alnum:] :._-' | cut -c1-60)" >> "$f"
pkill -f "$target" > "$TMPDIR/pkill.out" 2>&1; echo "pkill_rc=$? err=$(head -1 "$TMPDIR/pkill.out" | tr -cd '[:alnum:] :._-' | cut -c1-60)" >> "$f"
rm -f "$TMPDIR/shot.png"; screencapture -x "$TMPDIR/shot.png" > /dev/null 2>&1; echo "screencapture_rc=$? file=$([[ -s "$TMPDIR/shot.png" ]] && echo yes || echo no)" >> "$f"
if [[ "%(osascript)s" == "1" ]]; then
  osascript -e 'return 1' > /dev/null 2>&1; echo "osascript_plain_rc=$?" >> "$f"
  osascript -e 'tell application "Finder" to get version' > /dev/null 2>&1; echo "osascript_appleevent_rc=$?" >> "$f"
fi
echo "proc=$(python3 -I "${0:A:h}/proc.py" "%(marker)s" 2>&1 | tail -1)" >> "$f"
echo "runtime-done"
'''


def make_project(name, marker):
    project = WORK / name / 'project'
    (project / 'checks').mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(project)], check=True)
    (project / 'README.txt').write_text('SB-README-%s\nA fixture project for the Claude nono probe.\n' % marker)
    (project / 'checks/proc.py').write_text(PROC_HELPER)
    (project / 'checks/boundary.sh').write_text(BOUNDARY_SCRIPT % {'item': json.dumps(SECRET.item), 'marker': marker})
    (project / 'mcp_inner.py').write_text(INNER_SERVER)
    (project / '.mcp.json').write_text(json.dumps({'mcpServers': {'project_probe': {'command': '/usr/bin/python3', 'args': ['-I', str(project / 'mcp_inner.py'), 'project_probe', 'project_echo']}}}))
    return project


def canonical(path):
    return os.path.realpath(os.path.expanduser(str(path)))


def skill_targets():
    plugins = PROFILE / 'skill-plugins'
    result = []
    if plugins.is_dir():
        result.append(str(plugins))
        for entry in plugins.iterdir():
            link = entry / 'skills'
            target = canonical(link)
            if target != str(link) and os.path.isdir(target):
                result.append(target)
    return result


def user_temp_folders():
    found = []
    for name in ['DARWIN_USER_TEMP_DIR', 'DARWIN_USER_CACHE_DIR']:
        value = subprocess.run(['/usr/bin/getconf', name], capture_output=True, text=True).stdout.strip()
        if value:
            found.append(canonical(value))
    return found


# ---- one sandboxed CLI ----------------------------------------------------------------------------------------------
class Session:
    def __init__(self, name, option, project, marker, *, mediated=(), diagnostics=False, profile=None):
        self.name, self.option, self.project, self.marker = name, option, project, marker
        self.profile = pathlib.Path(profile or PROFILE)
        self.id = 'cnp-' + uuid.uuid4().hex[:8]
        self.worker = SANDBOX_ROOT / 'workers' / self.id
        self.temporary = self.worker / 'tmp'
        socket = self.worker / 'mcp.sock'
        self.socket = socket if len(str(socket).encode()) <= 100 else pathlib.Path('/tmp/switchboard-%d/%s.sock' % (os.getuid(), self.id))
        self.mediated = list(mediated)
        self.diagnostics = diagnostics
        self.events, self.stderr = [], []
        self.permission_requests, self.refresh_requests, self.other_requests = [], 0, []
        self.init = None
        self.q = queue.Queue()
        self.lock = threading.Lock()
        self.proc = None
        self.host = None
        self.token_pipe = None

    def grants(self):
        grants = [('--allow', self.project), ('--allow', self.profile), ('--read', CLAUDE.parent)]
        for tree in TOOLCHAIN_TREES:
            if os.path.isdir(tree):
                grants.append(('--read', tree))
        grants.append(('--read', ROOT / 'SandboxRuntime'))
        for path in skill_targets():
            if not path.startswith(str(self.profile) + '/'):
                grants.append(('--read', path))
        for path in [DATA_ROOT / 'dropped-files', DATA_ROOT / 'mobile-photos']:
            if path.is_dir():
                grants.append(('--read', path))
        if (HOME / '.gitconfig').is_file():
            grants.append(('--read-file', HOME / '.gitconfig'))
        if (HOME / '.config/git').is_dir():
            grants.append(('--read', HOME / '.config/git'))
        caches = HOME / 'Library/Caches/Switchboard'
        caches.mkdir(parents=True, exist_ok=True)
        grants += [('--allow', caches), ('--allow', self.temporary), ('--read-file', self.worker / 'settings.json'),
                   ('--read-file', RELAY), ('--allow-unix-socket', self.socket)]
        return [(mode, canonical(path)) for mode, path in grants]

    def policy(self, grants):
        reads = [p for m, p in grants if m in ('--allow', '--read')]
        read_files = [p for m, p in grants if m in ('--read-file', '--allow-file')]
        writes = [p for m, p in grants if m == '--allow']
        commands = {}
        for name, executable, extra in self.mediated:
            sandbox = {'fs_read': reads, 'fs_read_file': read_files, 'fs_write': writes, 'network': {'allow_all': False},
                       'environment': {'allow_vars': ['PATH', 'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_*', 'TERM', 'TMPDIR', 'SSL_CERT_FILE']}}
            sandbox.update(extra)
            commands[name] = {'executable': executable, 'sandbox': sandbox}
        dirs = []
        for tree in TOOLCHAIN_TREES[:2]:
            for sub in ['Toolchains/XcodeDefault.xctoolchain/usr/bin', 'usr/bin']:
                path = pathlib.Path(tree) / sub
                if path.is_dir() and not (path.stat().st_mode & 0o022):
                    dirs.append(str(path))
        document = {'meta': {'name': 'switchboard-' + self.id, 'version': '1'}, 'workdir': {'access': 'none'}}
        # nono 0.81.0 refuses command_policies fields (executable_dirs) when no command is policy-controlled
        # ("inactive_non_empty"); without mediated commands the section is left out.
        if commands:
            document['command_policies'] = {'executable_dirs': dirs, 'commands': commands}
        return document

    def start(self, credential_env=None, token_for_pipe=None, mcp=True, refresh_token=None):
        self.refresh_token = refresh_token
        self.temporary.mkdir(parents=True, exist_ok=True)
        os.chmod(self.worker, 0o700)
        self.socket.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        settings = {'sandbox': {'enabled': False}, 'crossSessionInbound': 'refuse',
                    'permissions': {'allow': ['Bash', 'Read', 'Agent', 'Task', 'mcp__sbprobe__probe_echo', 'mcp__project_probe__project_echo']}}
        (self.worker / 'settings.json').write_text(json.dumps(settings))
        grants = self.grants()
        (self.worker / 'policy.json').write_text(json.dumps(self.policy(grants), indent=1))
        (self.worker / 'probe_server.py').write_text(INNER_SERVER)
        (self.worker / 'servers.json').write_text(json.dumps({'servers': {'sbprobe': {'command': '/usr/bin/python3',
                                                                                     'args': ['-I', str(self.worker / 'probe_server.py'), 'sbprobe', 'probe_echo']}}}))
        self.host_log = self.worker / 'mcp-host.log'
        command = [NONO, 'run'] + ([] if self.diagnostics else ['--silent', '--no-diagnostics']) + ['--no-audit', '--no-rollback',
                                                                                                     '--profile', str(self.worker / 'policy.json')]
        for mode, path in grants:
            command += [mode, path]
        mcp_config = {'mcpServers': {}}
        if mcp:
            mcp_config['mcpServers']['sbprobe'] = {'command': '/usr/bin/python3', 'args': ['-I', str(RELAY), str(self.socket), 'sbprobe']}
            mcp_config['mcpServers'].update(json.loads((self.project / '.mcp.json').read_text())['mcpServers'])
        self.session_id = str(uuid.uuid4())
        command += ['--', str(CLAUDE), '--print', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
                    '--permission-prompt-tool', 'stdio', '--setting-sources', '', '--strict-mcp-config', '--mcp-config', json.dumps(mcp_config),
                    '--plugin-dir=' + str(self.profile / 'skill-plugins'), '--settings', str(self.worker / 'settings.json'),
                    '--session-id', self.session_id, '--no-session-persistence', '--permission-mode', 'default', '--model', args.model]
        env = {'HOME': str(HOME), 'USER': os.environ.get('USER', ''), 'LOGNAME': os.environ.get('USER', ''), 'LANG': 'en_US.UTF-8', 'PATH': PATH,
               'CLAUDE_CONFIG_DIR': str(self.profile), 'DISABLE_AUTOUPDATER': '1', 'TMPDIR': str(self.temporary),
               'XDG_STATE_HOME': str(SANDBOX_ROOT / 'state'), 'XDG_CONFIG_HOME': str(SANDBOX_ROOT / 'config'),
               'SWITCHBOARD_EXTERNAL_SANDBOX': '1', 'SSL_CERT_FILE': '/etc/ssl/cert.pem', 'SB_PROBE_ENV_MARKER': self.marker}
        env.update(credential_env or {})
        if token_for_pipe is not None:
            env['CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR'] = '3'
            split = command.index('--')
            command = command[:split + 1] + FD_LAUNCHER + command[split + 1:]
        if mcp:
            self.host = subprocess.Popen(['/usr/bin/python3', '-I', str(HOST), '--socket', str(self.socket), '--spec', str(self.worker / 'servers.json'),
                                          '--log', str(self.host_log)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True)
            if self.host.stdout.readline().strip() != 'ready':
                raise RuntimeError('MCP host did not start')
        self.proc = subprocess.Popen(LAUNCHER + command, env=env, cwd=str(self.project), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        if token_for_pipe is not None:
            with self.lock:
                self.proc.stdin.write(token_for_pipe + '\n')
                self.proc.stdin.flush()
        threading.Thread(target=self._read_out, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()
        self.control({'subtype': 'initialize', 'hooks': None}, timeout=60)

    def send(self, value):
        with self.lock:
            self.proc.stdin.write(json.dumps(value) + '\n')
            self.proc.stdin.flush()

    def _respond(self, request_id, response=None, error=None):
        body = {'subtype': 'error', 'request_id': request_id, 'error': error} if error else {'subtype': 'success', 'request_id': request_id, 'response': response}
        self.send({'type': 'control_response', 'response': body})

    def _read_out(self):
        for line in self.proc.stdout:
            try:
                value = json.loads(line)
            except ValueError:
                self.events.append({'raw': line[:500]})
                continue
            self.events.append(value)
            if value.get('type') == 'control_request':
                request = value.get('request', {})
                subtype = request.get('subtype')
                try:
                    if subtype == 'can_use_tool':
                        self.permission_requests.append(request.get('tool_name'))
                        self._respond(value['request_id'], {'behavior': 'allow', 'updatedInput': request.get('input', {})})
                    elif subtype == 'oauth_token_refresh':
                        self.refresh_requests += 1
                        if self.refresh_token:
                            self._respond(value['request_id'], {'accessToken': self.refresh_token})
                        else:
                            self._respond(value['request_id'], error='probe has no token for this option')
                    else:
                        self.other_requests.append(subtype)
                        self._respond(value['request_id'], error='probe does not handle ' + str(subtype))
                except (BrokenPipeError, ValueError):
                    pass
                continue
            if value.get('type') == 'system' and value.get('subtype') == 'init' and self.init is None:
                self.init = value
            self.q.put(value)
        self.q.put({'type': '_eof'})

    def _read_err(self):
        for line in self.proc.stderr:
            self.stderr.append(line.rstrip('\n'))

    def control(self, request, timeout=60):
        request_id = 'probe-' + uuid.uuid4().hex[:8]
        self.send({'type': 'control_request', 'request_id': request_id, 'request': request})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.q.get(timeout=1)
            except queue.Empty:
                continue
            if value.get('type') == '_eof':
                raise RuntimeError('CLI exited during %s: %s' % (request.get('subtype'), ' | '.join(self.stderr[-5:])[:600]))
            if value.get('type') == 'control_response' and value.get('response', {}).get('request_id') == request_id:
                return value['response']
        raise TimeoutError('no control response to ' + str(request.get('subtype')))

    def turn(self, prompt, timeout=None):
        timeout = timeout or args.turn_timeout
        started = time.monotonic()
        before = len(self.permission_requests)
        self.send({'type': 'user', 'message': {'role': 'user', 'content': prompt}, 'parent_tool_use_id': None, 'session_id': self.session_id})
        tools, outputs = [], []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.q.get(timeout=1)
            except queue.Empty:
                continue
            kind = value.get('type')
            if kind == '_eof':
                return {'error': 'CLI exited: ' + ' | '.join(self.stderr[-6:])[:800], 'tools': tools, 'outputs': outputs, 'seconds': round(time.monotonic() - started, 1)}
            content = value.get('message', {}).get('content') if isinstance(value.get('message'), dict) else None
            if kind == 'assistant' and isinstance(content, list):
                for block in content:
                    if block.get('type') == 'tool_use':
                        tools.append({'name': block.get('name'), 'input': block.get('input'), 'parent': value.get('parent_tool_use_id')})
            if kind == 'user' and isinstance(content, list):
                for block in content:
                    if block.get('type') == 'tool_result':
                        body = block.get('content')
                        text = body if isinstance(body, str) else ' '.join(part.get('text', '') for part in body or [] if isinstance(part, dict))
                        outputs.append({'text': text[:2000], 'error': bool(block.get('is_error'))})
            if kind == 'result':
                return {'result': (value.get('result') or '')[:2000], 'is_error': value.get('is_error'), 'subtype': value.get('subtype'),
                        'tools': tools, 'outputs': outputs, 'permissions': self.permission_requests[before:], 'seconds': round(time.monotonic() - started, 1)}
        return {'error': 'turn timeout', 'tools': tools, 'outputs': outputs, 'seconds': round(time.monotonic() - started, 1)}

    def group(self):
        return [p for p in processes() if p[2] == self.proc.pid]

    def stop(self, watch=()):
        """SIGTERM to the launcher's process group; facts about what survived. `watch` are command substrings to track."""
        facts = {}
        if self.proc is None:
            if self.host:
                self.host.kill()
            shutil.rmtree(self.worker, ignore_errors=True)
            return facts
        before = processes()
        members = [p for p in before if p[2] == self.proc.pid]
        tracked = {w: [p[0] for p in before if w in p[3]] for w in watch}
        relay_before = [p[0] for p in before if 'mcp_relay.py ' + str(self.socket) in p[3]]
        facts['group_members_before'] = len(members)
        facts['tracked_before'] = {w: len(v) for w, v in tracked.items()}
        facts['relay_processes_before'] = len(relay_before)
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        started = time.monotonic()
        while time.monotonic() - started < 8:
            alive = [p for p in processes() if p[2] == self.proc.pid and '<defunct>' not in p[3]]
            if not alive:
                break
            time.sleep(0.25)
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        after = processes()
        alive_pids = {p[0] for p in after if '<defunct>' not in p[3]}
        facts['sigterm_seconds'] = round(time.monotonic() - started, 2)
        facts['group_survivors'] = [p[3][:100] for p in after if p[2] == self.proc.pid and '<defunct>' not in p[3]]
        facts['tracked_survivors'] = {w: len([pid for pid in v if pid in alive_pids]) for w, v in tracked.items()}
        facts['relay_survivors'] = len([pid for pid in relay_before if pid in alive_pids])
        facts['cli_exit'] = self.proc.poll()
        # Anything left is killed so the probe never leaks processes.
        leftovers = [p[0] for p in after if p[2] == self.proc.pid] + [pid for v in tracked.values() for pid in v if pid in alive_pids]
        for pid in leftovers:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        if self.host:
            # The app stops the host when the worker ends; the probe does the same and checks the socket is gone.
            self.host.terminate()
            try:
                self.host.wait(timeout=10)
                facts['host_exit'] = self.host.returncode
            except subprocess.TimeoutExpired:
                self.host.kill()
                facts['host_exit'] = 'killed'
            facts['socket_removed'] = not self.socket.exists()
            if self.host_log.exists():
                host_logs.append((self.name, self.host_log.read_bytes()))
        transcript = OUT / 'sessions' / (self.name + '.jsonl')
        transcript.write_text('\n'.join(json.dumps(e) for e in self.events) + '\n' + '\n'.join('STDERR ' + l for l in self.stderr) + '\n')
        transcripts.append(transcript)
        shutil.rmtree(self.worker, ignore_errors=True)
        if self.socket.parent != self.worker:
            try:
                self.socket.unlink()
            except OSError:
                pass
        facts['worker_removed'] = not self.worker.exists()
        return facts


def read_kv(path):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                values[key] = value
    if 'proc' in values:
        try:
            values['proc'] = json.loads(values['proc'])
        except ValueError:
            pass
    return values


def denials(stderr_lines):
    """nono's end-of-run denial summary (diagnostics on): the paths and services it blocked."""
    found, active = [], False
    for line in stderr_lines:
        text = line.strip()
        if text.startswith('Sandbox denial') or text.startswith('Also blocked') or text.startswith('Sandbox blocked') or text.startswith('Blocked inside'):
            active = True
            found.append(text)
            continue
        if active:
            if not text:
                active = False
                continue
            if text.startswith('/') or text.startswith('mach-') or text.startswith('user-preference') or text.startswith('forbidden') or \
                    text.startswith('file-') or text.startswith('process-') or text.startswith('network') or text.startswith('+'):
                found.append(text)
    return found[:80]


def exposed(values):
    """Token visibility for one Bash command, from boundary.txt; yes/no per channel."""
    def positive(key):
        value = values.get(key, '0')
        return value not in ('0', 'unreadable', 'no', '', None)
    proc = values.get('proc') if isinstance(values.get('proc'), dict) else {}
    return {'keychain_item': positive('keychain_item_secret'), 'keychain_item_absolute': positive('keychain_item_secret_absolute'),
            'credentials_file': positive('credentials_file'), 'environment': positive('env_oauth_token') or positive('env_sk_values'),
            'ancestor_environment': bool(proc.get('ancestor_env_token')), 'inherited_descriptor': bool(proc.get('fds_token'))}


# ---- check 1: credentials -------------------------------------------------------------------------------------------
OPTIONS = {
    'a': 'mediated security with keychain_access read (Keychain item through a PATH shim)',
    'b': '.credentials.json in CLAUDE_CONFIG_DIR (scratch profile copy without the refresh token)',
    'c': 'CLAUDE_CODE_OAUTH_TOKEN in the environment',
    'd': 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3: token as the first stdin line, moved to fd 3 by a zsh launcher inside the sandbox; CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH=1',
    'e': 'as d with a stale token: the CLI must ask the host for a fresh one (oauth_token_refresh over stdio)',
}
qualifying = []
working = []


def credential_session(option, name, mediated_extra=(), diagnostics=False):
    marker = 'sbm' + uuid.uuid4().hex[:10]
    project = make_project(name, marker)
    mediated = list(mediated_extra)
    credential_env, pipe, profile, refresh = {}, None, None, None
    if option == 'a':
        mediated.append(('security', '/usr/bin/security', {'keychain_access': 'read'}))
    elif option == 'b':
        profile = WORK / name / 'profile'
        profile.mkdir(mode=0o700)
        credentials = profile / '.credentials.json'
        descriptor = os.open(str(credentials), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(descriptor, SECRET.file_document().encode())
        os.close(descriptor)
        for entry in ['skill-plugins']:
            if (PROFILE / entry).exists():
                os.symlink(PROFILE / entry, profile / entry)
    elif option == 'c':
        credential_env = {'CLAUDE_CODE_OAUTH_TOKEN': SECRET.token}
    elif option == 'd':
        credential_env = {'CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH': '1'}
        pipe, refresh = SECRET.token, SECRET.token
    elif option == 'e':
        credential_env = {'CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH': '1'}
        pipe, refresh = 'sk-ant-oat01-' + 'x' * 95, SECRET.token
    session = Session(name, option, project, marker, mediated=mediated, diagnostics=diagnostics, profile=profile)
    session.launch = dict(credential_env=credential_env, token_for_pipe=pipe, refresh_token=refresh)
    return session


def wipe_profile(name):
    credentials = WORK / name / 'profile/.credentials.json'
    if credentials.exists():
        size = credentials.stat().st_size
        with credentials.open('r+b') as handle:
            handle.write(b'\0' * size)
        credentials.unlink()


if '1' in GROUPS:
    if not SECRET.ready:
        record('1/credentials', 'skipped', True, reason=SECRET.reason)
    else:
        for option in args.options.split(','):
            name = 'cred-' + option
            if option in ('a',) and SECRET.minutes is not None and SECRET.minutes < 30:
                record('1%s/credentials' % option, 'skipped', False, option=OPTIONS[option],
                       reason='stored token expires in %s min; a refresh would rotate the app login and could not be written back' % SECRET.minutes)
                continue
            session = None
            facts = {'option': OPTIONS[option], 'load': load()}
            try:
                session = credential_session(option, name)
                session.start(**session.launch)
                pong = session.turn('Reply with the single word pong and nothing else.')
                facts['turn'] = {k: pong.get(k) for k in ['result', 'is_error', 'error', 'seconds']}
                facts['started_turn'] = bool(pong.get('result')) and 'pong' in pong.get('result', '').lower() and not pong.get('is_error')
                facts['refresh_requests'] = session.refresh_requests
                if facts['started_turn']:
                    check = session.turn('Use the Bash tool to run exactly this command from the current directory: zsh checks/boundary.sh\n'
                                         'Then reply with the last line it printed.')
                    values = read_kv(session.project / '.probe-out/boundary.txt')
                    facts['bash_ran'] = bool(values)
                    facts['permission_requests'] = check.get('permissions')
                    facts['visible'] = exposed(values)
                    facts['keychain_scope'] = {'other_item_attributes_rc': values.get('keychain_other_item_attributes_rc'),
                                               'items_listed': values.get('keychain_items_listed')}
                    facts['proc'] = values.get('proc')
                    facts['env_oauth_names'] = values.get('env_oauth_names')
                    facts['bash_fd_list'] = values.get('bash_fd_list')
                    facts['cli_fd3_type'] = values.get('lsof_cli_fd3')
                if option == 'a':
                    facts['refresh_write'] = 'not measured: keychain_access read only; a write test would need readwrite on the app login item'
                if option in ('b', 'c', 'd'):
                    facts['refresh'] = 'not measured in this option: the CLI cannot refresh without the refresh token' if option in ('b', 'c') else \
                        'see option e (host refresh over stdio)'
            except Exception as error:
                facts['error'] = repr(error)[:600]
            finally:
                if session:
                    facts['teardown'] = session.stop()
                    facts['stderr_tail'] = [l[:200] for l in session.stderr[-4:]]
                wipe_profile(name)
            visible = facts.get('visible', {})
            leaks = [k for k, v in visible.items() if v]
            facts['token_visible_to_bash'] = 'yes: ' + ','.join(leaks) if leaks else ('no' if facts.get('bash_ran') else 'not measured')
            if option == 'e':
                facts['host_refresh_worked'] = bool(facts.get('started_turn')) and facts.get('refresh_requests', 0) > 0
            ok = bool(facts.get('started_turn')) and facts.get('bash_ran') and not leaks
            if facts.get('started_turn'):
                working.append(option)
            if ok:
                qualifying.append(option)
            record('1%s/credentials' % option, 'pass' if ok else 'fail', False, **facts)
        record('1/credential-choice', 'pass' if qualifying else 'fail', True, qualifying=qualifying, working=working,
               token_id=SECRET.ident, expires_in_min=SECRET.minutes,
               note='an option qualifies when the CLI answers a turn and no Bash channel sees the token')

# ---- checks 2-6: one main session -----------------------------------------------------------------------------------
if GROUPS & {'2', '3', '4', '5', '6'}:
    if not SECRET.ready:
        for group in sorted(GROUPS & {'2', '3', '4', '5', '6'}):
            record('%s/main-session' % group, 'skipped', True, reason=SECRET.reason)
    else:
        option = args.main_option or next((o for o in ['d', 'c', 'b', 'a', 'e'] if o in qualifying), None) or \
            next((o for o in ['d', 'c', 'b', 'a'] if o in working), 'a')
        target = 'sb-probe-target-' + uuid.uuid4().hex[:8]
        sleeper = subprocess.Popen(['/bin/sleep', '900'], start_new_session=True)  # outside the boundary
        outside = subprocess.Popen(['/usr/bin/python3', '-I', '-c', 'import time; time.sleep(900)', target], start_new_session=True)
        mediated = [('pgrep', '/usr/bin/pgrep', {}), ('lsof', '/usr/sbin/lsof', {}), ('sysctl', '/usr/sbin/sysctl', {}),
                    ('ps', '/bin/ps', {'unsafe_macos_seatbelt_rules': ['(allow process-info*)']}),
                    ('log', '/usr/bin/log', {'unsafe_macos_seatbelt_rules': ['(allow process-info*)', '(allow file-read* (subpath "/private/var/db/diagnostics") (subpath "/private/var/db/uuidtext"))',
                                                                              '(allow mach-lookup (global-name "com.apple.logd") (global-name "com.apple.logd.admin") (global-name "com.apple.diagnosticd"))']})]
        if args.osascript:
            mediated.append(('osascript', '/usr/bin/osascript', {'unsafe_macos_seatbelt_rules': ['(allow appleevent-send)', '(allow mach-lookup (global-name "com.apple.coreservices.appleevents"))']}))
        session = None
        main_facts = {'credential_option': option, 'load': load()}
        try:
            session = credential_session(option, 'main', mediated_extra=mediated, diagnostics=True)
            session.start(**session.launch)
            project = session.project
            (project / 'checks/runtime.sh').write_text(RUNTIME_SCRIPT % {'target': json.dumps(target), 'osascript': '1' if args.osascript else '0', 'marker': session.marker})
            t1 = session.turn('Do two things. First, use the Bash tool to run: echo SB_ECHO_OK. Second, use the Read tool to read the file README.txt '
                              'in the current directory. Then reply with the first line of README.txt.')
            init = session.init or {}
            servers = {s.get('name'): s.get('status') for s in init.get('mcp_servers', [])}
            tools = init.get('tools', [])
            skills = [c for c in init.get('slash_commands', []) if ':' in str(c)] + [s for s in init.get('skills', []) if ':' in str(s)]
            echo_ok = any('SB_ECHO_OK' in o['text'] for o in t1.get('outputs', []))
            read_ok = any(('SB-README-' + session.marker) in o['text'] for o in t1.get('outputs', []))
            if '2' in GROUPS:
                record('2/bash-echo', 'pass' if echo_ok else 'fail', True, tools=[t['name'] for t in t1.get('tools', [])], error=t1.get('error'),
                       permission_requests=t1.get('permissions'))
                record('2/read-project-file', 'pass' if read_ok else 'fail', True, result=(t1.get('result') or '')[:120])
                record('2/skills-plugins', 'pass' if skills else 'fail', False, skills_loaded=len(skills),
                       grants=[p for p in skill_targets() if not p.startswith(str(PROFILE) + '/')])
            t2 = session.turn('Use the Bash tool to run exactly this command from the current directory: zsh checks/runtime.sh\n'
                              'Then reply with the last line it printed.')
            runtime = read_kv(project / '.probe-out/runtime.txt')
            if '3' in GROUPS:
                t3 = session.turn('Call the tool mcp__sbprobe__probe_echo and then the tool mcp__project_probe__project_echo, '
                                  'both without arguments. Reply with both tool outputs verbatim.')
                outputs = ' '.join(o['text'] for o in t3.get('outputs', []))
                relay_ok = 'sbprobe-probe_echo keychains_listable=1' in outputs
                inner_ok = 'project_probe-project_echo keychains_listable=0' in outputs
                record('3/relay-server', 'pass' if servers.get('sbprobe') == 'connected' and 'mcp__sbprobe__probe_echo' in tools and relay_ok else 'fail', True,
                       status=servers.get('sbprobe'), listed='mcp__sbprobe__probe_echo' in tools, call_outside_boundary=relay_ok,
                       permission_requests=t3.get('permissions'))
                record('3/project-mcp-server', 'pass' if servers.get('project_probe') == 'connected' and inner_ok else 'fail', True,
                       status=servers.get('project_probe'), listed='mcp__project_probe__project_echo' in tools, call_inside_boundary=inner_ok,
                       note='--strict-mcp-config: the app passes approved .mcp.json servers through --mcp-config; they run inside the boundary')
            if '4' in GROUPS:
                pgrep_n = int(runtime.get('pgrep_target', '0') or 0)
                record('4/pgrep-mediated', 'pass' if pgrep_n >= 1 else 'fail', True, matches=pgrep_n, pgrep_lf=runtime.get('pgrep_lf_target'),
                       rules='none needed as a mediated command; in the plain session pgrep sees only same-sandbox processes')
                lsof = runtime.get('lsof_listen_rc', '')
                record('4/lsof-mediated', 'pass' if lsof.startswith('0') else 'fail', True, listen=lsof, pid=runtime.get('lsof_pid_rc'))
                record('4/sysctl-loadavg', 'pass' if runtime.get('sysctl_loadavg') == '0' else 'fail', True, rc=runtime.get('sysctl_loadavg'),
                       note='works in the plain session too; mediation not needed')
                ps = runtime.get('ps_rc', '')
                record('4/ps-mediated', 'pass' if ps.startswith('0') else 'fail', False, result=ps,
                       note='/bin/ps is setuid root; Seatbelt refuses setuid execs inside any sandbox (forbidden-exec-sugid), mediated or not; pgrep -lf is the substitute')
                log_show = runtime.get('log_show_rc', '')
                record('4/log-show-mediated', 'pass' if log_show.startswith('0') and 'lines=0' not in log_show else 'fail', False, result=log_show,
                       absolute=runtime.get('log_show_absolute_rc'), zsh_builtin_log_rc=runtime.get('zsh_builtin_log_rc'),
                       note='log(1) refuses to run sandboxed ("Cannot run while sandboxed"); every nono mediated command runs in a command sandbox')
                pkill = runtime.get('pkill_rc', '')
                alive = outside.poll() is None
                record('4/pkill-refused', 'pass' if alive and not pkill.startswith('0') else 'fail', True, result=pkill, target_alive=alive)
                shot = runtime.get('screencapture_rc', '')
                record('4/screencapture-refused', 'pass' if shot.startswith('0') is False and 'file=no' in shot else 'fail', True, result=shot)
                if args.osascript:
                    record('4/osascript-mediated', 'pass' if runtime.get('osascript_appleevent_rc') == '0' else 'fail', False,
                           plain=runtime.get('osascript_plain_rc'), appleevent=runtime.get('osascript_appleevent_rc'))
                else:
                    record('4/osascript-mediated', 'skipped', False, reason='off by default; pass --osascript')
            if '5' in GROUPS:
                proc = runtime.get('proc') if isinstance(runtime.get('proc'), dict) else {}
                ancestors = proc.get('ancestors', [])
                nested = 'sandbox-exec' in ancestors
                record('5/cli-sandbox-off', 'pass' if runtime and not nested else 'fail', True, ancestors=ancestors[:8],
                       settings={'sandbox': {'enabled': False}})
                record('5/swift-version', 'pass' if runtime.get('swift_version_rc') == '0' else 'fail', True, rc=runtime.get('swift_version_rc'),
                       xcrun_find=runtime.get('xcrun_find_rc'))
                record('5/external-sandbox-env', 'pass' if runtime.get('external_env') == '1' else 'fail', True, value=runtime.get('external_env'),
                       tmpdir_is_worker=runtime.get('tmpdir_is_worker'), tmpdir_write_rc=runtime.get('tmpdir_write_rc'))
            if '2' in GROUPS:
                record('2/usr-bin-python3', 'pass' if runtime.get('python_usr_bin') == '42' else 'fail', True, output=runtime.get('python_usr_bin'))
            if '6' in GROUPS:
                t4 = session.turn('Start three things and do not wait for any of them to finish:\n'
                                  '1. Call the Bash tool with run_in_background set to true and the command: sleep 313\n'
                                  '2. Call the Bash tool with run_in_background set to true and the command: lsof -r 5 -nP -iTCP -sTCP:LISTEN > /dev/null\n'
                                  '3. Call the Agent tool with run_in_background set to true, subagent_type general-purpose, description "sleeper", and the '
                                  'prompt: "Use the Bash tool to run the command sleep 317 (not in the background), then reply done."\n'
                                  'After starting all three, reply with the single word started.')
                main_facts['teardown_turn'] = {'tools': [t['name'] for t in t4.get('tools', [])], 'error': t4.get('error')}
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    rows = processes()
                    seen = {w: any(w in p[3] for p in rows) for w in ['sleep 313', 'sleep 317', 'lsof -r 5']}
                    if all(seen.values()):
                        break
                    time.sleep(1)
                main_facts['before_sigterm'] = seen
        except Exception as error:
            main_facts['error'] = repr(error)[:800]
        finally:
            teardown = session.stop(watch=['sleep 313', 'sleep 317', 'lsof -r 5']) if session else {}
            for child in (sleeper, outside):
                child.kill()
            denied = denials(session.stderr) if session else []
            main_facts['stderr_tail'] = [l[:200] for l in (session.stderr[-3:] if session else [])]
        if '2' in GROUPS:
            record('2/denials', 'info', False, nono_denials=denied, grants=session.grants() if session else None,
                   note='nono diagnostics of the main session (the app runs with --silent --no-diagnostics)')
        if '6' in GROUPS:
            seen = main_facts.get('before_sigterm', {})
            survivors = teardown.get('tracked_survivors', {})
            ok = (teardown.get('group_survivors') == [] and teardown.get('relay_survivors') == 0 and all(v == 0 for v in survivors.values())
                  and teardown.get('socket_removed') and teardown.get('worker_removed') and all(seen.values()) and bool(seen))
            record('6/teardown', 'pass' if ok else 'fail', True, started=seen, **teardown)
        if main_facts.get('error'):
            record('2/main-session-error', 'fail', True, **main_facts)
        else:
            record('2/main-session', 'info', False, **main_facts)

# ---- secrets absent from logs and output ------------------------------------------------------------------------------
if SECRET.ready:
    host_hits = [name for name, data in host_logs if SECRET.found_in(data)]
    record('1/secret-absent-host-log', 'pass' if not host_hits else 'fail', True, logs=len(host_logs), hits=host_hits)
    output_hits = [str(p.relative_to(OUT)) for p in OUT.rglob('*') if p.is_file() and SECRET.found_in(p.read_bytes())]
    record('1/secret-absent-probe-output', 'pass' if not output_hits else 'fail', True, files=len(list(OUT.rglob('*'))), hits=output_hits)
    snapshot_hits = []
    for folder in ['shell-snapshots', 'session-env']:
        base = PROFILE / folder
        if base.is_dir():
            for path in base.rglob('*'):
                try:
                    if path.is_file() and path.stat().st_mtime >= STARTED - 5 and SECRET.found_in(path.read_bytes()):
                        snapshot_hits.append(folder + '/' + path.name)
                except OSError:
                    pass
    record('1/secret-absent-shell-snapshots', 'pass' if not snapshot_hits else 'fail', True, hits=snapshot_hits)
    predicate = ('process == "%s" OR process == "nono" OR process == "security" OR process == "securityd" OR process == "Python" '
                 'OR process == "python3" OR process == "zsh" OR process == "bash"') % CLAUDE.name
    try:
        unified = subprocess.Popen(['/usr/bin/log', 'show', '--start', START_TEXT, '--style', 'compact', '--info', '--debug', '--predicate', predicate],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        hit, size, tail = False, 0, b''
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            chunk = unified.stdout.read(1 << 20)
            if not chunk:
                break
            size += len(chunk)
            if SECRET.found_in(tail + chunk):
                hit = True
            tail = chunk[-200:]
        unified.kill()
        unified.wait()
        record('1/secret-absent-unified-log', 'pass' if not hit else 'fail', True, bytes_scanned=size, predicate=predicate, since=START_TEXT)
    except OSError as error:
        record('1/secret-absent-unified-log', 'skipped', True, reason=repr(error))

for group, label in [('1', 'credentials'), ('2', 'runtime-tree'), ('3', 'mcp-relay'), ('4', 'process-information'), ('5', 'nested-sandbox'), ('6', 'teardown')]:
    if group not in GROUPS:
        record('%s/%s' % (group, label), 'skipped', True, reason='not selected in this run (--only %s)' % args.only)

# ---- summary ---------------------------------------------------------------------------------------------------------
if not args.keep:
    shutil.rmtree(WORK, ignore_errors=True)
else:
    for path in WORK.rglob('.credentials.json'):
        path.unlink()
failed = [r['check'] for r in results if r['required'] and r['status'] == 'fail']
skipped = [r['check'] for r in results if r['required'] and r['status'] == 'skipped']
summary = {'stamp': STAMP, 'cli': str(CLAUDE), 'cli_version': CLAUDE.name, 'profile': str(PROFILE), 'nono': NONO, 'model': args.model,
           'checks': len(results), 'required_failed': failed, 'required_skipped': skipped,
           'credential_qualifying': qualifying, 'credential_working': working, 'token_id': SECRET.ident,
           'statuses': {r['check']: r['status'] for r in results}, 'seconds': round(time.time() - STARTED, 1)}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True))
print('RESULTS', OUT / 'results.jsonl')
print('SUMMARY', 'required failed: %s' % failed if failed else 'all required checks passed', '| skipped: %s' % skipped if skipped else '')
sys.exit(1 if failed else 0)
