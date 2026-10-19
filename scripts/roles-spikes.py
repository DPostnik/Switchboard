#!/usr/bin/env python3 -I
"""Behavioural spikes for the agent roles plan (docs/agent-roles-plan.md, section 4.6).

Drives the pinned Claude CLI with the app's own profile (CLAUDE_CONFIG_DIR under the Switchboard data folder)
through the stream-json control protocol, exactly as the adapter does, and checks what the permission layers
really enforce. Each spike runs in a fresh temporary project. Nothing outside that folder is written.

Usage: python3 -I scripts/roles-spikes.py [spike ...]   (default: all)
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading, time, uuid

HOME = pathlib.Path.home() / 'Library/Application Support/Switchboard/claude'
CLI = pathlib.Path.home() / '.local/bin/claude'
MODEL = 'claude-sonnet-5-5'
PINNED = '2.1.292'


def env():
    e = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'] if k in os.environ}
    e['PATH'] = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    e['CLAUDE_CONFIG_DIR'] = str(HOME); e['DISABLE_AUTOUPDATER'] = '1'
    return e


class Run:
    """One CLI process. `on_permission(tool, input) -> 'allow'|'deny'`, `on_hook(event, input) -> dict|None`."""

    def __init__(self, cwd, args, hooks=None, on_permission=None, on_hook=None, resume=None):
        self.cwd = cwd; self.hooks = hooks or {}; self.on_permission = on_permission; self.on_hook = on_hook
        self.session = resume or str(uuid.uuid4())
        base = ['--print', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
                '--include-partial-messages', '--permission-prompt-tool', 'stdio', '--setting-sources', '',
                '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--disable-slash-commands',
                '--resume' if resume else '--session-id', self.session, '--model', MODEL]
        self.args = base + args
        self.events = []; self.permissions = []; self.hook_calls = []; self.result = None; self.hook_ms = []
        self.proc = None; self.pending = {}; self.lock = threading.Lock()

    def start(self):
        self.proc = subprocess.Popen([str(CLI)] + self.args, cwd=self.cwd, env=env(), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.reader = threading.Thread(target=self._read, daemon=True); self.reader.start()
        init = {'subtype': 'initialize', 'hooks': self.hooks or None}
        self.control(init)

    def _send(self, value):
        with self.lock:
            self.proc.stdin.write(json.dumps(value) + '\n'); self.proc.stdin.flush()

    def control(self, request, timeout=20):
        rid = str(uuid.uuid4()); ev = threading.Event(); self.pending[rid] = [ev, None]
        self._send({'type': 'control_request', 'request_id': rid, 'request': request})
        if not ev.wait(timeout): raise RuntimeError('control timeout: ' + request['subtype'])
        return self.pending.pop(rid)[1]

    def _respond(self, rid, response):
        self._send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': rid, 'response': response}})

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line: continue
            try: v = json.loads(line)
            except Exception: continue
            self.events.append(v)
            t = v.get('type')
            if t == 'control_response':
                r = v['response']; p = self.pending.get(r.get('request_id'))
                if p: p[1] = r.get('response'); p[0].set()
            elif t == 'control_request':
                req = v['request']; rid = v['request_id']; sub = req.get('subtype')
                if sub == 'can_use_tool':
                    name = req.get('tool_name'); inp = req.get('input')
                    decision = self.on_permission(name, inp) if self.on_permission else 'deny'
                    self.permissions.append((name, inp, decision))
                    if decision == 'allow': self._respond(rid, {'behavior': 'allow', 'updatedInput': inp})
                    else: self._respond(rid, {'behavior': 'deny', 'message': 'denied by spike'})
                elif sub == 'hook_callback':
                    started = time.monotonic()
                    out = self.on_hook(req.get('callback_id'), req.get('input')) if self.on_hook else {}
                    self.hook_calls.append((req.get('callback_id'), req.get('input'), out))
                    self._respond(rid, out or {})
                    self.hook_ms.append((time.monotonic() - started) * 1000)
                else:
                    self._send({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': rid, 'error': 'unsupported'}})
            elif t == 'result':
                self.result = v

    def ask(self, prompt, timeout=240):
        self._send({'type': 'user', 'session_id': self.session, 'uuid': str(uuid.uuid4()),
                    'message': {'role': 'user', 'content': prompt}})
        deadline = time.time() + timeout
        while self.result is None and time.time() < deadline and self.proc.poll() is None: time.sleep(0.2)
        return self.result

    def close(self):
        try: self.proc.terminate(); self.proc.wait(5)
        except Exception: pass
        err = self.proc.stderr.read() if self.proc.stderr else ''
        return err

    def tool_uses(self):
        out = []
        for e in self.events:
            if e.get('type') == 'assistant':
                for part in e['message'].get('content', []):
                    if part.get('type') == 'tool_use': out.append((part['name'], part.get('input'), e.get('parent_tool_use_id')))
        return out

    def tool_results(self):
        out = []
        for e in self.events:
            if e.get('type') == 'user':
                for part in e['message'].get('content', []) if isinstance(e['message'].get('content'), list) else []:
                    if part.get('type') == 'tool_result':
                        c = part.get('content'); text = c if isinstance(c, str) else json.dumps(c)[:400]
                        out.append((part.get('tool_use_id'), part.get('is_error'), text[:400]))
        return out

    def final_text(self):
        return (self.result or {}).get('result', '')


def project():
    root = pathlib.Path(tempfile.mkdtemp(prefix='roles-spike-'))
    (root / 'README.md').write_text('spike project\n')
    return root


def report(name, checks):
    ok = all(v for _, v in checks)
    print(f"\n=== {name}: {'PASS' if ok else 'FAIL'}")
    for label, v in checks: print(f"  [{'x' if v else ' '}] {label}")
    return ok


def spike1_subagent_cap():
    root = project(); outside = root.parent / (root.name + '-outside'); outside.mkdir(exist_ok=True)
    agents = {'worker': {'description': 'Read-only worker', 'prompt': 'You are a read-only worker. Do exactly what the parent asks and report the outcome truthfully, including tool errors.',
                         'tools': ['Read', 'Grep', 'Glob']}}
    settings = {'permissions': {'deny': ['Write(**)', 'Edit(**)']}}
    run = Run(str(root), ['--permission-mode', 'bypassPermissions', '--agents', json.dumps(agents), '--settings', json.dumps(settings)],
              on_permission=lambda n, i: 'deny')
    run.start()
    run.ask('Delegate to the `worker` subagent (use the Agent tool with subagent_type "worker", run_in_background false): '
            f'it must create the file {root}/worker.txt with the text "hi" using the Write tool, and then run the shell command `touch {root}/worker-bash.txt` with Bash. '
            'Do not do any of this yourself. After it returns, report verbatim which steps failed and why. Do not retry with other tools.')
    err = run.close()
    uses = run.tool_uses(); sub = [u for u in uses if u[2] is not None]
    checks = [
        ('parent used the Agent tool', any(u[0] == 'Agent' for u in uses)),
        ('worker did not create worker.txt', not (root / 'worker.txt').exists()),
        ('worker did not create worker-bash.txt', not (root / 'worker-bash.txt').exists()),
        ('worker tool calls were only Read/Grep/Glob or absent', all(u[0] in ('Read', 'Grep', 'Glob') for u in sub)),
        ('no can_use_tool reached the client', not run.permissions),
        ('result received', run.result is not None),
    ]
    print('  subagent tool uses:', [(u[0]) for u in sub]); print('  final:', run.final_text()[:500]); print('  stderr:', err[:300])
    return report('spike 1 subagent cap', checks)


def spike2_deny_inheritance():
    root = project()
    settings = {'permissions': {'deny': ['Write(**)', 'Edit(**)', 'Bash(touch:*)']}}
    run = Run(str(root), ['--permission-mode', 'bypassPermissions', '--settings', json.dumps(settings)], on_permission=lambda n, i: 'deny')
    run.start()
    run.ask(f'First, try yourself: create {root}/direct.txt with the Write tool, then run `touch {root}/direct-bash.txt` with Bash. '
            f'Second, delegate to a general-purpose subagent (Agent tool, run_in_background false) the same two steps with file names sub.txt and sub-bash.txt in {root}. '
            'Report verbatim which steps failed and why. Never work around a denial with another tool or command.')
    err = run.close()
    checks = [
        ('direct Write denied', not (root / 'direct.txt').exists()),
        ('direct Bash touch denied', not (root / 'direct-bash.txt').exists()),
        ('subagent Write denied', not (root / 'sub.txt').exists()),
        ('subagent Bash touch denied', not (root / 'sub-bash.txt').exists()),
        ('no can_use_tool reached the client', not run.permissions),
        ('result received', run.result is not None),
    ]
    print('  tool uses:', [(u[0], 'sub' if u[2] else 'main') for u in run.tool_uses()]); print('  final:', run.final_text()[:500]); print('  stderr:', err[:300])
    return report('spike 2 deny inheritance', checks)


def spike3_hook():
    root = project()
    hooks = {'PreToolUse': [{'matcher': 'Bash', 'hookCallbackIds': ['bash-guard'], 'timeout': 10}]}
    def on_hook(cb, inp):
        cmd = (inp or {}).get('tool_input', {}).get('command', '')
        if 'touch' in cmd or 'curl' in cmd:
            return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                           'permissionDecisionReason': 'blocked by the role (spike)'}}
        return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'}}
    run = Run(str(root), ['--permission-mode', 'bypassPermissions'], hooks=hooks, on_hook=on_hook, on_permission=lambda n, i: 'deny')
    run.start()
    run.ask(f'Run these shell commands one by one with Bash, each as its own call: (1) `echo first`, (2) `touch {root}/hooked.txt`, (3) `curl -sS https://example.com -o /dev/null`, (4) `echo last`. '
            'Report verbatim which commands were blocked and the reason given. Do not retry blocked commands with other tools or forms.')
    err = run.close()
    bash = [u for u in run.tool_uses() if u[0] == 'Bash']
    checks = [
        ('hook callbacks received', len(run.hook_calls) >= 2),
        ('hook saw the Bash command text', any('touch' in json.dumps(c[1]) for c in run.hook_calls)),
        ('touch was blocked (file absent)', not (root / 'hooked.txt').exists()),
        ('echo commands still ran', any('echo' in (u[1] or {}).get('command', '') for u in bash)),
        ('hook round trip under 50 ms on the client side', bool(run.hook_ms) and max(run.hook_ms) < 50),
        ('result received', run.result is not None),
    ]
    print('  hook calls:', [(c[0], (c[1] or {}).get('tool_input', {}).get('command'), (c[2] or {}).get('hookSpecificOutput', {}).get('permissionDecision')) for c in run.hook_calls])
    print('  results:', run.tool_results()[:6]); print('  final:', run.final_text()[:500]); print('  stderr:', err[:300])
    return report('spike 3 PreToolUse hook', checks)


def spike4_add_dir():
    root = project(); extra = root.parent / (root.name + '-extra'); extra.mkdir(exist_ok=True); outside = root.parent / (root.name + '-outside'); outside.mkdir(exist_ok=True)
    settings = {'permissions': {'additionalDirectories': [str(extra)]}}
    run = Run(str(root), ['--permission-mode', 'acceptEdits', '--tools', 'Read,Glob,Grep,Write,Edit', '--add-dir', str(extra), '--settings', json.dumps(settings)],
              on_permission=lambda n, i: 'deny')
    run.start()
    run.ask(f'Create three files with the Write tool, each as its own call, text "x": {root}/in.txt, {extra}/extra.txt, {outside}/out.txt. '
            'Report verbatim which writes were denied. Do not retry.')
    err = run.close()
    asked = [p[0] + ':' + str((p[1] or {}).get('file_path')) for p in run.permissions]
    checks = [
        ('write inside the project ran without a prompt', (root / 'in.txt').exists() and not any(str(root) + '/' in a for a in asked)),
        ('write inside the extra root ran without a prompt', (extra / 'extra.txt').exists() and not any(str(extra) + '/' in a for a in asked)),
        ('write outside both roots asked the client', any(str(outside) in a for a in asked)),
        ('outside write did not happen after deny', not (outside / 'out.txt').exists()),
        ('result received', run.result is not None),
    ]
    print('  asked:', asked); print('  final:', run.final_text()[:400]); print('  stderr:', err[:300])
    return report('spike 4 add-dir', checks)


def spike6_resume_fewer_tools():
    root = project()
    run = Run(str(root), ['--permission-mode', 'bypassPermissions', '--tools', 'Read,Glob,Grep,Write,Edit,Bash'], on_permission=lambda n, i: 'deny')
    run.start(); run.ask(f'Run `echo turn-one > {root}/one.txt` with Bash and reply "done".'); err1 = run.close()
    first_ok = (root / 'one.txt').exists()
    run2 = Run(str(root), ['--permission-mode', 'default', '--tools', 'Read,Glob,Grep'], resume=run.session, on_permission=lambda n, i: 'deny')
    run2.start(); run2.ask(f'Run `echo turn-two > {root}/two.txt` with Bash. If Bash is not available, say so and read {root}/one.txt instead.'); err2 = run2.close()
    uses = run2.tool_uses(); bash_ids = {u[1] for u in []}
    bash_ids = {part['id'] for e in run2.events if e.get('type') == 'assistant' for part in e['message'].get('content', []) if part.get('type') == 'tool_use' and part['name'] == 'Bash'}
    checks = [
        ('first turn ran Bash', first_ok),
        ('resumed session completed a turn', run2.result is not None and not run2.result.get('is_error')),
        ('any Bash call in the resumed turn was refused by the CLI', all(r[1] for r in run2.tool_results() if r[0] in bash_ids) and not (root / 'two.txt').exists()),
        ('resumed turn could still Read', any(u[0] == 'Read' for u in uses)),
    ]
    print('  second-turn tools:', [u[0] for u in uses]); print('  results:', run2.tool_results()[:4]); print('  final:', run2.final_text()[:400]); print('  stderr:', (err1 + err2)[:300])
    return report('spike 6 resume with fewer tools', checks)


SPIKES = {'1': spike1_subagent_cap, '2': spike2_deny_inheritance, '3': spike3_hook, '4': spike4_add_dir, '6': spike6_resume_fewer_tools}

# --- Spike 5: Codex re-resume with a changed per-thread config -------------------------------------------------------

CODEX = pathlib.Path('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex')
CODEX_HOME = pathlib.Path.home() / 'Library/Application Support/Switchboard/codex'


class CodexRun:
    def __init__(self):
        e = dict(os.environ); e['CODEX_HOME'] = str(CODEX_HOME)
        for k in ['OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL', 'OPENAI_API_BASE']: e.pop(k, None)
        self.proc = subprocess.Popen([str(CODEX), 'app-server', '--listen', 'stdio://', '-c', 'cli_auth_credentials_store="file"', '-c', 'analytics.enabled=false'],
                                     cwd=str(CODEX_HOME), env=e, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.seq = 0; self.pending = {}; self.notes = []; self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()
        self.request('initialize', {'clientInfo': {'name': 'roles_spike', 'title': 'Switchboard spike', 'version': '0.1.0'}, 'capabilities': {'experimentalApi': True}})
        self._send({'method': 'initialized', 'params': {}})

    def _send(self, v):
        with self.lock: self.proc.stdin.write(json.dumps(v) + '\n'); self.proc.stdin.flush()

    def request(self, method, params=None, timeout=60):
        self.seq += 1; rid = str(self.seq); ev = threading.Event(); self.pending[rid] = [ev, None, None]
        self._send({'id': rid, 'method': method, 'params': params or {}})
        if not ev.wait(timeout): raise RuntimeError('timeout ' + method)
        _, result, error = self.pending.pop(rid)
        if error: raise RuntimeError(f'{method}: {error}')
        return result

    def _read(self):
        for line in self.proc.stdout:
            try: v = json.loads(line)
            except Exception: continue
            if 'id' in v and ('result' in v or 'error' in v) and str(v['id']) in self.pending:
                p = self.pending[str(v['id'])]; p[1] = v.get('result'); p[2] = v.get('error'); p[0].set()
            elif 'method' in v and 'id' in v:
                # Server request (approval): decline, never approve in a spike.
                self._send({'id': v['id'], 'result': {'decision': 'denied'}})
            else: self.notes.append(v)

    def wait_turn(self, turn_id, timeout=240):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for n in self.notes:
                if n.get('method') == 'turn/completed' and n.get('params', {}).get('turn', {}).get('id') == turn_id: return n
            time.sleep(0.3)
        return None

    def items(self):
        return [n for n in self.notes if n.get('method', '').startswith('item/')]

    def close(self):
        try: self.proc.terminate(); self.proc.wait(5)
        except Exception: pass


def spike5_codex_reresume():
    root = project()
    toolbox = pathlib.Path(__file__).resolve().parent.parent / 'Tests' / 'Fixtures'
    # A tiny stdio MCP server that exposes one tool, so "is the server configured" is observable from the thread.
    server = root / 'spike-mcp.py'
    server.write_text('''#!/usr/bin/env python3
import sys, json
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    if 'id' not in m: continue
    mid = m['id']; method = m.get('method')
    if method == 'initialize': r = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'spike', 'version': '1'}}
    elif method == 'tools/list': r = {'tools': [{'name': 'spike_marker', 'description': 'Returns the marker word. Call it when asked for the marker.', 'inputSchema': {'type': 'object', 'properties': {}}}]}
    elif method == 'tools/call': r = {'content': [{'type': 'text', 'text': 'MARKER-ZEBRA-42'}]}
    else: r = {}
    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': mid, 'result': r}) + '\\n'); sys.stdout.flush()
''')
    def config(enabled):
        return {'mcp_servers.spike': {'command': '/usr/bin/python3', 'args': ['-I', str(server)], 'enabled': enabled, 'required': False, 'startup_timeout_sec': 20, 'tool_timeout_sec': 30}}
    base = {'approvalPolicy': 'never', 'sandbox': 'read-only', 'cwd': str(root), 'developerInstructions': 'Answer in one short line.'}
    c = CodexRun()
    try:
        variant0 = os.environ.get('SPIKE5_VARIANT', 'plain')
        t = c.request('thread/start', dict(base, config=config(variant0 == 'startconfig')))
        tid = t['thread']['id']
        print('  account:', json.dumps(c.request('account/read', {'refreshToken': False}))[:200])
        turn = c.request('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'Do you have a tool named spike_marker? Answer only YES or NO.', 'text_elements': []}],
                                        'approvalPolicy': 'never', 'sandboxPolicy': {'type': 'readOnly'}})
        done1 = c.wait_turn(turn['turn']['id']); print('  turn1 status:', (done1 or {}).get('params', {}).get('turn', {}).get('status'), json.dumps((done1 or {}).get('params', {}).get('turn', {}).get('error'))[:160]); texts1 = [json.dumps(n)[:300] for n in c.notes if n.get('method') == 'item/completed']
        count1 = len(c.notes)
        # Re-resume the live thread with the server enabled. Variants isolate the auth loss seen in 0.160.0.
        variant = os.environ.get('SPIKE5_VARIANT', 'plain')
        resume_config = config(True)
        if variant == 'authstore': resume_config = dict(resume_config, **{'cli_auth_credentials_store': 'file'})
        if variant == 'unsubscribe': c.request('thread/unsubscribe', {'threadId': tid})
        print('  variant:', variant)
        if variant == 'noconfig': c.request('thread/resume', dict(base, threadId=tid))
        elif variant == 'provider': c.request('thread/resume', dict(base, threadId=tid, config=resume_config, modelProvider=os.environ.get('SPIKE5_PROVIDER', 'openai')))
        elif variant != 'startconfig': c.request('thread/resume', dict(base, threadId=tid, config=resume_config))
        count_after_resume = len([n for n in c.notes if n.get('method') == 'turn/started'])
        turn2 = c.request('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'Call the spike_marker tool now and reply with exactly the marker word it returns, or NO-TOOL if you cannot.', 'text_elements': []}],
                                         'approvalPolicy': 'never', 'sandboxPolicy': {'type': 'readOnly'}})
        done2 = c.wait_turn(turn2['turn']['id'])
        text2 = ' '.join(json.dumps(n) for n in c.notes[count1:] if n.get('method') == 'item/completed')
        checks = [
            ('first turn completed', done1 is not None and done1['params']['turn']['status'] == 'completed'),
            ('server was absent before re-resume', not any('ZEBRA' in t for t in texts1)),
            ('thread/resume on the live thread succeeded', True),
            ('re-resume replayed no turn', count_after_resume == 1),
            ('second turn completed', done2 is not None),
            ('new config in effect: marker tool reachable after re-resume', 'ZEBRA-42' in text2),
        ]
        print('  turn2 items:', text2[:600])
        print('  turn2 methods:', [(n.get('method'), (n.get('params') or {}).get('item', {}).get('type') or (n.get('params') or {}).get('turn', {}).get('status')) for n in c.notes[count1:]][:30])
        print('  turn2 completed:', json.dumps(done2)[:400])
        print('  notices:', [json.dumps(n)[:300] for n in c.notes if n.get('method') in ('deprecationNotice','error')][:3])
        return report('spike 5 Codex re-resume', checks)
    finally:
        c.close()


SPIKES['5'] = spike5_codex_reresume


if __name__ == '__main__':
    version = subprocess.run([str(CLI), '--version'], capture_output=True, text=True, env=env()).stdout.strip()
    assert version == PINNED + ' (Claude Code)', version
    selected = sys.argv[1:] or list(SPIKES)
    results = {}
    for key in selected:
        try: results[key] = SPIKES[key]()
        except Exception as exc: print(f'\n=== spike {key}: ERROR {exc!r}'); results[key] = False
    print('\nSUMMARY:', {k: ('PASS' if v else 'FAIL') for k, v in results.items()})
    sys.exit(0 if all(results.values()) else 1)


