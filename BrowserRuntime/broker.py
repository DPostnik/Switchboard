"""Private per-root browser executor. One worker, separate client contexts.

Only connection establishment may poll/reconnect, before any tool is sent.
An interrupted operation leaves a durable fence. A confirmed Chrome exit is
required to retire that fence; action IDs are never removed or replayed.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import signal
import socket
import stat
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
PROTOCOL = 1
LIMIT = 8_000_000


def revision():
    digest = hashlib.sha256()
    for name in ('broker.py', 'server.py', 'transport.py', 'chrome_host.py', 'profiles.py', 'cdp.py', 'page_input.py', 'page_read.js', 'page_tree.js', 'runtime.lock.json'):
        digest.update(Path(__file__).with_name(name).read_bytes())
    return digest.hexdigest()


BUILD_REVISION = revision()


def endpoint(root):
    # macOS Unix sockets have a short pathname limit. The directory is private,
    # checked without following links; the hash separates app/test roots.
    directory = Path('/tmp') / ('context-desk-browser-' + str(os.getuid()))
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('unsafe_browser_ipc_directory')
    return directory / (hashlib.sha256(str(Path(root).resolve()).encode()).hexdigest()[:32] + '.sock')


class Wire:
    def __init__(self, connection):
        self.socket = connection
        self.socket.settimeout(0.5)
        self.buffer = b''
        self.write_lock = threading.Lock()

    def send(self, value):
        data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode() + b'\n'
        if len(data) > LIMIT:
            raise ValueError('browser_ipc_message_too_large')
        with self.write_lock:
            self.socket.sendall(data)

    def receive(self, deadline=None, stopped=None):
        while True:
            if stopped is not None and stopped.is_set():
                raise EOFError('browser_client_disconnected')
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError('browser_executor_deadline_no_replay')
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError('invalid_browser_ipc_message')
                return value
            if len(self.buffer) > LIMIT:
                raise ValueError('browser_ipc_message_too_large')
            try:
                data = self.socket.recv(65536)
            except socket.timeout:
                continue
            if not data:
                raise EOFError('browser_executor_disconnected_outcome_may_be_unknown')
            self.buffer += data

    def close(self):
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.socket.close()


class RemoteBrowser:
    """MCP-facing client; never reconnects or resends after tool dispatch."""
    def __init__(self, root, workspace, language, installation_root=None, max_browsers=2, profile_lease=None):
        self.root = Path(root).resolve()
        self.workspace = str(Path(workspace).resolve(strict=True))
        self.language = language
        self.installation_root = Path(installation_root).resolve() if installation_root is not None else None
        self.max_browsers = max_browsers
        self.profile_lease = profile_lease
        self.wire = None
        self.failed = False
        self.terminal = False
        self.stopped = threading.Event()
        self.counter = 0

    def connect(self):
        from server import Rejected
        def tr(ru, en):
            return ru if self.language == 'ru' else en
        path = endpoint(self.root)
        # This lock protects only startup. No tool bytes have been sent yet.
        with (self.root / 'broker-start.lock').open('a') as launch_lock:
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(launch_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if self.stopped.wait(0.05) or time.monotonic() >= deadline:
                        raise Rejected(tr('Исполнитель запускается. Действие не отправлено.', 'The executor is starting. No action was sent.'))
            connection = socket.socket(socket.AF_UNIX)
            try:
                connection.connect(str(path))
            except (FileNotFoundError, ConnectionRefusedError):
                connection.close()
                child = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()),
                    '--root', str(self.root), '--max-browsers', str(self.max_browsers)] + (['--installation-root', str(self.installation_root)] if self.installation_root else []), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
                # Reap only the child we created, without owning its lifetime.
                threading.Thread(target=child.wait, daemon=True).start()
                while True:
                    if self.stopped.is_set():
                        raise EOFError('browser_start_cancelled_before_dispatch')
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise Rejected(tr(
                            'Общий исполнитель недоступен. Возможно, старый адаптер держит блокировку. После завершения задач выйди через Cmd+Q и открой приложение. Действие не отправлено.',
                            'The shared executor is unavailable. An old adapter may hold the lock. After active tasks finish, quit with Cmd+Q and reopen the app. No action was sent.'))
                    connection = socket.socket(socket.AF_UNIX)
                    try:
                        connection.connect(str(path))
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        connection.close()
                        self.stopped.wait(0.05)
            wire = Wire(connection)
            self.wire = wire
            if self.stopped.is_set():
                wire.close()
                raise EOFError('browser_start_cancelled_before_dispatch')
            wire.send({'hello': PROTOCOL, 'revision': BUILD_REVISION, 'workspace': self.workspace,
                       'language': self.language, 'maxBrowsers': self.max_browsers, 'profileLease': self.profile_lease})
            reply = wire.receive(deadline, self.stopped)
            if reply.get('hello') != PROTOCOL or reply.get('revision') != BUILD_REVISION:
                wire.close()
                raise Rejected(tr('Версия исполнителя изменилась. Перезапусти приложение после завершения задач.',
                                  'The executor version changed. Restart the app after active tasks finish.'))

    def call(self, name, arguments):
        from server import Rejected, require
        # The executor keeps the authoritative failed state and decides per tool
        # (browser_close and browser_open can recover); only a lost wire stops this client.
        require(not self.stopped.is_set(), 'executor_stopped_outcome_may_be_unknown')
        if self.wire is None:
            self.connect()
        self.counter += 1
        try:
            self.wire.send({'id': self.counter, 'name': name, 'arguments': arguments})
            result = self.wire.receive(time.monotonic() + 80, self.stopped)
            if result.get('id') != self.counter:
                raise ValueError('browser_executor_response_mismatch')
        except Exception:
            self.failed = True
            self.stop()
            raise
        self.failed = bool(result.get('outcomeUnknown'))
        self.terminal = bool(result.get('failed'))
        if 'error' in result:
            raise Rejected(result['error'])
        return result['result']

    def persist(self):
        pass  # Checkpoints belong to the executor, not to the MCP front end.

    def stop(self):
        self.stopped.set()
        if self.wire:
            self.wire.close()

    disconnect = stop


class Client:
    def __init__(self, wire, browser, language, profile_lease=None):
        self.wire, self.browser, self.language = wire, browser, language
        self.profile_lease = profile_lease
        self.closed = threading.Event()
        self.pending = False
        self.last_id = 0
        self.lock = threading.Lock()


class Executor:
    def __init__(self, root, browser_factory=None, installation_root=None, max_browsers=2):
        import server
        self.root = Path(root).resolve()
        self.factory = browser_factory or server.Browser
        self.installation_root = installation_root
        self.max_browsers = max_browsers
        self.jobs = queue.Queue(maxsize=32)
        self.clients = set()
        self.clients_lock = threading.Lock()
        self.stopped = threading.Event()
        self.fence = self.root / 'executor-in-flight.json'
        self.worker = None
        self.listener = None
        self.path = endpoint(self.root)
        self.identity = BUILD_REVISION

    def apply_approved_read_recovery(self):
        """Called only at startup, after acquiring the legacy executor lock.

        An operator may explicitly identify an old, otherwise untyped fence as
        a failed snapshot read. Approval is bound to exact bytes AND mtime;
        neither another failure nor a known mutating tool can consume it.
        This archives evidence and retires a fence; it never dispatches a tool.
        """
        import server
        approval_path = self.root / 'approved-read-recovery.json'
        if not self.fence.exists() or not approval_path.exists():
            return False
        try:
            raw = self.fence.read_bytes()
            modified = self.fence.stat().st_mtime_ns
            fence = json.loads(raw)
            approval = json.loads(approval_path.read_text())
            if (not isinstance(fence, dict) or not isinstance(approval, dict)
                    or approval.get('schema') != 1
                    or approval.get('confirmedTool') != 'browser_snapshot'
                    or approval.get('reason') != 'operator_confirmed_read_failure'
                    or approval.get('fenceSHA256') != hashlib.sha256(raw).hexdigest()
                    or approval.get('fenceModifiedNS') != modified
                    or fence.get('tool') not in (None, 'browser_snapshot')
                    or fence.get('state') != 'outcome_unknown'):
                return False
        except (OSError, ValueError):
            return False
        records = self.root / 'records'
        records.mkdir(exist_ok=True, mode=0o700)
        evidence = records / ('read-recovery-' + approval['fenceSHA256'] + '-' + str(modified) + '.json')
        server.save(evidence, {'fence': fence, 'approval': approval,
                               'state': 'operator_confirmed_read_failure_retired', 'replayed': False})
        self.fence.unlink()
        approval_path.unlink()
        return True

    def quarantine(self):
        """A stale fence is retired only after the recorded Chrome has exited."""
        if not self.fence.exists():
            return False
        from chrome_host import ChromeHost
        record = self.root / 'testing-chrome-owner.json'
        if record.exists():
            try:
                owner = json.loads(record.read_text())
                if ChromeHost(self.root).process_gone(owner):
                    self.fence.unlink()
                    return False
            except (OSError, ValueError):
                pass
        return True

    def receive(self, connection):
        import server
        wire, client = Wire(connection), None
        try:
            hello = wire.receive(time.monotonic() + 5, self.stopped)
            if hello.get('hello') != PROTOCOL or hello.get('revision') != self.identity:
                wire.send({'error': 'executor_version_mismatch'})
                return
            language = hello.get('language')
            if language not in ('ru', 'en') or not isinstance(hello.get('workspace'), str):
                return
            limit = hello.get('maxBrowsers', 2)
            if type(limit) is not int or not 1 <= limit <= 8:
                return
            workspace = Path(hello['workspace']).resolve(strict=True)
            if not workspace.is_dir() or workspace.parent == workspace:
                return
            options = {'workspace': workspace}
            if self.installation_root is not None:
                options['installation_root'] = self.installation_root
                options['max_browsers'] = limit
            client = Client(wire, self.factory(self.root, **options), language, hello.get('profileLease'))
            with self.clients_lock:
                if len(self.clients) >= 32 or self.stopped.is_set():
                    return
                self.clients.add(client)
            wire.send({'hello': PROTOCOL, 'revision': self.identity})
            while not self.stopped.is_set():
                message = wire.receive(stopped=self.stopped)
                with client.lock:
                    ident = message.get('id')
                    if client.pending or type(ident) is not int or ident <= client.last_id:
                        return
                    client.last_id, client.pending = ident, True
                try:
                    self.jobs.put_nowait((client, message))
                except queue.Full:
                    with client.lock:
                        client.pending = False
                    raise
        except Exception:
            pass
        finally:
            if client:
                client.closed.set()
                client.browser.stop()
            wire.close()
            # Cleanup is performed by the worker, never in parallel with dispatch.

    def cleanup(self):
        with self.clients_lock:
            dead = [c for c in self.clients if c.closed.is_set() and not c.pending]
            for client in dead:
                browser = client.browser
                browser.stop()
                if browser.session:
                    browser.checkpoint.update(state='disconnected', outcomeUnknown=browser.failed)
                    browser.persist()
                self.clients.remove(client)

    def work(self):
        try:
            self.run_jobs()
        except BaseException:
            self.stopped.set()  # Persistence/cleanup failure stops every dispatch.

    def run_jobs(self):
        import server
        while not self.stopped.is_set() or not self.jobs.empty():
            try:
                client, message = self.jobs.get(timeout=0.1)
            except queue.Empty:
                self.cleanup()
                continue
            browser = client.browser
            response = {'id': message['id']}
            server.LANGUAGE = client.language  # Only this worker dispatches tools.
            try:
                if client.closed.is_set() or self.stopped.is_set():
                    continue
                with (self.root / 'operation.lock').open('a') as operation_lock:
                    fcntl.flock(operation_lock, fcntl.LOCK_EX)
                    if client.closed.is_set() or self.stopped.is_set():
                        continue
                    from profiles import validate
                    validate(self.root, client.profile_lease, browser.workspace, language=client.language)
                    name = message.get('name')
                    browser.uncertain = False
                    was_failed = browser.failed
                    shared = False
                    if name == 'browser_close':
                        with self.clients_lock:
                            shared = any(c is not client and c.browser.session for c in self.clients)
                    # browser_close passes an existing fence: a live task closes its own tab, and the
                    # client whose action left the fence quits Chrome, which is what retires it.
                    fenced = name == 'browser_close' and self.fence.exists()
                    if not fenced:
                        server.require(not self.quarantine(), server.tr(
                            'Исход прошлой операции неизвестен. Действия остановлены без повтора. Вызови browser_close для своей сессии (закроет Chrome чата) или закрой выделенный Chrome; затем начни новую сессию.',
                            'A previous operation has an unknown outcome. Actions are stopped without replay. Call browser_close for your session (it quits the chat’s Chrome) or close the dedicated Chrome, then start a new session.'))
                        server.save(self.fence, {'client': id(client), 'request': message['id'],
                            'tool': name, 'state': 'outcome_unknown'})
                    try:
                        result = server.dispatch(browser, name, message.get('arguments'), shared=shared)
                        browser.persist()
                        if name == 'browser_close' and 'browserQuit' not in result:
                            # Another task of this chat still works in the same Chrome: keep it.
                            result['browserQuit'] = 'kept' if shared else browser.quit_idle_chrome()
                            if result['browserQuit'] == 'kept':
                                result.update(browser.kept_reason(other_task=shared))
                        response['result'] = result
                    finally:
                        if not browser.failed and (not fenced or was_failed):
                            self.fence.unlink(missing_ok=True)
            except Exception as error:
                response.update(error=str(error)[:2000], failed=browser.failed,
                                outcomeUnknown=browser.failed or browser.uncertain or self.fence.exists())
            finally:
                with client.lock:
                    client.pending = False
                if not client.closed.is_set() and not self.stopped.is_set():
                    try:
                        client.wire.send(response)
                    except Exception:
                        client.closed.set()
                        client.browser.stop()
                        client.wire.close()
                self.cleanup()

    def run(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.root / 'executor.lock').open('a') as lock:
            # Also excludes old adapters. Never remove or replace this lock file.
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.apply_approved_read_recovery()
            self.path.unlink(missing_ok=True)
            self.listener = socket.socket(socket.AF_UNIX)
            self.listener.bind(str(self.path))
            os.chmod(self.path, 0o600)
            self.listener.listen(32)
            self.listener.settimeout(0.2)
            self.worker = threading.Thread(target=self.work)
            self.worker.start()
            empty_since = time.monotonic()
            try:
                while not self.stopped.is_set():
                    try:
                        connection, _ = self.listener.accept()
                    except socket.timeout:
                        with self.clients_lock:
                            if self.clients:
                                empty_since = time.monotonic()
                            elif time.monotonic() - empty_since > 3:
                                break
                        continue
                    empty_since = time.monotonic()
                    threading.Thread(target=self.receive, args=(connection,), daemon=True).start()
            finally:
                self.stopped.set()
                self.listener.close()
                with self.clients_lock:
                    for client in self.clients:
                        client.closed.set()
                        client.browser.stop()
                        client.wire.close()
                self.worker.join()
                self.cleanup()
                self.path.unlink(missing_ok=True)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--installation-root', type=Path)
    parser.add_argument('--max-browsers', type=int, choices=range(1, 9), default=2)
    args = parser.parse_args()
    os.umask(0o077)
    executor = Executor(args.root, installation_root=args.installation_root, max_browsers=args.max_browsers)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: executor.stopped.set())
    executor.run()


if __name__ == '__main__':
    main()
