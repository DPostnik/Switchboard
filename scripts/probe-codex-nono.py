#!/usr/bin/env python3
"""Codex app-server under the pinned nono helper, option 1 shape (credential-free, loopback model fixture).

Session sandbox = project + toolchain caches; command mediation only for `security` (Keychain); app-owned
MCP servers run outside the boundary behind SandboxRuntime/mcp_host.py and reach Codex through
mcp_relay.py over one unix socket. Three cases: developer, developer with another project's workdir,
reader. Every case asserts zero approval callbacks, MCP tool discovery and process-group teardown.
Writes docs/handoffs/permission-runtime-2026-11-11/codex-nono-results.json. Run outside an enclosing
Seatbelt sandbox.
"""
import argparse
import http.server
import json
import os
import pathlib
import queue
import shutil
import signal
import subprocess
import tempfile
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import nono_git_policy  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--nono', required=True, help='Verified helper from prepare-nono.py')
parser.add_argument('--codex', default=str(pathlib.Path.home() / 'Library/Application Support/Switchboard/agents/codex/bin/codex'))
args = parser.parse_args()

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = str(pathlib.Path(args.codex).resolve())
NONO = str(pathlib.Path(args.nono).resolve())
OUT = ROOT / 'docs/handoffs/permission-runtime-2026-11-11'
OUT.mkdir(parents=True, exist_ok=True)
DEVELOPER = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
TOOLCHAIN = DEVELOPER / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
RELAY = ROOT / 'SandboxRuntime/mcp_relay.py'
HOST = ROOT / 'SandboxRuntime/mcp_host.py'
SETSID = ['/usr/bin/python3', '-I', '-c', 'import os,sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])']
(ROOT / '.build/nono-integration').mkdir(parents=True, exist_ok=True)
root = pathlib.Path(tempfile.mkdtemp(prefix='codex-', dir=str(ROOT / '.build/nono-integration'))).resolve()
results = {}
MCP_SERVER = r'''
import json, sys
def reply(i, result): sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'result': result}) + '\n'); sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line)
    if m.get('method') == 'initialize':
        reply(m['id'], {'protocolVersion': m['params'].get('protocolVersion', '2025-03-26'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'probe', 'version': '1'}})
    elif m.get('method') == 'tools/list':
        reply(m['id'], {'tools': [{'name': 'probe_echo', 'description': 'Echo', 'inputSchema': {'type': 'object', 'properties': {}}}]})
    elif m.get('method') == 'tools/call':
        reply(m['id'], {'content': [{'type': 'text', 'text': 'echo'}]})
    elif 'id' in m:
        reply(m['id'], {})
'''


def ps_has(text):
    return text in subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout


try:
    for name in ['developer', 'other-workdir', 'reader']:
        case = root / name
        for sub in ['project', 'other', 'cache', 'home', 'tmp', 'config', 'state', 'outside']:
            (case / sub).mkdir(parents=True)
        project, other, cache, home = case / 'project', case / 'other', case / 'cache', case / 'home'
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        subprocess.run(['git', 'init', '-q', str(other)], check=True)
        reader = name == 'reader'
        workdir = other if name == 'other-workdir' else project
        commands = [
            {'cmd': 'printf WRITE > marker && cat marker', 'workdir': str(workdir)},
            {'cmd': 'printf WRITE > marker && cat marker', 'workdir': str(workdir)},
            {'cmd': f'printf CACHE > "{cache}/marker" && cat "{cache}/marker"', 'workdir': str(workdir)},
            {'cmd': f'"{TOOLCHAIN}/swiftc" --version > /dev/null && echo TOOLCHAIN', 'workdir': str(workdir)},
            {'cmd': 'security find-identity -v -p codesigning | grep -c "Apple Development"', 'workdir': str(workdir)},
            # Every other `security` form is refused by the argument allow-list (output discarded, exit 0 = refused).
            {'cmd': '! security dump-keychain > /dev/null 2>&1 && ! security find-generic-password -s switchboard-probe-unlisted -w > /dev/null 2>&1'
                    ' && ! security find-internet-password -s github.com -w > /dev/null 2>&1', 'workdir': str(workdir)},
            # Narrowed git, same planner shape as Claude (invariant 14): the queue's network shape reaches the remote with the
            # Keychain; an alias, injected config, `ext::` and `git credential` do not. Exit 0 = every check as expected.
            {'cmd': f'git -C "{ROOT}" ls-remote --refs origin refs/heads/main > /dev/null 2>&1'
                    f' && ! git -c "alias.kc=!test -r \'{pathlib.Path.home()}/Library/Keychains/login.keychain-db\'" kc > /dev/null 2>&1'
                    f' && ! env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.inj GIT_CONFIG_VALUE_0="!true" git inj > /dev/null 2>&1'
                    f' && ! git -C "{ROOT}" ls-remote "ext::sh -c true" > /dev/null 2>&1'
                    f' && ! git credential fill < /dev/null > /dev/null 2>&1', 'workdir': str(workdir)},
        ]
        requests, events, calls = [], [], []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(body)
                index = len(requests)
                if index <= len(commands):
                    item = {'type': 'function_call', 'id': 'fc_%d' % index, 'call_id': 'call_%d' % index, 'name': 'exec_command',
                            'arguments': json.dumps(dict(commands[index - 1], sandbox_permissions='use_default'))}
                else:
                    item = {'type': 'message', 'id': 'msg_end', 'role': 'assistant', 'status': 'completed',
                            'content': [{'type': 'output_text', 'text': 'Fixture complete.'}]}
                output = [{'type': 'response.created', 'response': {'id': 'resp_%d' % index, 'status': 'in_progress', 'output': []}},
                          {'type': 'response.output_item.added', 'output_index': 0, 'item': item},
                          {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                          {'type': 'response.completed', 'response': {'id': 'resp_%d' % index, 'status': 'completed', 'output': [item],
                                                                      'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
                data = ''.join('event: %s\ndata: %s\n\n' % (e['type'], json.dumps(e)) for e in output).encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(data))); self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        # App-owned MCP server outside the boundary: host + spec live in `outside`, which the session cannot read.
        outside = case / 'outside'
        (outside / 'probe_server.py').write_text(MCP_SERVER)
        (outside / 'servers.json').write_text(json.dumps({'servers': {'probe': {'command': '/usr/bin/python3', 'args': ['-I', str(outside / 'probe_server.py')]}}}))
        # AF_UNIX paths are limited to 104 bytes on macOS: the socket lives in a short private directory.
        sockdir = pathlib.Path(tempfile.mkdtemp(prefix='sb-mcp-', dir='/tmp'))
        os.chmod(sockdir, 0o700)
        sock = sockdir / 'mcp.sock'
        host = subprocess.Popen(['/usr/bin/python3', '-I', str(HOST), '--socket', str(sock), '--spec', str(outside / 'servers.json'),
                                 '--log', str(outside / 'host.log')], stdout=subprocess.PIPE, text=True)
        assert host.stdout.readline().strip() == 'ready'
        (home / 'config.toml').write_text(
            'model_provider="fixture"\nmodel="gpt-6-astra"\n[model_providers.fixture]\nname="Local fixture"\nwire_api="responses"\n'
            'base_url="http://127.0.0.1:%d/v1"\nrequires_openai_auth=false\nsupports_websockets=false\nrequest_max_retries=0\nstream_max_retries=0\n'
            '[projects.%s]\ntrust_level="trusted"\n'
            '[mcp_servers.probe]\ncommand="/usr/bin/python3"\nargs=%s\nstartup_timeout_sec=30\n'
            % (server.server_port, json.dumps(str(project)), json.dumps(['-I', str(RELAY), str(sock), 'probe'])))
        env = {'HOME': str(pathlib.Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', 'CODEX_HOME': str(home),
               'TMPDIR': str(case / 'tmp'), 'XDG_CONFIG_HOME': str(case / 'config'), 'XDG_STATE_HOME': str(case / 'state'), 'LANG': 'en_US.UTF-8'}
        policy = case / 'policy.json'
        policy.write_text(json.dumps({
            'meta': {'name': 'switchboard-codex-probe', 'version': '1'}, 'workdir': {'access': 'none'},
            'command_policies': {
                'executable_dirs': [str(TOOLCHAIN), str(DEVELOPER / 'usr/bin')],
                # The app's shape: sandbox in the session edge, argument allow-list with default deny.
                'commands': {'security': {'executable': '/usr/bin/security', 'from': {'session': {
                    'sandbox': {'keychain_access': 'read', 'fs_read': [str(project)], 'network': {'allow_all': False}},
                    'invocation_policy': {'default': 'deny', 'allow': [{'argv': {'prefix': ['find-identity']}}]}}}},
                    'git': nono_git_policy.git_policy(
                        {'fs_read': [str(project), str(other), str(cache), str(ROOT), '/opt/homebrew', str(pathlib.Path.home() / '.config/git')],
                         'fs_read_file': [str(pathlib.Path.home() / '.gitconfig')],
                         'fs_write': [] if reader else [str(project), str(cache)], 'fs_write_file': []},
                        pathlib.Path.home(), [project, ROOT])}}}))
        grants = [('--read' if reader else '--allow', project), ('--read' if reader else '--allow', cache), ('--read', other),
                  ('--read', ROOT), ('--read', '/opt/homebrew'), ('--read-file', pathlib.Path.home() / '.gitconfig'),
                  ('--allow', home), ('--allow', case / 'tmp'), ('--read', pathlib.Path(BIN).parent), ('--read', DEVELOPER),
                  ('--read-file', RELAY), ('--allow-unix-socket', sock)]
        command = SETSID + [NONO, 'run', '--silent', '--no-audit', '--no-diagnostics', '--no-rollback', '--profile', str(policy)]
        for mode, path in grants:
            command += [mode, str(path)]
        command += ['--', BIN, 'app-server', '--listen', 'stdio://', '-c', 'analytics.enabled=false']
        proc = subprocess.Popen(command, env=env, cwd=str(home), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, bufsize=1)
        q = queue.Queue()
        print(name, 'pid', proc.pid, flush=True)

        def read(stream, kind):
            for line in stream:
                q.put((kind, line))
            q.put(('exit', kind))

        threading.Thread(target=read, args=(proc.stdout, 'out'), daemon=True).start()
        threading.Thread(target=read, args=(proc.stderr, 'err'), daemon=True).start()

        def send(v):
            proc.stdin.write(json.dumps(v) + '\n'); proc.stdin.flush()

        def receive():
            kind, line = q.get(timeout=60)
            if kind == 'exit':
                raise RuntimeError('EOF from ' + line + '; exit=' + str(proc.poll()))
            if kind == 'err':
                events.append({'stderr': line.strip()}); return {}
            v = json.loads(line); events.append(v)
            if 'id' in v and 'method' in v:
                calls.append(v)
                # Never auto-approve: decline control requests, refuse anything else.
                if v['method'] == 'item/commandExecution/requestApproval':
                    send({'id': v['id'], 'result': {'decision': 'decline'}})
                else:
                    send({'id': v['id'], 'error': {'code': -32601, 'message': 'Fixture refuses unsupported request'}})
            return v

        def rpc(i, m, params):
            send({'id': i, 'method': m, 'params': params})
            while True:
                v = receive()
                if v.get('id') == i and 'method' not in v:
                    if 'error' in v:
                        raise RuntimeError(m + ': ' + json.dumps(v['error']))
                    return v

        summary = {'approvals': 0, 'commands': [], 'mcp_tools': [], 'error': None}
        try:
            rpc(1, 'initialize', {'clientInfo': {'name': 'switchboard_probe', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
            send({'method': 'initialized'})
            t = rpc(2, 'thread/start', {'cwd': str(project), 'ephemeral': True, 'approvalPolicy': 'never', 'sandbox': 'workspace-write'})
            tid = t['result']['thread']['id']
            for _ in range(20):
                status = rpc(3, 'mcpServerStatus/list', {'threadId': tid, 'detail': 'toolsAndAuthOnly'})
                probe = [s for s in status['result'].get('data', []) if s.get('name') == 'probe']
                if probe and probe[0].get('tools'):
                    summary['mcp_tools'] = sorted(probe[0]['tools'].keys()) if isinstance(probe[0]['tools'], dict) else [t.get('name') for t in probe[0]['tools']]
                    break
                time.sleep(0.5)
            rpc(4, 'turn/start', {'threadId': tid, 'approvalPolicy': 'never',
                                  'sandboxPolicy': {'type': 'externalSandbox', 'networkAccess': 'enabled'},
                                  'input': [{'type': 'text', 'text': 'Run the local fixture.', 'text_elements': []}]})
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                v = receive()
                if v.get('method') == 'turn/completed':
                    break
        except Exception as error:
            summary['error'] = repr(error)
        completed = [e['params']['item'] for e in events if e.get('method') == 'item/completed' and e.get('params', {}).get('item', {}).get('type') == 'commandExecution']
        summary['commands'] = [{'exit': i.get('exitCode'), 'output': (i.get('aggregatedOutput') or '')[:120].strip()} for i in completed]
        summary['approvals'] = len(calls)
        summary['model_requests'] = len(requests)
        # Teardown: the group signal must end the helper, Codex and the relay; the host stops its server.
        def group_members():
            rows = subprocess.run(['/bin/ps', '-axo', 'pid=,pgid=,command='], capture_output=True, text=True).stdout.splitlines()
            return [r.strip() for r in rows if r.split() and r.split()[1] == str(proc.pid)]
        members_before = group_members()
        relay_rows = [r for r in subprocess.run(['/bin/ps', '-axo', 'pid=,pgid=,command='], capture_output=True, text=True).stdout.splitlines() if 'mcp_relay.py ' + str(sock) in r]
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
        started = time.monotonic()
        while time.monotonic() - started < 6 and group_members():
            time.sleep(0.25)
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        survivors = [r for r in group_members() if '<defunct>' not in r]
        if survivors:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except PermissionError:
                for row in survivors:
                    try:
                        os.kill(int(row.split()[0]), signal.SIGKILL)
                    except OSError as error:
                        row_error = repr(error)
                        summary.setdefault('kill_errors', []).append(row[:90] + ' ' + row_error)
            time.sleep(1)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        started2 = time.monotonic()
        while time.monotonic() - started2 < 6 and ps_has('mcp_relay.py ' + str(sock)):
            time.sleep(0.25)
        summary['teardown'] = {'members_before': len(members_before), 'relay_in_group': all(r.split()[1] == str(proc.pid) for r in relay_rows) and bool(relay_rows),
                               'sigterm_survivors': [r[:90] for r in survivors], 'after_sigkill': [r[:90] for r in group_members()],
                               'relay_alive_after': ps_has('mcp_relay.py ' + str(sock)), 'seconds': round(time.monotonic() - started, 2)}
        host.terminate(); host.wait(timeout=10)
        shutil.rmtree(sockdir, ignore_errors=True)
        summary['markers'] = {'project': (project / 'marker').exists(), 'other': (other / 'marker').exists(), 'cache': (cache / 'marker').exists()}
        summary['stderr_tail'] = [e['stderr'] for e in events if 'stderr' in e][-5:]
        results[name] = summary
        server.shutdown(); server.server_close()
        print(name, json.dumps({k: v for k, v in summary.items() if k != 'stderr_tail'}), flush=True)
    (OUT / 'codex-nono-results.json').write_text(json.dumps(results, indent=2))
    failures = []
    for name, s in results.items():
        if s['error']:
            failures.append(name + ': ' + s['error'])
        if s['approvals']:
            failures.append(name + ': approval callbacks ' + str(s['approvals']))
        if s['mcp_tools'] != ['probe_echo']:
            failures.append(name + ': MCP tools through the relay ' + str(s['mcp_tools']))
        exits = [c['exit'] for c in s['commands']]
        # The cache grant does not depend on the command's workdir; a reader has no write grant at all.
        expected = [0, 0, 0, 0, 0, 0, 0] if name == 'developer' else ([1, 1, 0, 0, 0, 0, 0] if name == 'other-workdir' else [1, 1, 1, 0, 0, 0, 0])
        if exits != expected:
            failures.append(name + ': command exits ' + str(exits) + ' expected ' + str(expected))
        if name == 'developer' and len(s['commands']) > 4 and not s['commands'][4]['output'].endswith('1'):
            failures.append('developer: security identities ' + s['commands'][4]['output'])
        if s['markers'] != {'project': name == 'developer', 'other': False, 'cache': name != 'reader'}:
            failures.append(name + ': markers ' + str(s['markers']))
        if s['teardown']['members_before'] < 2 or s['teardown']['after_sigkill'] or s['teardown']['relay_alive_after']:
            failures.append(name + ': teardown ' + str(s['teardown']))
    for f in failures:
        print('FAIL', f)
    print('PASS: Codex externalSandbox under nono (option 1): repeated writes, caches, toolchain, Keychain mediation with argument allow-list, MCP relay, denials, teardown'
          if not failures else 'FAILED %d checks' % len(failures))
finally:
    shutil.rmtree(root, ignore_errors=True)
