#!/usr/bin/env python3
"""Lightweight Git fixtures; no app build or shared Swift cache."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('snapshot', Path(__file__).with_name('verification_snapshot.py'))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='snapshot-tests-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@localhost')
        self.git('remote', 'add', 'origin', '/nonexistent/snapshot-fixture.git')
        (self.repo / 'file').write_text('base\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE).decode()

    def patch(self, name='change.patch', before='base', after='changed'):
        path = Path(self.temp.name) / name
        path.write_text(f'diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-{before}\n+{after}\n')
        return str(path)

    def create(self, tasks=None):
        destination = Path(self.temp.name) / 'snapshot'
        snapshot.create_snapshot(self.repo, self.base,
                                 tasks or [{'id': 'one', 'patch': self.patch()}], destination)
        return destination / 'manifest.json'

    def test_preserves_dirty_workspace_and_index(self):
        (self.repo / 'file').write_text('unrelated\n')
        self.git('add', 'file')
        original_index = self.git('write-tree')
        manifest = self.create()
        checkout = snapshot.prepare_checkout(self.repo, manifest)
        self.assertEqual((checkout / 'file').read_text(), 'changed\n')
        self.assertEqual((self.repo / 'file').read_text(), 'unrelated\n')
        self.assertEqual(self.git('write-tree'), original_index)
        self.assertEqual(snapshot.prepare_checkout(self.repo, manifest), checkout)
        (checkout / 'file').write_text('drift\n')
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.verify_checkout(self.repo, manifest)

    def test_new_file_and_tamper(self):
        patch = Path(self.temp.name) / 'new.patch'
        patch.write_text('diff --git a/new b/new\nnew file mode 100644\n--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+new\n')
        manifest = self.create([{'id': 'new', 'patch': str(patch)}])
        checkout = snapshot.prepare_checkout(self.repo, manifest)
        self.assertEqual((checkout / 'new').read_text(), 'new\n')
        (manifest.parent / '0000.patch').write_text('tampered')
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.verify_snapshot(self.repo, manifest)

    def test_ordered_dependencies(self):
        first = self.patch()
        second = self.patch('second.patch', 'changed', 'finished')
        manifest = self.create([{'id': 'one', 'patch': first},
                                {'id': 'two', 'patch': second, 'dependencies': ['one']}])
        checkout = snapshot.prepare_checkout(self.repo, manifest)
        self.assertEqual((checkout / 'file').read_text(), 'finished\n')

    def test_missing_dependency_and_conflict(self):
        with self.assertRaises(snapshot.SnapshotError):
            self.create([{'id': 'one', 'patch': self.patch(), 'dependencies': ['missing']}])
        with self.assertRaises(snapshot.SnapshotError):
            self.create([{'id': 'one', 'patch': self.patch()}, {'id': 'two', 'patch': self.patch()}])

    def test_traversal_and_symlink(self):
        for path in ['../escape', '/absolute', '.git/config', 'a/../../escape', 'a\\escape', '.build/state', 'build/app', '.runtime/lock']:
            with self.assertRaises(snapshot.SnapshotError):
                snapshot.validate_path(path)
        patch = Path(self.temp.name) / 'link.patch'
        patch.write_text('diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/tmp\n')
        with self.assertRaises(snapshot.SnapshotError):
            self.create([{'id': 'link', 'patch': str(patch)}])

    def test_publication_plan_preserves_local_refs_and_dirty_index(self):
        manifest_path = self.create()
        snapshot.prepare_checkout(self.repo, manifest_path)
        (self.repo / 'file').write_text('staged local work\n')
        self.git('add', 'file')
        original_index = self.git('write-tree')
        plan = snapshot.publication_plan(self.repo, manifest_path, {'one': 'Fix fixture'}, self.base)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
        self.assertEqual(self.git('write-tree'), original_index)
        self.assertEqual(self.git('rev-parse', plan['head'] + '^{tree}').strip(), plan['tree'])
        self.assertIn('--force-with-lease=refs/heads/main:' + self.base, plan['push_arguments'])
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.publication_plan(self.repo, manifest_path, {'one': 'Fix'}, '0' * 40)

    def test_publication_intent_is_durable_and_unknown_not_replayed(self):
        manifest_path = self.create()
        snapshot.prepare_checkout(self.repo, manifest_path)
        plan = snapshot.publication_plan(self.repo, manifest_path, {'one': 'Fix'}, self.base)
        attempt = Path(self.temp.name) / 'attempt.json'
        calls = []

        def lost_transport(args, **kwargs):
            import json
            self.assertEqual(json.loads(attempt.read_text())['state'], 'unknown')
            calls.append(args)
            raise OSError('lost transport')

        result = snapshot.publish_plan(self.repo, plan, attempt, runner=lost_transport)
        self.assertEqual(result['state'], 'unknown')
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.publish_plan(self.repo, plan, attempt, runner=lost_transport)
        self.assertEqual(len(calls), 1)

        def remote_accepted(args, **kwargs):
            self.assertIn('ls-remote', args)
            return subprocess.CompletedProcess(args, 0, (plan['head'] + '\trefs/heads/main\n').encode(), b'')

        self.assertEqual(snapshot.reconcile_publication(self.repo, attempt, runner=remote_accepted)['state'], 'published')

    def test_publication_cas_rejection_needs_reconciliation(self):
        manifest_path = self.create()
        snapshot.prepare_checkout(self.repo, manifest_path)
        plan = snapshot.publication_plan(self.repo, manifest_path, {'one': 'Fix'}, self.base)
        attempt = Path(self.temp.name) / 'attempt.json'

        def rejected(args, **kwargs):
            self.assertIn('--force-with-lease=refs/heads/main:' + self.base, args)
            return subprocess.CompletedProcess(args, 1, b'', b'stale info')

        self.assertEqual(snapshot.publish_plan(self.repo, plan, attempt, runner=rejected)['state'], 'unknown')

        def remote_changed(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, ('f' * 40 + '\trefs/heads/main\n').encode(), b'')

        self.assertEqual(snapshot.reconcile_publication(self.repo, attempt, runner=remote_changed)['state'], 'remote_changed')

    def test_patch_cannot_write_through_existing_symlink(self):
        (self.repo / 'link').symlink_to(Path(self.temp.name))
        self.git('add', 'link')
        self.git('commit', '-qm', 'existing link')
        self.base = self.git('rev-parse', 'HEAD').strip()
        patch = Path(self.temp.name) / 'escape.patch'
        patch.write_text('diff --git a/link/escape b/link/escape\nnew file mode 100644\n--- /dev/null\n+++ b/link/escape\n@@ -0,0 +1 @@\n+escape\n')
        with self.assertRaises(snapshot.SnapshotError):
            self.create([{'id': 'escape', 'patch': str(patch)}])
        self.assertFalse((Path(self.temp.name) / 'escape').exists())

    def test_bundle_digest_covers_resources_modes_and_escape(self):
        bundle = Path(self.temp.name) / 'Fixture.app'
        resources = bundle / 'Contents/Resources'
        resources.mkdir(parents=True)
        asset = resources / 'script.py'
        asset.write_text('original')
        original = snapshot.bundle_digest(bundle)
        asset.write_text('changed')
        self.assertNotEqual(original, snapshot.bundle_digest(bundle))
        original = snapshot.bundle_digest(bundle)
        asset.chmod(0o700)
        self.assertNotEqual(original, snapshot.bundle_digest(bundle))
        (resources / 'escape').symlink_to('/tmp')
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.bundle_digest(bundle)

    def test_build_info_requires_pinned_clean_commit(self):
        import json
        bundle = Path(self.temp.name) / 'Fixture.app'
        resources = bundle / 'Contents/Resources'
        resources.mkdir(parents=True)
        executable = bundle / 'Contents/MacOS/Switchboard'
        executable.parent.mkdir()
        executable.write_text('fixture')
        info = resources / 'build-info.json'
        info.write_text(json.dumps({'commit': self.base[:7], 'dirty': False}))
        snapshot.verify_build_info(bundle, {'commit': self.base})
        info.write_text(json.dumps({'commit': self.base[:7], 'dirty': True}))
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.verify_build_info(bundle, {'commit': self.base})
        info.write_text(json.dumps({'commit': 'f' * 7, 'dirty': False}))
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.verify_build_info(bundle, {'commit': self.base})

    def test_refuses_foreign_checkout(self):
        manifest = self.create()
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.prepare_checkout(self.repo, manifest, self.repo)


if __name__ == '__main__':
    unittest.main()
