#!/usr/bin/env python3
"""stdio <-> unix-socket relay for an app-owned MCP server that runs outside the agent's sandbox.

The agent process (inside the external sandbox) spawns this script as the MCP server command. It connects
to the host socket Switchboard owns, names the server it stands for, and copies bytes both ways until
either side closes. No protocol parsing, no retries, no buffering beyond one chunk.
"""
import os
import selectors
import socket
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write('usage: mcp_relay.py <socket> <server-name>\n')
        return 64
    path, name = sys.argv[1], sys.argv[2]
    if not name or any(c in name for c in '\n\r\0/') or len(name) > 128:
        sys.stderr.write('mcp_relay: invalid server name\n')
        return 64
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.connect(path)
    except OSError as error:
        sys.stderr.write('mcp_relay: cannot reach the host socket: %s\n' % error)
        return 69
    connection.sendall((name + '\n').encode())
    stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
    os.set_blocking(stdin, False)
    connection.setblocking(False)
    selector = selectors.DefaultSelector()
    selector.register(stdin, selectors.EVENT_READ)
    selector.register(connection, selectors.EVENT_READ)
    open_ends = 2
    while open_ends == 2:
        # The agent may spawn this relay in its own process group; a dead parent (reparented to launchd) ends it.
        ready = selector.select(timeout=1.0)
        if not ready and os.getppid() == 1:
            break
        for key, _ in ready:
            if key.fd == stdin:
                try:
                    chunk = os.read(stdin, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    open_ends -= 1
                    try:
                        connection.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    break
                connection.setblocking(True)
                connection.sendall(chunk)
                connection.setblocking(False)
            else:
                try:
                    chunk = connection.recv(65536)
                except BlockingIOError:
                    continue
                except OSError:
                    chunk = b''
                if not chunk:
                    open_ends -= 1
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(stdout, view)
                    view = view[written:]
    # Drain the remaining direction briefly so a final response is not lost, then exit.
    if open_ends == 1:
        connection.setblocking(True)
        connection.settimeout(1.0)
        try:
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(stdout, view)
                    view = view[written:]
        except OSError:
            pass
    connection.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
