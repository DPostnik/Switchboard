import json
import tempfile
import unittest
from pathlib import Path

import server


class RolePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = self.root / 'environments' / 'e'
        self.environment.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def policy(self, **kwargs):
        return server.RolePolicy(roots=[self.environment, self.root], **kwargs)

    def rejected(self, policy, name, arguments):
        with self.assertRaises(server.Rejected):
            policy.check(name, arguments)

    def test_missing_flags_fail_closed(self):
        policy = self.policy()
        self.assertEqual(policy.hidden(), {'browser_eval'})
        self.rejected(policy, 'browser_eval', {'session': 's', 'expression': '1', 'expectedURL': 'https://a.example'})
        self.rejected(policy, 'browser_input', {'session': 's', 'action': 'upload', 'files': ['a']})
        self.rejected(policy, 'browser_action', {'session': 's', 'name': 'upload_file', 'arguments': {}})
        self.rejected(policy, 'browser_import_session', {'session': 's', 'expectedURL': 'https://www.linkedin.com/feed'})
        policy.check('browser_read', {'session': 's'})
        policy.check('browser_input', {'session': 's', 'action': 'click', 'ref': 'ref_1'})

    def test_operating_role_forwards_eval_and_upload(self):
        policy = self.policy(allow_eval=True, allow_upload=True, import_scope='any')
        self.assertEqual(policy.hidden(), set())
        policy.check('browser_eval', {'session': 's', 'expression': '1', 'expectedURL': 'https://a.example'})
        policy.check('browser_input', {'session': 's', 'action': 'upload', 'files': ['a']})
        policy.check('browser_import_session', {'session': 's', 'expectedURL': 'https://any.example.com/x'})

    def test_listed_scope_ignores_the_app_wide_any_site_setting(self):
        (self.root / 'chrome-session-import.json').write_text(json.dumps({'profile': 'Default', 'site': '*'}))
        (self.environment / 'chrome-session-import.json').write_text(json.dumps({'profile': 'Default', 'site': 'linkedin.com'}))
        policy = self.policy(import_scope='listed')
        policy.check('browser_import_session', {'session': 's', 'expectedURL': 'https://www.linkedin.com/feed'})
        self.rejected(policy, 'browser_import_session', {'session': 's', 'expectedURL': 'https://mail.google.com/'})
        self.rejected(policy, 'browser_import_session', {'session': 's', 'expectedURL': 'https://evil-linkedin.com/'})

    def test_listed_scope_skips_symlinked_or_oversized_policies(self):
        target = self.root / 'elsewhere.json'
        target.write_text(json.dumps({'site': 'google.com'}))
        (self.environment / 'chrome-session-import.json').symlink_to(target)
        (self.root / 'chrome-session-import.json').write_text(json.dumps({'site': 'google.com', 'pad': 'x' * 5000}))
        self.rejected(self.policy(import_scope='listed'), 'browser_import_session', {'session': 's', 'expectedURL': 'https://mail.google.com/'})

    def test_messages_have_both_languages(self):
        for language in ('ru', 'en'):
            server.LANGUAGE = language
            with self.assertRaises(server.Rejected) as caught:
                self.policy().check('browser_eval', {})
            self.assertTrue(str(caught.exception))
        server.LANGUAGE = 'en'


if __name__ == '__main__':
    unittest.main()
