"""Launch the pinned Chrome for Testing, then expose only its verified local endpoint.

Chrome outlives MCP reconnects so manual sign-in and user tabs are preserved.
No default profile, WebDriver flags or auto-connect discovery. Explicit cookie
import runs in the native host; this helper never receives cookie values.
"""
import json
import base64
import hashlib
import fcntl
import os
from pathlib import Path
import re
import socket
import subprocess
import signal
import sys
import threading
import time
import urllib.request
from urllib.parse import urlparse

from install import chrome_app, verify_chrome

# Pages that carry no task or person's work: a Chrome with only these may be quit.
BLANK_PAGES = ('about:blank', 'chrome://newtab/', 'chrome://new-tab-page/')

class ChromeLaunchError(RuntimeError):
    # Stable machine-readable reason for native callers; the message stays localized.
    code = None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


def chrome_command(executable, profile, port):
    if not Path(executable).is_absolute() or not Path(profile).is_absolute() or not 1024 <= port <= 65535:
        raise ValueError('invalid_chrome_launch_parameters')
    return [str(executable), '--user-data-dir=' + str(profile),
            '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=' + str(port),
            '--no-first-run', '--no-default-browser-check', 'about:blank']


class ChromeHost:
    def __init__(self, root, language='en', max_browsers=2):
        self.root = Path(root).resolve()
        self.profile = self.root / 'testing-profile'
        self.record = self.root / 'testing-chrome-owner.json'
        self.language = language
        self.max_browsers = max_browsers
        self.child = None
        self.owner = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def error(self, ru, en):
        return ChromeLaunchError(ru if self.language == 'ru' else en)

    @staticmethod
    def process_field(pid, field):
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', field + '='],
                                capture_output=True, text=True, timeout=3)
        return result.stdout.strip() if result.returncode == 0 else None

    def process_gone(self, owner):
        """Only definite exit or the recorded zombie permits a fresh launch."""
        if not isinstance(owner, dict) or type(owner.get('pid')) is not int or owner['pid'] <= 0:
            return False
        if self.child and self.child.pid == owner['pid']:
            # Reap our own exited child; never wait on or signal an adopted PID.
            if self.child.poll() is not None:
                return True
        state = self.process_field(owner['pid'], 'stat')
        if state is None:
            return True
        if not owner.get('birth'):
            return False
        birth = self.process_field(owner['pid'], 'lstart')
        if birth and birth != owner['birth']:
            # The PID was reused by another process: the recorded Chrome exited.
            return True
        return state.startswith('Z') and birth == owner['birth']

    def matches(self, owner):
        if not isinstance(owner, dict):
            return False
        pid, port = owner.get('pid'), owner.get('port')
        if type(pid) is not int or pid <= 0 or type(port) is not int or not 1024 <= port <= 65535:
            return False
        executable = owner.get('executable')
        if executable not in self.executables() or owner.get('profile') != str(self.profile):
            return False
        return (self.process_field(pid, 'lstart') == owner.get('birth')
                and bool(owner.get('birth'))
                and self.process_field(pid, 'command') == ' '.join(chrome_command(executable, self.profile, port)))

    @staticmethod
    def executables():
        return [str(chrome_app() / 'Contents/MacOS/Google Chrome for Testing')]

    @staticmethod
    def owns_listener(pid, port):
        result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid),
                                 '-iTCP:' + str(port), '-sTCP:LISTEN', '-Fn'],
                                capture_output=True, text=True, timeout=3)
        listeners = {line[1:] for line in result.stdout.splitlines() if line.startswith('n')}
        return result.returncode == 0 and listeners == {'127.0.0.1:' + str(port)}

    def endpoint(self, owner):
        if not self.matches(owner) or not self.owns_listener(owner['pid'], owner['port']):
            return None
        base = 'http://127.0.0.1:' + str(owner['port'])
        try:
            with self.opener.open(base + '/json/version', timeout=1) as response:
                value = json.loads(response.read(32768))
            ws = urlparse(value['webSocketDebuggerUrl'])
            if (not value.get('Browser', '').startswith('Chrome/') or ws.scheme != 'ws'
                    or ws.hostname != '127.0.0.1' or ws.port != owner['port']
                    or ws.username or ws.password or ws.query or ws.fragment
                    or not ws.path.startswith('/devtools/browser/')
                    or (owner.get('browserPath') and owner['browserPath'] != ws.path)):
                return None
            # Recheck after the read: no adoption of a replaced PID/listener.
            if not self.matches(owner) or not self.owns_listener(owner['pid'], owner['port']):
                return None
            owner['browserPath'] = ws.path
            return base
        except (OSError, ValueError, KeyError):
            return None

    def page_targets(self, owner):
        """Read-only page inventory of the verified endpoint: CDP target ID -> URL."""
        base = self.endpoint(owner)
        if not base:
            return None
        try:
            with self.opener.open(base + '/json/list', timeout=2) as response:
                value = json.loads(response.read(4_000_000))
        except (OSError, ValueError):
            return None
        if not isinstance(value, list):
            return None
        return {t['id']: t.get('url', '') for t in value
                if isinstance(t, dict) and t.get('type') == 'page' and isinstance(t.get('id'), str)}

    def close_target(self, owner, target):
        """One close request for one recorded page target. Never retried by this host."""
        if not isinstance(target, str) or not re.fullmatch(r'[0-9A-F]{32}', target):
            return False
        base = self.endpoint(owner)
        if not base:
            return False
        try:
            with self.opener.open(base + '/json/close/' + target, timeout=2) as response:
                return response.status == 200
        except (OSError, ValueError):
            return False

    def persist(self, owner):
        temporary = self.record.with_suffix('.tmp')
        with temporary.open('w') as stream:
            json.dump(owner, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        temporary.replace(self.record)

    def ensure(self, cancelled=None, seconds=15):
        if self.root.parent.name != 'environments':
            return self.ensure_owned(cancelled, seconds)
        # Serialize only admission/startup, never page operations. Existing
        # profiles are not reassigned and live browsers are never evicted.
        with (self.root.parent / 'launch.lock').open('a') as lock:
            deadline = time.monotonic() + seconds
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if (cancelled and cancelled.is_set()) or time.monotonic() >= deadline:
                        raise self.error('Запуск браузера занят. Действие не отправлено.',
                                         'Browser startup is busy. No action was sent.')
                    time.sleep(0.05)
            own = json.loads(self.record.read_text()) if self.record.exists() else None
            if own is None or self.process_gone(own):
                active = 0
                for record in self.root.parent.glob('*/testing-chrome-owner.json'):
                    owner = json.loads(record.read_text())
                    if not self.process_gone(owner):
                        active += 1
                if active >= self.max_browsers:
                    error = self.error('Достигнут лимит браузеров. Заверши неиспользуемый Chrome этого приложения через Cmd+Q или увеличь лимит в настройках. Действие не отправлено.',
                                       'Browser limit reached. Quit an unused Chrome owned by this app with Cmd+Q or increase the limit in settings. No action was sent.')
                    error.code = 'browser_limit'
                    raise error
            return self.ensure_owned(cancelled, seconds)

    def ensure_owned(self, cancelled=None, seconds=15):
        cancelled = cancelled or threading.Event()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.profile.is_symlink():
            raise self.error('Профиль браузера не должен быть символической ссылкой.', 'The browser profile must not be a symbolic link.')
        self.profile.mkdir(exist_ok=True, mode=0o700)
        owner = None
        launched = False
        if self.record.exists():
            old = json.loads(self.record.read_text())
            pid = old.get('pid')
            if type(pid) is not int or pid <= 0:
                raise self.error('Некорректная запись процесса Chrome.', 'Invalid Chrome process record.')
            if not self.process_gone(old):
                if not self.matches(old):
                    raise self.error('Процесс Chrome изменился. Подключение отклонено.', 'The Chrome process changed. Connection was denied.')
                owner = old
        if owner is None:
            if cancelled.is_set():
                raise self.error('Запуск браузера отменён.', 'Browser startup was cancelled.')
            executable = next((p for p in self.executables() if os.access(p, os.X_OK)), None)
            if not executable:
                raise self.error('Установи Chrome for Testing по инструкции в настройках браузера.',
                                 'Install Chrome for Testing using the browser settings instructions.')
            verify_chrome(chrome_app())
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            # A positive port uses Chrome's documented manual debugging mode.
            # Listener ownership below handles a port allocation race fail-closed.
            env = {k: v for k, v in os.environ.items() if k in ('HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL')}
            self.child = subprocess.Popen(chrome_command(executable, self.profile, port),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=env, start_new_session=True)
            owner = {'pid': self.child.pid, 'port': port, 'executable': executable,
                     'profile': str(self.profile), 'birth': self.process_field(self.child.pid, 'lstart')}
            self.persist(owner)
            launched = True
        self.owner = owner
        end = time.monotonic() + seconds
        while time.monotonic() < end and not cancelled.is_set():
            if self.child and self.child.poll() is not None:
                raise self.error('Chrome не запустился. Закрой старое окно браузера Switchboard и попробуй снова.',
                                 'Chrome did not start. Close the previous Switchboard browser and try again.')
            endpoint = self.endpoint(owner)
            if endpoint:
                self.persist(owner)
                if launched:
                    self.hide_created_browser(owner)
                return endpoint
            cancelled.wait(0.2)
        raise self.error('Подключение к Chrome не подтверждено. Автоматического перезапуска не было.',
                         'Chrome connection was not confirmed. No automatic restart was attempted.')

    def hide_created_browser(self, owner):
        """Hide only our fresh child, once. Reattachment preserves manual visibility.

        AppKit via JXA needs neither Accessibility nor Apple Events permission.
        A visibility failure must not retry or invalidate browser work.
        """
        if not self.child or self.child.pid != owner['pid'] or not self.matches(owner):
            return False
        return self.visibility(owner, hide=True)

    def visibility(self, owner, hide=False):
        """Read or restore hidden state of this verified process, never by app name."""
        if not self.matches(owner):
            return False
        script = '''ObjC.import('AppKit');
function run(args) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(args[0]));
    if (!app || app.isNil() || ObjC.unwrap(app.bundleIdentifier) !== 'com.google.chrome.for.testing' ||
        ObjC.unwrap(app.executableURL.path) !== args[1]) return 'false';
    if (args[2] !== 'hide') return app.hidden ? 'true' : 'false';
    app.hide;
    const deadline = Date.now() + 2000;
    while (!app.hidden && Date.now() < deadline) {
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
    }
    return app.hidden ? 'true' : 'false';
}'''
        try:
            result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script,
                                     str(owner['pid']), owner['executable'], 'hide' if hide else 'status'],
                                    capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and result.stdout.strip() == 'true':
                return True
        except (OSError, subprocess.TimeoutExpired):
            pass
        if not hide:
            return False
        print('Не удалось скрыть браузер; он продолжает работать.' if self.language == 'ru'
              else 'Could not hide the browser; it is still running.', file=sys.stderr)
        return False

    def close_created_for_test(self):
        """Only fixtures call this; never terminate a reattached/user Chrome."""
        if not self.child or self.child.poll() is not None:
            return
        if not self.owner or not self.matches(self.owner):
            raise RuntimeError('refuse_to_terminate_unverified_chrome')
        self.child.terminate()
        self.child.wait(timeout=10)

    def control(self, close=False):
        """Explicit native UI control. Never launches Chrome or retries a signal."""
        if not self.record.exists():
            return {'running': False}
        if not close:
            return self.control_owned(False)
        with (self.root / 'operation.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise self.error('Браузер выполняет операцию. Действие управления не отправлено.',
                                 'The browser is performing an operation. No control action was sent.')
            return self.control_owned(close)

    def prepare_cookie_import(self):
        """Caller holds operation.lock throughout preparation, write and verification.

        Never attach to a live browser for import: it could overwrite refreshed
        cookies in an active tab. A persisted uncertain write is retired only
        after definite exit of the recorded Chrome, as in the executor.
        """
        old = json.loads(self.record.read_text()) if self.record.exists() else None
        if old is not None and not self.process_gone(old):
            return {'code': 'destination_running'}
        fence = self.root / 'executor-in-flight.json'
        if fence.exists():
            if old is None or not self.process_gone(old):
                return {'code': 'uncertain'}
            fence.unlink()
        endpoint = self.ensure()
        return {'webSocketURL': endpoint.replace('http://', 'ws://', 1) + self.owner['browserPath']}

    def close_if_idle(self):
        """Caller holds operation.lock. Quit this environment's Chrome only when every tab is blank.

        A scheduled run that never opened a tab (for example, one whose sign-in preflight launched
        Chrome but whose agent did not need the site) otherwise left Chrome running with no owner
        able to close it. Any page with an address (an unclosed task tab, a person's tab) keeps it.
        Never launches Chrome; the close itself is control_owned's single, never-resent request.
        """
        if not self.record.exists():
            return {'running': False}
        owner = json.loads(self.record.read_text())
        if self.process_gone(owner):
            return {'running': False}
        targets = self.page_targets(owner)
        if not isinstance(targets, dict):
            raise self.error('Не удалось проверить вкладки Chrome. Ничего не закрыто.',
                             'Could not inspect the Chrome tabs. Nothing was closed.')
        if any(url not in BLANK_PAGES for url in targets.values()):
            return {'running': True, 'kept': True}
        return self.control_owned(True)

    def control_owned(self, close):
        owner = json.loads(self.record.read_text())
        if self.process_gone(owner):
            return {'running': False}
        if not self.endpoint(owner):
            raise self.error('Принадлежность Chrome не подтверждена. Действие не выполнено.',
                             'Chrome ownership could not be verified. No action was performed.')
        if not close:
            return {'running': True, 'pid': owner['pid']}
        if (self.root / 'executor-in-flight.json').exists():
            raise self.error('В браузере есть незавершённая операция. Проверь её результат и закрой Chrome вручную.',
                             'The browser has an unfinished operation. Review its result and quit Chrome manually.')
        intent = self.root / 'manual-close.json'
        if intent.exists() and json.loads(intent.read_text()) == owner:
            raise self.error('Закрытие уже запрошено. Автоматического повтора нет; проверь окно Chrome.',
                             'Close was already requested. It will not be retried; check the Chrome window.')
        # Persist intent before sending. A crashed helper cannot resend the signal.
        with intent.open('w') as stream:
            json.dump(owner, stream)
            stream.flush()
            os.fsync(stream.fileno())
        if not self.matches(owner):
            raise self.error('Процесс Chrome изменился. Закрытие отклонено.',
                             'The Chrome process changed. Close was denied.')
        self.graceful_close(owner)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.process_gone(owner):
                return {'running': False}
            time.sleep(.1)
        raise self.error('Завершение Chrome не подтверждено. Команда закрытия не повторена.',
                         'Chrome exit was not confirmed. The close command was not repeated.')

    def graceful_close(self, owner):
        """One fixed Browser.close frame to the verified loopback CDP endpoint.

        SIGTERM can lose recently committed browser state on macOS. Use Chrome's
        graceful shutdown. Never accept a reply/EOF as proof of process exit;
        control_owned performs that independent check and never resends intent.
        This is not a general WebSocket or arbitrary JavaScript transport.
        """
        path = owner.get('browserPath', '')
        if not path.startswith('/devtools/browser/') or any(c not in '/-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' for c in path):
            raise self.error('Адрес Chrome не подтверждён.', 'The Chrome address was not verified.')
        key = base64.b64encode(os.urandom(16)).decode('ascii')
        with socket.create_connection(('127.0.0.1', owner['port']), timeout=2) as connection:
            request = ('GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:' + str(owner['port']) +
                       '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key +
                       '\r\nSec-WebSocket-Version: 13\r\n\r\n')
            connection.sendall(request.encode('ascii'))
            header = b''
            deadline = time.monotonic() + 2
            while b'\r\n\r\n' not in header and len(header) < 16_384 and time.monotonic() < deadline:
                chunk = connection.recv(1024)
                if not chunk:
                    break
                header += chunk
            lines = header.split(b'\r\n\r\n', 1)[0].decode('ascii').split('\r\n')
            fields = dict((k.lower(), v.strip()) for k, v in (line.split(':', 1) for line in lines[1:] if ':' in line))
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode('ascii')).digest()).decode('ascii')
            if (b'\r\n\r\n' not in header or lines[0] != 'HTTP/1.1 101 WebSocket Protocol Handshake'
                    and lines[0] != 'HTTP/1.1 101 Switching Protocols'
                    or fields.get('upgrade', '').lower() != 'websocket'
                    or 'upgrade' not in fields.get('connection', '').lower().split(',')
                    or fields.get('sec-websocket-accept') != accept
                    or not self.matches(owner) or not self.owns_listener(owner['pid'], owner['port'])):
                raise self.error('Принадлежность Chrome не подтверждена. Закрытие не отправлено.',
                                 'Chrome ownership was not verified. Close was not sent.')
            data = b'{"id":1,"method":"Browser.close"}'
            mask = os.urandom(4)
            connection.sendall(bytes((0x81, 0x80 | len(data))) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
            try:
                connection.recv(4096)  # Bounded wait; only process exit confirms success.
            except (TimeoutError, ConnectionError):
                pass


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--language', choices=('ru', 'en'), default='en')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--close', action='store_true')
    mode.add_argument('--close-if-idle', action='store_true')
    mode.add_argument('--prepare-cookie-import', action='store_true')
    mode.add_argument('--profile-idle', action='store_true')
    parser.add_argument('--profile-lease')
    parser.add_argument('--max-browsers', type=int, choices=range(1, 9), default=2)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        host = ChromeHost(args.root, args.language, args.max_browsers)
        if args.profile_idle:
            # The native caller already holds operation.lock throughout catalog changes.
            from profiles import idle
            idle(host)
            print(json.dumps({'running': False}))
        elif args.prepare_cookie_import:
            # Cookie importer holds operation.lock and validates its captured lease.
            print(json.dumps(host.prepare_cookie_import()))
        else:
            from profiles import validate
            host.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            with (host.root / 'operation.lock').open('a') as operation_lock:
                try:
                    fcntl.flock(operation_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise host.error('Браузер выполняет операцию. Действие управления не отправлено.',
                                     'The browser is performing an operation. No control action was sent.')
                validate(host.root, args.profile_lease, allow_human=True, language=args.language)
                if args.close_if_idle:
                    print(json.dumps(host.close_if_idle()))
                else:
                    print(json.dumps(host.control_owned(args.close) if host.record.exists() else {'running': False}))
    except Exception as error:
        result = {'error': str(error)}
        if getattr(error, 'code', None):
            result['code'] = error.code
        print(json.dumps(result))
        raise SystemExit(1)
