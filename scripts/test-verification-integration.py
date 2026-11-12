#!/usr/bin/env python3
"""Queue/snapshot/CLI acceptance tests. Git is real; builds and host probes are fake."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verification_queue import VerificationQueue

spec = importlib.util.spec_from_file_location('verify_project_integration', Path(__file__).with_name('verify-project.py'))
project = importlib.util.module_from_spec(spec)
spec.loader.exec_module(project)
REAL_RUN = subprocess.run
IDENTITY = {'tools': {'fixture': '1'}, 'inputs': {}, 'platform': 'fixture', 'environment': {}}


class VerificationIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='verification-integration-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@localhost')
        self.git('remote', 'add', 'origin', '/nonexistent/fixture.git')
        (self.repo / '.gitignore').write_text('build/\n.build/\n')
        for name in ('a', 'b'):
            (self.repo / name).write_text('base\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.state = self.repo / '.build/verification'
        self.queue = VerificationQueue(self.state)
        self.addCleanup(self.queue.close)
        self.calls = []
        self.return_code = 0
        self.flaky = False
        self.zero_tests = False
        self.mutate_checkout = False
        self.enterContext(patch.object(project, 'fingerprint', return_value=IDENTITY))
        self.enterContext(patch.object(project, 'preflight'))
        self.enterContext(patch.object(project, 'run_check', side_effect=lambda argv, lease_fd=None, **kwargs: self.fake_run(argv, **kwargs)))
        self.enterContext(patch.object(project.subprocess, 'run', side_effect=self.fake_run))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE).decode()

    def fake_run(self, argv, **kwargs):
        if argv[:2] == ['zsh', 'scripts/build-app.sh']:
            self.calls.append(('build', Path(kwargs['cwd'])))
            executable = Path(kwargs['cwd']) / 'build/Switchboard.app/Contents/MacOS/Switchboard'
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text('fixture executable')
            resources = executable.parents[1] / 'Resources'
            resources.mkdir(exist_ok=True)
            resources.joinpath('build-info.json').write_text(json.dumps({'commit': subprocess.check_output(['git', '-C', str(kwargs['cwd']), 'rev-parse', 'HEAD'], text=True).strip(), 'dirty': False}))
            if self.mutate_checkout:
                (Path(kwargs['cwd']) / 'a').write_text('unexpected mutation\n')
            return subprocess.CompletedProcess(argv, self.return_code)
        if argv[:2] == ['zsh', 'scripts/test.sh']:
            self.calls.append(('tests', Path(kwargs['cwd'])))
            if self.flaky:
                kwargs['stdout'].write('FLAKY (fixture retry)\n')
            if self.zero_tests:
                kwargs['stdout'].write('Test run with 0 tests passed\n')
            return subprocess.CompletedProcess(argv, self.return_code)
        if argv[0] == 'codesign':
            self.calls.append(('codesign', None))
            return subprocess.CompletedProcess(argv, 0)
        if argv[0] not in ('git', 'cp'):
            self.fail('Unexpected subprocess in lightweight acceptance test: ' + repr(argv))
        return REAL_RUN(argv, **kwargs)

    def submit(self, name, file='a', before='base', after='changed', **extra):
        source = Path(self.temp.name) / (name + '.patch')
        source.write_text(f'diff --git a/{file} b/{file}\n--- a/{file}\n+++ b/{file}\n@@ -1 +1 @@\n-{before}\n+{after}\n')
        task = dict(id=name, base=self.base, patch=str(source), checks=[dict(kind='build')])
        task.update(extra)
        manifest = Path(self.temp.name) / (name + '.json')
        manifest.write_text(json.dumps(task))
        argv = ['verify-project.py', '--repo', str(self.repo), '--state-dir', str(self.state), 'submit', str(manifest)]
        with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
            project.main()
        return self.queue.status(name)

    def run_batch(self):
        runner = project.make_runner(self.repo, self.state, self.queue)
        return self.queue.execute_next(runner, resolve_identity=runner.resolve_identity)

    def reject_publish(self, batch):
        messages = Path(self.temp.name) / 'messages.json'
        messages.write_text('{}')
        with self.assertRaises(ValueError):
            project.publish_batch(self.queue, self.repo, self.state, batch['id'], messages, self.base, 'main')
        self.assertFalse((self.state / 'batches' / batch['id'] / 'publication-attempt.json').exists())

    def test_simultaneous_identical_patch_aliases_build_and_publish_once(self):
        self.submit('one')
        self.submit('alias')
        batch = self.run_batch()
        self.assertEqual([kind for kind, _ in self.calls], ['build'])
        self.assertEqual(batch['spec']['task_ids'], ['one', 'alias'])
        self.assertEqual(len(batch['spec']['tasks']), 1)
        self.assertEqual(self.queue.status('one')['status'], 'verified')
        self.assertEqual(self.queue.status('alias')['status'], 'verified')
        messages = Path(self.temp.name) / 'messages.json'
        messages.write_text(json.dumps({'one': 'Fix fixture', 'alias': 'Same requested fix'}))
        plans = []
        def published(repo, plan, attempt):
            plans.append(plan)
            return {'state': 'published'}
        with patch('verification_snapshot.publish_plan', side_effect=published):
            project.publish_batch(self.queue, self.repo, self.state, batch['id'], messages, self.base, 'main')
        self.assertEqual(len(plans[0]['commits']), 1)
        self.assertEqual(self.queue.status('one')['status'], 'published')
        self.assertEqual(self.queue.status('alias')['status'], 'published')

    def test_alias_dependency_edges_remain_topological(self):
        self.submit('one', after='first')
        self.submit('alias', after='first')
        self.submit('child', before='first', after='second', dependencies=['alias'])
        batch = self.run_batch()
        self.assertEqual([t['id'] for t in batch['spec']['tasks']], ['one', 'child'])
        self.assertEqual(batch['spec']['tasks'][1]['dependencies'], ['one'])
        self.assertEqual((self.state / 'worktree/a').read_text(), 'second\n')
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(all(self.queue.status(t)['status'] == 'verified' for t in ('one', 'alias', 'child')))

    def test_zero_selected_native_tests_does_not_verify(self):
        self.submit('one', checks=[dict(kind='native-tests', filters=['MissingTests'])])
        self.zero_tests = True
        batch = self.run_batch()
        self.assertEqual(batch['status'], 'failed')
        self.reject_publish(batch)

    def test_two_submissions_combine_and_build_once(self):
        self.submit('one', file='a', after='first')
        self.submit('two', file='b', after='second')
        batch = self.run_batch()
        checkout = self.state / 'worktree'
        self.assertEqual((checkout / 'a').read_text(), 'first\n')
        self.assertEqual((checkout / 'b').read_text(), 'second\n')
        self.assertEqual([kind for kind, _ in self.calls], ['build'])
        self.assertEqual(batch['status'], 'verified')
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
        self.assertEqual((self.repo / 'a').read_text(), 'base\n')

    def test_duplicate_resolved_tree_reuses_checks_and_artifact(self):
        self.submit('one')
        first = self.run_batch()
        self.submit('same-tree')
        second = self.run_batch()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(second['status'], 'verified')
        artifact = self.state / 'batches' / second['id'] / 'artifact/Switchboard.app/Contents/MacOS/Switchboard'
        self.assertTrue(artifact.exists())
        self.assertNotEqual(first['id'], second['id'])

    def test_dependency_patch_changes_resolved_tree_and_reruns(self):
        self.submit('one', after='first')
        self.run_batch()
        self.submit('two', before='first', after='second', dependencies=['one'])
        batch = self.run_batch()
        self.assertEqual((self.state / 'worktree/a').read_text(), 'second\n')
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(batch['status'], 'verified')

    def test_mutated_frozen_patch_is_rejected_without_build(self):
        task = self.submit('one')
        Path(task['spec']['patch']).write_text('tampered')
        with self.assertRaises(ValueError):
            self.run_batch()
        self.assertEqual(self.queue.status('one')['status'], 'interrupted')
        self.assertEqual(self.calls, [])

    def test_runner_mutation_is_rejected_after_check(self):
        self.submit('one')
        self.mutate_checkout = True
        with self.assertRaises(Exception):
            self.run_batch()
        self.assertEqual(self.queue.status('one')['status'], 'interrupted')
        self.assertFalse((self.state / 'batches' / self.queue.status('one')['batch_id'] / 'artifact').exists())

    def test_cancelled_patch_excluded_from_replanned_batch(self):
        self.submit('one', file='a')
        self.submit('two', file='b')
        self.queue.plan_batch()
        self.queue.cancel('one')
        batch = self.run_batch()
        self.assertEqual(batch['spec']['task_ids'], ['two'])
        self.assertEqual((self.state / 'worktree/a').read_text(), 'base\n')
        self.assertEqual((self.state / 'worktree/b').read_text(), 'changed\n')

    def test_failed_machine_check_blocks_publication(self):
        self.submit('one')
        self.return_code = 1
        batch = self.run_batch()
        self.assertEqual(batch['status'], 'failed')
        self.reject_publish(batch)

    def test_restriction_blocks_publication_after_success(self):
        self.submit('one', restrictions={'allow_publish': False})
        batch = self.run_batch()
        self.assertEqual(batch['status'], 'verified')
        self.reject_publish(batch)

    def test_live_required_remains_unpublished(self):
        self.submit('one', needs_live=True)
        batch = self.run_batch()
        self.assertEqual(batch['status'], 'awaiting_live')
        self.reject_publish(batch)

    # Install lease: one batch at a time owns build/Switchboard.app until it is confirmed live and published.

    def built(self, name, file, **extra):
        self.submit(name, file=file, **{'after': name, 'title': 'Title of ' + name, **extra})
        batch = self.run_batch()
        self.assertIn(batch['status'], ('verified', 'awaiting_live'))
        return batch

    def install(self, batch, take_over=False, at=0):
        home = Path(self.temp.name) / 'home'
        with patch.object(project.Path, 'home', return_value=home), \
             patch.object(project, 'request_restart', side_effect=lambda repo, path: self.restarts.append(batch['id']) or {'restart': 'requested'}), \
             contextlib.redirect_stderr(io.StringIO()) as stderr:
            result = project.install_batch(self.queue, self.repo, self.state, batch['id'], take_over=take_over,
                                           now=lambda: self.clock + at)
        return result, stderr.getvalue()

    def refused(self, batch, at=0):
        before = self.installed_build_info()
        with self.assertRaises(project.InstallRefused) as caught:
            self.install(batch, at=at)
        # Nothing staged, replaced, recorded or requested.
        self.assertEqual(self.installed_build_info(), before)
        self.assertFalse((self.state / 'batches' / batch['id'] / 'install-attempt.json').exists())
        self.assertNotIn(batch['id'], self.restarts)
        self.assertEqual([p for p in (self.repo / 'build').iterdir() if p.name.startswith('verification-install-')], [])
        return caught.exception

    def installed_build_info(self):
        return (self.repo / 'build/Switchboard.app/Contents/Resources/build-info.json').read_text()

    def archived_build_info(self, batch):
        return (self.state / 'batches' / batch['id'] / 'artifact/Switchboard.app/Contents/Resources/build-info.json').read_text()

    def publish(self, batch):
        (self.state / 'batches' / batch['id'] / 'live-evidence.json').write_text('{}')
        messages = Path(self.temp.name) / 'messages.json'
        messages.write_text(json.dumps({t: 'Publish ' + t for t in batch['spec']['task_ids']}))
        with patch('verification_snapshot.publish_plan', return_value={'state': 'published'}):
            project.publish_batch(self.queue, self.repo, self.state, batch['id'], messages, self.base, 'main')

    def lease_fixture(self, **extra):
        self.restarts = []
        self.clock = 1_900_000_000.0
        first = self.built('first', 'a', needs_live=True, **extra)
        second = self.built('second', 'b', needs_live=True)
        self.install(first)
        self.assertEqual(self.installed_build_info(), self.archived_build_info(first))
        return first, second

    def test_install_refused_while_holder_awaits_live_and_until_published(self):
        first, second = self.lease_fixture()
        refusal = self.refused(second, at=12 * 60)
        message = str(refusal)
        self.assertNotIn('\n', message)
        for expected in (first['id'], 'first (Title of first)', '12 min ago', 'live confirmation',
                         'confirm-live and publish', f'install {second["id"]} --take-over', '45 min'):
            self.assertIn(expected, message)
        self.assertEqual(refusal.details['state'], 'refused')
        self.assertEqual(refusal.details['holder']['batch_id'], first['id'])
        # Live confirmed but not yet published: still the holder.
        self.queue.transition('first', 'verified', 'fixture live evidence')
        self.assertIn('waiting for publication', str(self.refused(second, at=20 * 60)))
        self.publish(first)
        result, note = self.install(second, at=21 * 60)
        self.assertEqual(result['state'], 'waiting_for_restart')
        self.assertNotIn('displaced', result)
        self.assertEqual(note, '')
        self.assertEqual(self.installed_build_info(), self.archived_build_info(second))
        self.assertEqual(self.restarts, [first['id'], second['id']])
        self.assertEqual(self.queue.install_lease(self.clock)['batch_id'], second['id'])

    def assert_lease_ends(self, final):
        first, second = self.lease_fixture()
        self.refused(second)
        if final == 'blocked':
            self.queue.transition('first', 'blocked', 'fixture live check failed')
        else:
            # Not reachable after install through the CLI today; the lease must still not outlive it.
            self.queue.db.execute('UPDATE tasks SET status=? WHERE id=?', (final, 'first'))
        self.assertFalse(self.queue.install_lease(self.clock)['active'])
        result, _ = self.install(second)
        self.assertNotIn('displaced', result)
        self.assertEqual(self.installed_build_info(), self.archived_build_info(second))

    def test_lease_ends_when_holder_live_check_is_blocked(self):
        self.assert_lease_ends('blocked')

    def test_lease_ends_when_holder_failed(self):
        self.assert_lease_ends('failed')

    def test_lease_ends_when_holder_cancelled(self):
        self.assert_lease_ends('cancelled')

    def test_publication_policy_decides_whether_verified_holder_still_holds(self):
        self.restarts, self.clock = [], 1_900_000_000.0
        unpublishable = self.built('first', 'a', restrictions={'allow_publish': False})
        second = self.built('second', 'b')
        self.install(unpublishable)
        # Verified without live and publication prohibited: nothing is pending, so no lease.
        self.assertFalse(self.queue.install_lease(self.clock)['active'])
        self.install(second)
        third = self.built('third', 'a', before='base', after='third')
        # Verified without live but publication pending: holds.
        self.assertIn('waiting for publication', str(self.refused(third)))

    def test_stale_lease_expires_after_the_limit(self):
        first, second = self.lease_fixture()
        self.refused(second, at=project.INSTALL_LEASE_LIMIT_SECONDS - 1)
        result, note = self.install(second, at=project.INSTALL_LEASE_LIMIT_SECONDS)
        self.assertEqual(result['displaced']['batch_id'], first['id'])
        self.assertEqual(result['displaced']['reason'], 'expired')
        self.assertIn('stale lease had expired', note)
        self.assertIn(first['id'], note)
        self.assertEqual(self.installed_build_info(), self.archived_build_info(second))
        lease = self.queue.install_lease(self.clock + project.INSTALL_LEASE_LIMIT_SECONDS)
        self.assertEqual((lease['batch_id'], lease['displaced']['reason']), (second['id'], 'expired'))
        attempt = json.loads((self.state / 'batches' / second['id'] / 'install-attempt.json').read_text())
        self.assertEqual(attempt['displaced']['batch_id'], first['id'])

    def test_take_over_is_explicit_and_records_the_displaced_holder(self):
        first, second = self.lease_fixture()
        self.refused(second, at=60)
        result, note = self.install(second, take_over=True, at=60)
        self.assertEqual((result['displaced']['batch_id'], result['displaced']['reason']), (first['id'], 'take_over'))
        self.assertEqual(result['displaced']['task_ids'], ['first'])
        self.assertIn('explicit --take-over', note)
        self.assertEqual(self.installed_build_info(), self.archived_build_info(second))
        self.assertEqual(self.queue.install_lease(self.clock)['displaced']['batch_id'], first['id'])
        # The displaced batch is now refused in turn; it does not get its bundle back automatically.
        with self.assertRaises(project.InstallRefused):
            self.install(first, at=120)
        self.assertEqual(self.installed_build_info(), self.archived_build_info(second))
        self.assertEqual(self.restarts, [first['id'], second['id']])

    def test_reinstalling_the_holder_keeps_the_attempt_guard(self):
        first, second = self.lease_fixture()
        with self.assertRaises(FileExistsError):
            self.install(first, at=60)
        self.assertEqual(self.restarts, [first['id']])
        self.assertEqual(self.installed_build_info(), self.archived_build_info(first))
        lease = self.queue.install_lease(self.clock)
        self.assertEqual((lease['batch_id'], lease['installed_at'], lease['displaced']), (first['id'], self.clock, None))

    def cli(self, *args):
        return REAL_RUN([sys.executable, '-B', str(Path(project.__file__).resolve()), '--repo', str(self.repo),
                         '--state-dir', str(self.state), *args], capture_output=True, text=True)

    def test_cli_refusal_exit_and_status(self):
        self.restarts, self.clock = [], __import__('time').time() - 5 * 60
        first = self.built('first', 'a', needs_live=True)
        second = self.built('second', 'b', needs_live=True)
        status = json.loads(self.cli('status').stdout)
        self.assertIsNone(status['install_lease'])
        self.install(first)
        refused = self.cli('install', second['id'])
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(len(refused.stderr.strip().splitlines()), 1)
        self.assertIn('install refused: batch ' + first['id'], refused.stderr)
        self.assertEqual(json.loads(refused.stdout)['holder']['batch_id'], first['id'])
        self.assertFalse((self.state / 'batches' / second['id'] / 'install-attempt.json').exists())
        status = json.loads(self.cli('status').stdout)
        lease = status['install_lease']
        self.assertEqual((lease['batch_id'], lease['holds'], lease['waiting_for']), (first['id'], True, 'live confirmation'))
        self.assertGreaterEqual(lease['age_seconds'], 5 * 60)
        self.assertLess(lease['expires_in_seconds'], project.INSTALL_LEASE_LIMIT_SECONDS - 5 * 60 + 1)
        self.assertNotIn('install_lease', json.loads((self.state / 'status.json').read_text()))
        self.queue.transition('first', 'verified', 'fixture live evidence')
        self.publish(first)
        lease = json.loads(self.cli('status').stdout)['install_lease']
        self.assertEqual((lease['batch_id'], lease['holds'], lease['waiting_for']), (first['id'], False, None))

    def test_flaky_exit_zero_does_not_verify(self):
        self.submit('one', checks=[dict(kind='native-tests', filters=['FixtureTests'])])
        self.flaky = True
        batch = self.run_batch()
        self.assertEqual([kind for kind, _ in self.calls], ['build', 'tests'])
        self.assertEqual(batch['status'], 'failed')
        self.reject_publish(batch)


if __name__ == '__main__':
    unittest.main()
