import io
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch, Mock

from chrome_host import ChromeHost, ChromeLaunchError, chrome_command


class ChromeHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.host = ChromeHost(self.temp.name)
        self.owner = dict(pid=123, port=9233, executable=ChromeHost.executables()[0],
                          profile=str(self.host.profile), birth='birth')

    def test_tab_inventory_and_close_use_only_verified_endpoint(self):
        class Response(io.BytesIO):
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
        listing = [{'id': 'A' * 32, 'type': 'page', 'url': 'https://framer.com/'},
                   {'id': 'B' * 32, 'type': 'service_worker', 'url': 'https://framer.com/sw.js'}]
        opened = []
        def fake_open(url, timeout):
            opened.append(url)
            return Response(json.dumps(listing).encode() if url.endswith('/json/list') else b'Target is closing')
        with patch.object(self.host, 'endpoint', return_value='http://127.0.0.1:9233'), \
             patch.object(self.host.opener, 'open', side_effect=fake_open):
            self.assertEqual(self.host.page_targets(self.owner), {'A' * 32: 'https://framer.com/'})
            self.assertFalse(self.host.close_target(self.owner, '../json/new'))
            self.assertTrue(self.host.close_target(self.owner, 'A' * 32))
        self.assertEqual(opened, ['http://127.0.0.1:9233/json/list', 'http://127.0.0.1:9233/json/close/' + 'A' * 32])
        with patch.object(self.host, 'endpoint', return_value=None), patch.object(self.host.opener, 'open') as never:
            self.assertIsNone(self.host.page_targets(self.owner))
            self.assertFalse(self.host.close_target(self.owner, 'A' * 32))
        never.assert_not_called()

    def test_normal_launch(self):
        command = chrome_command(self.owner['executable'], self.host.profile, 9233)
        for forbidden in ('--enable-automation', '--disable-sync', '--use-mock-keychain', '--password-store=basic'):
            self.assertNotIn(forbidden, command)
        self.assertIn('--remote-debugging-port=9233', command)
        with self.assertRaises(ValueError):
            chrome_command(self.owner['executable'], self.host.profile, 0)

    def test_graceful_close_sends_one_masked_fixed_command_after_endpoint_recheck(self):
        owner = dict(self.owner, browserPath='/devtools/browser/fixture')
        key = base64.b64encode(b'k' * 16).decode()
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        header = b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n'
        connection = Mock()
        connection.recv.side_effect = [header, b'']
        context = Mock()
        context.__enter__ = Mock(return_value=connection)
        context.__exit__ = Mock(return_value=False)
        with patch('chrome_host.os.urandom', side_effect=[b'k' * 16, b'mask']), patch('chrome_host.socket.create_connection', return_value=context) as connect, \
             patch.object(self.host, 'matches', return_value=True), patch.object(self.host, 'owns_listener', return_value=True):
            self.host.graceful_close(owner)
        connect.assert_called_once_with(('127.0.0.1', owner['port']), timeout=2)
        self.assertEqual(connection.sendall.call_count, 2)
        frame = connection.sendall.call_args.args[0]
        self.assertEqual(frame[0], 0x81)
        self.assertEqual(frame[1] & 0x80, 0x80)
        mask, encoded = frame[2:6], frame[6:]
        self.assertEqual(json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(encoded))), {'id': 1, 'method': 'Browser.close'})

    def test_graceful_close_rejects_bad_handshake_before_command(self):
        connection = Mock()
        connection.recv.return_value = b'HTTP/1.1 200 OK\r\n\r\n'
        context = Mock()
        context.__enter__ = Mock(return_value=connection)
        context.__exit__ = Mock(return_value=False)
        with patch('chrome_host.socket.create_connection', return_value=context):
            with self.assertRaises(ChromeLaunchError):
                self.host.graceful_close(dict(self.owner, browserPath='/devtools/browser/fixture'))
        self.assertEqual(connection.sendall.call_count, 1)

    def test_regular_chrome_and_legacy_profile_are_never_adopted(self):
        legacy = dict(self.owner, executable='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
        self.assertFalse(self.host.matches(legacy))
        self.assertNotEqual(self.host.profile, self.host.root / 'profile')
        self.assertNotEqual(self.host.record, self.host.root / 'chrome-owner.json')
        self.assertTrue(all('Google Chrome for Testing.app' in p for p in self.host.executables()))

    def test_missing_testing_browser_does_not_fall_back_to_regular_chrome(self):
        with patch('chrome_host.os.access', return_value=False), patch('chrome_host.subprocess.Popen') as launch:
            with self.assertRaisesRegex(ChromeLaunchError, 'Chrome for Testing'):
                self.host.ensure()
        launch.assert_not_called()

    def test_process_identity_and_profile(self):
        command = ' '.join(chrome_command(self.owner['executable'], self.host.profile, 9233))
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'birth' if field == 'lstart' else command):
            self.assertTrue(self.host.matches(self.owner))
            self.assertFalse(self.host.matches(dict(self.owner, birth='reused pid')))
            self.assertFalse(self.host.matches(dict(self.owner, profile='/other/profile')))
            self.assertFalse(self.host.matches(dict(self.owner, executable='/other/chrome')))

    def test_listener_must_be_loopback_and_owned(self):
        with patch('chrome_host.subprocess.run') as run:
            for output, code, expected in [('p123\nn127.0.0.1:9233\n', 0, True),
                                           ('p123\nn*:9233\n', 0, False), ('', 1, False)]:
                run.return_value = Mock(stdout=output, returncode=code)
                self.assertEqual(self.host.owns_listener(123, 9233), expected)
            self.assertIn('123', run.call_args.args[0])

    def test_endpoint_identity(self):
        with patch.object(self.host, 'matches', return_value=True), patch.object(self.host, 'owns_listener', return_value=True):
            for endpoint, accepted in [('ws://127.0.0.1:9233/devtools/browser/one', True),
                                       ('ws://localhost:9233/devtools/browser/one', False),
                                       ('ws://127.0.0.1:9999/devtools/browser/one', False),
                                       ('ws://127.0.0.1:9233/devtools/browser/two', False)]:
                self.host.opener.open = Mock(return_value=io.BytesIO(json.dumps(dict(Browser='Chrome/1', webSocketDebuggerUrl=endpoint)).encode()))
                self.assertEqual(bool(self.host.endpoint(dict(self.owner, browserPath='/devtools/browser/one'))), accepted)

    def test_cancel_does_not_launch(self):
        event = threading.Event()
        event.set()
        with patch('chrome_host.subprocess.Popen') as launch, self.assertRaises(ChromeLaunchError):
            self.host.ensure(cancelled=event)
        launch.assert_not_called()

    def test_browser_limit_is_reported_with_stable_code_before_launch(self):
        environments = Path(self.temp.name) / 'environments'
        other = environments / 'other'
        other.mkdir(parents=True)
        (other / 'testing-chrome-owner.json').write_text(json.dumps(self.owner))
        host = ChromeHost(environments / 'run', max_browsers=1)
        host.root.mkdir()
        with patch.object(host, 'process_gone', return_value=False), patch('chrome_host.subprocess.Popen') as launch:
            with self.assertRaises(ChromeLaunchError) as raised:
                host.prepare_cookie_import()
        self.assertEqual(raised.exception.code, 'browser_limit')
        launch.assert_not_called()

    def test_cookie_import_never_adopts_live_browser_or_retires_unknown_fence(self):
        self.host.persist(self.owner)
        fence = self.host.root / 'executor-in-flight.json'
        fence.write_text('{"state":"outcome_unknown"}')
        with patch.object(self.host, 'process_gone', return_value=False), patch.object(self.host, 'ensure') as launch:
            self.assertEqual(self.host.prepare_cookie_import(), {'code': 'destination_running'})
            launch.assert_not_called()
            self.assertTrue(fence.exists())
        self.host.record.unlink()
        with patch.object(self.host, 'ensure') as launch:
            self.assertEqual(self.host.prepare_cookie_import(), {'code': 'uncertain'})
            launch.assert_not_called()

    def test_cookie_import_retires_fence_only_after_confirmed_exit(self):
        self.host.persist(self.owner)
        fence = self.host.root / 'executor-in-flight.json'
        fence.write_text('{"state":"outcome_unknown"}')
        self.host.owner = dict(self.owner, browserPath='/devtools/browser/fixture')
        with patch.object(self.host, 'process_gone', return_value=True), patch.object(self.host, 'ensure', return_value='http://127.0.0.1:9233') as launch:
            self.assertEqual(self.host.prepare_cookie_import(), {'webSocketURL': 'ws://127.0.0.1:9233/devtools/browser/fixture'})
            self.assertEqual(launch.call_count, 1)
            self.assertFalse(fence.exists())

    def test_foreign_live_process_is_not_adopted(self):
        self.host.persist(self.owner)
        # Same start time (a reused PID within one second) but another command.
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'birth' if field == 'lstart' else 'foreign'), \
             patch('chrome_host.subprocess.Popen') as launch:
            with self.assertRaises(ChromeLaunchError):
                self.host.ensure()
            launch.assert_not_called()

    def test_reused_host_cannot_terminate_chrome(self):
        with patch('chrome_host.subprocess.Popen') as launch:
            self.host.close_created_for_test()
            launch.assert_not_called()

    def test_zombie_requires_same_birth_and_reused_pid_means_exit(self):
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'Z' if field == 'stat' else 'birth'):
            self.assertTrue(self.host.process_gone(self.owner))
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'S' if field == 'stat' else 'birth'):
            self.assertFalse(self.host.process_gone(self.owner))
            # Another process now holds the PID: the recorded Chrome is gone
            # and must not occupy a browser-limit slot.
            self.assertTrue(self.host.process_gone(dict(self.owner, birth='earlier')))
            self.assertFalse(self.host.process_gone(dict(self.owner, birth='')))
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'S' if field == 'stat' else None):
            self.assertFalse(self.host.process_gone(self.owner))
        with patch.object(self.host, 'process_field', return_value=None):
            self.assertTrue(self.host.process_gone(self.owner))

    def test_zombie_record_allows_one_fresh_launch(self):
        self.host.persist(self.owner)
        child = Mock(pid=456)
        child.poll.return_value = None
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'Z' if field == 'stat' else 'birth'), \
             patch('chrome_host.os.access', return_value=True), \
             patch('chrome_host.verify_chrome'), \
             patch('chrome_host.subprocess.Popen', return_value=child) as launch, \
             patch.object(self.host, 'endpoint', return_value='http://127.0.0.1:9999'), \
             patch.object(self.host, 'hide_created_browser', return_value=True) as hide:
            self.assertEqual(self.host.ensure(), 'http://127.0.0.1:9999')
        self.assertEqual(launch.call_count, 1)
        hide.assert_called_once_with(self.host.owner)
        self.assertEqual(self.host.owner['pid'], 456)

    def test_reattachment_preserves_user_visibility(self):
        self.host.persist(self.owner)
        with patch.object(self.host, 'process_gone', return_value=False), \
             patch.object(self.host, 'matches', return_value=True), \
             patch.object(self.host, 'endpoint', return_value='http://127.0.0.1:9233'), \
             patch.object(self.host, 'hide_created_browser') as hide:
            self.assertEqual(self.host.ensure(), 'http://127.0.0.1:9233')
        hide.assert_not_called()

    def test_hide_requires_verified_fresh_child(self):
        with patch('chrome_host.subprocess.run') as run:
            self.assertFalse(self.host.hide_created_browser(self.owner))
            self.host.child = Mock(pid=999)
            self.assertFalse(self.host.hide_created_browser(self.owner))
            self.host.child = Mock(pid=123)
            with patch.object(self.host, 'matches', return_value=False):
                self.assertFalse(self.host.hide_created_browser(self.owner))
        run.assert_not_called()

    def test_hide_timeout_is_not_retried(self):
        import subprocess
        self.host.child = Mock(pid=123)
        with patch.object(self.host, 'matches', return_value=True), \
             patch('chrome_host.subprocess.run', side_effect=subprocess.TimeoutExpired('osascript', 5)) as run, \
             patch('chrome_host.sys.stderr', new_callable=io.StringIO) as errors:
            self.assertFalse(self.host.hide_created_browser(self.owner))
            self.assertIn('still running', errors.getvalue())
        run.assert_called_once()

    def test_close_if_idle_quits_only_a_chrome_with_blank_tabs(self):
        self.host.record.parent.mkdir(parents=True, exist_ok=True)
        self.assertEqual(self.host.close_if_idle(), {'running': False})  # No record: never launches.
        self.host.persist(self.owner)
        with patch.object(ChromeHost, 'process_gone', return_value=True), \
             patch.object(ChromeHost, 'control_owned') as close:
            self.assertEqual(self.host.close_if_idle(), {'running': False})
        close.assert_not_called()
        with patch.object(ChromeHost, 'process_gone', return_value=False), \
             patch.object(ChromeHost, 'page_targets', return_value={'A' * 32: 'https://www.linkedin.com/feed/', 'B' * 32: 'about:blank'}), \
             patch.object(ChromeHost, 'control_owned') as close:
            self.assertEqual(self.host.close_if_idle(), {'running': True, 'kept': True})
        close.assert_not_called()
        with patch.object(ChromeHost, 'process_gone', return_value=False), \
             patch.object(ChromeHost, 'page_targets', return_value=None), \
             patch.object(ChromeHost, 'control_owned') as close:
            with self.assertRaises(ChromeLaunchError):
                self.host.close_if_idle()
        close.assert_not_called()
        with patch.object(ChromeHost, 'process_gone', return_value=False), \
             patch.object(ChromeHost, 'page_targets', return_value={'A' * 32: 'about:blank', 'B' * 32: 'chrome://newtab/'}), \
             patch.object(ChromeHost, 'control_owned', return_value={'running': False}) as close:
            self.assertEqual(self.host.close_if_idle(), {'running': False})
        close.assert_called_once_with(True)
