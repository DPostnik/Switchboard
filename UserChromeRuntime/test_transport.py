"""Local-only transport tests. No user Chrome, account or app state access."""
import io
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import server


class Fragmented(io.BytesIO):
    def read(self, count=-1):
        return super().read(min(count, 2))


class Frames(unittest.TestCase):
    def test_partial_reads_unicode(self):
        target = io.BytesIO()
        server.write_frame(target, {'value': 'Привет'})
        self.assertEqual(server.read_frame(Fragmented(target.getvalue())), {'value': 'Привет'})

    def test_short_raw_writes_preserve_exact_frame(self):
        class ShortWriter(io.BytesIO):
            def write(self, payload):
                return super().write(payload[:3])
        target = ShortWriter()
        value = {'value': 'Привет', 'payload': 'x' * 5000}
        server.write_frame(target, value)
        self.assertEqual(server.read_frame(io.BytesIO(target.getvalue())), value)
        self.assertEqual(len(target.getvalue()), 4 + struct.unpack('<I', target.getvalue()[:4])[0])

    def test_stalled_raw_write_fails_closed(self):
        class StalledWriter(io.BytesIO):
            def write(self, payload):
                return 0
        with self.assertRaisesRegex(server.Rejected, 'partial_frame_write'):
            server.write_frame(StalledWriter(), {'value': 'fixture'})

    def test_partial_frame_and_bounds(self):
        for payload in (b'\x05', struct.pack('<I', 8) + b'{}', struct.pack('<I', server.MAX_FRAME + 1), b'\0\0\0\0'):
            with self.subTest(payload=payload):
                with self.assertRaises(server.Rejected):
                    server.read_frame(io.BytesIO(payload))

    def test_invalid_object(self):
        with self.assertRaises(server.Rejected):
            server.read_frame(io.BytesIO(struct.pack('<I', 2) + b'[]'))

    def test_second_coordinator_cannot_mutate_live_state(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory).chmod(0o700)
            coordinator = server.Coordinator(directory, 'a' * 32, exclusive=True)
            coordinator.state['leases']['fixture'] = {'tabId': 5}
            coordinator.save()
            try:
                with self.assertRaises(BlockingIOError):
                    server.Coordinator(directory, 'a' * 32, exclusive=True)
                state = json.loads((Path(directory) / 'state.json').read_text())
                self.assertIn('fixture', state['leases'])
            finally:
                coordinator.database.close()
                coordinator.server_lock.close()

    def test_private_token_rejects_symlink_and_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'token'
            path.write_text('x' * 32)
            path.chmod(0o600)
            self.assertEqual(server.private_token(path), 'x' * 32)
            alias = path.with_name('alias')
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                server.private_token(alias)
            path.chmod(0o644)
            with self.assertRaises(server.Rejected):
                server.private_token(path)


class CLI(unittest.TestCase):
    def test_mcp_isolated_launch_and_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'token'
            path.write_text('t' * 32)
            path.chmod(0o600)
            messages = [
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list', 'params': {}},
            ]
            process = subprocess.run([sys.executable, '-I', str(Path(server.__file__).resolve()), 'mcp',
                '--state-dir', directory, '--chat-id', 'chat', '--profile-id', 'profile', '--capability-file', str(path)],
                input=''.join(json.dumps(message) + '\n' for message in messages), text=True, capture_output=True, timeout=3)
            self.assertEqual(process.returncode, 0, process.stderr)
            replies = [json.loads(line) for line in process.stdout.splitlines()]
            self.assertEqual(len(replies), 2)
            self.assertEqual(replies[0]['result']['protocolVersion'], '2024-11-05')
            names = [tool['name'] for tool in replies[1]['result']['tools']]
            self.assertEqual(set(names), {'switchboard_user_chrome_' + operation for operation in server.OPERATIONS})
            hints = {tool['name'][len('switchboard_user_chrome_'):]: tool['annotations'] for tool in replies[1]['result']['tools']}
            self.assertEqual({name for name, hint in hints.items() if hint['readOnlyHint']}, set(server.READONLY_OPERATIONS))
            self.assertTrue(all(hints[name]['destructiveHint'] for name in ('input', 'upload', 'release')))
            self.assertFalse(any(hints[name]['destructiveHint'] for name in server.READONLY_OPERATIONS))
            self.assertNotIn('t' * 32, process.stdout + process.stderr)

    def test_coordinator_cli_acknowledges_idle_shutdown_then_exits(self):
        with tempfile.TemporaryDirectory(prefix='uc-', dir='/tmp') as directory:
            root = Path(directory)
            root.chmod(0o700)
            (root / 'control-token').write_text('c' * 32)
            (root / 'control-token').chmod(0o600)
            process = subprocess.Popen([sys.executable, '-I', str(Path(server.__file__).resolve()), 'serve',
                '--state-dir', directory, '--extension-id', 'a' * 32], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 2
                while True:
                    try:
                        status = server.call(root, {'type': 'status'})
                        break
                    except OSError:
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.01)
                self.assertEqual(status['runtimeRevision'], server.RUNTIME_REVISION)
                result = server.call(root, {'type': 'control', 'command': 'shutdown-if-idle', 'controlToken': 'c' * 32})
                self.assertTrue(result['shuttingDown'])
                process.wait(timeout=2)
                self.assertEqual(process.returncode, 0, process.stderr.read())
                self.assertFalse((root / 'coordinator.sock').exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
                process.stdout.close()
                process.stderr.close()

    def test_native_cli_forwards_exact_frames(self):
        with tempfile.TemporaryDirectory(prefix='uc-', dir='/tmp') as directory:
            root = Path(directory)
            root.chmod(0o700)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(root / 'coordinator.sock'))
            listener.listen(1)
            received = []
            def host():
                connection, _ = listener.accept()
                with connection, connection.makefile('rwb', buffering=0) as stream:
                    received.append(server.read_frame(stream))
                    server.write_frame(stream, {'type': 'welcome', 'version': 1, 'paired': False})
            worker = threading.Thread(target=host)
            worker.start()
            process = subprocess.Popen([sys.executable, '-I', str(Path(server.__file__).resolve()), 'native',
                '--state-dir', directory, '--extension-id', 'a' * 32, 'chrome-extension://' + 'a' * 32 + '/'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                server.write_frame(process.stdin, {'type': 'hello', 'version': 1, 'profileId': 'fixture'})
                response = server.read_frame(process.stdout)
                self.assertEqual(response, {'type': 'welcome', 'version': 1, 'paired': False})
                worker.join(2)
                self.assertFalse(worker.is_alive())
                self.assertEqual(received[0]['origin'], 'chrome-extension://' + 'a' * 32 + '/')
                self.assertEqual(received[0]['hello']['profileId'], 'fixture')
                process.wait(timeout=2)
                self.assertEqual(process.returncode, 0, process.stderr.read())
            finally:
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()
                listener.close()


class Transport(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.token = 'a' * 32
        (self.root / 'control-token').write_text(self.token)
        (self.root / 'control-token').chmod(0o600)
        self.coordinator = server.Coordinator(self.root, 'a' * 32)
        self.coordinator.state['enabled'] = True
        self.coordinator.state['profiles']['profile'] = {'name': 'Fixture', 'pairingSecret': 'fixture-secret' }
        self.coordinator.state['selectedProfileId'] = 'profile'
        self.grant = self.control('grant', chatId='chat', projectRoot=str(self.root))
        self.client, self.remote = socket.socketpair()
        self.stream = self.remote.makefile('rwb', buffering=0)
        self.thread = threading.Thread(target=self.coordinator.client, args=(self.client,), daemon=True)
        self.thread.start()
        server.write_frame(self.stream, {'type': 'native', 'origin': 'chrome-extension://' + 'a' * 32 + '/',
            'hello': {'type': 'hello', 'version': 1, 'profileId': 'profile', 'profileName': 'Fixture', 'pairingCode': '123456', 'pairingSecret': 'fixture-secret'}})
        self.welcome = server.read_frame(self.stream)
        self.assertEqual(self.welcome.get('type'), 'welcome', self.welcome)

    def tearDown(self):
        try:
            self.remote.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.stream.close()
        self.remote.close()
        self.thread.join(1)
        self.coordinator.database.close()
        self.temporary.cleanup()

    def control(self, command, **kwargs):
        return self.coordinator.control(dict(type='control', command=command, controlToken=self.token, **kwargs))

    def request(self, operation, identifier='action', **kwargs):
        return dict(type='execute', operation=operation, id=identifier, chatId='chat',
                    profileId='profile', capability=self.grant['capability'], params=kwargs)

    def execute_fake(self, request, result=None, disconnect=False):
        output = {}
        def run():
            try:
                output['result'] = self.coordinator.execute(request)
            except Exception as error:
                output['error'] = str(error)
        worker = threading.Thread(target=run)
        worker.start()
        wire = server.read_frame(self.stream)
        if disconnect:
            self.remote.shutdown(socket.SHUT_RDWR)
        else:
            server.write_frame(self.stream, {'type': 'response', 'id': wire['id'], 'result': result or {}})
        worker.join(2)
        self.assertFalse(worker.is_alive())
        return wire, output

    def test_grant_renewal_and_default_profile(self):
        renewed = self.control('grant', chatId='chat', projectRoot=str(self.root))
        self.assertEqual(renewed['capability'], self.grant['capability'])
        self.assertEqual(renewed['profileId'], 'profile')
        self.assertEqual(self.coordinator.status()['selectedProfileId'], 'profile')

    def test_select_profile_requires_pairing(self):
        with self.assertRaisesRegex(server.Rejected, 'profile_not_paired'):
            self.control('select-profile', profileId='unpaired')
        self.coordinator.state['profiles']['second'] = {'name': 'Second', 'pairingSecret': 'other-secret'}
        selected = self.control('select-profile', profileId='second')
        self.assertEqual(selected['selectedProfileId'], 'second')
        self.assertEqual(selected['runtimeRevision'], server.RUNTIME_REVISION)
        persisted = json.loads((self.root / 'state.json').read_text())
        self.assertEqual(persisted['selectedProfileId'], 'second')

    def test_shutdown_rejects_active_leases_and_pending_actions(self):
        _, output = self.execute_fake(self.request('open'), {'tabId': 5})
        with self.assertRaisesRegex(server.Rejected, 'coordinator_busy'):
            self.control('shutdown-if-idle')
        self.assertFalse(self.coordinator.shutting_down)
        self.coordinator.state['leases'].clear()
        self.coordinator.pending['fixture'] = {}
        with self.assertRaisesRegex(server.Rejected, 'coordinator_busy'):
            self.control('shutdown-if-idle')
        self.coordinator.pending.clear()
        result = self.control('shutdown-if-idle')
        self.assertTrue(result['shuttingDown'])
        with self.assertRaisesRegex(server.Rejected, 'shutting_down'):
            self.coordinator.execute(self.request('list', 'after-shutdown'))

    def test_grant_switch_revokes_previous_profile_lease(self):
        _, output = self.execute_fake(self.request('open'), {'tabId': 5})
        self.coordinator.state['profiles']['second'] = {'name': 'Second', 'pairingSecret': 'second-secret'}
        self.control('select-profile', profileId='second')
        grant = self.control('grant', chatId='chat', projectRoot=str(self.root))
        self.assertEqual(grant['profileId'], 'second')
        self.assertNotEqual(grant['capability'], self.grant['capability'])
        self.assertNotIn(output['result']['leaseId'], self.coordinator.state['leases'])
        self.assertEqual(server.read_frame(self.stream)['type'], 'revoke')

    def test_control_and_capability_fail_closed(self):
        with self.assertRaises(server.Rejected):
            self.coordinator.control({'controlToken': 'bad', 'command': 'grant'})
        request = self.request('list')
        request['capability'] = 'bad'
        with self.assertRaises(server.Rejected):
            self.coordinator.execute(request)
        self.control('set-enabled', enabled=False)
        with self.assertRaises(server.Rejected):
            self.coordinator.execute(self.request('list'))

    def test_exact_origin_and_version(self):
        for origin, version in [('chrome-extension://' + 'b' * 32 + '/', 1), ('chrome-extension://' + 'a' * 32 + '/', 2)]:
            with self.assertRaises(server.Rejected):
                self.coordinator.extension(None, {'origin': origin, 'hello': {'type': 'hello', 'version': version}})

    def test_paired_profile_requires_reconnect_secret(self):
        for proof in ('', 'wrong-proof'):
            with self.assertRaisesRegex(server.Rejected, 'pairing_proof_required'):
                self.coordinator.extension(None, {'origin': 'chrome-extension://' + 'a' * 32 + '/',
                    'hello': {'type': 'hello', 'version': 1, 'profileId': 'profile', 'pairingCode': '123456', 'pairingSecret': proof}})
        self.assertNotIn('pairingSecret', json.dumps(self.coordinator.status()))

    def test_approved_file_rejects_symlinks_and_oversize(self):
        fixture = self.root / 'target'
        fixture.write_bytes(b'x' * 512001)
        with self.assertRaisesRegex(server.Rejected, 'too_large'):
            server.approved_file(self.root, fixture)
        alias = self.root / 'alias'
        alias.symlink_to(fixture)
        with self.assertRaises(OSError):
            server.approved_file(self.root, alias)

    def test_lease_and_duplicate_action(self):
        wire, output = self.execute_fake(self.request('open', url='https://example.test'), {'tabId': 5})
        lease = output['result']['leaseId']
        self.assertEqual(wire['capability'], self.welcome['capability'])
        self.assertNotEqual(wire['capability'], self.grant['capability'])
        request = self.request('read', 'read-action')
        request['leaseId'] = lease
        wire, output = self.execute_fake(request, {'text': 'Fixture'})
        self.assertEqual(wire['params']['tabId'], 5)
        self.assertEqual(output['result']['text'], 'Fixture')
        with self.assertRaisesRegex(server.Rejected, 'already_dispatched'):
            self.coordinator.execute(request)
        with self.assertRaisesRegex(server.Rejected, 'tab_leased'):
            self.coordinator.execute(self.request('select', 'select', tabId=5, userSelected=True))

    def test_upload_requires_project_path_and_bounded_file(self):
        _, output = self.execute_fake(self.request('open'), {'tabId': 5})
        lease = output['result']['leaseId']
        request = self.request('upload', 'upload', paths=['/etc/passwd'])
        request['leaseId'] = lease
        with self.assertRaisesRegex(server.Rejected, 'outside_project'):
            self.coordinator.execute(request)
        fixture = self.root / 'fixture.txt'
        fixture.write_text('hello')
        request['params']['paths'] = [str(fixture)]
        wire, output = self.execute_fake(request)
        self.assertNotIn('paths', wire['params'])
        self.assertEqual(wire['params']['files'][0]['base64'], 'aGVsbG8=')

    def test_unknown_outcome_is_durable_and_never_replayed(self):
        wire, output = self.execute_fake(self.request('open'), disconnect=True)
        self.assertEqual(output['error'], 'unknown_outcome_do_not_replay')
        row = self.coordinator.database.execute('SELECT state FROM actions WHERE id=?', ('action',)).fetchone()
        self.assertEqual(row[0], 'unknown')

    def test_disconnect_clears_unusable_session_leases(self):
        _, output = self.execute_fake(self.request('open'), {'tabId': 5})
        self.assertIn(output['result']['leaseId'], self.coordinator.state['leases'])
        self.remote.shutdown(socket.SHUT_RDWR)
        self.thread.join(1)
        self.assertEqual(self.coordinator.state['leases'], {})

    def test_detached_event_preserves_connection_grant_and_other_tabs(self):
        _, first = self.execute_fake(self.request('open', 'open-first'), {'tabId': 5})
        _, second = self.execute_fake(self.request('open', 'open-second'), {'tabId': 6})
        self.coordinator.state['leases']['other-profile'] = {'profileId': 'other', 'chatId': 'chat', 'tabId': 5}
        server.write_frame(self.stream, {'type': 'event', 'event': 'detached', 'profileId': 'profile', 'tabId': 5})
        # A framed request/response after the event proves the native connection stayed usable.
        _, result = self.execute_fake(self.request('list', 'after-detach'), {'tabs': []})
        self.assertNotIn('error', result)
        self.assertNotIn(first['result']['leaseId'], self.coordinator.state['leases'])
        self.assertIn(second['result']['leaseId'], self.coordinator.state['leases'])
        self.assertIn('other-profile', self.coordinator.state['leases'])
        self.assertIn('chat', self.coordinator.state['grants'])
        persisted = json.loads((self.root / 'state.json').read_text())
        self.assertNotIn(first['result']['leaseId'], persisted['leases'])
        request = self.request('read', 'remaining-tab')
        request['leaseId'] = second['result']['leaseId']
        _, result = self.execute_fake(request, {'text': 'still usable'})
        self.assertEqual(result['result']['text'], 'still usable')

    def test_detach_during_release_and_repeated_late_event_are_idempotent(self):
        _, opened = self.execute_fake(self.request('open', 'release-open'), {'tabId': 5})
        request = self.request('release', 'release')
        request['leaseId'] = opened['result']['leaseId']
        result = {}
        def release():
            try:
                result['value'] = self.coordinator.execute(request)
            except Exception as error:
                result['error'] = str(error)
        worker = threading.Thread(target=release)
        worker.start()
        wire = server.read_frame(self.stream)
        event = {'type': 'event', 'event': 'detached', 'profileId': 'profile', 'tabId': 5}
        server.write_frame(self.stream, event)
        server.write_frame(self.stream, {'type': 'response', 'id': wire['id'], 'result': {'released': True}})
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(result, {'value': {'released': True}})
        server.write_frame(self.stream, event)
        _, result = self.execute_fake(self.request('list', 'after-release'), {'tabs': []})
        self.assertNotIn('error', result)
        self.assertEqual(self.coordinator.state['leases'], {})
        self.assertIn('chat', self.coordinator.state['grants'])

    def test_unknown_extension_event_fails_closed(self):
        server.write_frame(self.stream, {'type': 'event', 'event': 'unknown', 'profileId': 'profile', 'tabId': 5})
        reply = server.read_frame(self.stream)
        self.assertEqual(reply['error']['code'], 'unknown_extension_message')
        self.thread.join(1)
        self.assertNotIn('profile', self.coordinator.links)

    def test_detached_event_rejects_wrong_profile(self):
        server.write_frame(self.stream, {'type': 'event', 'event': 'detached', 'profileId': 'other', 'tabId': 5})
        reply = server.read_frame(self.stream)
        self.assertEqual(reply['error']['code'], 'detached_profile_mismatch')
        self.thread.join(1)
        self.assertNotIn('profile', self.coordinator.links)

    def test_detached_event_rejects_boolean_tab(self):
        server.write_frame(self.stream, {'type': 'event', 'event': 'detached', 'profileId': 'profile', 'tabId': True})
        reply = server.read_frame(self.stream)
        self.assertEqual(reply['error']['code'], 'detached_tab_required')
        self.thread.join(1)
        self.assertNotIn('profile', self.coordinator.links)

    def test_stop_revokes_grant_and_detaches(self):
        _, output = self.execute_fake(self.request('open'), {'tabId': 5})
        self.control('revoke', chatId='chat')
        wire = server.read_frame(self.stream)
        self.assertEqual(wire['type'], 'revoke')
        self.assertEqual(wire['profileId'], 'profile')
        with self.assertRaisesRegex(server.Rejected, 'revoked'):
            self.coordinator.execute(self.request('list', 'after-revoke'))
        restarted = server.Coordinator(self.root, 'a' * 32)
        self.assertNotIn('chat', restarted.state['grants'])
        restarted.database.close()


if __name__ == '__main__':
    unittest.main()
