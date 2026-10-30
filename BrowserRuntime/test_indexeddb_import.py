"""Agent-triggered IndexedDB transfer: request recording and the pre-launch clone. Never touches personal Chrome."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import server


class IndexedDBRequestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.browser = server.Browser(self.root, rpc=Mock())
        self.browser.session, self.browser.page, self.browser.checkpoint = 'owned', 1, {'state': 'opened'}
        self.browser.expected = Mock()
        self.consent = self.root / 'chrome-indexeddb-import.json'
        self.consent.write_text(json.dumps({'site': 'linkedin.com', 'profile': 'Default'}))
        self.url = 'https://www.linkedin.com/feed'

    def tearDown(self):
        self.temp.cleanup()

    def marker(self):
        return self.root / 'indexeddb-import-pending.json'

    def call(self, url=None):
        return server.dispatch(self.browser, 'browser_import_indexeddb', {'session': 'owned', 'expectedURL': url or self.url})

    def test_records_marker_and_returns_instruction(self):
        out = self.call()
        # IndexedDB is per exact origin, so the request records the full page host the grant covers.
        self.assertEqual(out['pendingIndexedDB'], 'www.linkedin.com')
        self.assertEqual(out['nextStep'], 'close_then_open')
        self.assertEqual(json.loads(self.marker().read_text())['site'], 'www.linkedin.com')
        self.browser.expected.assert_called_once_with(self.url)

    def test_rejects_without_consent_wrong_site_or_foreign_session(self):
        for url in ['https://evil.com/', 'https://linkedin.com.evil.test/', 'http://localhost:8080/']:
            with self.assertRaises(server.Rejected):
                self.call(url)
        with self.assertRaises(server.Rejected):
            server.dispatch(self.browser, 'browser_import_indexeddb', {'session': 'foreign', 'expectedURL': self.url})
        self.consent.unlink()
        with self.assertRaises(server.Rejected):
            self.call()
        # No request was recorded for any rejected call.
        self.assertFalse(self.marker().exists())


class IndexedDBApplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.browser = server.Browser(self.root, rpc=Mock())

    def tearDown(self):
        self.temp.cleanup()

    def marker(self):
        return self.root / 'indexeddb-import-pending.json'

    def ok_result(self):
        return Mock(returncode=0, stdout=json.dumps(
            {'storeName': 'https_linkedin.com_0.indexeddb.leveldb', 'copiedBytes': 10, 'blobCopied': False,
             'websiteSignInVerified': False}).encode())

    def test_runs_helper_when_chrome_closed_and_consumes_marker(self):
        self.marker().write_text(json.dumps({'site': 'linkedin.com'}))
        with patch.object(Path, 'is_file', return_value=True), patch('server.subprocess.run') as run:
            run.return_value = self.ok_result()
            self.browser.apply_pending_indexeddb()
            run.assert_called_once()
            self.assertEqual(run.call_args.args[0][1], '--browser-import-indexeddb')
            self.assertEqual(run.call_args.args[0][3], 'linkedin.com')
        self.assertFalse(self.marker().exists())

    def test_refuses_when_chrome_running_and_keeps_marker(self):
        self.marker().write_text(json.dumps({'site': 'linkedin.com'}))
        (self.root / 'testing-chrome-owner.json').write_text(json.dumps({'pid': 1, 'birth': 'x'}))
        self.browser.chrome = Mock(process_gone=Mock(return_value=False))
        with patch('server.subprocess.run') as run:
            with self.assertRaises(server.Rejected):
                self.browser.apply_pending_indexeddb()
            run.assert_not_called()
        self.assertTrue(self.marker().exists())

    def test_invalid_marker_removed_without_running_helper(self):
        self.marker().write_text('not-json')
        with patch('server.subprocess.run') as run:
            self.browser.apply_pending_indexeddb()
            run.assert_not_called()
        self.assertFalse(self.marker().exists())

    def test_helper_error_surfaces_and_marker_consumed(self):
        self.marker().write_text(json.dumps({'site': 'linkedin.com'}))
        with patch.object(Path, 'is_file', return_value=True), patch('server.subprocess.run') as run:
            run.return_value = Mock(returncode=0, stdout=json.dumps({'error': 'no store here'}).encode())
            with self.assertRaisesRegex(server.Rejected, 'no store here'):
                self.browser.apply_pending_indexeddb()
        self.assertFalse(self.marker().exists())

    def test_no_marker_does_nothing(self):
        with patch('server.subprocess.run') as run:
            self.browser.apply_pending_indexeddb()
            run.assert_not_called()


class IndexedDBRolePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = self.root / 'environments' / 'e'
        self.environment.mkdir(parents=True)
        (self.environment / 'chrome-indexeddb-import.json').write_text(json.dumps({'profile': 'Default', 'site': 'linkedin.com'}))

    def tearDown(self):
        self.temp.cleanup()

    def policy(self, **kwargs):
        return server.RolePolicy(roots=[self.environment, self.root], **kwargs)

    def test_requires_scope_and_explicit_per_site_consent(self):
        allowed = {'session': 's', 'expectedURL': 'https://www.linkedin.com/feed'}
        other = {'session': 's', 'expectedURL': 'https://mail.google.com/'}
        with self.assertRaises(server.Rejected):
            self.policy(import_scope='none').check('browser_import_indexeddb', allowed)
        # Even an "any" role needs an explicit IndexedDB grant naming the exact site.
        self.policy(import_scope='any').check('browser_import_indexeddb', allowed)
        with self.assertRaises(server.Rejected):
            self.policy(import_scope='any').check('browser_import_indexeddb', other)
        self.policy(import_scope='listed').check('browser_import_indexeddb', allowed)
        with self.assertRaises(server.Rejected):
            self.policy(import_scope='listed').check('browser_import_indexeddb', other)


class IndexedDBCatalogTests(unittest.TestCase):
    def test_catalog_has_both_languages(self):
        previous = server.LANGUAGE
        try:
            descriptions = []
            for language in ('ru', 'en'):
                server.LANGUAGE = language
                tool = next(t for t in server.catalog() if t['name'] == 'browser_import_indexeddb')
                self.assertFalse(tool['annotations']['readOnlyHint'])
                descriptions.append(tool['description'])
            self.assertNotEqual(*descriptions)
        finally:
            server.LANGUAGE = previous


if __name__ == '__main__':
    unittest.main()
