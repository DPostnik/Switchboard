"""Synthetic agent import tests; never touch personal Chrome or Keychain."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import server


class SessionImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.browser = server.Browser(self.root, rpc=Mock())
        self.browser.session = 'owned'
        self.browser.page = 1
        self.browser.checkpoint = {'state': 'opened'}
        self.browser.expected = Mock()
        self.browser.chrome = Mock(owner={'browserPath': '/devtools/browser/fixture'})
        self.browser.chrome.endpoint.return_value = 'http://127.0.0.1:45678'
        self.browser.chrome.process_gone.return_value = False
        self.policy = self.root / 'chrome-session-import.json'
        self.policy.write_text(json.dumps({'site': 'linkedin.com', 'profile': 'Default'}))
        self.url = 'https://www.linkedin.com/login'
        self.result = {'verified': 2, 'skipped': 0, 'unverified': 0, 'websiteSignInVerified': False,
                       'localStorageVerified': 1, 'localStorageSkipped': 0, 'localStorageUnverified': 0}

    def tearDown(self):
        self.temp.cleanup()

    def call(self, url=None):
        return server.dispatch(self.browser, 'browser_import_session', {'session': 'owned', 'expectedURL': url or self.url})

    def test_disabled_wrong_site_and_foreign_session_never_launch_helper(self):
        with patch('server.subprocess.run') as run:
            for url in ['https://evillinkedin.com/', 'https://linkedin.com.evil.test/']:
                with self.assertRaises(server.Rejected):
                    self.call(url)
            with self.assertRaises(server.Rejected):
                server.dispatch(self.browser, 'browser_import_session', {'session': 'foreign', 'expectedURL': self.url})
            self.policy.unlink()
            with self.assertRaises(server.Rejected):
                self.call()
            run.assert_not_called()

    def test_any_site_policy_in_browser_root_passes_exact_page_host(self):
        environment = self.root / 'environments' / 'fixture'
        browser = server.Browser(environment, rpc=Mock(), installation_root=self.root)
        browser.session, browser.page, browser.checkpoint = 'owned', 1, {'state': 'opened'}
        browser.expected, browser.chrome = self.browser.expected, self.browser.chrome
        self.policy.write_text(json.dumps({'site': '*', 'profile': 'Default'}))
        with patch.object(Path, 'is_file', return_value=True), patch('server.subprocess.run') as run:
            run.return_value = Mock(returncode=0, stdout=json.dumps(self.result).encode())
            url = 'https://Gist.GitHub.com/x'
            self.assertEqual(server.dispatch(browser, 'browser_import_session', {'session': 'owned', 'expectedURL': url}), self.result)
            self.assertEqual(run.call_args.args[0][3], 'gist.github.com')
            # The chat's own site policy wins over the shared wildcard.
            (environment / 'chrome-session-import.json').write_text(json.dumps({'site': 'linkedin.com', 'profile': 'Default'}))
            server.dispatch(browser, 'browser_import_session', {'session': 'owned', 'expectedURL': self.url})
            self.assertEqual(run.call_args.args[0][3], 'linkedin.com')

    def test_any_site_policy_rejects_hosts_without_domain(self):
        self.policy.write_text(json.dumps({'site': '*', 'profile': 'Default'}))
        with patch('server.subprocess.run') as run:
            for url in ['http://localhost:8080/', 'file:///etc/passwd']:
                with self.assertRaises(server.Rejected):
                    self.call(url)
            run.assert_not_called()

    def test_success_is_secret_free_and_not_reimported(self):
        with patch.object(Path, 'is_file', return_value=True), patch('server.subprocess.run') as run:
            run.return_value = Mock(returncode=0, stdout=json.dumps(self.result).encode())
            self.assertEqual(self.call(), self.result)
            self.browser.expected.assert_called_once_with(self.url)
            # Card reads replace the checkpoint; they must not reset import protection.
            self.browser.checkpoint = {"state": "cards"}
            with self.assertRaises(server.Rejected):
                self.call()
            run.assert_called_once()
            self.assertFalse(self.browser.failed)

    def test_timeout_and_uncertain_result_stop_without_replay(self):
        for outcome in [subprocess.TimeoutExpired('helper', 60), Mock(returncode=0, stdout=b'{"error":"unknown", "outcomeUnknown":true}')]:
            with self.subTest(outcome=type(outcome).__name__):
                self.browser.failed = False
                with patch.object(Path, 'is_file', return_value=True), patch('server.subprocess.run') as run:
                    if isinstance(outcome, Exception):
                        run.side_effect = outcome
                    else:
                        run.return_value = outcome
                    with self.assertRaises(server.Rejected):
                        self.call()
                    self.assertTrue(self.browser.failed)
                    with self.assertRaises(server.Rejected):
                        self.call()
                    run.assert_called_once()

    def test_preflight_failure_can_be_resolved_without_quarantine(self):
        with patch.object(Path, 'is_file', return_value=True), patch('server.subprocess.run') as run:
            run.return_value = Mock(returncode=0, stdout=b'{"error":"Chrome running", "outcomeUnknown":false}')
            with self.assertRaisesRegex(server.Rejected, 'Chrome running'):
                self.call()
            self.assertFalse(self.browser.failed)
            self.assertNotIn('importedSite', self.browser.checkpoint)

    def test_changed_page_never_launches_helper(self):
        self.browser.expected.side_effect = server.Rejected('page changed')
        with patch('server.subprocess.run') as run:
            with self.assertRaises(server.Rejected):
                self.call()
            run.assert_not_called()

    def test_catalog_has_both_languages(self):
        previous = server.LANGUAGE
        try:
            descriptions = []
            for language in ['ru', 'en']:
                server.LANGUAGE = language
                tool = next(t for t in server.catalog() if t['name'] == 'browser_import_session')
                self.assertFalse(tool['annotations']['readOnlyHint'])
                descriptions.append(tool['description'])
            self.assertNotEqual(*descriptions)
        finally:
            server.LANGUAGE = previous


if __name__ == '__main__':
    unittest.main()
