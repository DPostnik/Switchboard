"""Stage a stable npm release in an isolated app root. Publish the tested directory with one rename."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import uuid

STABLE = re.compile(r'(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)')
REQUIRED = ('installedCodexCompatibilityWithoutInference', 'installedCodexRoutesBrowserEnvironmentsWithoutInference',
            'candidateCodexSurfaceMatchesAdapter')
RECEIPT = 'switchboard-compat-v1.json'


def passed(output, code):
    return code == 0 and 'FLAKY' not in output and '✘' not in output and all(
        re.search(r'✔ Test ' + name + r'\(\) passed after', output) for name in REQUIRED)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def verified_active(root, version):
    try:
        binary = (root / 'bin/codex').resolve(strict=True)
        binary.relative_to(root.resolve())
        receipt = json.loads((binary.parent / RECEIPT).read_text())
        return receipt['version'] == version and receipt['sha256'] == sha(binary)
    except (KeyError, OSError, ValueError, TypeError):
        return False


def check(version, active, work, root, probe_only=False):
    if not STABLE.fullmatch(version) or not STABLE.fullmatch(active):
        return 'skipped: stable releases only'
    parts = lambda s: tuple(map(int, s.split('.')))
    if parts(version) <= parts(active):
        return 'skipped: current or older'
    link = root / 'bin'
    if not link.is_symlink():
        return 'skipped: no managed installation'
    with (root / '.candidate.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = link.resolve(strict=True)
        # Recheck under lock: never downgrade or replace an install selected during a check.
        with tempfile.TemporaryDirectory(dir=root, prefix='.trial-') as tmp:
            trial = Path(tmp)
            env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'USER', 'LANG', 'TMPDIR', 'DEVELOPER_DIR')}
            env.update(CODEX_HOME=str(trial / 'home'), SWITCHBOARD_DATA_ROOT=str(trial))
            (trial / 'home').mkdir()
            def run(args, **kw):
                return subprocess.run(args, cwd=work, env=env, timeout=kw.pop('timeout', 180), check=True, **kw)
            if run([previous / 'codex', '--version'], capture_output=True, text=True).stdout.strip() != 'codex-cli ' + active:
                return 'skipped: active installation changed'
            fingerprint = hashlib.sha256()
            for pattern in ('Sources/CodexAdapter/*.swift', 'Tests/ContextCoreTests/CodexCompatibilityTests.swift',
                            'Sources/AgentContract/*.swift', 'Sources/ContextCore/*.swift', 'Tests/ContextCoreTests/CompatibilitySnapshotTests.swift',
                            'scripts/codex-candidate.py', 'scripts/compat-snapshot.py'):
                for file in sorted(work.glob(pattern)):
                    fingerprint.update(file.read_bytes())
            cache = root / '.candidate-result.json'
            key = version + ':' + fingerprint.hexdigest()
            try:
                last = json.loads(cache.read_text())
            except (OSError, ValueError):
                last = {}
            if not probe_only and isinstance(last, dict) and last.get('failed') == key:
                return 'failed: compatibility scenarios (cached)'
            managed = trial / 'agents/codex'
            package = managed / 'package'
            arch, triple = {'arm64': ('arm64', 'aarch64'), 'x86_64': ('x64', 'x86_64')}[platform.machine()]
            run(['npm', 'install', '--prefix', package, '--ignore-scripts', '--no-audit', '--no-fund', '--save-exact',
                 '--registry', 'https://registry.npmjs.org', '@openai/codex@' + version + '-darwin-' + arch])
            relative = Path('node_modules/@openai/codex/vendor') / (triple + '-apple-darwin') / 'bin'
            binary = package / relative / 'codex'
            if not binary.is_file():  # Native packages before the bin layout used codex/codex.
                relative = relative.parent / 'codex'
                binary = package / relative / 'codex'
            if run([binary, '--version'], capture_output=True, text=True).stdout.strip() != 'codex-cli ' + version:
                raise ValueError('candidate version mismatch')
            digest = sha(binary)
            (binary.parent / RECEIPT).write_text(json.dumps(dict(version=version, sha256=digest)))
            (managed / 'bin').symlink_to(binary.parent)
            run(['python3', '-I', 'scripts/compat-snapshot.py', 'codex', '--binary', binary, '--out', trial])
            snapshot = trial / ('codex-' + version + '.json')
            env.update(SWITCHBOARD_CODEX_COMPATIBILITY_LIVE='1', SWITCHBOARD_CODEX_EXECUTABLE=str(managed / 'bin/codex'),
                       SWITCHBOARD_CODEX_SNAPSHOT=str(snapshot), SWITCHBOARD_CODEX_CANDIDATE=version)
            result = subprocess.run(['zsh', 'scripts/test.sh', '--verbose', '--filter', 'CodexCompatibilityTests',
                                     '--filter', 'candidateCodexSurfaceMatchesAdapter'], cwd=work, env=env, timeout=1200,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if not passed(result.stdout, result.returncode):
                for line in result.stdout.splitlines():
                    if '✘' in line or 'error:' in line:
                        print(line[:500], file=sys.stderr)
                # A build, network or harness failure is not proof against the candidate.
                if not any('✘ Test ' + n + '()' in result.stdout for n in REQUIRED):
                    return 'failed: incomplete test run'
                if not probe_only:
                    cache.write_text(json.dumps({'failed': key}))
                return 'failed: compatibility scenarios'
            if probe_only:
                return 'passed: probe only'
            if link.resolve() != previous or sha(binary) != digest:
                return 'failed: installation changed'
            snapshot.rename(package / snapshot.name)
            destination = root / (version + '-' + uuid.uuid4().hex)
            package.rename(destination)
            staged = trial / 'activate'
            staged.symlink_to(destination / relative)
            os.replace(staged, link)
            return 'promoted'


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('version'); p.add_argument('active')
    p.add_argument('--root', type=Path, required=True); p.add_argument('--probe-only', action='store_true')
    args = p.parse_args()
    status = check(args.version, args.active, Path(__file__).resolve().parents[1], args.root, args.probe_only)
    print(status)
    raise SystemExit(1 if status.startswith('failed') else 0)
