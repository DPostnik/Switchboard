#!/usr/bin/env python3
"""Hosts app-owned MCP servers outside the agent's external sandbox.

Switchboard starts one host per sandboxed agent process. The host listens on a unix socket; the agent
spawns `mcp_relay.py <socket> <name>` as its MCP server command. For each connection the host reads the
server name, looks it up in the spec file Switchboard maintains (`{"servers": {name: {"command", "args",
"env"}}}`) and starts that command with the connection as its stdin/stdout. The spec file is the trusted
side: the sandboxed process chooses only a name. The host exits with its children when Switchboard
terminates it or when the owning process disappears.
"""
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

MAX_NAME = 128


class Host:
    def __init__(self, spec_path, log):
        self.spec_path = spec_path
        self.log = log
        self.children = {}
        self.lock = threading.Lock()
        self.closing = False

    def note(self, text):
        self.log.write(time.strftime('%Y-%m-%dT%H:%M:%S ') + text + '\n')
        self.log.flush()

    def spec(self, name):
        try:
            with open(self.spec_path, encoding='utf-8') as handle:
                document = json.load(handle)
        except (OSError, ValueError) as error:
            self.note('spec unreadable: %s' % error)
            return None
        servers = document.get('servers') if isinstance(document, dict) else None
        entry = servers.get(name) if isinstance(servers, dict) else None
        if not isinstance(entry, dict) or not isinstance(entry.get('command'), str) or not os.path.isabs(entry['command']):
            return None
        args = entry.get('args', [])
        env = entry.get('env', {})
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            return None
        if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
            return None
        return entry['command'], args, env

    def serve(self, connection):
        try:
            name = b''
            while not name.endswith(b'\n') and len(name) <= MAX_NAME:
                chunk = connection.recv(1)
                if not chunk:
                    return
                name += chunk
            name = name.decode('utf-8', 'replace').strip()
            if not name or len(name) > MAX_NAME:
                self.note('rejected: empty or long name')
                return
            resolved = self.spec(name)
            if resolved is None:
                self.note('rejected: unknown server %r' % name)
                return
            command, args, env = resolved
            environment = dict(os.environ)
            environment.update(env)
            child = subprocess.Popen([command] + args, stdin=connection.fileno(), stdout=connection.fileno(),
                                     stderr=self.log, env=environment, close_fds=True)
            with self.lock:
                if self.closing:
                    child.terminate()
                self.children[child.pid] = (name, child)
            self.note('started %s pid %d' % (name, child.pid))
        except OSError as error:
            self.note('start failed: %s' % error)
            return
        finally:
            connection.close()
        child.wait()
        with self.lock:
            self.children.pop(child.pid, None)
        self.note('exited %s pid %d status %s' % (name, child.pid, child.returncode))

    def shutdown(self):
        with self.lock:
            self.closing = True
            children = list(self.children.values())
        for _, child in children:
            try:
                child.terminate()
            except OSError:
                pass
        deadline = time.monotonic() + 5
        for _, child in children:
            try:
                child.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                child.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--spec', required=True)
    parser.add_argument('--owner-pid', type=int, default=0, help='Exit when this process is gone')
    parser.add_argument('--log', default='')
    args = parser.parse_args()
    log = open(args.log, 'a', encoding='utf-8') if args.log else sys.stderr
    host = Host(args.spec, log)
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(args.socket)
    os.chmod(args.socket, 0o600)
    listener.listen(16)
    listener.settimeout(1.0)
    stop = threading.Event()

    def handle_signal(*_):
        stop.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    host.note('listening on %s' % args.socket)
    print('ready', flush=True)
    while not stop.is_set():
        if args.owner_pid:
            try:
                os.kill(args.owner_pid, 0)
            except ProcessLookupError:
                host.note('owner gone')
                break
            except PermissionError:
                pass
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=host.serve, args=(connection,), daemon=True).start()
    host.shutdown()
    listener.close()
    try:
        os.unlink(args.socket)
    except OSError:
        pass
    host.note('stopped')
    return 0


if __name__ == '__main__':
    sys.exit(main())
