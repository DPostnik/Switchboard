"""Real front ends + executor processes; fake Chrome never touches user state."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
import server
import broker
from transport import StdioRPC


def serve_fake():
    pages = {}
    counter = [0]
    class FakeBrowser(server.Browser):
        def __init__(self, root, **kwargs):
            def rpc(name, arguments):
                with (Path(root) / 'dispatch.jsonl').open('a') as stream:
                    stream.write(json.dumps({'name': name, 'args': arguments,
                        'workspace': str(self.workspace), 'limit': self.max_browsers, 'phase': 'start'}) + '\n')
                if name == 'new_page':
                    counter[0] += 1
                    pages[counter[0]] = arguments['url']
                    text = str(counter[0]) + ': ' + arguments['url']
                elif name == 'navigate_page':
                    pages[arguments['pageId']] = arguments['url']
                    text = 'navigated'
                elif name == 'evaluate_script':
                    text = '```json\n' + json.dumps({'url': pages[arguments['pageId']], 'readyState': 'complete'}) + '\n```'
                elif name == 'list_pages':
                    text = '## Pages\n' + '\n'.join(str(i) + ': ' + url for i, url in pages.items())
                elif name == 'close_page':
                    pages.pop(arguments['pageId'])
                    text = 'closed'
                elif name == 'click':
                    if arguments.get('uid') == 'wait-for-disconnect':
                        self.stopped.wait(10)
                    raise TimeoutError('injected lost response after dispatch')
                elif name == 'take_snapshot':
                    while (Path(root) / 'hold-snapshot').exists() and not self.stopped.wait(0.05):
                        pass
                    self.stopped.wait(0.2)
                    text = pages[arguments['pageId']]
                else:
                    text = 'ok'
                with (Path(root) / 'dispatch.jsonl').open('a') as stream:
                    stream.write(json.dumps({'name': name, 'phase': 'end'}) + '\n')
                return {'content': [{'type': 'text', 'text': text}]}
            super().__init__(root, rpc=rpc, **kwargs)

        def quit_idle_chrome(self, seconds=8):
            with (Path(self.root) / 'dispatch.jsonl').open('a') as stream:
                stream.write(json.dumps({'name': 'quit_idle_chrome', 'phase': 'start'}) + '\n')
            return 'quit'
    executor = broker.Executor(Path(sys.argv[2]), browser_factory=FakeBrowser, installation_root=Path(sys.argv[2]))
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: executor.stopped.set())
    executor.run()


class MultiClientTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.clients = []
        self.sequence = 0
        self.executor = None

    def tearDown(self):
        for client in self.clients:
            client.close()
        if self.executor and self.executor.poll() is None:
            self.executor.terminate()
            self.executor.wait(timeout=5)
        self.directory.cleanup()

    def start_executor(self):
        self.executor = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), '--serve-fake', str(self.root)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 3
        while not broker.endpoint(self.root).exists():
            self.assertIsNone(self.executor.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)

    def client(self, language='en', workspace=None, limit=2, lease=None):
        # Full role rights: these tests cover multi-client routing; the role gate has its own tests.
        command = [sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(self.root), '--language', language,
                   '--max-browsers', str(limit), '--allow-eval', '--allow-upload', '--import-scope', 'any']
        if lease is not None:
            command += ['--profile-lease', lease]
        client = StdioRPC(command, cwd=str(workspace) if workspace else None).start()
        self.clients.append(client)
        info = client.initialize_mcp(expected_server_version=server.VERSION)
        self.assertEqual(len(info['tools']), 15)
        return client

    def call(self, client, tool, **arguments):
        if tool == 'browser_snapshot':
            arguments.setdefault('mode', 'interactive')
        self.sequence += 1
        return client.rpc('tools/call', {'name': tool, 'arguments': arguments}, str(self.sequence), time.monotonic_ns() + 8_000_000_000)

    def opened(self, client):
        result = self.call(client, 'browser_open', url='https://example.test/')
        self.assertFalse(result.get('isError'), result)
        return json.loads(result['content'][0]['text'])

    def trace(self):
        path = self.root / 'dispatch.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_startup_consumes_exact_read_approval_without_replaying(self):
        fence = self.root / 'executor-in-flight.json'
        fence.write_text('{"client":7,"request":2,"state":"outcome_unknown"}')
        approval = {'schema': 1, 'confirmedTool': 'browser_snapshot',
            'reason': 'operator_confirmed_read_failure',
            'fenceSHA256': hashlib.sha256(fence.read_bytes()).hexdigest(),
            'fenceModifiedNS': fence.stat().st_mtime_ns}
        (self.root / 'approved-read-recovery.json').write_text(json.dumps(approval))
        self.start_executor()
        client = self.client()
        self.assertEqual(self.trace(), [])
        self.assertFalse(fence.exists())
        self.assertEqual(len(list((self.root / 'records').glob('read-recovery-*.json'))), 1)
        self.opened(client)
        self.assertEqual(sum(r['name'] == 'new_page' and r['phase'] == 'start' for r in self.trace()), 1)

    def test_catalogs_and_legacy_lock_in_both_languages(self):
        with (self.root / 'executor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for language in ('ru', 'en'):
                client = self.client(language)
                result = self.call(client, 'browser_open', url='https://example.test/')
                self.assertTrue(result['isError'])
                self.assertIn('Cmd+Q', result['content'][0]['text'])
                self.assertIn('Действие не отправлено' if language == 'ru' else 'No action was sent', result['content'][0]['text'])
                self.assertFalse((self.root / 'testing-profile').exists())

    def test_two_open_sessions_keep_tabs_tokens_and_workspaces_separate(self):
        self.start_executor()
        projects = [self.root / 'project-a', self.root / 'project-b']
        for path in projects:
            path.mkdir()
        a, b = [self.client(workspace=p) for p in projects]
        first, second = self.opened(a), self.opened(b)
        self.assertNotEqual(first['session'], second['session'])
        self.assertNotEqual(first['pageId'], second['pageId'])
        count = len(self.trace())
        self.assertTrue(self.call(b, 'browser_snapshot', session=first['session'])['isError'])
        self.assertEqual(len(self.trace()), count)
        for client, opened in [(a, first), (b, second), (a, first)]:
            self.assertFalse(self.call(client, 'browser_snapshot', session=opened['session']).get('isError'))
        closed = self.call(a, 'browser_close', session=first['session'])
        self.assertFalse(closed.get('isError'))
        # The other task still has a tab in the same Chrome, so it is not asked to quit.
        kept = json.loads(closed['content'][0]['text'])
        self.assertEqual((kept['browserQuit'], kept['keptReason']), ('kept', 'other_task'))
        self.assertIn('keptNote', kept)
        self.assertFalse(any(r['name'] == 'quit_idle_chrome' for r in self.trace()))
        self.assertFalse(self.call(b, 'browser_snapshot', session=second['session']).get('isError'))
        closed = self.call(b, 'browser_close', session=second['session'])
        self.assertEqual(json.loads(closed['content'][0]['text'])['browserQuit'], 'quit')
        self.assertEqual(sum(r['name'] == 'quit_idle_chrome' for r in self.trace()), 1)
        navigation = [row for row in self.trace() if row['name'] == 'navigate_page' and row['phase'] == 'start']
        self.assertEqual([r['workspace'] for r in navigation], [str(p.resolve()) for p in projects])
        self.assertEqual([r['args']['pageId'] for r in navigation], [first['pageId'], second['pageId']])

    def test_concurrent_calls_are_serialized(self):
        self.start_executor()
        clients = [self.client(), self.client()]
        sessions = [self.opened(c)['session'] for c in clients]
        barrier = threading.Barrier(3)
        errors = []
        def snapshot(index):
            try:
                barrier.wait()
                answer = self.call(clients[index], 'browser_snapshot', session=sessions[index])
                self.assertFalse(answer.get('isError'), answer)
            except Exception as error:
                errors.append(error)
        workers = [threading.Thread(target=snapshot, args=(i,)) for i in range(2)]
        for worker in workers:
            worker.start()
        barrier.wait()
        for worker in workers:
            worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        phases = [row['phase'] for row in self.trace() if row['name'] == 'take_snapshot']
        self.assertEqual(phases, ['start', 'end', 'start', 'end'])

    def test_reconnecting_client_applies_new_limit_even_with_existing_executor(self):
        self.start_executor()
        for limit in (2, 4):
            self.opened(self.client(limit=limit))
        starts = [row for row in self.trace() if row['name'] == 'new_page' and row['phase'] == 'start']
        self.assertEqual([row['limit'] for row in starts], [2, 4])

    def test_disconnect_while_queued_never_dispatches_or_consumes_action_id(self):
        self.start_executor()
        a, b = self.client(), self.client()
        first, second = self.opened(a), self.opened(b)
        hold = self.root / 'hold-snapshot'
        hold.touch()
        errors = []
        def request(c, tool, arguments):
            try:
                self.call(c, tool, **arguments)
            except Exception as error:
                errors.append(error)
        active = threading.Thread(target=request, args=(a, 'browser_snapshot', {'session': first['session']}))
        active.start()
        deadline = time.monotonic() + 3
        while not any(row['name'] == 'take_snapshot' for row in self.trace()):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        queued = threading.Thread(target=request, args=(b, 'browser_action', {
            'session': second['session'], 'actionID': 'queued-action', 'expectedURL': 'https://example.test/',
            'name': 'click', 'arguments': {'uid': '1_1'}}))
        queued.start()
        time.sleep(0.1)
        b.close()
        hold.unlink()
        for worker in (active, queued):
            worker.join(timeout=3)
            self.assertFalse(worker.is_alive())
        self.assertFalse((self.root / 'records/action-queued-action.json').exists())
        self.assertFalse(any(row['name'] == 'click' for row in self.trace()))
        self.assertFalse(self.call(a, 'browser_snapshot', session=first['session']).get('isError'))

    def test_protocol_revision_and_duplicate_ids_fail_closed(self):
        self.start_executor()
        connection = socket.socket(socket.AF_UNIX)
        connection.connect(str(broker.endpoint(self.root)))
        wire = broker.Wire(connection)
        wire.send({'hello': broker.PROTOCOL, 'revision': 'other-build'})
        self.assertIn('error', wire.receive(time.monotonic() + 2))
        wire.close()
        connection = socket.socket(socket.AF_UNIX)
        connection.connect(str(broker.endpoint(self.root)))
        wire = broker.Wire(connection)
        try:
            wire.send({'hello': broker.PROTOCOL, 'revision': broker.revision(),
                       'workspace': str(self.root), 'language': 'en'})
            self.assertEqual(wire.receive(time.monotonic() + 2)['hello'], broker.PROTOCOL)
            request = {'id': 1, 'name': 'browser_open', 'arguments': {'url': 'https://example.test/'}}
            wire.send(request)
            self.assertIn('result', wire.receive(time.monotonic() + 2))
            wire.send(request)
            with self.assertRaises(EOFError):
                wire.receive(time.monotonic() + 2)
            self.assertEqual(sum(r['name'] == 'new_page' and r['phase'] == 'start' for r in self.trace()), 1)
        finally:
            wire.close()

    def test_unknown_fence_requires_confirmed_chrome_exit_and_keeps_action_records(self):
        executor = broker.Executor(self.root)
        executor.fence.write_text('{}')
        self.assertTrue(executor.quarantine())
        (self.root / 'testing-chrome-owner.json').write_text('{"pid":123}')
        record = self.root / 'action-evidence.json'
        record.write_text('{"state":"outcome_unknown"}')
        with patch('chrome_host.ChromeHost.process_gone', return_value=False):
            self.assertTrue(executor.quarantine())
        with patch('chrome_host.ChromeHost.process_gone', return_value=True):
            self.assertFalse(executor.quarantine())
        self.assertEqual(json.loads(record.read_text())['state'], 'outcome_unknown')

    def test_idle_disconnect_preserves_other_client_and_stops_unused_broker(self):
        self.start_executor()
        a, b = self.client(), self.client()
        first, second = self.opened(a), self.opened(b)
        a.close()
        self.assertFalse(self.call(b, 'browser_snapshot', session=second['session']).get('isError'))
        self.assertFalse(any(row['name'] == 'close_page' for row in self.trace()))
        b.close()
        self.executor.wait(timeout=5)
        self.assertEqual(self.executor.returncode, 0)
        self.assertFalse(broker.endpoint(self.root).exists())
        for opened in (first, second):
            record = json.loads((self.root / 'records' / (opened['session'] + '.json')).read_text())
            self.assertEqual(record['state'], 'disconnected')
        with (self.root / 'executor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_unknown_action_fences_all_clients_and_survives_executor_restart(self):
        self.start_executor()
        a, b = self.client(), self.client()
        first, second = self.opened(a), self.opened(b)
        arguments = dict(session=first['session'], actionID='uncertain-action', expectedURL='https://example.test/', name='click', arguments={'uid': '1_1'})
        for _ in range(2):
            self.assertTrue(self.call(a, 'browser_action', **arguments)['isError'])
        count = len(self.trace())
        self.assertTrue(self.call(b, 'browser_snapshot', session=second['session'])['isError'])
        self.assertEqual(count, len(self.trace()))
        a.close(); b.close()
        self.executor.wait(timeout=5)
        self.start_executor()
        c = self.client()
        self.assertTrue(self.call(c, 'browser_open', url='https://example.test/')['isError'])
        self.assertEqual(count, len(self.trace()))
        self.assertEqual(sum(row['name'] == 'click' for row in self.trace()), 1)
        record = json.loads((self.root / 'records/action-uncertain-action.json').read_text())
        self.assertEqual(record['state'], 'outcome_unknown')

    def disconnect_in_flight(self, cancel=False, crash=False):
        self.start_executor()
        a, b = self.client(), self.client()
        first, second = self.opened(a), self.opened(b)
        errors = []
        def action():
            try:
                a.rpc('tools/call', {'name': 'browser_action', 'arguments': {
                    'session': first['session'], 'actionID': 'disconnect-action',
                    'expectedURL': 'https://example.test/', 'name': 'click',
                    'arguments': {'uid': 'wait-for-disconnect'}}}, 'active',
                    time.monotonic_ns() + 8_000_000_000)
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=action)
        worker.start()
        deadline = time.monotonic() + 3
        while not any(row['name'] == 'click' for row in self.trace()):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        if crash:
            self.executor.kill()
            self.executor.wait(timeout=3)
        elif cancel:
            a.notify('notifications/cancelled', {'requestId': 'active'})
            a.process.wait(timeout=3)
        else:
            a.close(grace_seconds=3)
        worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        if not crash:
            self.assertTrue(errors)
        self.assertTrue(self.call(b, 'browser_snapshot', session=second['session'])['isError'])
        self.assertEqual(sum(row['name'] == 'click' for row in self.trace()), 1)
        self.assertTrue((self.root / 'executor-in-flight.json').exists())
        self.assertEqual(json.loads((self.root / 'records/action-disconnect-action.json').read_text())['state'], 'outcome_unknown')

    def test_eof_during_action_never_replays(self):
        self.disconnect_in_flight()

    def test_active_cancellation_never_replays(self):
        self.disconnect_in_flight(cancel=True)

    def test_executor_crash_never_reconnects_or_replays_tool(self):
        self.disconnect_in_flight(crash=True)


if __name__ == '__main__':
    if '--serve-fake' in sys.argv:
        serve_fake()
    else:
        unittest.main()
