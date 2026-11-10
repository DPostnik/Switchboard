"""Bounded DOM inspection, honest MCP hints, and the unchanged eval boundary."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import server
from test_page_input import FakePage


class PageInspectTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.browser = server.Browser(Path(self.directory.name), rpc=lambda *_: {'content': []})
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}
        self.page = FakePage()
        self.page.model['read'] = {'kind': 'page_inspect', 'count': 0, 'matches': [], 'next': 3, 'fresh': True}
        self.browser.page_session_factory = lambda: self.page

    def tearDown(self):
        self.directory.cleanup()

    def test_selector_is_quoted_data_and_does_not_dispatch_input(self):
        selector = 'button[data-label="x\\\";globalThis.pwned=true;//"]'
        result = server.dispatch(self.browser, 'browser_read', {
            'session': 'owner', 'mode': 'inspect', 'selector': selector, 'limit': 3})
        self.assertEqual(self.page.requests[-1]['selector'], selector)
        self.assertEqual(self.page.requests[-1]['limit'], 3)
        self.assertEqual(result['count'], 0)
        self.assertEqual(result['content'], 'untrusted_page_data')
        self.assertNotIn('next', result)
        self.assertFalse(any(method.startswith('Input.') for method, _ in self.page.sent))
        self.assertEqual(list((Path(self.directory.name) / 'records').glob('action-*')), [])

    def test_invalid_scope_is_rejected_before_page_contact(self):
        for values in ({}, {'selector': ''}, {'selector': 7}, {'selector': 'x' * 513},
                       {'selector': 'button', 'ref': 'ref_1'}, {'selector': 'button', 'filter': 'interactive'},
                       {'selector': 'button', 'limit': True}, {'selector': 'button', 'limit': 51},
                       {'selector': 'button', 'expression': 'alert(1)'}):
            with self.assertRaises(server.Rejected):
                server.dispatch(self.browser, 'browser_read', {'session': 'owner', 'mode': 'inspect', **values})
        with self.assertRaises(server.Rejected):
            self.browser.read('foreign', 'inspect', selector='button')
        with self.assertRaises(server.Rejected):
            self.browser.read('owner', selector='button')
        self.assertEqual(self.page.sent, [])

    def test_determinate_selector_failure_and_lost_read_do_not_dispatch_or_replay(self):
        self.page.model['read'] = {'error': 'invalid_selector'}
        with self.assertRaisesRegex(server.Rejected, 'invalid_selector'):
            self.browser.read('owner', 'inspect', selector='[')
        self.assertFalse(self.browser.failed)
        self.page.fail_on = 'Runtime.evaluate'
        with self.assertRaises(server.Rejected):
            self.browser.read('owner', 'inspect', selector='button')
        self.assertFalse(self.browser.failed)
        self.assertFalse(any(method.startswith('Input.') for method, _ in self.page.sent))

    def test_catalog_distinguishes_observation_scrolling_and_consequential_actions(self):
        tools = {tool['name']: tool for tool in server.catalog()}
        for name in ('browser_read', 'browser_verify', 'browser_snapshot', 'browser_screenshot',
                     'browser_find', 'browser_logs', 'browser_status'):
            self.assertTrue(tools[name]['annotations']['readOnlyHint'], name)
            self.assertFalse(tools[name]['annotations']['destructiveHint'], name)
        for name in ('browser_open', 'browser_cards'):
            self.assertFalse(tools[name]['annotations']['readOnlyHint'], name)
            self.assertFalse(tools[name]['annotations']['destructiveHint'], name)
        for name in ('browser_eval', 'browser_input', 'browser_action', 'browser_next',
                     'browser_import_session', 'browser_import_indexeddb', 'browser_close'):
            self.assertFalse(tools[name]['annotations']['readOnlyHint'], name)
            self.assertTrue(tools[name]['annotations']['destructiveHint'], name)
        self.assertFalse(tools['browser_status']['annotations']['openWorldHint'])
        policy = server.RolePolicy()
        policy.check('browser_read', {'session': 'owner', 'mode': 'inspect', 'selector': 'button'})
        self.assertIn('browser_eval', policy.hidden())
        with self.assertRaises(server.Rejected):
            policy.check('browser_eval', {'expression': 'document.title'})
        try:
            for language, phrase in [('en', 'caller-provided JavaScript'), ('ru', 'пользовательского JavaScript')]:
                server.LANGUAGE = language
                tool = next(t for t in server.catalog() if t['name'] == 'browser_read')
                self.assertIn(phrase, tool['description'])
                self.assertIn('inspect', tool['inputSchema']['properties']['mode']['enum'])
                with self.assertRaises(server.Rejected) as caught:
                    self.browser.read('owner', 'inspect', selector='button', limit=51)
                self.assertIn('целым числом' if language == 'ru' else 'integer', str(caught.exception))
                self.page.model['read'] = {'kind': 'page_inspect', 'count': 2, 'matches': [], 'truncated': True}
                result = self.browser.read('owner', 'inspect', selector='button')
                self.assertIn('сузь selector' if language == 'ru' else 'narrow selector', result['hint'])
        finally:
            server.LANGUAGE = 'en'


@unittest.skipUnless(shutil.which('node'), 'Node is required for the page-model fixture')
class InspectPageModelTests(unittest.TestCase):
    def inspect(self, selector='input', limit=20, max_chars=20000):
        # Execute the actual shipped page model against observable DOM objects.
        # Mutation APIs fail the test instead of silently pretending to succeed.
        fixture = r'''
const fs = require('fs');
if (!String.prototype.toWellFormed) String.prototype.toWellFormed = function(){return String(this)};
global.window = global;
global.location = {href:'https://example.test/form'};
global.getComputedStyle = (element) => ({display:'block', visibility:element.hidden?'hidden':'visible'});
const forbidden = () => {throw new Error('inspection mutated the page')};
global.fetch = forbidden;
function element(type, value, extra={}) {
  const attrs = {type, id:type, ...extra};
  return {tagName:'INPUT', type, value, innerText:'', labels:[], hidden:extra.hidden,
    checked:type==='checkbox', disabled:type==='checkbox',
    getAttribute:name => Object.hasOwn(attrs,name)?String(attrs[name]):null,
    getBoundingClientRect:() => ({x:10,y:20,width:120,height:30}),
    getClientRects:() => extra.hidden?[]:[{}],
    focus:forbidden, click:forbidden, scrollIntoView:forbidden, dispatchEvent:forbidden};
}
const nodes = [element('text','Ada'),element('password','password-secret'),
  element('text','card-secret', {autocomplete:'cc-number'}),element('checkbox','yes'),
  element('text','hidden-secret',{hidden:true})];
global.document = {title:'Fixture', readyState:'complete', querySelectorAll:selector => {
  if(selector==='[') throw new SyntaxError('invalid CSS');
  return selector==='missing'?[]:nodes;
}};
const model = eval('(' + fs.readFileSync(process.argv[1],'utf8') + ')');
console.log(JSON.stringify(model(JSON.parse(process.argv[2]))));
'''
        request = {'op': 'read', 'mode': 'inspect', 'selector': selector, 'limit': limit,
                   'maxChars': max_chars, 'depth': 60}
        result = subprocess.run([shutil.which('node'), '-e', fixture, str(Path(server.__file__).with_name('page_tree.js')),
                                 json.dumps(request)], capture_output=True, text=True, timeout=10, check=True)
        return json.loads(result.stdout)

    def test_actual_model_reads_state_redacts_secrets_and_never_activates_controls(self):
        result = self.inspect()
        self.assertEqual(result['scope'], 'top_document')
        self.assertEqual(result['count'], 5)
        self.assertEqual(result['matches'][0]['value'], 'Ada')
        self.assertEqual(result['matches'][0]['rect']['width'], 120)
        self.assertTrue(result['matches'][3]['disabled'])
        self.assertTrue(result['matches'][3]['checked'])
        self.assertFalse(result['matches'][4]['visible'])
        serialized = json.dumps(result)
        self.assertNotIn('password-secret', serialized)
        self.assertNotIn('card-secret', serialized)
        self.assertNotIn('hidden-secret', serialized)

    def test_actual_model_reports_empty_invalid_and_bounded_results(self):
        self.assertEqual(self.inspect('missing')['count'], 0)
        self.assertEqual(self.inspect('[')['error'], 'invalid_selector')
        limited = self.inspect(limit=2)
        self.assertEqual((limited['count'], len(limited['matches']), limited['reason']), (5, 2, 'match_limit'))
        bounded = self.inspect(max_chars=1000)
        self.assertEqual(bounded['reason'], 'character_limit')
        self.assertLessEqual(len(json.dumps(bounded, separators=(',', ':'))), 1100)


if __name__ == '__main__':
    unittest.main()
