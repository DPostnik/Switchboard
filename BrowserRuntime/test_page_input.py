import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
import unittest

import cdp
import page_input
import server
from server import Browser, Rejected, dispatch

# Smallest JPEG header carrying a 640x400 start-of-frame marker.
JPEG = b'\xff\xd8\xff\xe0\x00\x04\x00\x00\xff\xc0\x00\x0b\x08\x01\x90\x02\x80\x01\x01\x11\x00\xff\xd9'


class FakePage:
    def __init__(self, url='https://example.test/', fail_on=None):
        self.url, self.fail_on = url, fail_on
        self.sent = []
        self.closed = 0
        self.model = {'quiet': {'armed': True, 'idleMs': 1000}}  # op -> page_tree.js result
        self.requests = []
        self.events = []
        self.queued = []  # Events delivered by poll(), in order.
        self.dialog = None  # A showing dialog: its opening event waits in the buffer once.
        self.socket = object()
        self.page_enabled = False
        self.opens_dialog = None  # Dialog opened by a mouse press (its reply never comes).

    def poll(self, timeout):
        if self.dialog and not self.dialog.get('delivered'):
            self.dialog['delivered'] = True
            return {'method': 'Page.javascriptDialogOpening', 'params': self.dialog}
        # Queued events model the page's reaction, so they arrive only after input.
        if self.queued and any(m.startswith('Input.') for m, _ in self.sent):
            return self.queued.pop(0)
        time.sleep(min(timeout, 0.005))
        return None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.closed += 1

    def send(self, method, params=None, seconds=None, interrupt=None, session=None):
        self.sent.append((method, params))
        if self.opens_dialog and method == 'Input.dispatchMouseEvent' and params['type'] == 'mousePressed':
            event = {'method': 'Page.javascriptDialogOpening', 'params': self.opens_dialog}
            self.events.append(event)
            return {'interrupted': event}
        if method == self.fail_on:
            raise getattr(self, 'fail_error', None) or cdp.CDPTransportError('cdp_connection_lost_outcome_may_be_unknown')
        if method == 'Page.handleJavaScriptDialog':
            if not self.dialog:
                raise cdp.CDPError('No dialog is showing')
            self.dialog = None
        if method == 'Page.getNavigationHistory':
            return {'currentIndex': 0, 'entries': [{'url': self.url}]}
        if method == 'Page.getFrameTree':
            return {'frameTree': {'frame': {'id': 'MAIN'}}}
        if method == 'Runtime.evaluate':
            if params['expression'] == 'devicePixelRatio':
                return {'result': {'value': 2}}
            if params['expression'].startswith('(' + server.PAGE_TREE):
                request = json.loads(params['expression'][len(server.PAGE_TREE) + 3:-1])
                request.pop('floor', None)
                self.requests.append(request)
                return {'result': {'value': self.model.get(request['op'], {})}}
            return {'result': {'value': {'url': self.url, 'title': 'Fixture', 'readyState': 'complete'}}}
        if method == 'Page.getLayoutMetrics':
            return {'cssVisualViewport': {'clientWidth': 1280, 'clientHeight': 800, 'pageX': 0, 'pageY': 40}}
        if method == 'Page.captureScreenshot':
            return {'data': base64.b64encode(JPEG).decode()}
        return {}


class HelperTests(unittest.TestCase):
    def test_capture_scale_bounds_longer_side(self):
        self.assertEqual(page_input.capture_scale(1280, 800, 2), 0.5)
        self.assertEqual(page_input.capture_scale(600, 400, 1), 1.0)
        self.assertAlmostEqual(page_input.capture_scale(800, 3000, 1) * 3000, 1280)

    def test_coordinates_map_back_and_reject_outside(self):
        viewport = {'imageWidth': 640, 'imageHeight': 400, 'cssWidth': 1280, 'cssHeight': 800}
        self.assertEqual(page_input.to_css((320, 100), viewport), (640, 200))
        self.assertIsNone(page_input.to_css((641, 10), viewport))
        self.assertIsNone(page_input.to_css((True, 10), viewport))
        self.assertIsNone(page_input.to_css((None, 10), viewport))

    def test_key_combos(self):
        down, up = page_input.key_events('Enter')
        self.assertEqual((down['type'], down['text'], down['windowsVirtualKeyCode']), ('keyDown', '\r', 13))
        self.assertEqual(up['type'], 'keyUp')
        down, _ = page_input.key_events('cmd+a')
        self.assertEqual((down['type'], down['modifiers'], down['commands']), ('rawKeyDown', 4, ['selectAll']))
        self.assertNotIn('text', down)
        down, _ = page_input.key_events('shift+Tab')
        self.assertEqual((down['key'], down['modifiers']), ('Tab', 8))
        self.assertEqual(page_input.key_events('shift+a')[0]['text'], 'A')
        self.assertEqual(page_input.key_events('+')[0]['key'], '+')
        for invalid in ('', 'hyper+a', 'cmd+cmd+a', 'F13', 'Ä', 'x' * 41):
            self.assertIsNone(page_input.key_events(invalid), invalid)

    def test_mouse_sequences(self):
        click = page_input.mouse_events('click', (5, 6))
        self.assertEqual([e['type'] for e in click], ['mouseMoved', 'mousePressed', 'mouseReleased'])
        double = page_input.mouse_events('double_click', (5, 6))
        self.assertEqual([e.get('clickCount') for e in double if e['type'] == 'mousePressed'], [1, 2])
        self.assertEqual(page_input.mouse_events('right_click', (1, 1))[1]['button'], 'right')
        drag = page_input.mouse_events('drag', (0, 0), (80, 40))
        self.assertEqual((drag[1]['type'], drag[-1]['type'], drag[-1]['x'], drag[-1]['y']), ('mousePressed', 'mouseReleased', 80, 40))
        wheel = page_input.mouse_events('scroll', (3, 4), delta=(0, 600))[-1]
        self.assertEqual((wheel['type'], wheel['deltaY']), ('mouseWheel', 600))

    def test_jpeg_size(self):
        self.assertEqual(cdp.jpeg_size(JPEG), (640, 400))
        self.assertIsNone(cdp.jpeg_size(b'\x89PNG'))


class BrowserInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.browser = Browser(Path(self.directory.name), rpc=lambda *_: {'content': []})
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.browser.page_session_factory = lambda: self.page
        self.browser.stopped.wait = lambda seconds: False

    def tearDown(self):
        self.directory.cleanup()

    def inputs(self):
        return [p for m, p in self.page.sent if m.startswith('Input.')]

    def test_screenshot_returns_image_and_mapping(self):
        result = self.browser.screenshot('owner')
        capture = next(p for m, p in self.page.sent if m == 'Page.captureScreenshot')
        self.assertEqual(capture['clip'], {'x': 0, 'y': 40, 'width': 1280, 'height': 800, 'scale': 0.5})
        self.assertEqual((result['width'], result['height'], result['url']), (640, 400, 'https://example.test/'))
        blocks = server.content(result)
        self.assertEqual([b['type'] for b in blocks], ['text', 'image'])
        self.assertNotIn('_image', json.loads(blocks[0]['text']))
        with self.assertRaises(Rejected):
            self.browser.screenshot('other')

    def test_click_maps_screenshot_pixels_and_journals_once(self):
        with self.assertRaises(Rejected):  # Coordinates need a screenshot first.
            self.browser.input('owner', 'click', expected_url='https://example.test/', x=10, y=10)
        self.assertEqual(self.inputs(), [])
        self.browser.screenshot('owner')
        result = self.browser.input('owner', 'click', 'click-000001', 'https://example.test/', x=320, y=100)
        pressed = [p for p in self.inputs() if p['type'] == 'mousePressed']
        self.assertEqual([(p['x'], p['y']) for p in pressed], [(640, 200)])
        self.assertEqual(result['actionID'], 'click-000001')
        record = json.loads((Path(self.directory.name) / 'records/action-click-000001.json').read_text())
        self.assertEqual(record['state'], 'dispatched_observe_result')
        before = len(self.page.sent)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', 'click-000001', 'https://example.test/', x=320, y=100)
        self.assertFalse([m for m, _ in self.page.sent[before:] if m.startswith('Input.')])

    def test_only_risky_actions_need_expected_url(self):
        self.browser.screenshot('owner')
        self.browser.input('owner', 'click', x=1, y=1)  # Plain in-page click.
        self.browser.input('owner', 'type', text='x')
        self.browser.input('owner', 'key', key='Tab')
        self.page.model['classify'] = {'risk': 'submit'}
        sent = len(self.inputs())
        for action in ('click', 'key'):
            with self.assertRaises(Rejected) as raised:
                self.browser.input('owner', action, x=1, y=1, key='Enter')
            self.assertIn('expectedURL', str(raised.exception))
        result = self.browser.input('owner', 'click', 'submit-0001', 'https://example.test/', x=1, y=1)
        self.assertEqual(result['risk'], 'submit')
        self.assertIn('verification', result)
        self.page.model['classify'] = {'risk': 'upload'}
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', expected_url='https://example.test/', x=1, y=1)
        self.assertEqual(len(self.inputs()), sent + 3)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', expected_url='https://other.test/', x=1, y=1)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', expected_url='https://example.test/', x=641, y=1)

    def test_scroll_and_hover_do_not_need_url_and_scroll_invalidates_mapping(self):
        self.browser.screenshot('owner')
        self.browser.input('owner', 'hover', x=10, y=10)
        self.browser.input('owner', 'scroll', delta_y=500)
        wheel = [p for p in self.inputs() if p['type'] == 'mouseWheel'][0]
        self.assertEqual((wheel['x'], wheel['y'], wheel['deltaY']), (640, 400, 500))
        self.assertIsNone(self.browser.viewport)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'scroll', delta_y=0)

    def test_key_and_type(self):
        self.browser.input('owner', 'key', expected_url='https://example.test/', key='cmd+a')
        self.browser.input('owner', 'type', expected_url='https://example.test/', text='hello')
        self.assertIn(('Input.insertText', {'text': 'hello'}), self.page.sent)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'key', expected_url='https://example.test/', key='nope+x')

    def test_lost_dispatch_records_unknown_outcome_without_replay_and_keeps_tab_usable(self):
        self.browser.screenshot('owner')
        self.page.fail_on = 'Input.dispatchMouseEvent'
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'click', 'click-000002', 'https://example.test/', x=1, y=1)
        self.assertIn('no_replay', str(raised.exception))
        self.assertIn('browser_read', str(raised.exception))
        # The action is unknown, the browser is not: no app restart is needed to observe the page.
        self.assertTrue(self.browser.uncertain)
        self.assertFalse(self.browser.failed)
        record = json.loads((Path(self.directory.name) / 'records/action-click-000002.json').read_text())
        self.assertEqual(record['state'], 'outcome_unknown')
        self.assertEqual(len([m for m, _ in self.page.sent if m.startswith('Input.')]), 1)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', 'click-000002', 'https://example.test/', x=1, y=1)
        self.assertEqual(len([m for m, _ in self.page.sent if m.startswith('Input.')]), 1)
        self.assertEqual(self.browser.screenshot('owner')['width'], 640)

    def test_wait_and_screenshot_flag(self):
        result = self.browser.input('owner', 'wait', seconds=1, screenshot=True)
        self.assertEqual(result['width'], 640)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'wait', seconds=30)

    def test_dispatch_schema(self):
        names = [t['name'] for t in server.catalog()]
        self.assertIn('browser_screenshot', names)
        self.assertIn('browser_input', names)
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'browser_input', {'session': 'owner', 'action': 'click', 'selector': '#x'})
        self.assertEqual(dispatch(self.browser, 'browser_screenshot', {'session': 'owner'})['height'], 400)


class RefInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.browser = Browser(Path(self.directory.name), rpc=lambda *_: {'content': []})
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.page.model['resolve'] = {'x': 100.5, 'y': 40, 'scrolled': False, 'obscuredBy': None}
        self.browser.page_session_factory = lambda: self.page
        self.browser.stopped.wait = lambda seconds: False
        self.url = 'https://example.test/'

    def tearDown(self):
        self.directory.cleanup()

    def inputs(self):
        return [(m, p) for m, p in self.page.sent if m.startswith('Input.')]

    def records(self):
        return sorted((Path(self.directory.name) / 'records').glob('action-*.json'))

    def test_read_validates_and_marks_untrusted(self):
        self.page.model['read'] = {'kind': 'page_tree', 'tree': '- button "Go" [ref_1]', 'truncated': True}
        result = self.browser.read('owner', filter='interactive', max_chars=5000)
        self.assertEqual(self.page.requests[-1], {'op': 'read', 'mode': 'tree', 'filter': 'interactive', 'ref': None, 'depth': 60, 'maxChars': 5000})
        self.assertEqual((result['content'], bool(result['hint'])), ('untrusted_page_data', True))
        for bad in ({'mode': 'html'}, {'filter': 'some'}, {'ref': 'x'}, {'depth': 0}, {'max_chars': 999}):
            with self.assertRaises(Rejected):
                self.browser.read('owner', **bad)
        self.page.model['read'] = {'error': 'stale_ref'}
        with self.assertRaises(Rejected):
            self.browser.read('owner', ref='ref_9')

    def test_click_by_ref_needs_no_screenshot(self):
        result = self.browser.input('owner', 'click', 'click-ref-001', self.url, ref='ref_3')
        pressed = [p for m, p in self.inputs() if p['type'] == 'mousePressed']
        self.assertEqual([(p['x'], p['y']) for p in pressed], [(100.5, 40)])
        self.assertEqual(result['actionID'], 'click-ref-001')
        self.assertEqual(self.page.requests[0], {'op': 'resolve', 'ref': 'ref_3', 'focus': False})

    def test_stale_or_covered_ref_dispatches_nothing_and_writes_no_record(self):
        self.page.model['resolve'] = {'error': 'stale_ref'}
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'click', expected_url=self.url, ref='ref_3')
        self.assertIn('Stale', str(raised.exception))
        self.page.model['resolve'] = {'x': 1, 'y': 1, 'obscuredBy': 'dialog "Cookies"'}
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'click', expected_url=self.url, ref='ref_3')
        self.assertIn('Cookies', str(raised.exception))
        self.assertEqual((self.inputs(), self.records()), ([], []))
        self.browser.input('owner', 'hover', ref='ref_3')  # Hover may land on the cover.
        self.assertEqual(len(self.inputs()), 1)

    def test_scrolling_into_view_drops_screenshot_mapping(self):
        self.browser.screenshot('owner')
        self.page.model['resolve'] = {'x': 5, 'y': 5, 'scrolled': True}
        self.browser.input('owner', 'click', expected_url=self.url, ref='ref_3')
        self.assertIsNone(self.browser.viewport)

    def test_drag_between_refs_and_mixed_targets(self):
        self.browser.input('owner', 'drag', expected_url=self.url, ref='ref_1', to_ref='ref_2')
        self.assertEqual([r['ref'] for r in self.page.requests if r['op'] == 'resolve'], ['ref_1', 'ref_2'])
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', expected_url=self.url, ref='ref_1', x=1, y=1)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'drag', expected_url=self.url, ref='ref_1', to_ref='ref_2', to_x=1, to_y=1)

    def test_type_by_ref_focuses_first(self):
        self.browser.input('owner', 'type', expected_url=self.url, ref='ref_4', text='hi')
        self.assertEqual(self.page.requests[0]['focus'], True)
        self.assertEqual(self.inputs(), [('Input.insertText', {'text': 'hi'})])

    def test_select_journals_and_reports_options(self):
        self.page.model['select'] = {'selected': 'Large'}
        self.browser.input('owner', 'select', 'select-0001', self.url, ref='ref_5', value='Large')
        self.assertIn({'op': 'select', 'ref': 'ref_5', 'value': 'Large'}, self.page.requests)
        self.assertEqual(json.loads(self.records()[0].read_text())['state'], 'dispatched_observe_result')
        self.page.model['select'] = {'error': 'option_not_found', 'options': ['Small', 'Large']}
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'select', 'select-0002', self.url, ref='ref_5', value='Huge')
        self.assertIn('Small, Large', str(raised.exception))
        self.assertFalse(self.browser.failed)
        states = [json.loads(r.read_text())['state'] for r in self.records()]
        self.assertIn('not_applied', states)
        for bad in ({'value': None}, {'ref': None, 'value': 'x'}):
            with self.assertRaises(Rejected):
                self.browser.input('owner', 'select', expected_url=self.url, **{'ref': 'ref_5', **bad})

    def test_scroll_to_is_not_journaled(self):
        result = self.browser.input('owner', 'scroll_to', ref='ref_7')
        self.assertEqual((self.inputs(), self.records()), ([], []))
        self.assertNotIn('actionID', result)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'scroll_to')

    def test_catalog_lists_read(self):
        tool = next(t for t in server.catalog() if t['name'] == 'browser_read')
        self.assertTrue(tool['annotations']['readOnlyHint'])
        self.page.model['read'] = {'kind': 'page_text', 'text': 'Body'}
        self.assertEqual(dispatch(self.browser, 'browser_read', {'session': 'owner', 'mode': 'text'})['text'], 'Body')


class SettleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.browser = Browser(Path(self.directory.name), rpc=lambda *_: {'content': []})
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.page.model['resolve'] = {'x': 10, 'y': 10}
        self.browser.page_session_factory = lambda: self.page
        self.browser.stopped.wait = lambda seconds: False
        self.url = 'https://example.test/'

    def tearDown(self):
        self.directory.cleanup()

    def test_tree_changes_by_ref(self):
        before = {'url': self.url, 'tree': '- button "Add" [ref_1]\n- link "Cart (0)" [ref_2]\n- button "Close" [ref_3]'}
        after = {'tree': '- button "Add" [ref_1] focused\n- link "Cart (1)" [ref_2]\n- textbox "Coupon" [ref_9] value=""'}
        changes = page_input.tree_changes(before, after, self.url + '#top')
        self.assertEqual((changes['kind'], changes['added'], changes['changed'], changes['removed']), ('same_page', 1, 1, 1))
        self.assertEqual(changes['diff'].split('\n'), ['+ textbox "Coupon" [ref_9] value=""', '~ link "Cart (1)" [ref_2]', '- button "Close" [ref_3]'])
        moved = page_input.tree_changes(before, {'tree': '- link "Next" [ref_10]', 'fresh': True}, self.url)
        self.assertEqual((moved['kind'], moved['tree']), ('new_page', '- link "Next" [ref_10]'))
        other = page_input.tree_changes(before, {'tree': 'x'}, 'https://example.test/next')
        self.assertEqual(other['kind'], 'new_page')
        many = {'tree': '\n'.join('- link "%d" [ref_%d]' % (i, i + 10) for i in range(500))}
        big = page_input.tree_changes(before, many, self.url, limit=200)
        self.assertTrue(big['truncated'] and len(big['diff']) <= 200)

    def test_result_reports_changes_and_ref_floor_advances(self):
        self.page.model['read'] = {'tree': '- button "Go" [ref_4]', 'next': 5}
        result = self.browser.input('owner', 'click', ref='ref_4')
        self.assertEqual(result['changes']['kind'], 'same_page')
        self.assertTrue(result['settled'])
        self.assertEqual(self.browser.ref_floor, 4)
        self.browser.input('owner', 'hover', ref='ref_4', observe='none')
        sent = [json.loads(p['expression'][len(server.PAGE_TREE) + 3:-1]) for m, p in self.page.sent
                if m == 'Runtime.evaluate' and p['expression'].startswith('(' + server.PAGE_TREE)]
        self.assertEqual(sent[-1]['floor'], 4)  # Next document starts at ref_5.
        self.assertNotIn('changes', self.browser.input('owner', 'hover', ref='ref_4', observe='none'))

    def test_settle_waits_for_navigation_and_requests(self):
        self.page.queued = [
            {'method': 'Page.frameStartedLoading', 'params': {'frameId': 'MAIN'}},
            {'method': 'Network.requestWillBeSent', 'params': {'requestId': '1', 'type': 'Document'}},
        ]
        self.page.model['quiet'] = {'armed': True, 'idleMs': 1000}
        started = time.monotonic()
        result = self.browser.input('owner', 'click', ref='ref_1', settle=0.6)
        self.assertGreaterEqual(time.monotonic() - started, 0.55)  # Still loading: waits the full bound.
        self.assertEqual((result['settled'], result['navigated']), (False, True))
        self.page.sent = []
        self.page.queued = [
            {'method': 'Page.frameStartedLoading', 'params': {'frameId': 'MAIN'}},
            {'method': 'Network.requestWillBeSent', 'params': {'requestId': '2', 'type': 'Document'}},
            {'method': 'Network.loadingFinished', 'params': {'requestId': '2'}},
            {'method': 'Page.frameStoppedLoading', 'params': {'frameId': 'MAIN'}},
        ]
        result = self.browser.input('owner', 'click', ref='ref_1', settle=3)
        self.assertEqual((result['settled'], result['navigated']), (True, True))
        self.assertLess(result['waitedMs'], 1500)

    def test_dialog_during_action_is_reported_and_answered(self):
        self.page.queued = [{'method': 'Page.javascriptDialogOpening',
                             'params': {'type': 'confirm', 'message': 'Delete item?', 'url': self.url}}]
        self.page.dialog = {'type': 'confirm', 'message': 'Delete item?', 'url': self.url, 'delivered': True}
        result = self.browser.input('owner', 'click', ref='ref_1')
        self.assertEqual(result['dialog']['message'], 'Delete item?')
        self.assertNotIn('changes', result)
        with self.assertRaises(Rejected) as raised:  # Remembered across calls: no blocked evaluation.
            self.browser.read('owner')
        self.assertIn('dialog', str(raised.exception))
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', ref='ref_1')
        with self.assertRaises(Rejected):  # Answering needs the page that opened it.
            self.browser.input('owner', 'dialog', value='accept')
        self.page.sent = []
        result = self.browser.input('owner', 'dialog', 'dialog-0001', self.url, value='dismiss')
        answered = self.page.sent.index(('Page.handleJavaScriptDialog', {'accept': False}))
        self.assertFalse([m for m, _ in self.page.sent[:answered] if m == 'Runtime.evaluate'])  # The page is blocked.
        self.assertEqual(result['risk'], 'dialog')
        self.assertIsNone(self.browser.dialog)
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'dialog', expected_url=self.url, value='accept')
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'dialog', expected_url=self.url, value='maybe')

    def test_dialog_seen_by_another_session_is_answered_through_devtools(self):
        calls = []

        def rpc(name, arguments):
            calls.append((name, arguments))
            return {'content': [{'type': 'text', 'text': 'Successfully dismissed the dialog'}]}
        self.browser.injected = rpc
        self.page.fail_on = 'Page.enable'
        self.page.fail_error = cdp.CDPTransportError('cdp_deadline_outcome_may_be_unknown')
        with self.assertRaises(Rejected) as raised:
            self.browser.read('owner')
        self.assertIn('not responding', str(raised.exception))
        self.browser.input('owner', 'dialog', 'dialog-0002', self.url, value='dismiss')
        self.assertEqual(calls, [('handle_dialog', {'pageId': 7, 'action': 'dismiss'})])
        self.browser.injected = lambda *_: {'isError': True, 'content': [{'type': 'text', 'text': 'No open dialog found'}]}
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'dialog', 'dialog-0003', self.url, value='dismiss')
        self.assertIn('No open dialog', str(raised.exception))
        self.assertFalse(self.browser.failed)

    def test_dialog_opened_by_input_stops_the_sequence(self):
        self.page.opens_dialog = {'type': 'alert', 'message': 'Saved', 'url': self.url}
        result = self.browser.input('owner', 'click', 'click-dialog-1', ref='ref_1')
        mouse = [p['type'] for m, p in self.page.sent if m == 'Input.dispatchMouseEvent']
        self.assertEqual(mouse, ['mouseMoved', 'mousePressed'])  # Release not sent into a blocked page.
        self.assertEqual(result['dialog']['message'], 'Saved')
        self.assertFalse(self.browser.failed)
        record = json.loads((Path(self.directory.name) / 'records/action-click-dialog-1.json').read_text())
        self.assertEqual((record['state'], record['dialogOpened']), ('dispatched_observe_result', True))

    def test_navigation_risk_and_new_tabs(self):
        self.page.model['resolve'] = {'x': 1, 'y': 1, 'risk': 'navigation'}
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'click', ref='ref_1')
        self.assertEqual(self.browser.input('owner', 'click', 'nav-00001', self.url, ref='ref_1')['risk'], 'navigation')

        class Chrome:
            owner = {'pid': 1}
            hidden = []

            def __init__(self):
                self.tabs = {'A' * 32: self_url}

            def page_targets(self, owner):
                return dict(self.tabs)

            def visibility(self, owner, hide=False):
                self.hidden.append(hide)
                return True
        self_url = self.url
        chrome = Chrome()
        self.browser.chrome = chrome
        self.page.model['resolve'] = {'x': 1, 'y': 1, 'risk': None, 'newTab': True}
        original = self.page.send

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Input.dispatchMouseEvent' and params['type'] == 'mouseReleased':
                chrome.tabs['B' * 32] = self_url + 'help'
            return original(method, params, seconds, interrupt)
        self.page.send = send
        result = self.browser.input('owner', 'click', ref='ref_1')
        self.assertEqual(result['newTabs'], [self.url + 'help'])
        self.assertEqual(chrome.hidden, [False, True, False])  # Was hidden: hidden again, then rechecked.


class StageFourTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.project = tempfile.TemporaryDirectory()
        self.calls = []

        def rpc(name, arguments):
            self.calls.append((name, arguments))
            return {'content': [{'type': 'text', 'text': '## Console messages\nmsgid=1 [error] boom'}]}
        self.browser = Browser(Path(self.directory.name), rpc=rpc, workspace=Path(self.project.name))
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.browser.page_session_factory = lambda: self.page
        self.browser.stopped.wait = lambda seconds: False
        self.url = 'https://example.test/'
        Path(self.project.name, 'doc.pdf').write_bytes(b'pdf')

    def tearDown(self):
        self.directory.cleanup()
        self.project.cleanup()

    def test_upload_paths_stay_inside_the_project(self):
        project = Path(self.project.name).resolve()
        self.assertEqual(self.browser.upload_paths(['doc.pdf']), [str(project / 'doc.pdf')])
        self.assertEqual(self.browser.upload_paths([str(project / 'doc.pdf')]), [str(project / 'doc.pdf')])
        outside = Path(self.directory.name, 'secret.txt')
        outside.write_text('x')
        Path(self.project.name, 'link.txt').symlink_to(outside)
        for bad in ([str(outside)], ['link.txt'], ['../secret.txt'], ['missing.pdf'], [], ['doc.pdf'] * 11, 'doc.pdf'):
            with self.assertRaises(Rejected, msg=bad):
                self.browser.upload_paths(bad)
        (project / 'folder').mkdir()
        with self.assertRaises(Rejected):
            self.browser.upload_paths(['folder'])
        no_project = Browser(Path(self.directory.name), rpc=lambda *_: {})
        with self.assertRaises(Rejected):
            no_project.upload_paths(['doc.pdf'])

    def test_upload_sets_files_on_the_input_object_and_needs_expected_url(self):
        original = self.page.send

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Runtime.evaluate' and '"op": "element"' in params['expression']:
                self.page.sent.append((method, params))
                return {'result': {'type': 'object', 'objectId': 'input-1'}}
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        with self.assertRaises(Rejected):
            self.browser.input('owner', 'upload', ref='ref_2', files=['doc.pdf'])
        result = self.browser.input('owner', 'upload', 'upload-0001', self.url, ref='ref_2', files=['doc.pdf'])
        self.assertEqual(result['risk'], 'upload')
        sent = [p for m, p in self.page.sent if m == 'DOM.setFileInputFiles']
        self.assertEqual(sent, [{'files': [str(Path(self.project.name).resolve() / 'doc.pdf')], 'objectId': 'input-1'}])

    def test_upload_without_a_file_field_intercepts_the_chooser(self):
        self.page.model['element'] = 'not_a_file_input'
        self.page.model['resolve'] = {'x': 30, 'y': 40}
        self.page.queued = [{'method': 'Page.fileChooserOpened', 'params': {'frameId': 'MAIN', 'mode': 'selectSingle', 'backendNodeId': 91}}]
        original = self.page.send

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Runtime.evaluate' and '"op": "element"' in params['expression']:
                self.page.sent.append((method, params))
                return {'result': {'type': 'string', 'value': 'not_a_file_input'}}
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        result = self.browser.input('owner', 'upload', 'upload-0002', self.url, ref='ref_2', files=['doc.pdf'])
        self.assertEqual(result['risk'], 'upload')
        methods = [m for m, _ in self.page.sent if m in ('Page.setInterceptFileChooserDialog', 'Input.dispatchMouseEvent', 'DOM.setFileInputFiles')]
        self.assertEqual(methods[0], 'Page.setInterceptFileChooserDialog')
        self.assertEqual(methods[-2:], ['DOM.setFileInputFiles', 'Page.setInterceptFileChooserDialog'])
        intercept = [p for m, p in self.page.sent if m == 'Page.setInterceptFileChooserDialog']
        self.assertEqual(intercept, [{'enabled': True}, {'enabled': False}])
        sent = [p for m, p in self.page.sent if m == 'DOM.setFileInputFiles']
        self.assertEqual(sent, [{'files': [str(Path(self.project.name).resolve() / 'doc.pdf')], 'backendNodeId': 91}])

    def test_upload_reports_a_click_that_opened_no_chooser(self):
        self.page.model['resolve'] = {'x': 30, 'y': 40}
        original = self.page.send

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Runtime.evaluate' and '"op": "element"' in params['expression']:
                return {'result': {'type': 'string', 'value': 'not_a_file_input'}}
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        self.browser.file_chooser = lambda page, session, seconds=3: None
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'upload', 'upload-0003', self.url, ref='ref_2', files=['doc.pdf'])
        self.assertIn('no file chooser', str(raised.exception))
        self.assertFalse([m for m, _ in self.page.sent if m == 'DOM.setFileInputFiles'])
        self.assertEqual([p for m, p in self.page.sent if m == 'Page.setInterceptFileChooserDialog'][-1], {'enabled': False})
        record = json.loads((Path(self.directory.name) / 'records/action-upload-0003.json').read_text())
        self.assertEqual(record['state'], 'clicked_no_file_chooser')

    def test_eval_is_journaled_once_and_reports_errors(self):
        original = self.page.send
        replies = {'1+1': {'result': {'type': 'number', 'value': 2}},
                   'boom()': {'exceptionDetails': {'text': 'Uncaught', 'exception': {'description': 'ReferenceError: boom is not defined'}}},
                   'big': {'result': {'type': 'string', 'value': 'x' * 30000}},
                   'document.body': {'result': {'type': 'object', 'description': 'body'}}}

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Runtime.evaluate' and params['expression'] in replies:
                self.page.sent.append((method, params))
                self.assertTrue(params['replMode'] and params['awaitPromise'])
                return replies[params['expression']]
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        self.assertEqual(self.browser.evaluate_js('owner', '1+1', self.url, 'eval-00001')['value'], 2)
        with self.assertRaises(Rejected):
            self.browser.evaluate_js('owner', '1+1', self.url, 'eval-00001')
        self.assertEqual(sum(p['expression'] == '1+1' for m, p in self.page.sent if m == 'Runtime.evaluate'), 1)
        self.assertIn('ReferenceError', self.browser.evaluate_js('owner', 'boom()', self.url)['error'])
        big = self.browser.evaluate_js('owner', 'big', self.url)
        self.assertTrue(big['truncated'] and len(big['value']) == page_input.EVAL_CHARS)
        self.assertEqual(self.browser.evaluate_js('owner', 'document.body', self.url)['type'], 'body')
        for bad in ({'expected_url': None}, {'expected_url': 'https://other.test/'}, {'timeout': 60}):
            with self.assertRaises(Rejected):
                self.browser.evaluate_js('owner', '1+1', **{'expected_url': self.url, **bad})
        # A lost reply (an awaited promise outliving the deadline) is unknown for that
        # script only; the tab stays readable and nothing is replayed.
        failures = {'2+2': cdp.CDPTransportError('cdp_deadline_outcome_may_be_unknown'),
                    'while(true){}': cdp.CDPError('Internal error')}

        def failing(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Runtime.evaluate' and params['expression'] in failures:
                self.page.sent.append((method, params))
                raise failures[params['expression']]
            return original(method, params, seconds, interrupt, session)
        self.page.send = failing
        with self.assertRaisesRegex(Rejected, 'eval_outcome_unknown_no_replay'):
            self.browser.evaluate_js('owner', '2+2', self.url, 'eval-00002')
        self.assertTrue(self.browser.uncertain)
        self.assertFalse(self.browser.failed)
        self.assertEqual(json.loads((Path(self.directory.name) / 'records/action-eval-00002.json').read_text())['state'], 'outcome_unknown')
        self.assertEqual(self.browser.screenshot('owner')['width'], 640)
        # Chrome's own error reply (a synchronous loop stopped by timeout) is a determinate failure.
        self.browser.uncertain = False
        with self.assertRaisesRegex(Rejected, 'eval_error'):
            self.browser.evaluate_js('owner', 'while(true){}', self.url, 'eval-00003')
        self.assertFalse(self.browser.uncertain or self.browser.failed)
        self.assertEqual(json.loads((Path(self.directory.name) / 'records/action-eval-00003.json').read_text())['state'], 'failed')

    def test_logs_use_devtools_collection(self):
        result = self.browser.logs('owner', 'console', 20, 1, True)
        self.assertEqual(self.calls[-1], ('list_console_messages', {'pageId': 7, 'pageSize': 20, 'pageIdx': 1, 'types': ['error', 'warn']}))
        self.assertIn('boom', result['text'])
        self.browser.logs('owner', 'network')
        self.assertEqual(self.calls[-1], ('list_network_requests', {'pageId': 7, 'pageSize': 50, 'pageIdx': 0}))
        for bad in ({'kind': 'dom'}, {'limit': 0}, {'limit': 500}, {'problems': 'yes'}):
            with self.assertRaises(Rejected):
                self.browser.logs('owner', **bad)

    def test_frame_trees_nest_and_frame_refs_route_to_their_session(self):
        self.browser.frames = {'F' * 32: {'session': 'child', 'parent': None, 'url': 'https://pay.test/'}}
        trees = {None: '- heading "Shop" [ref_1]\n- iframe "Pay" [ref_2] (cross-origin)\n- button "Help" [ref_3]',
                 'child': '- textbox "Card" [ref_4] value=""'}
        original = self.page.send
        routed = []  # (method, params, session) of every command

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            routed.append((method, params, session))
            if method == 'Runtime.evaluate' and params['expression'].startswith('(' + server.PAGE_TREE):
                request = json.loads(params['expression'][len(server.PAGE_TREE) + 3:-1])
                if request['op'] == 'read':
                    return {'result': {'value': {'kind': 'page_tree', 'tree': trees[session]}}}
                if request['op'] == 'resolve':
                    return {'result': {'value': {'x': 10, 'y': 20}}}
            if method == 'DOM.getFrameOwner':
                return {'backendNodeId': 5}
            if method == 'DOM.resolveNode':
                return {'object': {'objectId': 'iframe-1'}}
            if method == 'Runtime.callFunctionOn':
                if 'byElement' in params['functionDeclaration']:
                    return {'result': {'value': 'ref_2'}}
                return {'result': {'value': {'x': 100, 'y': 300, 'width': 400, 'height': 200, 'scrolled': params['arguments'][0]['value']}}}
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        tree = self.browser.read('owner')['tree']
        self.assertEqual(tree.split('\n'), ['- heading "Shop" [ref_1]', '- iframe "Pay" [ref_2]', '  - textbox "Card" [ref_4] value=""', '- button "Help" [ref_3]'])
        self.assertEqual(self.browser.ref_frames, {'ref_4': 'F' * 32})
        self.browser.screenshot('owner')
        self.browser.input('owner', 'click', ref='ref_4')
        pressed = [p for m, p, _ in routed if m == 'Input.dispatchMouseEvent' and p['type'] == 'mousePressed']
        self.assertEqual([(p['x'], p['y']) for p in pressed], [(110, 320)])  # Frame offset + point inside the frame.
        self.assertIsNone(self.browser.viewport)  # The iframe was scrolled into view.
        resolves = [s for m, p, s in routed if m == 'Runtime.evaluate' and '"op": "resolve"' in p['expression']]
        self.assertEqual(resolves, ['child'])
        del self.browser.frames['F' * 32]  # Frame detached or reloaded.
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'click', ref='ref_4')
        self.assertIn('frame', str(raised.exception))


class FollowUpTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.browser = Browser(Path(self.directory.name), rpc=lambda *_: {'content': []})
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.browser.page_session_factory = lambda: self.page
        self.browser.stopped.wait = lambda seconds: False
        self.url = 'https://example.test/'

    def tearDown(self):
        self.directory.cleanup()

    def test_find_matches_roles_and_words_in_both_languages(self):
        tree = '\n'.join(['- searchbox "Search Wikipedia" [ref_1] value=""', '- button "Search" [ref_2]',
                          '- link "Войти" [ref_3] href=https://x.test/login', '- button "Отправить заказ" [ref_4]',
                          '- heading "Organic mango juice" [ref_6] level=2', '- text "no ref here"'])
        best = lambda query: [m['ref'] for m in page_input.find_matches(tree, query)]
        self.assertEqual(best('search button')[0], 'ref_2')
        self.assertEqual(best('search field')[0], 'ref_1')
        self.assertEqual(best('кнопка отправки'), ['ref_4'])
        self.assertEqual(best('login link'), ['ref_3'])
        self.assertEqual(best('ссылка войти'), ['ref_3'])
        self.assertEqual(best('кнопку'), ['ref_2', 'ref_4'])
        self.assertEqual(best('mango'), ['ref_6'])
        self.assertEqual(best('the'), [])
        self.assertEqual(best('checkout'), [])
        self.assertEqual(len(page_input.find_matches('\n'.join('- link "Item %d" [ref_%d]' % (i, i) for i in range(1, 99)), 'item', 5)), 5)

    def test_find_tool_reads_the_whole_tree(self):
        self.page.model['read'] = {'kind': 'page_tree', 'tree': '- button "Pay now" [ref_9]', 'truncated': True}
        result = self.browser.find('owner', 'pay button')
        self.assertEqual([m['ref'] for m in result['matches']], ['ref_9'])
        self.assertIn('partial', result)
        self.assertEqual(self.page.requests[-1]['filter'], 'all')
        self.assertIn('hint', self.browser.find('owner', 'nothing like this'))
        with self.assertRaises(Rejected):
            self.browser.find('owner', '')

    def test_dialog_in_a_frame_is_answered_in_its_session(self):
        routed = []
        original = self.page.send

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            routed.append((method, session))
            if method == 'Page.handleJavaScriptDialog':
                return {}
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        self.browser.note_event(self.page, {'method': 'Page.javascriptDialogOpening', 'sessionId': 'child',
                                            'params': {'type': 'confirm', 'message': 'Remove card?', 'url': 'https://pay.test/'}})
        self.assertTrue(self.browser.dialog[1]['inFrame'])
        with self.assertRaises(Rejected):
            self.browser.read('owner')
        self.browser.input('owner', 'dialog', 'dialog-frame-1', 'https://pay.test/', value='accept')
        self.assertIn(('Page.handleJavaScriptDialog', 'child'), routed)
        self.assertIsNone(self.browser.dialog)
        # A detached frame takes its dialog with it.
        self.browser.frames = {'F' * 32: {'session': 'child', 'parent': None, 'url': ''}}
        self.browser.note_event(self.page, {'method': 'Page.javascriptDialogOpening', 'sessionId': 'child', 'params': {'type': 'alert'}})
        self.browser.note_event(self.page, {'method': 'Target.detachedFromTarget', 'params': {'sessionId': 'child'}})
        self.assertIsNone(self.browser.dialog)

    def test_coordinate_click_inside_a_frame_is_classified_there(self):
        self.browser.frames = {'F' * 32: {'session': 'child', 'parent': None, 'url': ''}}
        original = self.page.send
        classified = []

        def send(method, params=None, seconds=None, interrupt=None, session=None):
            if method == 'Runtime.evaluate' and '"op": "classify"' in params['expression']:
                request = json.loads(params['expression'][len(server.PAGE_TREE) + 3:-1])
                classified.append((session, request['x'], request['y']))
                self.page.sent.append((method, params))
                return {'result': {'value': {'risk': 'submit'} if session == 'child' else {'risk': None, 'crossFrame': True}}}
            if method == 'DOM.getFrameOwner':
                return {'backendNodeId': 5}
            if method == 'DOM.resolveNode':
                return {'object': {'objectId': 'iframe-1'}}
            if method == 'Runtime.callFunctionOn':
                self.assertFalse(params['arguments'][0]['value'])  # Classifying never scrolls.
                return {'result': {'value': {'x': 100, 'y': 100, 'width': 400, 'height': 300, 'scrolled': False}}}
            return original(method, params, seconds, interrupt, session)
        self.page.send = send
        self.browser.screenshot('owner')  # 640x400 image of a 1280x800 viewport.
        with self.assertRaises(Rejected) as raised:
            self.browser.input('owner', 'click', x=150, y=100)  # CSS (300, 200): inside the frame.
        self.assertIn('expectedURL', str(raised.exception))
        self.assertEqual(classified, [(None, 300, 200), ('child', 200, 100)])
        self.assertEqual(self.browser.input('owner', 'click', 'frame-click-1', self.url, x=150, y=100)['risk'], 'submit')


class WebSocketTests(unittest.TestCase):
    def serve(self, replies):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        received = []

        def run():
            connection, _ = listener.accept()
            listener.close()
            data = b''
            while b'\r\n\r\n' not in data:
                data += connection.recv(4096)
            key = [l.split(': ')[1] for l in data.decode().split('\r\n') if l.lower().startswith('sec-websocket-key')][0]
            accept = base64.b64encode(hashlib.sha1((key + cdp.GUID).encode()).digest()).decode()
            connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
            state = {'buffer': b''}

            def text_frame():
                while True:
                    while len(state['buffer']) < 2:
                        state['buffer'] += connection.recv(65536)
                    buffer = state['buffer']
                    length, offset = buffer[1] & 0x7F, 2
                    if length == 126:
                        length, offset = struct.unpack('!H', buffer[2:4])[0], 4
                    while len(state['buffer']) < offset + 4 + length:
                        state['buffer'] += connection.recv(65536)
                    buffer = state['buffer']
                    mask = buffer[offset:offset + 4]
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(buffer[offset + 4:offset + 4 + length]))
                    state['buffer'] = buffer[offset + 4 + length:]
                    if buffer[0] & 0x0F == 0x1:  # Skip pongs and other control frames.
                        return payload

            for reply in replies:
                received.append(json.loads(text_frame()))
                for chunk in reply(received[-1]):
                    connection.sendall(chunk)
            connection.close()
        threading.Thread(target=run, daemon=True).start()
        return listener.getsockname()[1], received

    @staticmethod
    def server_frame(payload, opcode=0x1, final=True):
        size = len(payload)
        head = bytes(((0x80 if final else 0) | opcode,))
        head += bytes((size,)) if size < 126 else bytes((126,)) + struct.pack('!H', size) if size < 65536 else bytes((127,)) + struct.pack('!Q', size)
        return head + payload

    def test_reply_after_events_ping_and_fragments(self):
        big = 'x' * 70000

        def reply(message):
            body = json.dumps({'id': message['id'], 'result': {'value': big}}).encode()
            return [self.server_frame(b'{"method":"Page.loadEventFired","params":{}}'),
                    self.server_frame(b'hi', 0x9),
                    self.server_frame(body[:100], 0x1, False), self.server_frame(body[100:], 0x0)]
        port, received = self.serve([reply, lambda m: [self.server_frame(json.dumps({'id': m['id'], 'error': {'message': 'No node'}}).encode())]])
        with cdp.PageSession(port, 'A' * 32, timeout=5) as page:
            self.assertEqual(page.send('Runtime.evaluate', {'expression': '1'})['value'], big)
            self.assertEqual(page.events[0]['method'], 'Page.loadEventFired')
            with self.assertRaises(cdp.CDPError):
                page.send('DOM.focus')
        self.assertEqual([m['method'] for m in received], ['Runtime.evaluate', 'DOM.focus'])

    def test_closed_connection_is_unknown_outcome(self):
        port, _ = self.serve([lambda m: []])
        with cdp.PageSession(port, 'B' * 32, timeout=5) as page:
            with self.assertRaises(cdp.CDPTransportError):
                page.send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': 1, 'y': 1})

    def test_rejects_unverified_target(self):
        with self.assertRaises(cdp.CDPTransportError):
            cdp.PageSession(9222, '../browser/x')


if __name__ == '__main__':
    unittest.main()
