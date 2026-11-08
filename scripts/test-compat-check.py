"""Decision checks for compat-check.py; pure, no processes, network or files outside the repository sources."""
import datetime
import runpy
import tempfile
import json
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('compat_check', Path(__file__).with_name('compat-check.py'))
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)

NOW = datetime.datetime(2026, 11, 2, 3, 40, tzinfo=datetime.timezone.utc)
VERIFIED = {'codex': ['0.158.0-alpha.2.1', '0.159.0', '0.160.0'], 'claude': ['2.1.292'], 'gemini': ['0.66.0']}


class CompatCheckTests(unittest.TestCase):
    def test_candidate_must_pass_every_live_scenario_on_its_first_run(self):
        trial = runpy.run_path(str(Path(__file__).with_name('codex-candidate.py')))
        required, passed = trial['REQUIRED'], trial['passed']
        rows = [f'✔ Test {name}() passed after 0.6 seconds.' for name in required]
        self.assertTrue(passed('\n'.join(rows), 0))
        self.assertFalse(passed('\n'.join(rows[:-1]), 0))
        self.assertFalse(passed('\n'.join(rows + ['FLAKY']), 0))
        self.assertFalse(passed('\n'.join(rows), 1))

    def test_receipt_is_bound_to_the_selected_binary_and_reported_version(self):
        trial = runpy.run_path(str(Path(__file__).with_name('codex-candidate.py')))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            install = root / 'tested'
            install.mkdir()
            (root / 'bin').symlink_to(install)
            exe = install / 'codex'
            exe.write_bytes(b'original')
            (install / trial['RECEIPT']).write_text(json.dumps(dict(version='1.2.3', sha256=trial['sha'](exe))))
            self.assertTrue(trial['verified_active'](root, '1.2.3'))
            self.assertFalse(trial['verified_active'](root, '1.2.4'))
            exe.write_bytes(b'replaced')
            self.assertFalse(trial['verified_active'](root, '1.2.3'))

    def test_policy_matches_the_app(self):
        self.assertEqual(compat.classify('0.160.0', VERIFIED['codex']), 'verified')
        self.assertEqual(compat.classify('0.160.4', VERIFIED['codex']), 'same-minor')
        self.assertEqual(compat.classify('0.158.1', VERIFIED['codex']), 'same-minor')
        self.assertEqual(compat.classify('0.161.0', VERIFIED['codex']), 'unsupported')
        self.assertEqual(compat.classify('0.160.00', VERIFIED['codex']), 'unsupported')
        self.assertEqual(compat.classify('2.1.316', VERIFIED['claude']), 'same-minor')
        self.assertEqual(compat.classify('2.2.0', VERIFIED['claude']), 'unsupported')
        self.assertEqual(compat.classify(None, VERIFIED['claude']), 'missing')

    def test_verified_versions_are_read_from_the_sources(self):
        verified = compat.verified_versions(compat.ROOT)
        self.assertIn('0.160.0', verified['codex'])
        self.assertEqual(len(verified['claude']), 1)
        self.assertEqual(verified['gemini'], ['0.66.0'])

    def test_gemini_versions_follow_the_same_policy(self):
        self.assertEqual(compat.classify('0.66.3', VERIFIED['gemini']), 'same-minor')
        self.assertEqual(compat.classify('0.67.0', VERIFIED['gemini']), 'unsupported')
        self.assertEqual(compat.AGENTS['gemini']['version'].match('0.66.0')[1], '0.66.0')
        self.assertIsNone(compat.AGENTS['gemini']['version'].match('gemini 0.66.0'))
        line, findings, _ = compat.evaluate({}, VERIFIED, {'gemini': '0.66.1'}, {}, lambda a, v: 'passed', NOW)
        self.assertIn('gemini 0.66.1 same-minor, live tests passed', line)

    def test_live_tests_run_once_per_new_unverified_version(self):
        calls = []
        def live(agent, version):
            calls.append((agent, version)); return 'passed'
        state = {}
        line, findings, state = compat.evaluate(state, VERIFIED, {'codex': '0.160.0', 'claude': '2.1.293'}, {}, live, NOW)
        self.assertEqual(calls, [('claude', '2.1.293')])
        self.assertTrue(line.startswith('ok '), line)
        self.assertEqual([k for k, _ in findings], ['claude:2.1.293:passed'])
        _, _, state = compat.evaluate(state, VERIFIED, {'codex': '0.160.0', 'claude': '2.1.293'}, {}, live, NOW)
        self.assertEqual(len(calls), 1)

    def test_failures_and_unsupported_versions_need_attention(self):
        line, findings, _ = compat.evaluate({}, VERIFIED, {'codex': '0.160.2', 'claude': '2.2.0'}, {}, lambda a, v: 'failed', NOW)
        self.assertTrue(line.startswith('attention '), line)
        self.assertIn('codex:0.160.2:failed', [k for k, _ in findings])
        self.assertIn('claude:2.2.0:unsupported', [k for k, _ in findings])

    def test_without_live_tests_nothing_is_recorded_as_checked(self):
        line, findings, state = compat.evaluate({}, VERIFIED, {'codex': '0.160.2', 'claude': None}, {}, None, NOW)
        self.assertIn('live tests not run', line)
        self.assertIn('claude not installed', line)
        self.assertEqual(state['checked'].get('codex', {}), {})
        self.assertEqual(findings, [])

    def test_published_versions_on_another_branch_are_reported_once_per_branch(self):
        latest = {'codex': '0.166.0', 'claude': '2.1.316'}
        line, findings, _ = compat.evaluate({}, VERIFIED, {'codex': '0.160.0', 'claude': '2.1.292'}, latest, None, NOW)
        self.assertTrue(line.startswith('ok '), line)
        self.assertIn('latest 0.166.0 (unsupported)', line)
        self.assertIn('latest 2.1.316 (same-minor)', line)
        self.assertEqual([k for k, _ in findings], ['codex:published:0.166'])


if __name__ == '__main__':
    unittest.main()
