"""Fixed host installer security and no-retry contract; no device or signing keys used."""
import argparse
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('installer_server', ROOT / 'ChatDirectoryRuntime/server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class MobileInstallToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.bundle = self.make_bundle(self.project, 'ios-device', 'pl.example.app')
        # Not the running app's project: the installer no longer needs a host app.
        self.options = argparse.Namespace(diagnostics_project=str(self.project), host=None, mobile_install=True)
        self.calls = []
        self.state = self.root / 'host-state'
        self.addCleanup(patch.stopall)
        patch.object(server, 'MOBILE_INSTALL_ROOT', self.state).start()
        patch.object(server.subprocess, 'run', self.run_process).start()

    def make_bundle(self, project, folder, identifier, configuration='Debug-iphoneos', name='App.app'):
        bundle = project / '.build' / folder / 'Build/Products' / configuration / name
        bundle.mkdir(parents=True)
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier,
                                                           'CFBundleSupportedPlatforms': ['iPhoneOS']}))
        (bundle / 'App').write_bytes(b'fixture')
        return bundle

    def run_process(self, argv, **kwargs):
        self.calls.append(argv)
        if '-R' in argv:
            self.assertTrue(argv[argv.index('-R') + 1].startswith('='), 'Inline requirements need =; otherwise codesign reads a file')
        self.assertEqual(kwargs['env']['DEVELOPER_DIR'], '/Applications/Xcode.app/Contents/Developer')
        self.assertNotIn('GIT_CONFIG_COUNT', kwargs['env'])
        self.assertTrue(Path(argv[-1]).is_relative_to(self.state))
        self.assertNotEqual(Path(argv[-1]), self.bundle)
        return subprocess.CompletedProcess(argv, 0, b'Installed', b'')

    def test_installs_verified_staged_bundle_once_across_server_restart(self):
        first = server.install_mobile_app(self.options, {})
        self.assertEqual(first['status'], 'installed')
        self.assertEqual(len([c for c in self.calls if c[0] == '/usr/bin/xcrun']), 1)
        second = server.install_mobile_app(self.options, {})
        self.assertTrue(second['alreadyAttempted'])
        self.assertEqual(second['status'], 'installed')
        self.assertEqual(len([c for c in self.calls if c[0] == '/usr/bin/xcrun']), 1)
        verify = next(call for call in self.calls if "-R" in call)
        self.assertTrue(verify[-2].startswith('=anchor apple generic'))
        self.assertNotIn('--deep', verify)
        self.assertTrue(any('--deep' in call and '-R' not in call for call in self.calls))
        self.assertIn(server.MOBILE_TEAM, verify[-2])
        self.assertIn('identifier "pl.example.app"', verify[-2])
        self.assertEqual(first['source'], '.build/ios-device/Build/Products/Debug-iphoneos/App.app')
        self.assertEqual(list(self.state.glob('stage-*')), [])

    def test_app_id_stays_with_the_first_project(self):
        self.assertEqual(server.install_mobile_app(self.options, {})['status'], 'installed')
        other = self.root / 'other'
        self.make_bundle(other, 'ios-device', 'pl.example.app')
        foreign = argparse.Namespace(diagnostics_project=str(other), host=None, mobile_install=True)
        with self.assertRaises(ValueError): server.install_mobile_app(foreign, {})
        self.assertEqual(len([c for c in self.calls if c[0] == '/usr/bin/xcrun']), 1)

    def test_picks_newest_device_build_and_ignores_simulator(self):
        import os, time
        old = self.make_bundle(self.project, 'old-device', 'pl.example.app')
        os.utime(old / 'Info.plist', (time.time() - 3600, time.time() - 3600))
        os.utime(self.bundle / 'Info.plist', (time.time() - 60, time.time() - 60))
        self.make_bundle(self.project, 'sim', 'pl.example.sim', configuration='Debug-iphonesimulator')
        newest = self.make_bundle(self.project, 'release', 'pl.example.app', configuration='Release-iphoneos', name='New.app')
        self.assertEqual(server.mobile_artifact(self.project.resolve()), newest.resolve())

    def test_without_a_build_nothing_runs(self):
        import shutil
        shutil.rmtree(self.project / '.build')
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        self.assertEqual(self.calls, [])

    def test_timeout_remains_uncertain_and_is_never_redispatched(self):
        original = self.run_process
        def timeout(argv, **kwargs):
            if argv[0] == '/usr/bin/xcrun':
                self.calls.append(argv)
                raise subprocess.TimeoutExpired(argv, 15)
            return original(argv, **kwargs)
        with patch.object(server.subprocess, 'run', timeout):
            self.assertEqual(server.install_mobile_app(self.options, {})['status'], 'uncertain')
            self.assertTrue(server.install_mobile_app(self.options, {})['alreadyAttempted'])
        self.assertEqual(len([c for c in self.calls if c[0] == '/usr/bin/xcrun']), 1)

    def test_extra_arguments_and_missing_scope_never_run_a_process(self):
        for args in [{'path': '/tmp/other'}, {'device': 'other'}, {'force': True}]:
            with self.assertRaises(ValueError): server.install_mobile_app(self.options, args)
        self.options.mobile_install = False
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        self.options.mobile_install = True
        self.options.diagnostics_project = None
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        self.assertEqual(self.calls, [])

    def test_wrong_bundle_and_symlinks_fail_closed(self):
        (self.bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'pl.example.app'}))
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        (self.bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'x" or true',
                                                                'CFBundleSupportedPlatforms': ['iPhoneOS']}))
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        (self.bundle / 'linked').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        self.assertEqual(self.calls, [])

    def test_invalid_signature_never_installs(self):
        with patch.object(server.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'', b'invalid')):
            with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        self.assertEqual(list(self.state.glob('*.json')), [])

    def test_refuses_symlink_in_artifact_parent(self):
        build = self.project / '.build'
        build.rename(self.project / 'elsewhere')
        build.symlink_to(self.project / 'elsewhere', target_is_directory=True)
        with self.assertRaises(ValueError): server.install_mobile_app(self.options, {})
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
