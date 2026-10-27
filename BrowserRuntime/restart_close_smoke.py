#!/usr/bin/env python3
"""Real bundled MCP and Chrome: after an agent restart, browser_close with the old token closes its tab."""
import http.server
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
from install import ROOT, LOCK
from chrome_host import ChromeHost
from transport import StdioRPC
import server


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Restart fixture</title><p>earlier session</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='context-browser-restart-smoke-') as temporary:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        host = ChromeHost(root)
        clients = []
        sequence = iter(range(100))
        try:
            host.ensure()
            owner = dict(host.owner)
            def client():
                result = StdioRPC([sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(root)]).start()
                clients.append(result)
                result.initialize_mcp(expected_server_version=server.VERSION)
                return result
            def call(c, name, **arguments):
                response = c.rpc('tools/call', {'name': name, 'arguments': arguments}, str(next(sequence)), time.monotonic_ns() + 85_000_000_000)
                return response.get('isError', False), json.loads(response['content'][0]['text'])
            before = client()
            failed, opened = call(before, 'browser_open', url='http://127.0.0.1:' + str(fixture.server_port) + '/boeing')
            assert not failed, opened
            before.close()  # The agent restarts: its MCP connection ends, the token is all it keeps.
            record = root / 'records' / (opened['session'] + '.json')
            deadline = time.monotonic() + 10
            while json.loads(record.read_text()).get('state') != 'disconnected':
                assert time.monotonic() < deadline, 'session was not recorded as disconnected'
                time.sleep(0.1)
            after = client()
            failed, closed = call(after, 'browser_close', session=opened['session'])
            assert not failed and closed.get('earlierSession') and closed.get('browserQuit') == 'quit', closed
            assert host.process_gone(owner), 'chat Chrome still runs'
            assert json.loads(record.read_text())['state'] == 'orphan_closed'
            failed, again = call(after, 'browser_close', session=opened['session'])
            assert failed, again  # The earlier token is spent; nothing is resent.
            print(json.dumps({'result': 'passed', 'earlierSessionClosed': True, 'browserQuit': closed['browserQuit'],
                              'secondCloseRejected': True, 'externalSitesOrSubmissions': False}))
        finally:
            for c in clients:
                c.close()
            host.close_created_for_test()
            fixture.shutdown()


if __name__ == '__main__':
    main()
