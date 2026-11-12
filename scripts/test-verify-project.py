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


class BoundaryTests(unittest.TestCase):
    """The queue under Switchboard's external boundary: no ps, no restart script; builds stay where they are."""

    def setUp(self):
        sys.path.insert(0, str(Path(__file__).parent))
        self.addCleanup(sys.path.remove, str(Path(__file__).parent))
        from verification_queue import VerificationDeferred
        self.deferred = VerificationDeferred

    def preflight(self, load, ps):
        with patch.object(module.platform, 'system', return_value='Darwin'), \
             patch.object(module.os, 'getloadavg', return_value=(load, 0.0, 0.0)), \
             patch.object(module.os, 'cpu_count', return_value=8), \
             patch.object(module.subprocess, 'check_output', side_effect=ps) as check, \
             patch('sys.stderr') as stderr:
            module.preflight()
        return check, ''.join(str(call.args[0]) for call in stderr.write.call_args_list)

    def test_load_comes_from_the_kernel_and_ps_is_optional(self):
        idle = lambda argv, **kwargs: '1 /usr/bin/python3 scripts/swift-task.py test\n2 codex xcodebuild prompt\n'
        check, note = self.preflight(1.0, idle)
        self.assertEqual([call.args[0] for call in check.call_args_list], [['ps', '-axo', 'pid,command']])
        self.assertEqual(note, '')
        for failure in (PermissionError(1, 'Operation not permitted', 'ps'), FileNotFoundError('ps'),
                        subprocess.CalledProcessError(1, ['ps'])):
            _, note = self.preflight(1.0, failure)
            self.assertIn('heavy jobs not counted', note)
            self.assertIn('build lock', note)

    def test_busy_host_defers_with_or_without_ps(self):
        two = lambda argv, **kwargs: '1 python3 scripts/swift-task.py build\n2 /usr/bin/xcodebuild -scheme x\n'
        with self.assertRaisesRegex(self.deferred, 'heavy jobs 2'):
            self.preflight(1.0, two)
        with self.assertRaisesRegex(self.deferred, 'load 9.50, cores 8, heavy jobs not counted'):
            self.preflight(9.5, PermissionError(1, 'Operation not permitted', 'ps'))
        with self.assertRaisesRegex(self.deferred, 'heavy jobs 0'):
            self.preflight(9.5, lambda argv, **kwargs: '')

    def test_install_under_the_boundary_leaves_the_restart_to_the_app_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / 'restart-attempt.json'
            with patch.object(module.subprocess, 'run') as run, patch('sys.stderr') as stderr:
                result = module.request_restart(Path(directory), record, environ={'SWITCHBOARD_EXTERNAL_SANDBOX': '1'})
            run.assert_not_called()
            self.assertIn('request_app_restart', result['restart'])
            self.assertIn('exactly once', ''.join(str(call.args[0]) for call in stderr.write.call_args_list))
            self.assertIn('tool_required', record.read_text())
            # The recorded attempt blocks a second install from asking again.
            with self.assertRaises(FileExistsError):
                module.request_restart(Path(directory), record, environ={'SWITCHBOARD_EXTERNAL_SANDBOX': '1'})

    def test_install_outside_the_boundary_runs_the_restart_script_once(self):
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / 'restart-attempt.json'
            for environ in ({}, {'SWITCHBOARD_EXTERNAL_SANDBOX': '0'}):
                record.unlink(missing_ok=True)
                with patch.object(module.subprocess, 'run') as run:
                    self.assertEqual(module.request_restart(Path(directory), record, environ=environ), {'restart': 'requested'})
                run.assert_called_once_with(['zsh', 'scripts/request-app-restart.sh'], cwd=Path(directory), check=True)
            with patch.object(module.subprocess, 'run') as run, self.assertRaises(FileExistsError):
                module.request_restart(Path(directory), record, environ={})
            run.assert_not_called()

if __name__ == '__main__':
    unittest.main()
