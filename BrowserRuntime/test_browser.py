import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import hashlib
import base64
from unittest.mock import patch, Mock
import time
import unittest

import server
from server import Browser, Rejected, dispatch
from transport import StdioRPC, TransportError
import install


def envelope(value):
    return {'content': [{'type': 'text', 'text': 'Script ran on page and returned:\n```json\n' + json.dumps(value) + '\n```'}]}


class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.calls = []

        def rpc(name, args):
            self.calls.append((name, args))
            if name == 'evaluate_script':
                return envelope({'url': 'https://example.test/'})
            return {'content': [{'type': 'text', 'text': 'success'}]}
        self.browser = Browser(Path(self.directory.name), rpc=rpc)
        self.browser.session = 'owner'
        self.browser.page = 7
        self.browser.checkpoint = {'state': 'opened'}

    def tearDown(self):
        self.directory.cleanup()

    def test_open_preserves_visibility_without_replaying_uncertain_tab_creation(self):
        for hidden in (False, True):
            with self.subTest(hidden=hidden):
                browser = Browser(Path(self.directory.name), rpc=Mock(side_effect=TimeoutError('lost reply')))
                browser.chrome = Mock(owner={'pid': 123})
                browser.chrome.process_gone.return_value = False
                browser.chrome.visibility.return_value = hidden
                with self.assertRaises(TimeoutError):
                    browser.open('https://example.test/')
                browser.injected.assert_called_once()
                self.assertTrue(browser.failed)
                self.assertEqual(browser.chrome.visibility.call_count, 2 if hidden else 1)
                if hidden:
                    browser.chrome.visibility.assert_called_with({'pid': 123}, hide=True)
                with self.assertRaises(Rejected):
                    browser.open('https://example.test/')
                browser.injected.assert_called_once()

    def test_close_waits_for_inventory_without_replaying_action(self):
        inventories = iter(['## Pages\n7: https://example.test/', '## Pages\n1: about:blank'])
        def rpc(name, args):
            self.calls.append((name, args))
            return {'content': [{'type': 'text', 'text': next(inventories) if name == 'list_pages' else 'closed'}]}
        self.browser.injected = rpc
        self.assertEqual(self.browser.close_session('owner'), {'closed': True})
        self.assertEqual([n for n, _ in self.calls].count('close_page'), 1)
        self.assertEqual([n for n, _ in self.calls].count('list_pages'), 2)
        self.assertIsNone(self.browser.session)

    def test_kept_reason_names_hosts_and_never_blames_another_chat(self):
        browser = Browser(Path(self.directory.name), rpc=Mock())
        browser.chrome = Mock(owner={'pid': 123})
        server.save(browser.records / 'old.json', {'session': 'old', 'targetId': 'C' * 32, 'state': 'disconnected'})
        browser.chrome.page_targets.return_value = {
            'A' * 32: 'about:blank', 'B' * 32: 'https://www.pracuj.pl/praca/x?token=secret', 'C' * 32: 'https://linkedin.test/feed/'}
        kept = browser.kept_reason()
        self.assertEqual(kept['keptReason'], 'other_tabs')
        self.assertEqual(kept['keptTabs'], [{'host': 'www.pracuj.pl', 'openedBy': 'unknown'}, {'host': 'linkedin.test', 'openedBy': 'task'}])
        self.assertNotIn('secret', json.dumps(kept))
        self.assertEqual(browser.kept_reason(other_task=True)['keptReason'], 'other_task')
        browser.chrome.page_targets.return_value = None
        self.assertEqual(browser.kept_reason()['keptReason'], 'state_unknown')
        browser.chrome.close_target.assert_not_called()
        browser.chrome.graceful_close.assert_not_called()

    def test_idle_chrome_quits_once_only_when_blank_tabs_remain(self):
        owner = {'pid': 123}
        for targets, gone, expected in [
                ({'A' * 32: 'about:blank'}, [True, True], 'quit'),
                ({}, [False, True, True], 'quit'),
                ({'A' * 32: 'about:blank', 'B' * 32: 'https://indeed.test/'}, [True], 'kept'),
                (None, [True], 'kept'),
                ({'A' * 32: 'about:blank'}, [False] * 1000, 'quit_unconfirmed')]:
            with self.subTest(targets=targets, expected=expected):
                browser = Browser(Path(self.directory.name), rpc=Mock())
                chrome = browser.chrome = Mock(owner=owner)
                chrome.page_targets.return_value = targets
                chrome.process_gone.side_effect = gone
                self.assertEqual(browser.quit_idle_chrome(seconds=0.3), expected)
                self.assertEqual(chrome.graceful_close.call_count, 0 if expected == 'kept' else 1)
                if expected == 'quit':
                    self.assertIsNone(browser.chrome)
        # A live task tab, a failed executor or an unverified close never sends a second close.
        browser = Browser(Path(self.directory.name), rpc=Mock())
        browser.chrome = Mock(owner=owner)
        browser.chrome.page_targets.return_value = {}
        browser.session = 'owner'
        self.assertEqual(browser.quit_idle_chrome(), 'kept')
        browser.session, browser.failed = None, True
        self.assertEqual(browser.quit_idle_chrome(), 'kept')
        browser.failed = False
        browser.chrome.graceful_close.side_effect = server.Rejected('not verified')
        self.assertEqual(browser.quit_idle_chrome(), 'quit_unconfirmed')
        browser.chrome.process_gone.assert_not_called()
        browser.chrome.graceful_close.assert_called_once()

    def test_unconfirmed_close_stops_executor_without_replay(self):
        def rpc(name, args):
            self.calls.append((name, args))
            return {'content': [{'type': 'text', 'text': '## Pages\n7: https://example.test/'}]}
        self.browser.injected = rpc
        with self.assertRaisesRegex(Rejected, 'owned_page_close_not_confirmed'):
            self.browser.close_session('owner', confirmation_timeout=0)
        self.assertEqual(self.browser.checkpoint['state'], 'close_uncertain')
        with self.assertRaises(Rejected):
            self.browser.close_session('owner')
        self.assertEqual([n for n, _ in self.calls].count('close_page'), 1)

    def test_close_rejects_unconfirmed_inventory(self):
        with self.assertRaisesRegex(Rejected, 'page_inventory_not_confirmed'):
            self.browser.close_session('owner')
        self.assertTrue(self.browser.failed)
        self.assertEqual(self.browser.checkpoint['state'], 'close_uncertain')

    def test_scope_and_url_mismatch_prevent_dispatch(self):
        for token, url in [('other', 'https://example.test/'), ('owner', 'https://elsewhere.test/')]:
            with self.assertRaises(Rejected):
                self.browser.action(token, 'operation-01', url, 'click', {'uid': '1_1'})
        self.assertFalse(any(n == 'click' for n, _ in self.calls))
        with self.assertRaises(Rejected):
            self.browser.action('owner', 'operation-01', 'https://example.test/', 'click', {'pageId': 8})

    def test_action_id_is_durable_and_cannot_replay_after_restart(self):
        answer = self.browser.action('owner', 'operation-01', 'https://example.test/', 'click', {'uid': '1_1'})
        self.assertEqual(answer['verification'], 'required')
        original = self.browser.injected
        self.browser = Browser(Path(self.directory.name), rpc=original)
        self.browser.session, self.browser.page = 'owner', 7
        with self.assertRaises(Rejected):
            self.browser.action('owner', 'operation-01', 'https://example.test/', 'click', {'uid': '1_1'})
        self.assertEqual(sum(n == 'click' for n, _ in self.calls), 1)
        self.assertTrue(all(a.get('pageId') == 7 for n, a in self.calls))

    def test_uncertain_dispatch_is_recorded_and_stops_future_calls(self):
        original = self.browser.injected

        def timeout(name, args):
            if name == 'click':
                record = Path(self.directory.name) / 'records/action-operation-02.json'
                self.assertEqual(json.loads(record.read_text())['state'], 'outcome_unknown')
                raise TimeoutError('lost response')
            return original(name, args)
        self.browser.injected = timeout
        with self.assertRaises(TimeoutError):
            self.browser.action('owner', 'operation-02', 'https://example.test/', 'click', {'uid': '1_1'})
        self.assertTrue(self.browser.failed)
        with self.assertRaises(Rejected):
            self.browser.native('click', {'uid': '1_1', 'pageId': 7})

    def test_missing_page_invalidates_token_without_rebinding(self):
        self.browser.injected = lambda *args: {'isError': True, 'content': [{'type': 'text', 'text': 'Error: No page found'}]}
        with self.assertRaises(Rejected):
            self.browser.evaluate('() => 1')
        self.assertIsNone(self.browser.session)
        self.assertEqual(json.loads((Path(self.directory.name) / 'records/owner.json').read_text())['reason'], 'owned_page_missing')
        with self.assertRaises(Rejected):
            self.browser.owner('owner')
        self.assertFalse(self.browser.failed)

    def test_exit_before_action_never_dispatches_or_replays(self):
        host, transport = Mock(), Mock()
        host.process_gone.return_value = True
        self.browser.chrome, self.browser.transport = host, transport
        with self.assertRaises(Rejected):
            self.browser.native('click', {'pageId': 7, 'uid': '1_1'})
        self.assertEqual(self.calls, [])
        transport.close.assert_called_once()
        self.assertIsNone(self.browser.session)
        self.assertIsNone(self.browser.transport)
        self.assertFalse(self.browser.failed)

    def test_explicit_open_after_exit_creates_new_task(self):
        self.browser.chrome = Mock()
        self.browser.chrome.process_gone.return_value = True
        def rpc(name, args):
            self.calls.append((name, args))
            if name == 'new_page':
                return {'content': [{'type': 'text', 'text': '9: ' + args['url']}]}
            return envelope({'url': 'https://example.test/', 'readyState': 'complete'})
        self.browser.injected = rpc
        opened = self.browser.open('https://example.test/')
        self.assertNotEqual(opened['session'], 'owner')
        self.assertEqual(opened['pageId'], 9)
        self.assertEqual([name for name, _ in self.calls], ['new_page', 'navigate_page', 'evaluate_script'])

    def test_open_closes_only_verified_orphaned_tabs_once_and_records_new_target(self):
        browser = Browser(Path(self.directory.name))
        records = browser.records
        def record(name, **fields):
            server.save(records / name, {'session': name, 'pageId': 2, **fields})
        record('orphan.json', state='disconnected', outcomeUnknown=False, targetId='A' * 32)
        record('uncertain.json', state='disconnected', outcomeUnknown=True, targetId='B' * 32)
        record('live.json', state='navigated', targetId='C' * 32)
        record('gone.json', state='disconnected', outcomeUnknown=False, targetId='D' * 32)
        record('legacy.json', state='disconnected', outcomeUnknown=False)
        marker = []
        def rpc(name, args):
            if name == 'new_page':
                marker.append(args['url'])
                return {'content': [{'type': 'text', 'text': '9: ' + args['url']}]}
            return envelope({'url': 'https://example.test/', 'readyState': 'complete'})
        browser.injected = rpc
        browser.chrome = Mock(owner={'pid': 123})
        browser.chrome.process_gone.return_value = False
        browser.chrome.visibility.return_value = False
        browser.chrome.close_target.return_value = True
        browser.chrome.page_targets.side_effect = lambda owner: (
            {'A' * 32: 'https://framer.com/', 'B' * 32: 'https://x.test/', 'C' * 32: 'https://y.test/'}
            if not marker else {'E' * 32: marker[0], 'A' * 32: 'https://framer.com/'})
        opened = browser.open('https://example.test/')
        browser.chrome.close_target.assert_called_once_with({'pid': 123}, 'A' * 32)
        state = lambda name: json.loads((records / name).read_text())['state']
        self.assertEqual(state('orphan.json'), 'orphan_closed')
        self.assertEqual([state(n) for n in ('uncertain.json', 'live.json', 'gone.json', 'legacy.json')],
                         ['disconnected', 'navigated', 'disconnected', 'disconnected'])
        self.assertEqual(json.loads((records / (opened['session'] + '.json')).read_text())['targetId'], 'E' * 32)
        # A failed close is recorded and never retried by a later open.
        record('failing.json', state='disconnected', outcomeUnknown=False, targetId='F' * 32)
        browser.chrome.close_target.reset_mock(return_value=True)
        browser.chrome.close_target.return_value = False
        browser.chrome.page_targets.side_effect = lambda owner: {'F' * 32: 'https://framer.com/'}
        browser.session = browser.page = None
        browser.open('https://example.test/')
        browser.session = browser.page = None
        browser.open('https://example.test/')
        browser.chrome.close_target.assert_called_once_with({'pid': 123}, 'F' * 32)
        self.assertEqual(state('failing.json'), 'orphan_close_uncertain')

    def test_explicit_open_detects_user_closed_tab_without_adopting_other_tab(self):
        def rpc(name, args):
            self.calls.append((name, args))
            if name == 'list_pages':
                return {'content': [{'type': 'text', 'text': '## Pages\n8: https://other.test/'}]}
            if name == 'new_page':
                return {'content': [{'type': 'text', 'text': '9: ' + args['url']}]}
            return envelope({'url': 'https://example.test/', 'readyState': 'complete'})
        self.browser.injected = rpc
        self.assertEqual(self.browser.open('https://example.test/')['pageId'], 9)
        self.assertFalse(any(args.get('pageId') == 8 for _, args in self.calls))

    def test_explicit_open_keeps_live_owned_tab_busy(self):
        self.browser.injected = lambda *args: {'content': [{'type': 'text', 'text': '## Pages\n7: https://example.test/'}]}
        with self.assertRaises(Rejected):
            self.browser.open('https://example.test/')
        self.assertEqual(self.browser.session, 'owner')

    def test_ambiguous_failure_is_cleared_only_by_confirmed_chrome_exit(self):
        self.browser.failed = True
        self.browser.session = None
        self.browser.chrome = Mock(owner={'pid': 123})
        self.browser.chrome.process_gone.return_value = False
        with self.assertRaisesRegex(Rejected, 'browser_close'):
            self.browser.open('https://example.test/')
        self.assertTrue(self.browser.failed)
        self.assertEqual(self.calls, [])
        # Chrome exited (user Cmd+Q or browser_close): a new session may start.
        self.browser.chrome.process_gone.return_value = True
        self.browser.injected = lambda name, args: {'content': [{'type': 'text', 'text': '9: ' + args['url'] if name == 'new_page' else 'ok'}]} if name != 'evaluate_script' else envelope({'url': 'https://example.test/', 'readyState': 'complete'})
        self.assertEqual(self.browser.open('https://example.test/')['pageId'], 9)
        self.assertFalse(self.browser.failed)

    def test_close_after_failure_quits_chrome_once_and_reenables_open(self):
        self.browser.failed = True
        self.browser.checkpoint = {'state': 'navigated', 'url': 'https://example.test/'}
        chrome = self.browser.chrome = Mock(owner={'pid': 123})
        chrome.process_gone.side_effect = [False, False, True]
        self.browser.stopped.wait = lambda seconds: False
        with self.assertRaises(Rejected):
            server.dispatch(self.browser, 'browser_close', {'session': 'other'})
        with self.assertRaisesRegex(Rejected, 'другая задача|another task'):
            server.dispatch(self.browser, 'browser_close', {'session': 'owner'}, shared=True)
        chrome.graceful_close.assert_not_called()
        self.assertTrue(self.browser.failed)
        result = server.dispatch(self.browser, 'browser_close', {'session': 'owner'})
        self.assertEqual((result['closed'], result['browserQuit'], result['outcomeUnknown']), (True, 'quit', True))
        chrome.graceful_close.assert_called_once_with({'pid': 123})
        self.assertFalse(self.browser.failed)
        self.assertIsNone(self.browser.session)
        self.assertIsNone(self.browser.chrome)
        self.assertEqual(self.calls, [])  # No upstream tool call on a browser whose state is unknown.
        record = json.loads((Path(self.directory.name) / 'records/owner.json').read_text())
        self.assertEqual((record['state'], record['outcomeUnknown']), ('closed', True))

    def test_close_after_failure_without_owned_tab_accepts_any_session(self):
        # browser_open itself ended with an unknown outcome: failed, no session, no checkpoint.
        browser = Browser(Path(self.directory.name), rpc=Mock(side_effect=TimeoutError('lost reply')))
        chrome = browser.chrome = Mock(owner={'pid': 123})
        chrome.process_gone.return_value = False
        with self.assertRaises(TimeoutError):
            browser.open('https://example.test/')
        self.assertTrue(browser.failed)
        self.assertIsNone(browser.session)
        with self.assertRaisesRegex(Rejected, 'any session value|любым значением session'):
            browser.open('https://example.test/')
        chrome.process_gone.side_effect = [False, True]
        browser.stopped.wait = lambda seconds: False
        result = dispatch(browser, 'browser_close', {'session': 'stale-token'})
        self.assertEqual((result['closed'], result['browserQuit'], result['outcomeUnknown']), (True, 'quit', True))
        chrome.graceful_close.assert_called_once_with({'pid': 123})
        self.assertFalse(browser.failed)
        self.assertIsNone(browser.chrome)
        self.assertEqual(list(Path(self.directory.name).glob('records/*.json')), [])  # Nothing to record without a session.

    def test_close_after_failure_without_chrome_clears_failed_state(self):
        browser = Browser(Path(self.directory.name), rpc=Mock())
        browser.failed = True
        result = dispatch(browser, 'browser_close', {'session': 'any'})
        self.assertEqual((result['closed'], result['browserQuit']), (True, 'none'))
        self.assertFalse(browser.failed)
        browser.injected.assert_not_called()
        # An owned tab still requires its own token.
        browser.failed, browser.session, browser.page = True, 'owner', 7
        with self.assertRaisesRegex(Rejected, 'session_not_owned'):
            dispatch(browser, 'browser_close', {'session': 'other'})

    def test_close_after_failure_keeps_failed_state_when_exit_is_unconfirmed(self):
        self.browser.failed = True
        chrome = self.browser.chrome = Mock(owner={'pid': 123})
        chrome.process_gone.return_value = False
        self.browser.stopped.wait = lambda seconds: False
        with self.assertRaises(Rejected):
            self.browser.close_after_failure('owner', seconds=0.2)
        chrome.graceful_close.assert_called_once()
        self.assertTrue(self.browser.failed)
        self.assertEqual(self.browser.session, 'owner')
        chrome.graceful_close.side_effect = OSError('refused')
        chrome.graceful_close.reset_mock()
        with self.assertRaisesRegex(Rejected, 'refused'):
            self.browser.close_after_failure('owner', seconds=0.2)
        self.assertTrue(self.browser.failed)

    def observation(self, cards, **extra):
        return {'url': 'https://example.test/', 'cards': cards, 'placeholders': len(cards),
                'truncated': False, 'bottom': True, 'scroll': {'top': 0, 'height': 50, 'total': 50},
                'loading': False, 'empty': False, 'readyState': 'complete', 'next': 'unknown',
                'visibility': 'visible', **extra}

    def test_loading_shell_and_blank_placeholders_are_partial(self):
        for observation in [self.observation([]), self.observation([{'id': '1', 'title': ''}]),
                            self.observation([{'id': '1', 'title': 'Card'}], loading=True)]:
            self.browser.read = lambda *_, **kwargs: observation
            result = self.browser.cards('owner', {'card': '.card'}, 1)
            self.assertFalse(result['complete'])

    def test_delayed_card_metadata_is_not_lost(self):
        observations = [self.observation([{'id': '1', 'title': ''}]),
                        self.observation([{'id': '1', 'title': 'Loaded'}])]
        self.browser.read = lambda *_, **kwargs: observations.pop(0) if len(observations) > 1 else observations[0]
        result = self.browser.cards('owner', {'card': '.card'}, 2)
        self.assertTrue(result['complete'])
        self.assertEqual(result['cards'][0]['title'], 'Loaded')
        saved = json.loads((Path(self.directory.name) / 'records/owner.json').read_text())
        self.assertEqual(saved['state'], 'page_complete')

    def test_explicit_empty_and_truncation_have_distinct_results(self):
        self.browser.read = lambda *_, **kwargs: self.observation([], empty=True)
        self.assertEqual(self.browser.cards('owner', {'card': '.card'}, 1)['reason'], 'explicit_empty')
        self.browser.read = lambda *_, **kwargs: self.observation([{'id': '1', 'title': 'Card'}], truncated=True)
        self.assertFalse(self.browser.cards('owner', {'card': '.card'}, 1)['complete'])

    def test_pagination_noop_clicks_once_and_returns_partial(self):
        self.browser.read = lambda *_, **kwargs: self.observation([{'id': '1', 'title': 'Card'}])
        self.browser.cards('owner', {'card': '.card'}, 1)
        result = self.browser.next('owner', 'next-page-01', 'https://example.test/', '1_5', {'card': '.card'}, 1)
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'page_transition_not_observed')
        self.assertEqual(sum(n == 'click' for n, _ in self.calls), 1)

    def test_virtualized_subset_is_not_a_new_page(self):
        self.browser.read = lambda *_, **kwargs: self.observation([{'id': '1', 'title': 'Old card'}])
        result = self.browser.cards('owner', {'card': '.card'}, 1, baseline=['1', '2'])
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'page_transition_not_observed')

    def test_static_count_skips_scroll_only_with_hydrated_unique_cards(self):
        calls = []
        card = {'id': '1', 'title': 'Loaded', 'company': 'Employer'}
        def read(*args, **kwargs):
            calls.append(kwargs.get('advance'))
            return self.observation([card], bottom=False)
        self.browser.read = read
        result = self.browser.cards('owner', {'card': '.card', 'company': '.company'}, 1, expected_cards=1)
        self.assertTrue(result['complete'])
        self.assertEqual(result['reason'], 'stable_expected_cards')
        self.assertNotIn(True, calls)
        for rows in [[{**card, 'company': ''}], [card, card]]:
            calls.clear()
            def partial(*args, **kwargs):
                calls.append(kwargs.get('advance'))
                return self.observation(rows, bottom=False)
            self.browser.read = partial
            result = self.browser.cards('owner', {'card': '.card', 'company': '.company'}, 1, expected_cards=1)
            self.assertFalse(result['complete'])
            self.assertIn(True, calls)

    def test_static_mode_scrolls_while_loading_or_link_is_unhydrated(self):
        for extra, card in [({'loading': True}, {'id': '1', 'title': 'Card', 'url': 'https://example.test/job'}),
                            ({}, {'id': '1', 'title': 'Card', 'url': ''})]:
            advances = []
            def read(*args, **kwargs):
                advances.append(kwargs.get('advance'))
                return self.observation([card], bottom=False, **extra)
            self.browser.read = read
            result = self.browser.cards('owner', {'card': '.card', 'link': 'a'}, 1, expected_cards=1)
            self.assertFalse(result['complete'])
            self.assertIn(True, advances)

    def test_static_count_mismatch_uses_bottom_and_count_is_validated(self):
        self.browser.read = lambda *_, **kw: self.observation([{'id': '1', 'title': 'Loaded'}])
        result = self.browser.cards('owner', {'card': '.card'}, 1, expected_cards=20)
        self.assertEqual(result['reason'], 'stable_page_bottom')
        for count in [True, 0, 501, '20']:
            with self.assertRaises(Rejected):
                self.browser.cards('owner', {'card': '.card'}, 1, expected_cards=count)

    def test_next_token_revalidates_link_and_preserves_single_dispatch(self):
        link = {'url': 'https://example.test/?page=2', 'text': 'Next'}
        config = {'card': '.card', 'next': 'a.next'}
        self.browser.read = lambda *_, **kw: self.observation([{'id': '1', 'title': 'Card'}], nextLink=link)
        first = self.browser.cards('owner', config, 1)
        result = dispatch(self.browser, 'browser_next', {'session': 'owner', 'actionID': 'link-next-01',
            'expectedURL': 'https://example.test/', 'nextToken': first['nextToken'], 'selectors': config, 'timeout': 1})
        self.assertFalse(result['complete'])
        self.assertEqual(sum(n == 'navigate_page' for n, _ in self.calls), 1)
        self.assertFalse(any(n == 'take_snapshot' for n, _ in self.calls))
        with self.assertRaises(Rejected):
            self.browser.next('owner', 'link-next-02', 'https://example.test/', None, config, 1, first['nextToken'])

    def test_changed_link_and_wrong_token_never_navigate(self):
        config = {'card': '.card', 'next': 'a.next'}
        link = {'url': 'https://example.test/?page=2', 'text': 'Next'}
        self.browser.read = lambda *_, **kw: self.observation([{'id': '1', 'title': 'Card'}], nextLink=link)
        first = self.browser.cards('owner', config, 1)
        with self.assertRaises(Rejected):
            self.browser.next('owner', 'link-next-01', 'https://example.test/', None, config, 1, 'wrong')
        link['url'] = 'https://example.test/?page=3'
        # The checkpoint owns a separate serialized observation, as in real Chrome.
        self.browser.checkpoint['nextLink'] = {'url': 'https://example.test/?page=2', 'text': 'Next'}
        with self.assertRaises(Rejected):
            self.browser.next('owner', 'link-next-01', 'https://example.test/', None, config, 1, first['nextToken'])
        self.assertFalse(any(n == 'navigate_page' for n, _ in self.calls))

    def test_untrusted_arguments_do_not_escape_allowlist(self):
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'evaluate_script', {'function': 'evil()'})
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'browser_snapshot', {'session': 'owner', 'pageId': 1})
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'browser_open', {'url': 'javascript:alert(1)'})
        self.assertFalse(self.calls)

    def test_tool_copy_exists_in_both_languages(self):
        catalogs = []
        for language in ('ru', 'en'):
            server.LANGUAGE = language
            catalogs.append(server.catalog())
        self.assertEqual([x['name'] for x in catalogs[0]], [x['name'] for x in catalogs[1]])
        self.assertTrue(all(a['description'] != b['description'] for a, b in zip(*catalogs)))


class TransportTests(unittest.TestCase):
    def test_install_verification_rejects_changed_and_extra_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'package'
            package.mkdir()
            payload = package / 'file.js'
            payload.write_text('original')
            with tarfile.open(root / 'upstream.tgz', 'w:gz') as archive:
                archive.add(payload, arcname='package/file.js')
            checksum = base64.b64encode(hashlib.sha512((root / 'upstream.tgz').read_bytes()).digest()).decode()
            with patch.dict(install.LOCK, {'sha512': checksum}):
                install.verify(root)
                payload.write_text('changed')
                with self.assertRaises(ValueError):
                    install.verify(root)
                payload.write_text('original')
                (package / 'extra.js').write_text('extra')
                with self.assertRaises(ValueError):
                    install.verify(root)

    def test_packaged_server_handshake_and_unknown_request(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, str(Path(__file__).with_name('server.py')), '--root', directory, '--language', 'ru']
            transport = StdioRPC(command).start()
            try:
                info = transport.initialize_mcp(expected_server_version=server.VERSION)
                self.assertIn('browser_cards', info['tools'])
                self.assertIn('browser_next', info['tools'])
                self.assertFalse((Path(directory) / 'profile').exists())
                # A stale/other task cancellation cannot terminate this executor.
                transport.notify('notifications/cancelled', {'requestId': 'already-completed'})
                with self.assertRaises(TransportError):
                    transport.rpc('sampling/createMessage', {}, 'unsupported', time.monotonic_ns() + 1_000_000_000)
                result = transport.rpc('ping', {}, 'ping', time.monotonic_ns() + 1_000_000_000)
                self.assertEqual(result, {})
            finally:
                transport.close()

    def test_timeout_latches_transport_and_does_not_replay(self):
        code = 'import sys,time; sys.stdin.readline(); time.sleep(5)'
        transport = StdioRPC([sys.executable, '-c', code]).start()
        try:
            with self.assertRaises(TimeoutError):
                transport.rpc('tools/call', {}, '1', time.monotonic_ns() + 100_000_000)
            with self.assertRaises(TransportError):
                transport.rpc('tools/call', {}, '2', time.monotonic_ns() + 100_000_000)
        finally:
            transport.close(grace_seconds=0.1)

    def test_unknown_upstream_request_fails_closed(self):
        code = 'import sys,json,time; sys.stdin.readline(); print(json.dumps({"jsonrpc":"2.0","id":"request","method":"sampling/createMessage"}),flush=True); sys.stdin.readline(); time.sleep(1)'
        transport = StdioRPC([sys.executable, '-c', code]).start()
        try:
            with self.assertRaises(TransportError):
                transport.rpc('initialize', {}, '1', time.monotonic_ns() + 1_000_000_000)
            self.assertEqual(transport.denied_server_messages[0]['method'], 'sampling/createMessage')
        finally:
            transport.close(grace_seconds=0.1)


if __name__ == '__main__':
    unittest.main()
