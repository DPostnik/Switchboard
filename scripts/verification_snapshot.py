#!/usr/bin/env python3
"""Explicit, immutable patch snapshots for the serialized verification checkout.

Callers must hold the verification queue lock while preparing/using the checkout.
Only synchronization after confirmed publication changes the source checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import stat
import tempfile


class SnapshotError(ValueError):
    pass


def git(repo, *args, env=None, input=None):
    result = subprocess.run(['git', '-C', str(repo), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if result.returncode:
        raise SnapshotError(result.stderr.decode(errors='replace').strip())
    return result.stdout


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def validate_path(path):
    p = PurePosixPath(path)
    if p.parts and p.parts[0] in {'.build', 'build', '.runtime'}:
        raise SnapshotError('Reserved verification/build path: ' + path)
    if not path or p.is_absolute() or '..' in p.parts or '.git' in p.parts or '\\' in path:
        raise SnapshotError('Unsafe patch path: ' + path)


def _validate_tree(repo, tree):
    # Inspect tree paths too. Existing base symlinks are retained; patch-created
    # or modified symlinks are rejected during application.
    for entry in git(repo, 'ls-tree', '-rz', tree).split(b'\0'):
        if not entry:
            continue
        meta, raw_path = entry.split(b'\t', 1)
        validate_path(os.fsdecode(raw_path))
        if meta.split()[0] == b'120000':
            # Existing repository symlinks are allowed; Git's cached apply rejects
            # modifications through them. New/changed links are rejected below.
            continue


def create_snapshot(repo, base, tasks, destination):
    repo, destination = Path(repo).resolve(), Path(destination).resolve()
    if destination.exists():
        raise SnapshotError('Snapshot destination already exists')
    base = git(repo, 'rev-parse', '--verify', base + '^{commit}').decode().strip()
    seen, pinned = set(), []
    for task in tasks:
        task_id = task['id']
        if not isinstance(task_id, str) or not task_id or task_id in seen:
            raise SnapshotError('Task IDs must be unique nonempty strings')
        dependencies = task.get('dependencies', [])
        if any(dep not in seen for dep in dependencies):
            raise SnapshotError('Missing or unordered dependency for ' + task_id)
        data = Path(task['patch']).read_bytes()
        if not data:
            raise SnapshotError('Empty patch for ' + task_id)
        pinned.append((task_id, dependencies, data))
        seen.add(task_id)
    if not pinned:
        raise SnapshotError('At least one explicit patch is required')
    with tempfile.TemporaryDirectory(prefix='verification-index-') as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / 'index'))
        git(repo, 'read-tree', base, env=env)
        records = []
        for number, (task_id, dependencies, data) in enumerate(pinned):
            # --numstat -z exposes decoded paths (including quoted/non-ASCII
            # names); --cached applies only to the isolated index, never disk.
            stats = git(repo, 'apply', '--numstat', '-z', '-', input=data)
            paths = []
            for record in stats.split(b'\0'):
                if not record:
                    continue
                fields = record.split(b'\t', 2)
                if len(fields) != 3 or not fields[2]:
                    raise SnapshotError('Unsupported patch path encoding')
                path = os.fsdecode(fields[2])
                validate_path(path)
                paths.append(path)
            if not paths:
                raise SnapshotError('Patch has no paths')
            git(repo, 'apply', '--cached', '--check', '-', env=env, input=data)
            git(repo, 'apply', '--cached', '-', env=env, input=data)
            tree = git(repo, 'write-tree', env=env).decode().strip()
            for path in paths:
                entry = git(repo, 'ls-tree', tree, '--', path)
                if entry.startswith(b'120000 '):
                    raise SnapshotError('Patch introduces or modifies symlink: ' + path)
            records.append({'id': task_id, 'dependencies': dependencies,
                            'patch': f'{number:04d}.patch', 'sha256': digest(data), 'paths': paths, 'tree': tree})
        tree = git(repo, 'write-tree', env=env).decode().strip()
    _validate_tree(repo, tree)
    commit_env = dict(os.environ, GIT_AUTHOR_NAME='Verification', GIT_AUTHOR_EMAIL='verification@localhost',
                      GIT_COMMITTER_NAME='Verification', GIT_COMMITTER_EMAIL='verification@localhost',
                      GIT_AUTHOR_DATE='2000-01-01T00:00:00+0000', GIT_COMMITTER_DATE='2000-01-01T00:00:00+0000')
    commit = git(repo, 'commit-tree', tree, '-p', base, env=commit_env,
                 input=b'Immutable verification snapshot\n').decode().strip()
    manifest = {'version': 1, 'base': base, 'tree': tree, 'commit': commit, 'tasks': records}
    manifest['digest'] = digest(canonical(manifest))
    # Keep immutable objects reachable across Git maintenance/GC.
    git(repo, 'update-ref', 'refs/verification/snapshots/' + manifest['digest'], commit)
    destination.mkdir(parents=True)
    for record, (_, _, data) in zip(records, pinned):
        (destination / record['patch']).write_bytes(data)
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def verify_snapshot(repo, manifest_path):
    manifest_path = Path(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    unsigned = {key: value for key, value in manifest.items() if key != 'digest'}
    if digest(canonical(unsigned)) != manifest.get('digest') or manifest.get('version') != 1:
        raise SnapshotError('Snapshot manifest changed')
    for task in manifest['tasks']:
        validate_path(task['patch'])
        path = manifest_path.parent / task['patch']
        if path.is_symlink() or digest(path.read_bytes()) != task['sha256']:
            raise SnapshotError('Snapshot patch changed: ' + task['id'])
    actual = git(repo, 'rev-parse', manifest['commit'] + '^{tree}').decode().strip()
    if actual != manifest['tree']:
        raise SnapshotError('Snapshot tree mismatch')
    return manifest


def prepare_checkout(repo, manifest_path, checkout=None):
    repo = Path(repo).resolve()
    checkout = Path(checkout or repo / '.build/verification/worktree').resolve()
    if checkout != repo / '.build/verification/worktree':
        raise SnapshotError('Only the persistent verification worktree is allowed')
    manifest = verify_snapshot(repo, manifest_path)
    if checkout.exists():
        if not (checkout / '.git').is_file():
            raise SnapshotError('Integration checkout is not a managed Git worktree')
        common = git(checkout, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()
        expected = git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()
        if common != expected or checkout == repo:
            raise SnapshotError('Integration checkout belongs to another repository')
        if git(checkout, 'status', '--porcelain', '--untracked-files=all').strip():
            raise SnapshotError('Integration checkout has uncommitted changes; preserve for inspection')
        git(checkout, 'checkout', '--detach', manifest['commit'])
    else:
        checkout.parent.mkdir(parents=True, exist_ok=True)
        git(repo, 'worktree', 'add', '--detach', str(checkout), manifest['commit'])
    verify_checkout(repo, manifest_path, checkout)
    return checkout


def verify_checkout(repo, manifest_path, checkout=None):
    checkout = Path(checkout or Path(repo) / '.build/verification/worktree')
    manifest = verify_snapshot(repo, manifest_path)
    if git(checkout, 'rev-parse', 'HEAD').decode().strip() != manifest['commit']:
        raise SnapshotError('Integration checkout HEAD changed')
    if git(checkout, 'status', '--porcelain', '--untracked-files=all').strip():
        raise SnapshotError('Integration checkout inputs changed')
    return manifest




def bundle_digest(bundle):
    """Hash all bundle bytes, modes, names and symlink targets, without following links."""
    bundle = Path(bundle)
    if bundle.is_symlink() or not bundle.is_dir():
        raise SnapshotError('Artifact must be a real bundle directory')
    root = bundle.resolve()
    entries = []
    for path in sorted(bundle.rglob('*'), key=lambda p: p.relative_to(bundle).as_posix()):
        relative = path.relative_to(bundle).as_posix()
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if path.is_symlink():
            target = os.readlink(path)
            try:
                path.resolve().relative_to(root)
            except (ValueError, RuntimeError):
                raise SnapshotError('Bundle symlink escapes artifact: ' + relative)
            entries.append([relative, 'link', mode, target])
        elif stat.S_ISREG(info.st_mode):
            entries.append([relative, 'file', mode, digest(path.read_bytes())])
        elif stat.S_ISDIR(info.st_mode):
            entries.append([relative, 'directory', mode])
        else:
            raise SnapshotError('Unsupported artifact file: ' + relative)
    return digest(canonical(entries))


def verify_build_info(bundle, manifest):
    """Require clean build metadata naming the exact pinned source commit."""
    bundle = Path(bundle)
    info = json.loads((bundle / 'Contents/Resources/build-info.json').read_text())
    commit = info.get('commit')
    if not isinstance(commit, str) or len(commit) < 7 or not manifest['commit'].startswith(commit):
        raise SnapshotError('Artifact build-info does not match snapshot commit')
    if info.get('dirty') is not False:
        raise SnapshotError('Artifact was built from modified snapshot sources')
    if not (bundle / 'Contents/MacOS/Switchboard').is_file():
        raise SnapshotError('Artifact executable is missing')
    return info


def publication_plan(repo, manifest_path, messages, expected_remote_base, branch='main', checkout=None):
    """Create ordered commit objects and an explicit CAS publication plan.

    This deliberately does not push or move any local branch. The caller must
    record transport outcomes and must not retry an uncertain push.
    """
    manifest = verify_checkout(repo, manifest_path, checkout)
    if expected_remote_base != manifest['base']:
        raise SnapshotError('Remote baseline differs from verified snapshot base')
    git(repo, 'check-ref-format', 'refs/heads/' + branch)
    parent = manifest['base']
    commits = []
    for task in manifest['tasks']:
        message = messages.get(task['id'], '')
        if not isinstance(message, str) or not message.strip():
            raise SnapshotError('Explicit commit message required for ' + task['id'])
        if 'co-authored-by:' in message.lower():
            raise SnapshotError('Agent attribution is prohibited')
        commit = git(repo, 'commit-tree', task['tree'], '-p', parent,
                     input=(message.rstrip() + '\n').encode()).decode().strip()
        commits.append({'id': task['id'], 'commit': commit, 'tree': task['tree']})
        parent = commit
    if git(repo, 'rev-parse', parent + '^{tree}').decode().strip() != manifest['tree']:
        raise SnapshotError('Publication tree differs from verified tree')
    return {'snapshot_digest': manifest['digest'], 'expected_remote_base': expected_remote_base,
            'target_ref': 'refs/heads/' + branch, 'commits': commits, 'head': parent,
            'tree': manifest['tree'],
            'push_arguments': ['push', '--force-with-lease=refs/heads/' + branch + ':' + expected_remote_base,
                               'origin', parent + ':refs/heads/' + branch]}



def _write_attempt(path, record):
    # Atomic durable replacement; publication intent must survive process death.
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w') as handle:
        json.dump(record, handle, indent=2)
        handle.write('\n')
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def _sync_local_branch(repo, plan):
    """Fast-forward the checked-out branch while preserving unpublished edits."""
    repo = Path(os.fsdecode(git(Path(repo).resolve(), 'rev-parse', '--show-toplevel').rstrip(b'\n')))
    base, head, target = plan['expected_remote_base'], plan['head'], plan['target_ref']
    if git(repo, 'rev-parse', '--symbolic-full-name', 'HEAD').decode().strip() != target:
        raise SnapshotError('The published branch is not checked out')
    current = git(repo, 'rev-parse', 'HEAD').decode().strip()
    if current not in (base, head):
        raise SnapshotError('The local branch moved from the publication base')
    for marker in ('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply',
                   'sequencer', 'BISECT_START'):
        path = git(repo, 'rev-parse', '--git-path', marker).decode().rstrip('\n')
        if (repo / path).exists():
            raise SnapshotError('A Git operation is in progress: ' + marker)

    index = Path(os.fsdecode(git(repo, 'rev-parse', '--path-format=absolute', '--git-path', 'index').rstrip(b'\n')))
    lock = index.with_name(index.name + '.lock')
    if current == head and not lock.exists():
        return {'state': 'synced', 'head': head}

    paths = set(git(repo, 'diff-tree', '-r', '--no-renames', '--name-only', '-z', base, head).split(b'\0')[:-1])
    deleted = git(repo, 'diff-tree', '-r', '--no-renames', '--diff-filter=D', '--name-only', '-z',
                  base, head).split(b'\0')[:-1]
    # Git's ordinary fast-forward rejects unstaged edits even when they already
    # equal the incoming files. Prepare the replacement index under Git's index
    # lock. Two-tree read-tree preserves unrelated staged entries and rejects
    # conflicting ones. No worktree files are written on this path.
    with lock.open('xb') as locked_index:
        remove_lock = True
        try:
            if git(repo, 'symbolic-ref', 'HEAD').decode().strip() != target or \
                    git(repo, 'rev-parse', 'HEAD').decode().strip() != base:
                raise SnapshotError('The checked-out branch changed before local synchronization')
            with tempfile.TemporaryDirectory(prefix='verification-index-', dir=index.parent) as directory:
                candidate = Path(directory) / 'index'
                shutil.copyfile(index, candidate)
                env = dict(os.environ, GIT_INDEX_FILE=str(candidate))
                git(repo, 'read-tree', '-i', '-m', base, head, env=env)
                dirty = set(git(repo, 'diff', '--no-ext-diff', '--name-only', '-z', env=env).split(b'\0')[:-1])
                if not paths.intersection(dirty) and not any(os.path.lexists(repo / os.fsdecode(p)) for p in deleted):
                    with candidate.open('rb') as source:
                        shutil.copyfileobj(source, locked_index)
                    locked_index.flush()
                    os.fsync(locked_index.fileno())
                    remove_lock = False
                    try:
                        git(repo, 'update-ref', '-m', 'verification: fast-forward after publication', target, head, base)
                    except SnapshotError:
                        remove_lock = True
                        raise
                    # If installing the index fails after the ref changed, keep
                    # the prepared index and lock so Git cannot silently proceed.
                    lock.replace(index)
                    return {'state': 'synced', 'head': head}
        finally:
            if remove_lock:
                lock.unlink()

    # The published edits may instead come from a separate checkout. Let Git
    # apply them with its standard checks for overlapping local changes.
    if git(repo, 'symbolic-ref', 'HEAD').decode().strip() != target or \
            git(repo, 'rev-parse', 'HEAD').decode().strip() != base:
        raise SnapshotError('The checked-out branch changed before local synchronization')
    git(repo, 'merge', '--ff-only', '--no-autostash', '--no-overwrite-ignore', head)
    return {'state': 'synced', 'head': head}


def _record_local_sync(repo, attempt_path, record):
    if record.get('local_sync', {}).get('state') != 'synced':
        try:
            record['local_sync'] = _sync_local_branch(repo, record['plan'])
        except (SnapshotError, OSError) as error:
            record['local_sync'] = {'state': 'blocked', 'reason': str(error)}
        _write_attempt(attempt_path, record)
    return record


def publish_plan(repo, plan, attempt_path, remote='origin', runner=None):
    """Publish once after the queue has validated all verification evidence.

    An existing attempt is never replayed, including a failed/unknown attempt.
    Reconciliation can inspect remote state, but only a fresh authorized plan
    can start another publication. Local synchronization starts only after the
    success receipt is durable.
    """
    if not remote or remote.startswith('-') or any(c.isspace() for c in remote):
        raise SnapshotError('Invalid publication remote')
    # Accept only configured remote names; never arbitrary URLs/options.
    remotes = git(repo, 'remote').decode().splitlines()
    if remote not in remotes:
        raise SnapshotError('Publication remote is not configured')
    git(repo, 'check-ref-format', plan['target_ref'])
    if not plan['target_ref'].startswith('refs/heads/'):
        raise SnapshotError('Publication target must be a branch')
    actual_tree = git(repo, 'rev-parse', plan['head'] + '^{tree}').decode().strip()
    if actual_tree != plan['tree']:
        raise SnapshotError('Publication tree changed')
    git(repo, 'merge-base', '--is-ancestor', plan['expected_remote_base'], plan['head'])
    attempt_path = Path(attempt_path)
    attempt_path.parent.mkdir(parents=True, exist_ok=True)
    # O_EXCL makes the attempt itself the publication reservation.
    try:
        fd = os.open(attempt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise SnapshotError('Publication attempt exists; reconcile instead of retrying')
    os.close(fd)
    record = {'version': 1, 'state': 'unknown', 'remote': remote, 'plan': plan}
    _write_attempt(attempt_path, record)
    target = plan['target_ref']
    args = ['git', '-C', str(repo), 'push', '--force-with-lease=' + target + ':' + plan['expected_remote_base'],
            remote, plan['head'] + ':' + target]
    run = runner or subprocess.run
    try:
        result = run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        record['returncode'] = result.returncode
        # Even a nonzero exit may follow remote acceptance and transport loss.
        # Leave it unknown until a separate read confirms the remote ref.
        if result.returncode == 0:
            record['state'] = 'published'
        else:
            record['error'] = result.stderr.decode(errors='replace')[-4000:]
    except (OSError, subprocess.SubprocessError) as error:
        record['error'] = str(error)
    _write_attempt(attempt_path, record)
    if record['state'] == 'published':
        return _record_local_sync(repo, attempt_path, record)
    return record


def reconcile_publication(repo, attempt_path, runner=None):
    attempt_path = Path(attempt_path)
    record = json.loads(attempt_path.read_text())
    plan = record['plan']
    run = runner or subprocess.run
    result = run(['git', '-C', str(repo), 'ls-remote', '--refs', record['remote'], plan['target_ref']],
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise SnapshotError('Cannot reconcile publication: ' + result.stderr.decode(errors='replace'))
    lines = result.stdout.decode().splitlines()
    tip = lines[0].split()[0] if len(lines) == 1 else None
    record['observed_remote_tip'] = tip
    if tip == plan['head']:
        record['state'] = 'published'
        _write_attempt(attempt_path, record)
        return _record_local_sync(repo, attempt_path, record)
    if record['state'] == 'published':
        # A subsequent remote update does not erase a confirmed publication.
        _write_attempt(attempt_path, record)
        return record
    if tip == plan['expected_remote_base']:
        record['state'] = 'not_published'
    else:
        record['state'] = 'remote_changed'
    _write_attempt(attempt_path, record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('create')
    create.add_argument('--base', required=True)
    create.add_argument('--tasks', required=True, help='JSON file with ordered explicit task patches')
    create.add_argument('--destination', required=True)
    for name in ('verify', 'prepare', 'check'):
        sub = commands.add_parser(name)
        sub.add_argument('manifest')
        if name != 'verify':
            sub.add_argument('--checkout')
    args = parser.parse_args()
    if args.command == 'create':
        result = create_snapshot(args.repo, args.base, json.loads(Path(args.tasks).read_text()), args.destination)
    elif args.command == 'verify':
        result = verify_snapshot(args.repo, args.manifest)
    elif args.command == 'prepare':
        result = str(prepare_checkout(args.repo, args.manifest, args.checkout))
    else:
        result = verify_checkout(args.repo, args.manifest, args.checkout)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (SnapshotError, OSError, KeyError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))
