#!/usr/bin/env python3
"""Host + relay round trip, unknown server rejection and child teardown. No agent, no network."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
PYTHON = sys.executable


class HostTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='mcp-host-', dir=str(HERE.parent / '.build'))) if (HERE.parent / '.build').exists() else pathlib.Path(tempfile.mkdtemp(prefix='mcp-host-'))
        self.socket = self.root / 'mcp.sock'
        self.spec = self.root / 'servers.json'
        self.server = self.root / 'upper.py'
        self.server.write_text('import sys\nfor line in sys.stdin:\n    sys.stdout.write(line.upper()); sys.stdout.flush()\n')
        self.spec.write_text(json.dumps({'servers': {'upper': {'command': PYTHON, 'args': ['-I', str(self.server)], 'env': {'X_TEST': '1'}}}}))
        self.host = subprocess.Popen([PYTHON, '-I', str(HERE / 'mcp_host.py'), '--socket', str(self.socket), '--spec', str(self.spec),
                                      '--log', str(self.root / 'host.log')], stdout=subprocess.PIPE, text=True)
        self.assertEqual(self.host.stdout.readline().strip(), 'ready')

    def tearDown(self):
        if self.host.poll() is None:
            self.host.terminate()
            self.host.wait(timeout=10)
        subprocess.run(['rm', '-rf', str(self.root)])

    def relay(self, name, data, timeout=15):
        return subprocess.run([PYTHON, '-I', str(HERE / 'mcp_relay.py'), str(self.socket), name], input=data, capture_output=True, text=True, timeout=timeout)

    def test_round_trip_and_eof(self):
        result = self.relay('upper', 'hello\nworld\n')
        self.assertEqual(result.stdout, 'HELLO\nWORLD\n')
        self.assertEqual(result.returncode, 0)

    def test_unknown_server_closes(self):
        result = self.relay('missing', 'hello\n')
        self.assertEqual(result.stdout, '')
        self.assertIn('unknown server', (self.root / 'host.log').read_text())

    def test_bad_name_rejected_locally(self):
        result = self.relay('../x', 'hello\n')
        self.assertEqual(result.returncode, 64)

    def test_children_end_with_host(self):
        self.server.write_text('import sys,time\nprint("up",flush=True)\ntime.sleep(60)\n')
        relay = subprocess.Popen([PYTHON, '-I', str(HERE / 'mcp_relay.py'), str(self.socket), 'upper'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.assertEqual(relay.stdout.readline().strip(), 'up')
        log = (self.root / 'host.log')
        pid = None
        for _ in range(50):
            for line in log.read_text().splitlines():
                if line.split(' ', 1)[1].startswith('started upper pid '):
                    pid = int(line.split()[-1])
            if pid:
                break
            time.sleep(0.1)
        self.assertIsNotNone(pid)
        self.host.terminate()
        self.host.wait(timeout=10)
        time.sleep(0.5)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        relay.stdin.close()
        relay.wait(timeout=10)


if __name__ == '__main__':
    unittest.main()
