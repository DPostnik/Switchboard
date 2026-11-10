#!/usr/bin/env python3
"""Lightweight queue tests; all checks use fake runners."""
import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('verification_queue', Path(__file__).with_name('verification_queue.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.queue = module.VerificationQueue(self.temp.name)

    def tearDown(self):
        self.queue.close()
        self.temp.cleanup()

    def task(self, name, **values):
        task = dict(id=name, base='base', snapshot_id=name, checks=[dict(kind='build')])
        task.update(values)
        return self.queue.submit(task)

    def test_batch_union_and_immutable_id(self):
        self.task('a')
        self.task('b', checks=[dict(kind='native-tests', filters=['One'])])
        batch = self.queue.plan_batch()['spec']
        self.assertEqual(batch['task_ids'], ['a', 'b'])
        self.assertEqual([c['kind'] for c in batch['checks']], ['build', 'native-tests'])
        with self.assertRaises(ValueError):
            self.task('a', snapshot_id='changed')
        logs = []
        result = self.queue.execute_next(lambda batch, check, log: logs.append(log) or 0)
        self.assertEqual(result['status'], 'verified')
        self.assertEqual(len(set(logs)), 2)
        self.assertTrue(all(p.exists() for p in logs))

    def test_dependency_failure_and_cancel(self):
        self.task('a')
        self.task('b', dependencies=['a'], restrictions={'isolated': True})
        self.task('c')
        self.queue.cancel('c')
        self.queue.execute_next(lambda *args: 1)
        self.queue.plan_batch()
        self.assertEqual(self.queue.status('b')['status'], 'blocked')
        self.assertEqual(self.queue.status('c')['status'], 'cancelled')

    def test_crash_is_not_replayed(self):
        self.task('a')
        def crash(*args):
            raise RuntimeError('lost runner')
        with self.assertRaises(RuntimeError):
            self.queue.execute_next(crash)
        self.assertEqual(self.queue.status('a')['status'], 'interrupted')
        self.assertIsNone(self.queue.execute_next(lambda *args: self.fail('replayed')))

    def test_dependent_ready_tasks_batch_topologically(self):
        self.task('a')
        self.task('b', dependencies=['a'])
        batch = self.queue.plan_batch()['spec']
        self.assertEqual(batch['task_ids'], ['a', 'b'])
        self.assertEqual([t['id'] for t in batch['tasks']], ['a', 'b'])

    def test_awaiting_live_dependency_waits(self):
        self.task('a', needs_live=True)
        self.queue.execute_next(lambda *args: 0)
        self.task('b', dependencies=['a'])
        self.assertIsNone(self.queue.plan_batch())
        self.assertEqual(self.queue.status('b')['status'], 'queued')
        self.assertEqual(self.queue.projection()['tasks'][-1]['status'], 'waiting_dependencies')

    def test_exact_resolved_cache(self):
        self.task('a')
        self.queue.execute_next(lambda *args: 0, resolve_identity=lambda batch: {'tree': 'one'})
        self.task('b')
        self.queue.execute_next(lambda *args: self.fail('exact result rerun'), resolve_identity=lambda batch: {'tree': 'one'})
        self.assertEqual(self.queue.status('b')['status'], 'verified')
        self.task('c')
        calls = []
        self.queue.execute_next(lambda *args: calls.append(True) or 0, resolve_identity=lambda batch: {'tree': 'two'})
        self.assertEqual(calls, [True])

    def test_admission_deferred_without_attempt(self):
        self.task('a')
        def runner(*args):
            self.fail('admission launched a check')
        def admit(batch):
            raise module.VerificationDeferred('host busy')
        runner.admit = admit
        batch = self.queue.execute_next(runner)
        self.assertEqual(batch['status'], 'planned')
        self.assertEqual(self.queue.status('a')['status'], 'planned')
        self.assertIsNone(self.queue.projection()['batches'][0]['started_at'])
        self.assertEqual(list((self.queue.root / 'logs').iterdir()), [])
        del runner.admit
        self.assertEqual(self.queue.execute_next(lambda *args: 0)['status'], 'verified')

    def test_mid_batch_deferral_never_replays_completed_build(self):
        self.task('a', checks=[dict(kind='build'), dict(kind='native-tests', filters=['One'])])
        calls = []
        def runner(batch, check, log):
            calls.append(check['kind'])
            if check['kind'] == 'native-tests':
                raise module.VerificationDeferred('host became busy')
            return 0
        batch = self.queue.execute_next(runner)
        self.assertEqual(batch['status'], 'blocked')
        self.assertIsNone(self.queue.execute_next(runner))
        self.assertEqual(calls, ['build', 'native-tests'])

    def test_lease_exclusion(self):
        other = module.VerificationQueue(self.temp.name)
        try:
            with self.queue.executor():
                with self.assertRaises(RuntimeError):
                    other.recover()
        finally:
            other.close()

    def test_child_retains_executor_lease(self):
        with self.queue.executor() as lease_fd:
            child = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read()'],
                stdin=subprocess.PIPE, pass_fds=(lease_fd,))
        try:
            with self.assertRaises(RuntimeError):
                self.queue.recover()
        finally:
            child.communicate(timeout=5)
        self.queue.recover()

    def test_live_gate_and_projection(self):
        self.task('a', needs_live=True)
        self.queue.execute_next(lambda *args: 0)
        self.assertEqual(self.queue.status('a')['status'], 'awaiting_live')
        self.assertTrue((Path(self.temp.name) / 'status.json').exists())

    def test_invalid_check_and_no_cross_input_reuse(self):
        with self.assertRaises(ValueError):
            self.task('bad', checks=[dict(kind='shell')])
        self.task('a')
        self.queue.execute_next(lambda *args: 0)
        self.task('b')
        self.assertEqual(self.queue.status('b')['status'], 'queued')

    def test_recovery_after_abrupt_exit(self):
        self.task('a')
        batch = self.queue.plan_batch()
        self.queue.db.execute("UPDATE tasks SET status='running'")
        self.queue.db.execute("UPDATE batches SET status='running'")
        self.queue.recover()
        self.assertEqual(self.queue.status('a')['status'], 'interrupted')
        self.assertEqual(self.queue.batch(batch['id'])['status'], 'interrupted')


if __name__ == '__main__':
    unittest.main()
