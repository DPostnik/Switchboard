#!/usr/bin/env python3
"""Explicit persistent verification queue. Publication is a separate gated command."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import tempfile

ROOT = Path(__file__).resolve().parent.parent
KINDS = {'build', 'native-tests', 'web-build', 'web-tests', 'verification-tests'}


LEASE_GUARD = '''
import os, subprocess, sys
lease_fd = int(sys.argv[1])
os.set_inheritable(lease_fd, False)
# Only this waiting process inherits the lease. Build tools and their persistent
# helpers must never receive it. Keep waiting even if the coordinator disappears.
result = subprocess.run(sys.argv[2:], close_fds=True)
sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
'''


def run_check(argv, *, lease_fd=None, **kwargs):
    if lease_fd is None:
        return subprocess.run(argv, **kwargs)
    return subprocess.run(
        [sys.executable, '-B', '-c', LEASE_GUARD, str(lease_fd), *argv],
        pass_fds=(lease_fd,), **kwargs)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command_for(check, scope_reason=None):
    kind = check['kind']
    filters = check.get('filters', [])
    if kind not in KINDS or not isinstance(filters, list) or any(not isinstance(x, str) or not x or x.startswith('-') or '\x00' in x for x in filters):
        raise ValueError('unsupported check or invalid filters')
    if (kind == 'build' or kind.endswith('build')) and filters:
        raise ValueError('build checks do not accept filters')
    if kind == 'verification-tests':
        if filters:
            raise ValueError('verification-tests does not accept filters')
        return ['python3', '-B', 'scripts/test-verification.py'], '.'
    if kind == 'build':
        return ['zsh', 'scripts/build-app.sh'], '.'
    if kind == 'native-tests':
        if not filters and (not isinstance(scope_reason, str) or not scope_reason.strip()):
            raise ValueError('native-tests requires explicit filters or a recorded scope_reason')
        return ['zsh', 'scripts/test.sh', *[v for f in filters for v in ('--filter', f)]], '.'
    if kind == 'web-build':
        return ['npm', 'run', 'build'], 'Web'
    if not filters or any(not re.fullmatch(r'src/[A-Za-z0-9_./-]+\.(test|spec)\.[jt]sx?', f) or '..' in Path(f).parts for f in filters):
        raise ValueError('web-tests requires explicit src/...test.ts(x) file filters')
    return ['npm', 'test', '--', *filters], 'Web'


HEAVY_JOB = re.compile(r'(?:python[0-9.]* (?:-I )?\S*(?:swift-task\.py|scripts/perf/)|(?:^|/)xcodebuild(?: |$))', re.I)
JOBS_NOT_COUNTED = ('heavy jobs not counted: ps cannot run here (for example under the external boundary); '
                    'the shared build lock still runs builds and tests one at a time')


def heavy_job_count():
    """Running heavy jobs, or None when `ps` cannot run (it is setuid; nono refuses it)."""
    try:
        processes = subprocess.check_output(['ps', '-axo', 'pid,command'], text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return None
    return sum(bool(HEAVY_JOB.search(line)) for line in processes.splitlines())


def preflight():
    """A courtesy load check before heavy checks, not a security control. Load comes from the kernel without a
    subprocess, so it also works under the external boundary; builds and tests still run inside it."""
    if platform.system() != 'Darwin':
        raise ValueError('heavy verification requires the configured macOS host')
    one = os.getloadavg()[0]
    cores = os.cpu_count() or 1
    count = heavy_job_count()
    if one > cores or (count is not None and count >= 2):
        from verification_queue import VerificationDeferred
        jobs = f'heavy jobs {count}' if count is not None else JOBS_NOT_COUNTED
        raise VerificationDeferred(f'host busy: load {one:.2f}, cores {cores}, {jobs}; no check launched')
    if count is None:
        print(f'preflight: load {one:.2f}, cores {cores}; {JOBS_NOT_COUNTED}', file=sys.stderr, flush=True)


def fingerprint(checkout):
    versions = {}
    for tool, argv in [('swift', ['swift', '--version']), ('node', ['node', '--version']), ('npm', ['npm', '--version']), ('xcode', ['xcodebuild', '-version'])]:
        try:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=20)
            versions[tool] = {'executable': shutil.which(argv[0]), 'exit': result.returncode, 'version': (result.stdout + result.stderr).strip()}
        except (OSError, subprocess.TimeoutExpired) as error:
            versions[tool] = {'error': str(error)}
    files = ['Package.swift', 'Package.resolved', 'Web/package.json', 'Web/package-lock.json', 'scripts/build-app.sh', 'scripts/test.sh', 'scripts/swift-task.py']
    environment = {key: os.environ.get(key) for key in ['DEVELOPER_DIR', 'SDKROOT', 'SWIFT_EXEC', 'SWIFTFLAGS', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'SWITCHBOARD_INDEX_STORE', 'SWITCHBOARD_SIGN_IDENTITY', 'SWITCHBOARD_DATA_ROOT', 'PATH']}
    return {'environment': environment, 'tools': versions, 'inputs': {p: digest(checkout / p) for p in files if (checkout / p).is_file()}, 'platform': platform.platform()}


def emit(value):
    print(json.dumps(value, indent=2, ensure_ascii=False, default=str))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=Path, default=ROOT / '.build/verification')
    parser.add_argument('--repo', type=Path, default=ROOT)
    subs = parser.add_subparsers(dest='action', required=True)
    submit = subs.add_parser('submit')
    submit.add_argument('manifest', type=Path, help='JSON task with id, base, checks and explicit patch path')
    subs.add_parser('status')
    subs.add_parser('plan')
    run = subs.add_parser('run', help='run compatible batches; never publish/restart')
    run.add_argument('--drain', action='store_true')
    live = subs.add_parser('confirm-live')
    live.add_argument('batch_id')
    live.add_argument('evidence', type=Path)
    cancel = subs.add_parser('cancel')
    cancel.add_argument('task_id')
    install = subs.add_parser('install')
    install.add_argument('batch_id')
    install.add_argument('--take-over', action='store_true',
                         help='install even while another batch holds the installed bundle; only with the user')
    publish = subs.add_parser('publish')
    publish.add_argument('batch_id')
    publish.add_argument('messages', type=Path, help='JSON map of task IDs to commit messages')
    publish.add_argument('--expected-remote-base', required=True)
    publish.add_argument('--branch', default='main')
    reconcile = subs.add_parser('reconcile')
    reconcile.add_argument('batch_id')
    subs.add_parser('recover', help='mark interrupted work uncertain; never retry')
    args = parser.parse_args()
    from verification_queue import VerificationQueue
    queue = VerificationQueue(args.state_dir)
    try:
        if args.action == 'submit':
            task = json.loads(args.manifest.read_text())
            for check in task.get('checks', []):
                command_for(check, task.get('scope_reason'))
            if not task.get('checks'):
                raise ValueError('task requires checks')
            patch = Path(task['patch'])
            if not patch.is_absolute():
                patch = args.manifest.resolve().parent / patch
            task['patch'] = str(patch.resolve(strict=True))
            task['patch_digest'] = digest(patch)
            restrictions = task.get('restrictions', {})
            if set(restrictions) - {'allow_tests', 'allow_publish'} or any(type(v) is not bool for v in restrictions.values()):
                raise ValueError('unsupported restriction policy')
            if restrictions.get('allow_tests') is False and any(c['kind'].endswith('tests') for c in task['checks']):
                raise ValueError('tests prohibited by task restrictions')
            from verification_snapshot import create_snapshot
            task['base'] = subprocess.check_output(['git', '-C', str(args.repo), 'rev-parse', '--verify', task['base'] + '^{commit}'], text=True).strip()
            ancestors = dependency_tasks(queue, task.get('dependencies', []))
            if any(t['base'] != task['base'] for t in ancestors):
                raise ValueError('dependencies must share the task base commit')
            snapshot_key = hashlib.sha256(json.dumps([task['base'], task['id'], task['patch_digest'], [t['snapshot_id'] for t in ancestors]]).encode()).hexdigest()
            destination = args.state_dir.resolve() / 'snapshots' / snapshot_key
            if destination.exists():
                from verification_snapshot import verify_snapshot
                manifest = verify_snapshot(args.repo, destination / 'manifest.json')
            else:
                from verification_queue import canonical_snapshot_tasks
                snapshot_tasks, aliases = canonical_snapshot_tasks(ancestors + [task])
                manifest = create_snapshot(args.repo, task['base'], snapshot_tasks, destination)
            task['snapshot_id'] = manifest['digest']
            task['base'] = manifest['base']
            task['patch'] = str(destination.resolve() / manifest['tasks'][-1]['patch'])
            task['toolchain'] = fingerprint(args.repo)
            if any(c['kind'] == 'native-tests' for c in task['checks']) and not any(c['kind'] == 'build' for c in task['checks']):
                task['checks'].insert(0, {'kind': 'build', 'filters': []})
            emit(queue.submit(task))
        elif args.action == 'status':
            emit(dict(queue.projection(), install_lease=lease_view(queue, time.time())))
        elif args.action == 'plan':
            emit(queue.plan_batch())
        elif args.action == 'cancel':
            emit(queue.cancel(args.task_id))
        elif args.action == 'recover':
            emit(queue.recover())
        elif args.action == 'install':
            emit(install_batch(queue, args.repo, args.state_dir, args.batch_id, take_over=args.take_over))
        elif args.action == 'publish':
            emit(publish_batch(queue, args.repo, args.state_dir, args.batch_id, args.messages, args.expected_remote_base, args.branch))
        elif args.action == 'reconcile':
            from verification_snapshot import reconcile_publication
            with queue.executor():
                result = reconcile_publication(args.repo, args.state_dir / 'batches' / args.batch_id / 'publication-attempt.json')
                if result['state'] == 'published':
                    batch = queue.batch(args.batch_id)
                    for task_id in batch['spec']['task_ids']:
                        if queue.status(task_id)['status'] == 'verified':
                            queue.transition(task_id, 'published', 'Publication confirmed from remote tip')
                emit(result)
        elif args.action == 'confirm-live':
            emit(confirm_live(queue, args.state_dir, args.batch_id, args.evidence))
        else:
            runner = make_runner(args.repo, args.state_dir, queue)
            while True:
                result = queue.execute_next(runner, resolve_identity=runner.resolve_identity)
                emit(result)
                if not args.drain or result is None or result['status'] not in ('verified', 'awaiting_live'):
                    break
    finally:
        queue.close()


def dependency_tasks(queue, ids):
    ordered, seen = [], set()
    def visit(task_id):
        if task_id in seen:
            return
        seen.add(task_id)
        row = queue.status(task_id)
        if row is None:
            raise ValueError('unknown dependency: ' + task_id)
        task = row['spec']
        for ancestor in task.get('dependencies', []):
            visit(ancestor)
        ordered.append(task)
    for task_id in ids:
        visit(task_id)
    return ordered


def confirm_live(queue, state_dir, batch_id, evidence_path):
    with queue.executor():
        return _confirm_live(queue, state_dir, batch_id, evidence_path)


def _confirm_live(queue, state_dir, batch_id, evidence_path):
    batch = queue.batch(batch_id)
    if not batch or batch['status'] != 'awaiting_live':
        raise ValueError('batch is not awaiting live verification')
    evidence = json.loads(evidence_path.read_text())
    manifest = json.loads((state_dir / 'batches' / batch_id / 'snapshot/manifest.json').read_text())
    executable = state_dir / 'batches' / batch_id / 'artifact/Switchboard.app/Contents/MacOS/Switchboard'
    archived = json.loads((executable.parents[3] / 'identity.json').read_text())
    from verification_snapshot import bundle_digest, verify_build_info
    verify_build_info(executable.parents[2], manifest)
    if digest(executable) != archived['executable_sha256'] or archived['tree'] != manifest['tree'] or bundle_digest(executable.parents[2]) != archived['bundle_sha256']:
        raise ValueError('archived artifact identity changed')
    if evidence.get('snapshot_digest') != manifest['digest'] or evidence.get('executable_sha256') != digest(executable):
        raise ValueError('live evidence does not match exact built artifact')
    running = Path(evidence['running_executable']).resolve(strict=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(running.parents[2])], check=True)
    if bundle_digest(running.parents[2]) != archived['bundle_sha256'] or digest(running) != digest(executable) or not evidence.get('checks') or not evidence.get('verified_by'):
        raise ValueError('live evidence needs matching running artifact, checks and verifier')
    pid = int(evidence['pid'])
    process, started = process_identity(pid)
    if Path(process).resolve() != running:
        raise ValueError('process does not run the evidenced executable')
    # Require process launch after the verified artifact (whole seconds, as `ps -o lstart` reported).
    if started < int(executable.stat().st_mtime):
        raise ValueError('running process predates built artifact')
    destination = state_dir / 'batches' / batch_id / 'live-evidence.json'
    destination.write_text(json.dumps(evidence, indent=2))
    for task_id in batch['spec']['task_ids']:
        queue.transition(task_id, 'verified', 'Live evidence: ' + str(destination))
    return queue.projection()


def process_identity(pid):
    """Executable path and start time (epoch seconds) of a process, from libproc. `ps` is setuid and cannot run under
    the external boundary; libproc answers in both cases."""
    import ctypes
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    path = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, path, len(path)) <= 0:
        raise ValueError('process is not running: ' + str(pid))
    info = ctypes.create_string_buffer(136)  # struct proc_bsdinfo; pbi_start_tvsec is the uint64 at offset 120
    if libproc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), info, len(info)) != len(info):
        raise ValueError('process start time unavailable: ' + str(pid))
    return path.value.decode(), int.from_bytes(info.raw[120:128], sys.byteorder)


def clone_bundle(source, destination):
    """Prefer APFS clones; publish only a complete newly created directory."""
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError('artifact destination already exists: ' + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.verification-copy-', dir=destination.parent) as scratch:
        temporary = Path(scratch) / 'bundle'
        copied = subprocess.run(['cp', '-cR', str(source), str(temporary)], capture_output=True)
        if copied.returncode:
            # This path belongs exclusively to this invocation, including failed cp output.
            if temporary.is_symlink() or temporary.is_file():
                temporary.unlink()
            elif temporary.exists():
                shutil.rmtree(temporary)
            shutil.copytree(source, temporary, symlinks=True)
        temporary.rename(destination)


def durable_attempt(path, value):
    with path.open('x') as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


INSTALL_LEASE_LIMIT_SECONDS = 45 * 60


class InstallRefused(ValueError):
    """Another batch holds the installed bundle. Nothing was staged, replaced or recorded."""

    def __init__(self, details):
        super().__init__(details['reason'])
        self.details = details


def minutes(seconds):
    return f'{int(seconds // 60)} min'


def lease_view(queue, now, limit=INSTALL_LEASE_LIMIT_SECONDS):
    """The install lease as `status` shows it, or None when no batch was installed through the queue."""
    lease = queue.install_lease(now)
    if lease is None:
        return None
    expired = lease['age_seconds'] >= limit
    return dict(lease, holds=lease['active'] and not expired, expired=lease['active'] and expired,
                limit_seconds=limit, expires_in_seconds=max(0.0, limit - lease['age_seconds']) if lease['active'] else 0.0)


def claim_install_lease(queue, batch_id, now, take_over=False, limit=INSTALL_LEASE_LIMIT_SECONDS):
    """Refuse an install of a different batch while the holder waits for live confirmation or publication.

    Returns who was displaced (expired lease or explicit take-over), or None. Must run under the executor lock."""
    lease = lease_view(queue, now, limit)
    if lease is None or lease['batch_id'] == batch_id or not lease['active']:
        return None
    displaced = dict(batch_id=lease['batch_id'], installed_at=lease['installed_at'],
                     age_seconds=lease['age_seconds'], task_ids=[t['id'] for t in lease['tasks']])
    if lease['expired']:
        return dict(displaced, reason='expired', at=now)
    if take_over:
        return dict(displaced, reason='take_over', at=now)
    tasks = ', '.join(f"{t['id']} ({t['title']})" for t in lease['tasks']) or 'no tasks'
    reason = (f"install refused: batch {lease['batch_id']} holds the installed bundle (tasks: {tasks}; installed "
              f"{minutes(lease['age_seconds'])} ago; waiting for {lease['waiting_for']}). Wait, or let its chat finish "
              f"with confirm-live and publish, or with the user's approval run install {batch_id} --take-over; "
              f"the lease expires {minutes(limit)} after install")
    raise InstallRefused(dict(state='refused', batch_id=batch_id, reason=reason, holder=lease,
                              options=['wait', 'holder runs confirm-live and publish',
                                       f'install {batch_id} --take-over (explicit, with the user)']))


def install_batch(queue, repo, state_dir, batch_id, take_over=False, now=time.time):
    """Publish bundle locally once; retain old bundle for its running process."""
    with queue.executor():
        batch = queue.batch(batch_id)
        if not batch or batch['status'] not in ('verified', 'awaiting_live'):
            raise ValueError('installation requires completed machine checks')
        displaced = claim_install_lease(queue, batch_id, now(), take_over)
        directory = state_dir / 'batches' / batch_id
        artifact = directory / 'artifact/Switchboard.app'
        executable = artifact / 'Contents/MacOS/Switchboard'
        if not executable.is_file():
            raise ValueError('batch has no archived native build')
        archived = json.loads((directory / 'artifact/identity.json').read_text())
        from verification_snapshot import bundle_digest, verify_build_info, verify_snapshot
        manifest = verify_snapshot(repo, directory / 'snapshot/manifest.json')
        verify_build_info(artifact, manifest)
        if archived['tree'] != manifest['tree'] or digest(executable) != archived['executable_sha256'] or bundle_digest(artifact) != archived['bundle_sha256']:
            raise ValueError('archived executable changed after verification')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(artifact)], check=True)
        build = repo / 'build'
        build.mkdir(exist_ok=True)
        lock_path = Path.home() / 'Library/Caches/Switchboard/build.lock'
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            marker = directory / 'install-attempt.json'
            record = {'state': 'installing', 'executable_sha256': digest(executable), 'started_at': time.time()}
            if displaced:
                record['displaced'] = displaced
            durable_attempt(marker, record)
            stage = Path(tempfile.mkdtemp(prefix='verification-install-', dir=build)) / 'Switchboard.app'
            clone_bundle(artifact, stage)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
            if bundle_digest(stage) != archived['bundle_sha256']:
                raise ValueError('staged bundle differs from verified archive')
            destination = build / 'Switchboard.app'
            backup = build / '.replaced' / ('Switchboard-' + str(time.time_ns()) + '.app')
            # Durable lease before the bundle is replaced: a crash after this point still blocks other batches.
            previous_lease = queue.record_install_lease(batch_id, now(), displaced)
            try:
                if destination.exists():
                    backup.parent.mkdir(exist_ok=True)
                    destination.rename(backup)
                stage.rename(destination)
            except BaseException:
                if backup.exists():
                    backup.rename(destination)
                # The previous bundle is back in place (or was never moved), so its lease is too.
                queue.restore_install_lease(previous_lease)
                raise
            stage.parent.rmdir()
            record['state'] = 'installed'
            record['installed_at'] = time.time()
            record['destination'] = str(destination)
            marker.write_text(json.dumps(record, indent=2))
        if displaced:
            note = (f"install: took over the install lease of batch {displaced['batch_id']} (installed "
                    f"{minutes(displaced['age_seconds'])} ago): "
                    + ('the stale lease had expired' if displaced['reason'] == 'expired' else 'explicit --take-over'))
            print(note, file=sys.stderr, flush=True)
        result = request_restart(repo, directory / 'restart-attempt.json')
        if displaced:
            result['displaced'] = displaced
        return {'state': 'waiting_for_restart', 'batch_id': batch_id, 'artifact': str(destination), 'next': 'confirm-live', **result}


RESTART_TOOL_STEP = ('Installed. The restart was not requested from here: under the external boundary the restart script '
                     'cannot reach the running app. Call the app-owned request_app_restart tool exactly once (no retry, '
                     'also after an error), then end the turn and wait for the continuation message.')


def request_restart(repo, restart, environ=None):
    """Persist intent before delivery; an uncertain delivery is never repeated. Under the external boundary the agent
    asks the app through its own tool instead (channel 3), so nothing is started from here."""
    environ = os.environ if environ is None else environ
    if environ.get('SWITCHBOARD_EXTERNAL_SANDBOX') == '1':
        durable_attempt(restart, {'state': 'tool_required', 'recorded_at': time.time()})
        print(RESTART_TOOL_STEP, file=sys.stderr, flush=True)
        return {'restart': 'call request_app_restart once', 'restart_note': RESTART_TOOL_STEP}
    durable_attempt(restart, {'state': 'requested', 'requested_at': time.time()})
    subprocess.run(['zsh', 'scripts/request-app-restart.sh'], cwd=repo, check=True)
    return {'restart': 'requested'}


def publish_batch(queue, repo, state_dir, batch_id, messages_path, expected_base, branch):
    from verification_snapshot import publication_plan, publish_plan
    with queue.executor():
        batch = queue.batch(batch_id)
        if not batch or not all(queue.status(t)['status'] == 'verified' for t in batch['spec']['task_ids']):
            raise ValueError('publication requires every task verified')
        if batch['spec']['restrictions'].get('allow_publish') is False:
            raise ValueError('publication prohibited by restrictions')
        directory = state_dir / 'batches' / batch_id
        if batch['spec']['needs_live'] and not (directory / 'live-evidence.json').is_file():
            raise ValueError('publication requires recorded live evidence')
        messages = json.loads(messages_path.read_text())
        from verification_snapshot import prepare_checkout
        prepare_checkout(repo, directory / 'snapshot/manifest.json', checkout=state_dir / 'worktree')
        plan = publication_plan(repo, directory / 'snapshot/manifest.json', messages,
                                expected_base, branch=branch, checkout=state_dir / 'worktree')
        result = publish_plan(repo, plan, directory / 'publication-attempt.json')
        if result['state'] == 'published':
            for task_id in batch['spec']['task_ids']:
                queue.transition(task_id, 'published', 'Published exact verified snapshot')
        return result


def make_runner(repo, state_dir, queue=None):
    prepared = {}
    def prepare(batch):
        from verification_snapshot import create_snapshot, prepare_checkout
        batch_id = batch['id']
        if batch_id not in prepared:
            tasks = batch['tasks']
            for task in tasks:
                if digest(task['patch']) != task['patch_digest']:
                    raise ValueError('submitted patch changed; submit a new task')
            destination = state_dir / 'batches' / batch_id
            from verification_snapshot import SnapshotError
            from verification_queue import VerificationConflict
            checkout = state_dir / 'worktree'
            try:
                if (destination / 'snapshot/manifest.json').exists():
                    from verification_snapshot import verify_snapshot
                    manifest = verify_snapshot(repo, destination / 'snapshot/manifest.json')
                else:
                    manifest = create_snapshot(repo, batch['base'], tasks, destination / 'snapshot')
                prepare_checkout(repo, destination / 'snapshot/manifest.json', checkout=checkout)
            except SnapshotError as error:
                raise VerificationConflict(str(error)) from error
            prepared[batch_id] = (checkout, manifest, fingerprint(checkout))
        return prepared[batch_id]

    def resolve_identity(batch):
        checkout, manifest, identity = prepare(batch)
        if any(t.get('toolchain', {}).get('tools') != identity['tools'] or t.get('toolchain', {}).get('environment') != identity['environment'] for t in batch['tasks']):
            raise ValueError('toolchain changed since submission; submit a new immutable task')
        resolved = hashlib.sha256(json.dumps({'tree': manifest['tree'], 'commit': manifest['commit'], 'fingerprint': identity}, sort_keys=True).encode()).hexdigest()
        if queue is not None:
            cached = queue.cached_result(resolved, batch['checks'], batch['toolchain'], batch['restrictions'])
            if cached:
                old = state_dir / 'batches' / cached['id'] / 'artifact/Switchboard.app'
                new = state_dir / 'batches' / batch['id'] / 'artifact/Switchboard.app'
                if old.is_dir():
                    clone_bundle(old, new)
                    shutil.copyfile(old.parent / 'identity.json', new.parent / 'identity.json')
        return resolved

    def runner(batch, check, log_path):
        from verification_snapshot import verify_checkout
        batch_id = batch['id']
        checkout, manifest, identity = prepare(batch)
        manifest_path = state_dir / 'batches' / batch_id / 'snapshot/manifest.json'
        verify_checkout(repo, manifest_path, checkout)
        if batch['restrictions'].get('allow_tests') is False and check['kind'].endswith('tests'):
            raise ValueError('tests prohibited by restrictions')
        reason = next((t.get('scope_reason') for t in batch['tasks'] if t.get('scope_reason')), None)
        argv, relative = command_for(check, reason)
        if check['kind'] != 'verification-tests':
            preflight()
        if relative == 'Web' and not (checkout / 'Web/node_modules').is_dir():
            raise ValueError('web dependency installation requires an explicit authorized preparation step in the verification checkout')
        log = Path(log_path)
        log.parent.mkdir(parents=True, exist_ok=True)
        start = time.time()
        record = {'batch_id': batch_id, 'snapshot': manifest, 'fingerprint': identity, 'argv': argv, 'cwd': str(checkout / relative), 'started_at': start, 'artifact': str(checkout / 'build/Switchboard.app'), 'publication': 'not_requested', 'live_verification': 'requires_explicit_publication_and_running_app_check'}
        metadata = log.with_suffix(log.suffix + '.json')
        metadata.write_text(json.dumps(record, indent=2, default=str))
        try:
            with log.open('w') as output:
                process = run_check(argv, cwd=checkout / relative, stdout=output, stderr=subprocess.STDOUT, lease_fd=batch.get('lease_fd'))
            verify_checkout(repo, manifest_path, checkout)
            record['exit_code'] = process.returncode
            output_text = log.read_text(errors='replace')
            if check['kind'] == 'native-tests' and re.search(r'Test run with\s+0\s+tests?\b', output_text, re.I):
                record['zero_selected_tests'] = True
                record['exit_code'] = 2
                return 2
            if 'FLAKY (' in output_text:
                record['flaky'] = True
                record['exit_code'] = 2
                return 2
            if process.returncode == 0 and check['kind'] == 'build':
                artifact = state_dir / 'batches' / batch_id / 'artifact/Switchboard.app'
                clone_bundle(checkout / 'build/Switchboard.app', artifact)
                record['artifact'] = str(artifact)
                record['artifact_sha256'] = digest(artifact / 'Contents/MacOS/Switchboard')
                from verification_snapshot import bundle_digest, verify_build_info
                verify_build_info(artifact, manifest)
                (artifact.parent / 'identity.json').write_text(json.dumps({'tree': manifest['tree'], 'bundle_sha256': bundle_digest(artifact), 'executable_sha256': record['artifact_sha256']}))
            return process.returncode
        finally:
            record['finished_at'] = time.time()
            record['elapsed_seconds'] = record['finished_at'] - start
            # Preserve the full native test log before the next check overwrites it.
            native_log = checkout / '.build/local-build/test-last.log'
            if check['kind'] == 'native-tests' and native_log.exists():
                shutil.copyfile(native_log, str(log) + '.native.log')
            metadata.write_text(json.dumps(record, indent=2, default=str))
    runner.admit = lambda batch: preflight() if any(c['kind'] != 'verification-tests' for c in batch['checks']) else None
    runner.resolve_identity = resolve_identity
    return runner


if __name__ == '__main__':
    try:
        main()
    except InstallRefused as refusal:
        emit(refusal.details)
        print(f'verify-project: {refusal}', file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'verify-project: {error}', file=sys.stderr)
        sys.exit(1)
