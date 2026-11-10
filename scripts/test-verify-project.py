#!/usr/bin/env python3
"""Cheap CLI command policy checks; never launches a build."""
import importlib.util
import fcntl
import os
import sys
import time
from pathlib import Path
import unittest
import tempfile
import subprocess
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('verify_project', Path(__file__).with_name('verify-project.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CommandPolicyTests(unittest.TestCase):
    def test_clone_fallback_removes_only_its_partial_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            (source / 'asset').write_text('verified')
            destination = root / 'target'
            unrelated = root / 'unrelated'
            unrelated.write_text('preserve')
            def failed_copy(argv, **kwargs):
                partial = Path(argv[-1])
                partial.mkdir()
                (partial / 'partial').write_text('failed copy')
                return subprocess.CompletedProcess(argv, 1)
            with patch.object(module.subprocess, 'run', side_effect=failed_copy):
                module.clone_bundle(source, destination)
            self.assertEqual((destination / 'asset').read_text(), 'verified')
            self.assertFalse((destination / 'partial').exists())
            self.assertEqual(unrelated.read_text(), 'preserve')
            with self.assertRaises(ValueError):
                module.clone_bundle(source, destination)

    def test_verification_suite_is_fixed_command(self):
        self.assertEqual(module.command_for({'kind': 'verification-tests'}),
                         (['python3', '-B', 'scripts/test-verification.py'], '.'))
        with self.assertRaises(ValueError):
            module.command_for({'kind': 'verification-tests', 'filters': ['anything']})

    def test_native_build(self):
        self.assertEqual(module.command_for({'kind': 'build'}), (['zsh', 'scripts/build-app.sh'], '.'))

    def test_native_filter_is_literal_argument(self):
        command, cwd = module.command_for({'kind': 'native-tests', 'filters': ['QueueTests; touch /tmp/no']})
        self.assertEqual(command[-1], 'QueueTests; touch /tmp/no')
        self.assertEqual(cwd, '.')

    def test_reject_unscoped_or_injected_checks(self):
        for check in [{'kind': 'shell'}, {'kind': 'native-tests'}, {'kind': 'web-tests'},
                      {'kind': 'web-tests', 'filters': ['--help']},
                      {'kind': 'web-tests', 'filters': ['src/../other.test.ts']},
                      {'kind': 'build', 'filters': ['x']}]:
            with self.subTest(check=check), self.assertRaises(ValueError):
                module.command_for(check)

    def test_full_native_requires_scope_reason(self):
        self.assertEqual(module.command_for({'kind': 'native-tests'}, 'toolchain change'), (['zsh', 'scripts/test.sh'], '.'))

    def test_full_native_rejects_blank_or_nontext_reason(self):
        for reason in ['  ', 1, True, ['toolchain']]:
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                module.command_for({'kind': 'native-tests'}, reason)

    def test_scoped_web_tests(self):
        self.assertEqual(module.command_for({'kind': 'web-tests', 'filters': ['src/protocol/snapshot.test.ts']})[0],
                         ['npm', 'test', '--', 'src/protocol/snapshot.test.ts'])



class ExecutorLeaseTests(unittest.TestCase):
    def wait_for(self, predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail('fixture did not reach expected state')

    def test_lease_lifetime_with_persistent_grandchild(self):
        for coordinator_exits in (False, True):
            with self.subTest(coordinator_exits=coordinator_exits), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                # The helper outlives the command, like ibtoold. All fixtures have
                # a bounded lifetime even if an assertion fails.
                helper = "import time,pathlib; p=pathlib.Path('stop'); end=time.monotonic()+15\nwhile not p.exists() and time.monotonic()<end: time.sleep(.02)"
                child = """
import pathlib, subprocess, sys, time
helper = subprocess.Popen([sys.executable, '-c', sys.argv[1]], close_fds=False)
pathlib.Path('ready').write_text(str(helper.pid))
end = time.monotonic() + 15
while not pathlib.Path('finish').exists() and time.monotonic() < end:
    time.sleep(.02)
"""
                coordinator = """
import fcntl, importlib.util, sys
spec = importlib.util.spec_from_file_location('project', sys.argv[1])
project = importlib.util.module_from_spec(spec)
spec.loader.exec_module(project)
with open('executor.lock', 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    result = project.run_check([sys.executable, '-c', sys.argv[2], sys.argv[3]], lease_fd=lock.fileno())
sys.exit(result.returncode)
"""
                process = subprocess.Popen([sys.executable, '-B', '-c', coordinator,
                    str(Path(module.__file__).resolve()), child, helper], cwd=root)
                try:
                    self.wait_for(lambda: (root / 'ready').exists())
                    if coordinator_exits:
                        process.kill()
                        process.wait(timeout=5)
                    with (root / 'executor.lock').open('a') as probe:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        (root / 'finish').touch()
                        def released():
                            try:
                                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                                return True
                            except BlockingIOError:
                                return False
                        self.wait_for(released)
                        os.kill(int((root / 'ready').read_text()), 0)
                    if not coordinator_exits:
                        self.assertEqual(process.wait(timeout=5), 0)
                finally:
                    (root / 'finish').touch()
                    (root / 'stop').touch()
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)

    def test_guard_preserves_command_failure(self):
        with tempfile.TemporaryFile() as lock:
            result = module.run_check([sys.executable, '-c', 'raise SystemExit(7)'], lease_fd=lock.fileno())
        self.assertEqual(result.returncode, 7)

if __name__ == '__main__':
    unittest.main()
