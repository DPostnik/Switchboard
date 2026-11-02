#!/usr/bin/env python3 -I
"""Nightly upstream compatibility check for the agent CLIs; called at the end of scripts/nightly-tests.sh.

Cheap by design (user requirement): nothing runs on battery; installed versions cost one `--version` each;
the latest published version is one `npm view <package> version` per agent, at most once per 24 h; the live
no-inference tests run only for an installed version that is neither verified nor checked before. No model
requests, no downloads, nothing executed except the installed CLIs and this repository's own test script.

  python3 -I scripts/compat-check.py [--worktree DIR] [--app PATH] [--no-live] [--force-npm]
                                     [--state FILE] [--status FILE] [--no-notify]

State: ~/Library/Caches/Switchboard/compat/state.json. Result: one line in
~/Library/Logs/Switchboard/nightly-tests/compat-status, first word ok | attention | skipped. A notification is
posted once per newly seen problem or version, through `Switchboard --nightly-tests-report compat`.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()
STATE = HOME / 'Library/Caches/Switchboard/compat/state.json'
STATUS = HOME / 'Library/Logs/Switchboard/nightly-tests/compat-status'
NPM_INTERVAL = dt.timedelta(hours=24)
VERSION = re.compile(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.]+)?$')


def codex_candidates():
    apps = [f'{d}/{app}/Contents/Resources/{rel}' for d in ['/Applications', str(HOME / 'Applications')]
            for app in ['ChatGPT.app', 'Codex.app'] for rel in ['codex-cli/CodexCLI.app/Contents/MacOS/codex', 'codex']]
    path = [f'{p}/codex' for p in os.environ.get('PATH', '').split(':') if p.startswith('/')]
    return apps + ['/opt/homebrew/bin/codex', '/usr/local/bin/codex'] + path


def claude_candidates():
    path = [f'{p}/claude' for p in os.environ.get('PATH', '').split(':') if p.startswith('/')]
    return [str(HOME / '.local/bin/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude'] + path


# One entry per agent; a Gemini entry joins here once its adapter and live test exist.
AGENTS = {
    'codex': {'candidates': codex_candidates, 'version': re.compile(r'^codex-cli (\S+)$'), 'npm': '@openai/codex',
              'live': ('SWITCHBOARD_CODEX_COMPATIBILITY_LIVE', 'CodexCompatibilityTests')},
    'claude': {'candidates': claude_candidates, 'version': re.compile(r'^(\S+) \(Claude Code\)$'), 'npm': '@anthropic-ai/claude-code',
               'live': ('SWITCHBOARD_CLAUDE_COMPATIBILITY_LIVE', 'ClaudeCompatibilityTests')},
}


def verified_versions(root):
    """The exact versions the adapters were verified on, read from the sources of the tested tree."""
    codex = (root / 'Sources/CodexAdapter/CodexProtocolCompatibility.swift').read_text()
    current = re.search(r'static let currentVersion = "([^"]+)"', codex)[1]
    listed = re.search(r'static let supportedVersions = \[([^\]]*)\]', codex)[1]
    versions = re.findall(r'"([^"]+)"', listed) + ([current] if 'currentVersion' in listed else [])
    claude = re.search(r'static let pinnedVersion = "([^"]+)"', (root / 'Sources/ContextCore/ClaudeModels.swift').read_text())[1]
    return {'codex': sorted(set(versions)), 'claude': [claude]}


def branch(version):
    match = VERSION.match(version or '')
    return (int(match[1]), int(match[2])) if match else None


def classify(version, verified):
    """The app's connection policy: exact verified, same major.minor as a verified version (warning), or unsupported."""
    if not version:
        return 'missing'
    if version in verified:
        return 'verified'
    own = branch(version)
    return 'same-minor' if own and any(branch(v) == own for v in verified) else 'unsupported'


def installed(agent, timeout=20):
    spec = AGENTS[agent]
    binary = next((c for c in spec['candidates']() if os.path.isfile(c) and os.access(c, os.X_OK)), None)
    if not binary:
        return None
    with tempfile.TemporaryDirectory(prefix='compat-') as temp:
        # A throwaway profile: `--version` must not touch the user's or the app's CLI state.
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'USER', 'LANG', 'TMPDIR')}
        env.update(CODEX_HOME=temp, CLAUDE_CONFIG_DIR=temp, DISABLE_AUTOUPDATER='1')
        try:
            out = subprocess.run([binary, '--version'], capture_output=True, text=True, timeout=timeout, env=env, cwd=temp).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
    match = spec['version'].match(out)
    return match[1] if match else None


def published(package, timeout=20):
    with tempfile.TemporaryDirectory(prefix='compat-npm-') as temp:
        try:
            out = subprocess.run(['npm', 'view', package, 'version'], capture_output=True, text=True, timeout=timeout, cwd=temp).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
    return out if VERSION.match(out) else None


def on_ac_power():
    try:
        out = subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "'AC Power'" in out.splitlines()[0] if out else False


def run_live(agent, worktree, timeout=900):
    variable, test = AGENTS[agent]['live']
    env = dict(os.environ, **{variable: '1'})
    try:
        code = subprocess.run(['zsh', 'scripts/test.sh', '--filter', test], cwd=worktree, env=env, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        return 'failed'
    return 'passed' if code == 0 else 'failed'


def evaluate(state, verified, versions, latest, live, now):
    """Pure decision step. Returns (status line, findings to notify, state). `live(agent, version)` runs the tests."""
    checked = state.setdefault('checked', {})
    parts, problems, findings = [], [], []
    for agent in AGENTS:
        version, policy = versions.get(agent), classify(versions.get(agent), verified[agent])
        part = f'{agent} {version or "not installed"} {policy if version else ""}'.strip()
        if version and policy != 'verified':
            record = checked.setdefault(agent, {}).get(version)
            if record is None and live is not None:
                record = {'result': live(agent, version), 'policy': policy, 'at': now.isoformat(timespec='seconds')}
                checked[agent][version] = record
            if record:
                part += f', live tests {record["result"]}'
                findings.append((f'{agent}:{version}:{record["result"]}',
                                 f'{agent} {version} ({policy}) live tests {record["result"]}'))
                if record['result'] != 'passed':
                    problems.append(agent)
            else:
                part += ', live tests not run'
        if policy == 'unsupported':
            problems.append(agent)
            findings.append((f'{agent}:{version}:unsupported', f'{agent} {version} is outside the verified versions; the app will not connect'))
        newest = latest.get(agent)
        if newest and newest != version:
            upstream = classify(newest, verified[agent])
            part += f', latest {newest} ({upstream})'
            if upstream == 'unsupported' and branch(newest):
                major, minor = branch(newest)
                findings.append((f'{agent}:published:{major}.{minor}',
                                 f'{agent} {newest} is published; its {major}.{minor} branch is not verified yet'))
        parts.append(part)
    word = 'attention' if problems else 'ok'
    return f'{word} {now.isoformat(timespec="seconds")} ' + '; '.join(parts), findings, state


def notify(app, summary):
    if app and os.access(app, os.X_OK):
        if subprocess.run([app, '--nightly-tests-report', 'compat', summary], capture_output=True, timeout=30).returncode == 0:
            return
    text = summary.replace('"', '')
    subprocess.run(['osascript', '-e', f'display notification "{text}" with title "Switchboard: agent CLI compatibility"'],
                   capture_output=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--worktree', type=Path, default=ROOT, help='tree whose tests and verified versions are used')
    parser.add_argument('--app', default=str(ROOT / 'build/Switchboard.app/Contents/MacOS/Switchboard'))
    parser.add_argument('--no-live', action='store_true', help='do not run live tests (for example after a failed suite)')
    parser.add_argument('--force-npm', action='store_true', help='ignore the 24 h limit for npm view')
    parser.add_argument('--state', type=Path, default=STATE)
    parser.add_argument('--status', type=Path, default=STATUS)
    parser.add_argument('--no-notify', action='store_true', help='print findings instead of notifying (manual runs)')
    args = parser.parse_args()
    now = dt.datetime.now().astimezone()
    args.status.parent.mkdir(parents=True, exist_ok=True)
    if not on_ac_power():
        line = f'skipped: battery {now.isoformat(timespec="seconds")}'
        args.status.write_text(line + '\n'); print(line)
        return 0
    try:
        state = json.loads(args.state.read_text())
    except (OSError, ValueError):
        state = {}
    last = state.get('npmCheckedAt')
    if args.force_npm or not last or now - dt.datetime.fromisoformat(last) >= NPM_INTERVAL:
        state['latest'] = {agent: published(spec['npm']) for agent, spec in AGENTS.items()}
        state['npmCheckedAt'] = now.isoformat(timespec='seconds')
    versions = {agent: installed(agent) for agent in AGENTS}
    live = None if args.no_live else (lambda agent, version: run_live(agent, args.worktree))
    line, findings, state = evaluate(state, verified_versions(args.worktree), versions, state.get('latest') or {}, live, now)
    notified = set(state.get('notified', []))
    fresh = [text for key, text in findings if key not in notified]
    state['notified'] = sorted(notified | {key for key, _ in findings})
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
    args.status.write_text(line + '\n'); print(line)
    if fresh and args.no_notify:
        print('would notify: ' + '; '.join(fresh))
    elif fresh:
        notify(args.app, '; '.join(fresh)[:300])
    return 0


if __name__ == '__main__':
    sys.exit(main())
