#!/usr/bin/env python3
"""Persistent verification scheduling. No commands from task data are executed.

A runner receives (batch, check, log_path) and returns an exit code. It must
verify/materialize batch['snapshot_id'] before executing allowlisted checks.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid

KINDS = frozenset(('build', 'native-tests', 'web-build', 'web-tests', 'verification-tests'))
TERMINAL = frozenset(('verified', 'published', 'failed', 'cancelled', 'interrupted', 'blocked', 'conflict'))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def normalize_checks(checks):
    result = {}
    for item in checks:
        if not isinstance(item, dict) or set(item) - {'kind', 'filters'}:
            raise ValueError('Invalid check fields')
        kind = item.get('kind')
        filters = item.get('filters', [])
        if kind not in KINDS or not isinstance(filters, list) or any(not isinstance(f, str) or not f or '\x00' in f for f in filters):
            raise ValueError('Invalid check kind or filters')
        if filters and kind not in ('native-tests', 'web-tests'):
            raise ValueError('Only test checks accept filters')
        # An unfiltered check subsumes filtered checks of the same kind.
        previous = result.get(kind)
        result[kind] = [] if not filters or previous == [] else sorted(set((previous or []) + filters))
    if not result:
        raise ValueError('At least one check is required')
    return [{'kind': k, 'filters': result[k]} for k in sorted(result, key=lambda k: (k != 'build', k))]


def canonical_snapshot_tasks(tasks):
    """Collapse exact patch aliases and rewrite dependency edges in stable order.

    Equivalence requires the same pinned base, patch bytes digest and canonical
    dependencies. Checks remain attached to every request, outside this input list.
    """
    aliases, identities, canonical_tasks = {}, {}, []
    for task in tasks:
        dependencies = task.get('dependencies', [])
        if any(dep not in aliases for dep in dependencies):
            raise ValueError('Missing or unordered snapshot dependency for ' + task['id'])
        canonical_dependencies = sorted(set(aliases[dep] for dep in dependencies))
        patch_identity = task.get('patch_digest')
        # Bare queue clients may supply only a snapshot identity. Never infer
        # patch equivalence without an explicit content digest.
        identity = canonical([task.get('base'), patch_identity or task['id'], canonical_dependencies])
        representative = identities.get(identity)
        if representative is None:
            representative = task['id']
            identities[identity] = representative
            item = dict(task, dependencies=canonical_dependencies)
            canonical_tasks.append(item)
        aliases[task['id']] = representative
    return canonical_tasks, aliases


class VerificationDeferred(RuntimeError):
    """No verification was launched because host capacity is unavailable."""


class VerificationConflict(RuntimeError):
    """Combined task patches cannot produce an isolated verification snapshot."""


class VerificationQueue:
    def __init__(self, state_dir):
        self.root = Path(state_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / 'logs').mkdir(exist_ok=True)
        self.db = sqlite3.connect(self.root / 'queue.sqlite3', timeout=30, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS tasks (
              id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, spec TEXT NOT NULL,
              status TEXT NOT NULL, batch_id TEXT, created REAL NOT NULL, detail TEXT);
            CREATE TABLE IF NOT EXISTS batches (
              id TEXT PRIMARY KEY, spec TEXT NOT NULL, status TEXT NOT NULL,
              created REAL NOT NULL, detail TEXT);
            CREATE TABLE IF NOT EXISTS state_times (entity TEXT PRIMARY KEY, updated REAL, started REAL, finished REAL);
            CREATE TRIGGER IF NOT EXISTS task_insert AFTER INSERT ON tasks BEGIN
              INSERT OR REPLACE INTO state_times(entity,updated) VALUES ('task:' || NEW.id,NEW.created);
            END;
            CREATE TRIGGER IF NOT EXISTS task_update AFTER UPDATE ON tasks BEGIN
              UPDATE state_times SET updated=(julianday('now')-2440587.5)*86400 WHERE entity='task:' || NEW.id;
            END;
            CREATE TRIGGER IF NOT EXISTS batch_insert AFTER INSERT ON batches BEGIN
              INSERT OR REPLACE INTO state_times(entity,updated) VALUES ('batch:' || NEW.id,NEW.created);
            END;
            CREATE TRIGGER IF NOT EXISTS batch_update AFTER UPDATE ON batches BEGIN
              UPDATE state_times SET updated=(julianday('now')-2440587.5)*86400,
                started=CASE WHEN NEW.status='running' THEN (julianday('now')-2440587.5)*86400 ELSE started END,
                finished=CASE WHEN NEW.status NOT IN ('planned','running') THEN (julianday('now')-2440587.5)*86400 ELSE finished END
                WHERE entity='batch:' || NEW.id;
            END;
            CREATE TABLE IF NOT EXISTS results (identity TEXT PRIMARY KEY, batch_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS lease (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), owner TEXT, pid INTEGER, started REAL);
            CREATE TABLE IF NOT EXISTS install_lease (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), batch_id TEXT NOT NULL,
              installed_at REAL NOT NULL, displaced TEXT);
        ''')

    def install_lease(self, now):
        """The batch whose bundle `install` last placed in build/, and whether it still holds it.

        A holder keeps the lease only while a task awaits live confirmation. Successful or failed
        live verification ends the hold; publication uses the archived snapshot and saved evidence,
        not the installed bundle. Restart and chat completion alone do not change task state.
        Expiry is the caller's policy."""
        row = self.db.execute('SELECT * FROM install_lease WHERE singleton=1').fetchone()
        if row is None:
            return None
        batch = self.batch(row['batch_id'])
        tasks = [self.status(task_id) for task_id in (batch['spec']['task_ids'] if batch else [])]
        pending = [t for t in tasks if t and t['status'] == 'awaiting_live']
        waiting_for = 'live confirmation' if pending else None
        return dict(batch_id=row['batch_id'], installed_at=row['installed_at'],
                    age_seconds=max(0.0, now - row['installed_at']), active=bool(pending), waiting_for=waiting_for,
                    tasks=[dict(id=t['id'], title=t['spec'].get('title', t['id']), status=t['status']) for t in tasks if t],
                    displaced=json.loads(row['displaced']) if row['displaced'] else None)

    def record_install_lease(self, batch_id, installed_at, displaced=None):
        """Record durable intent before the bundle is replaced; returns the previous row for an exact rollback."""
        with self.transaction():
            previous = self.db.execute('SELECT * FROM install_lease WHERE singleton=1').fetchone()
            self.db.execute('INSERT OR REPLACE INTO install_lease VALUES (1,?,?,?)',
                            (batch_id, installed_at, canonical(displaced) if displaced else None))
        return dict(previous) if previous else None

    def restore_install_lease(self, previous):
        with self.transaction():
            self.db.execute('DELETE FROM install_lease')
            if previous:
                self.db.execute('INSERT INTO install_lease VALUES (?,?,?,?)', (previous['singleton'], previous['batch_id'],
                                previous['installed_at'], previous['displaced']))

    def projection(self):
        tasks = []
        for row in self.status():
            times = self.db.execute('SELECT * FROM state_times WHERE entity=?', ('task:' + row['id'],)).fetchone()
            display_status = row['status']
            if display_status == 'queued' and any(
                self.status(dependency)['status'] not in ('verified', 'published')
                for dependency in row['spec']['dependencies']
            ):
                display_status = 'waiting_dependencies'
            tasks.append(dict(id=row['id'], title=row['spec'].get('title', row['id']),
                status=display_status, blocker=row['detail'], batch_id=row['batch_id'],
                created_at=row['created'], updated_at=times['updated'] if times else row['created']))
        batches = []
        for row in self.db.execute('SELECT * FROM batches ORDER BY created,id'):
            item = self._record(row)
            times = self.db.execute('SELECT * FROM state_times WHERE entity=?', ('batch:' + item['id'],)).fetchone()
            batches.append(dict(id=item['id'], status=item['status'], created_at=item['created'],
                started_at=times['started'] if times else None, finished_at=times['finished'] if times else None,
                checks=item['spec']['checks'], log=str(self.root / 'logs'), blocker=item['detail']))
        return dict(schemaVersion=1, tasks=tasks, batches=batches)

    def project_status(self):
        with open(self.root / 'projection.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            temporary = self.root / ('status-' + uuid.uuid4().hex + '.tmp')
            temporary.write_text(canonical(self.projection()) + '\n')
            os.replace(temporary, self.root / 'status.json')

    def result_key(self, snapshot_identity, checks, toolchain, restrictions):
        """Identity must include the resolved combined tree and pinned tool inputs."""
        if not snapshot_identity:
            raise ValueError('Resolved snapshot identity is required')
        return hashlib.sha256(canonical(dict(snapshot=snapshot_identity,
            checks=normalize_checks(checks), toolchain=toolchain, restrictions=restrictions)).encode()).hexdigest()

    def cached_result(self, snapshot_identity, checks, toolchain, restrictions):
        key = self.result_key(snapshot_identity, checks, toolchain, restrictions)
        row = self.db.execute('SELECT batch_id FROM results WHERE identity=?', (key,)).fetchone()
        return self.batch(row['batch_id']) if row else None

    def record_result(self, batch_id, snapshot_identity):
        with self.transaction():
            batch = self.batch(batch_id)
            if not batch or batch['status'] not in ('verified', 'awaiting_live', 'published'):
                raise ValueError('Only completed machine checks can be cached')
            spec = batch['spec']
            key = self.result_key(snapshot_identity, spec['checks'], spec['toolchain'], spec['restrictions'])
            self.db.execute('INSERT OR IGNORE INTO results VALUES (?,?)', (key, batch_id))

    def transition(self, task_id, status, detail=None):
        """Explicit live-verification/publication gates, never automatic publication."""
        allowed = {'awaiting_live': {'verified', 'blocked'}, 'verified': {'published'}}
        with self.transaction():
            task = self.status(task_id)
            if task is None or status not in allowed.get(task['status'], set()):
                raise ValueError('Invalid task state transition')
            self.db.execute('UPDATE tasks SET status=?,detail=? WHERE id=?', (status, detail, task_id))
            if task['batch_id']:
                states = [row[0] for row in self.db.execute('SELECT status FROM tasks WHERE batch_id=?', (task['batch_id'],))]
                aggregate = 'published' if all(s == 'published' for s in states) else ('verified' if all(s in ('verified', 'published') for s in states) else ('blocked' if 'blocked' in states else None))
                if aggregate:
                    self.db.execute('UPDATE batches SET status=?,detail=? WHERE id=?', (aggregate, detail, task['batch_id']))
        return self.status(task_id)

    def close(self):
        self.db.close()

    @contextlib.contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
            self.project_status()
        except BaseException:
            if self.db.in_transaction:
                self.db.execute('ROLLBACK')
            raise

    def _record(self, row):
        if row is None:
            return None
        result = dict(row)
        result['spec'] = json.loads(result['spec'])
        return result

    def status(self, task_id=None):
        if task_id is not None:
            return self._record(self.db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone())
        return [self._record(r) for r in self.db.execute('SELECT * FROM tasks ORDER BY created,id')]

    def batch(self, batch_id):
        return self._record(self.db.execute('SELECT * FROM batches WHERE id=?', (batch_id,)).fetchone())

    def submit(self, task):
        spec = dict(task)
        if set(spec) - {'id', 'base', 'snapshot_id', 'checks', 'restrictions', 'needs_live', 'dependencies', 'patch', 'patch_digest', 'title', 'toolchain', 'scope_reason'}:
            raise ValueError('Unknown task fields')
        for key in ('id', 'base', 'snapshot_id'):
            if not isinstance(spec.get(key), str) or not spec[key]:
                raise ValueError('Required nonempty field: ' + key)
        if 'scope_reason' in spec and (not isinstance(spec['scope_reason'], str) or not spec['scope_reason'].strip()):
            raise ValueError('scope_reason must be a nonblank string')
        spec['checks'] = normalize_checks(spec.get('checks', []))
        spec.setdefault('restrictions', {})
        spec.setdefault('toolchain', {})
        spec.setdefault('needs_live', False)
        spec['dependencies'] = sorted(set(spec.get('dependencies', [])))
        if not isinstance(spec['restrictions'], dict) or type(spec['needs_live']) is not bool:
            raise ValueError('Invalid restrictions or needs_live')
        if any(not isinstance(d, str) for d in spec['dependencies']) or spec['id'] in spec['dependencies']:
            raise ValueError('Invalid dependencies')
        identity = {k: v for k, v in spec.items() if k != 'id'}
        fingerprint = hashlib.sha256(canonical(identity).encode()).hexdigest()
        with self.transaction():
            old = self.status(spec['id'])
            if old:
                if old['fingerprint'] != fingerprint:
                    raise ValueError('Task ID already has different immutable input')
                return old
            for dependency in spec['dependencies']:
                if self.status(dependency) is None:
                    raise ValueError('Unknown dependency: ' + dependency)
            reused = None
            self.db.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?,?)',
                (spec['id'], fingerprint, canonical(spec), 'verified' if reused else 'queued', reused['batch_id'] if reused else None, time.time(), 'Exact input result reused' if reused else None))
        return self.status(spec['id'])

    def cancel(self, task_id):
        with self.transaction():
            row = self.status(task_id)
            if row is None:
                raise KeyError(task_id)
            if row['status'] in ('queued', 'planned'):
                self.db.execute("UPDATE tasks SET status='cancelled',detail='Cancelled before execution' WHERE id=?", (task_id,))
                if row['batch_id']:
                    self.db.execute("UPDATE batches SET status='cancelled',detail='Batch invalidated by task cancellation' WHERE id=? AND status='planned'", (row['batch_id'],))
                    self.db.execute("UPDATE tasks SET status='queued',batch_id=NULL WHERE batch_id=? AND status='planned'", (row['batch_id'],))
            elif row['status'] == 'running':
                raise ValueError('Running verification cannot be safely cancelled; stop runner explicitly')
        return self.status(task_id)

    def _plan(self):
        ready = []
        keys = ('base', 'restrictions', 'needs_live', 'toolchain')
        all_tasks = self.status()
        by_id = {task['id']: task for task in all_tasks}
        blocked_states = TERMINAL - {'verified', 'published'}
        for task in all_tasks:
            if task['status'] != 'queued':
                continue
            dependencies = [by_id[d] for d in task['spec']['dependencies']]
            if any(d['status'] in blocked_states for d in dependencies):
                self.db.execute("UPDATE tasks SET status='blocked',detail='Dependency did not pass' WHERE id=?", (task['id'],))
                task['status'] = 'blocked'
                continue
            if not ready:
                if any(d['status'] not in ('verified', 'published') for d in dependencies):
                    continue
                ready.append(task)
            elif all(task['spec'][k] == ready[0]['spec'][k] for k in keys):
                if all(d['status'] in ('verified', 'published') or d['id'] in {r['id'] for r in ready} for d in dependencies):
                    ready.append(task)
        if not ready:
            return None
        first = ready[0]['spec']
        compatible = ready
        # Include previously verified dependency patches in the isolated input;
        # their status is not changed by this batch.
        snapshot_tasks = {}
        def include(task):
            for dep in task['spec']['dependencies']:
                include(by_id[dep])
            snapshot_tasks[task['id']] = task['spec']
        for task in compatible:
            include(task)
        batch_id = uuid.uuid4().hex
        spec = {k: first[k] for k in keys}
        spec['tasks'], spec['aliases'] = canonical_snapshot_tasks(list(snapshot_tasks.values()))
        spec.update(id=batch_id, task_ids=[t['id'] for t in compatible], checks=normalize_checks([c for t in compatible for c in t['spec']['checks']]))
        self.db.execute('INSERT INTO batches VALUES (?,?,?,?,?)', (batch_id, canonical(spec), 'planned', time.time(), None))
        self.db.executemany("UPDATE tasks SET status='planned',batch_id=? WHERE id=?", [(batch_id, t['id']) for t in compatible])
        return self.batch(batch_id)

    def plan_batch(self):
        with self.transaction():
            return self._plan()

    @contextlib.contextmanager
    def executor(self):
        # flock survives lease timestamp staleness: a slow live runner is never stolen.
        with open(self.root / 'executor.lock', 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('Verification executor is already active')
            try:
                with self.transaction():
                    self.db.execute("UPDATE tasks SET status='interrupted',detail='Executor ended without a result; explicit resubmission required' WHERE status='running'")
                    self.db.execute("UPDATE batches SET status='interrupted',detail='Executor ended without a result' WHERE status='running'")
                    self.db.execute('INSERT OR REPLACE INTO lease VALUES (1,?,?,?)', (uuid.uuid4().hex, os.getpid(), time.time()))
                yield lock.fileno()
            finally:
                self.db.execute('DELETE FROM lease')

    def recover(self):
        with self.executor():
            pass

    def execute_next(self, runner, resolve_identity=None):
        with self.executor() as lease_fd:
            with self.transaction():
                row = self.db.execute("SELECT * FROM batches WHERE status='planned' ORDER BY created,id LIMIT 1").fetchone()
                batch = self._record(row) if row else self._plan()
                if not batch:
                    return None
                batch_id = batch['id']
                active = self.db.execute("SELECT id FROM tasks WHERE batch_id=? AND status='planned'", (batch_id,)).fetchall()
                if not active:
                    self.db.execute("UPDATE batches SET status='cancelled' WHERE id=?", (batch_id,))
                    return self.batch(batch_id)
                admit = getattr(runner, 'admit', None)
                if admit:
                    try:
                        admit(batch['spec'])
                    except VerificationDeferred as error:
                        self.db.execute('UPDATE batches SET detail=? WHERE id=?', (str(error), batch_id))
                        self.db.execute("UPDATE tasks SET detail=? WHERE batch_id=? AND status='planned'", (str(error), batch_id))
                        return self.batch(batch_id)
                self.db.execute("UPDATE batches SET status='running' WHERE id=?", (batch_id,))
                self.db.execute("UPDATE tasks SET status='running' WHERE batch_id=? AND status='planned'", (batch_id,))
            batch['spec']['lease_fd'] = lease_fd
            outcome, detail = ('awaiting_live' if batch['spec']['needs_live'] else 'verified'), None
            completed_checks = 0
            reserved_log = None
            try:
                resolved_identity = resolve_identity(batch['spec']) if resolve_identity else None
                cached = self.cached_result(resolved_identity, batch['spec']['checks'], batch['spec']['toolchain'], batch['spec']['restrictions']) if resolved_identity else None
                if cached:
                    with self.transaction():
                        self._finish(batch_id, outcome, 'Exact machine-check input reused from ' + cached['id'])
                    return self.batch(batch_id)
                for index, check in enumerate(batch['spec']['checks']):
                    log_path = self.root / 'logs' / f'{batch_id}-{index:03d}-{check["kind"]}.log'
                    # Reserve the path exclusively, even when a runner writes nothing.
                    log_path.touch(exist_ok=False)
                    reserved_log = log_path
                    code = runner(batch['spec'], check, log_path)
                    completed_checks += 1
                    reserved_log = None
                    if type(code) is not int or code != 0:
                        outcome, detail = 'failed', f'{check["kind"]} returned {code!r}'
                        break
            except VerificationDeferred as error:
                if reserved_log and reserved_log.exists() and reserved_log.stat().st_size == 0:
                    reserved_log.unlink()
                outcome = 'planned' if completed_checks == 0 else 'blocked'
                detail = str(error) if completed_checks == 0 else 'Capacity unavailable after completed checks; explicit new task required: ' + str(error)
                with self.transaction():
                    self._finish(batch_id, outcome, detail)
                    if completed_checks == 0:
                        self.db.execute("UPDATE state_times SET started=NULL,finished=NULL WHERE entity=?", ('batch:' + batch_id,))
                return self.batch(batch_id)
            except BaseException as error:
                outcome, detail = ('conflict' if isinstance(error, VerificationConflict) else 'interrupted'), f'{type(error).__name__}: {error}'
                with self.transaction():
                    self._finish(batch_id, outcome, detail)
                raise
            with self.transaction():
                self._finish(batch_id, outcome, detail)
            if resolved_identity and outcome in ('verified', 'awaiting_live'):
                self.record_result(batch_id, resolved_identity)
            return self.batch(batch_id)

    def _finish(self, batch_id, outcome, detail):
        self.db.execute('UPDATE batches SET status=?,detail=? WHERE id=?', (outcome, detail, batch_id))
        self.db.execute("UPDATE tasks SET status=?,detail=? WHERE batch_id=? AND status='running'", (outcome, detail, batch_id))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', default='.build/verification')
    sub = parser.add_subparsers(dest='command', required=True)
    submit = sub.add_parser('submit')
    submit.add_argument('--task', required=True, help='JSON task object')
    status = sub.add_parser('status')
    status.add_argument('id', nargs='?')
    cancel = sub.add_parser('cancel')
    cancel.add_argument('id')
    sub.add_parser('plan')
    sub.add_parser('recover')
    args = parser.parse_args()
    queue = VerificationQueue(args.state_dir)
    try:
        if args.command == 'submit': result = queue.submit(json.loads(args.task))
        elif args.command == 'status': result = queue.status(args.id)
        elif args.command == 'cancel': result = queue.cancel(args.id)
        elif args.command == 'plan': result = queue.plan_batch()
        else: result = queue.recover()
        print(json.dumps(queue.projection() if args.command == 'status' and args.id is None else result, sort_keys=True))
    finally:
        queue.close()


if __name__ == '__main__':
    main()
