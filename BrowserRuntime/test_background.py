"""Background routing regressions without touching a user's browser/profile."""
import json
from pathlib import Path
import tempfile
import unittest

from server import Browser


class BackgroundTests(unittest.TestCase):
    def test_open_and_repeated_hidden_reads_never_request_foreground(self):
        calls = []

        def rpc(name, arguments):
            calls.append((name, arguments))
            if name == 'new_page':
                return {'content': [{'type': 'text', 'text': '9: ' + arguments['url']}]}
            value = {'url': 'https://example.test/', 'readyState': 'complete'}
            return {'content': [{'type': 'text', 'text': '```json\n' + json.dumps(value) + '\n```'}]}

        with tempfile.TemporaryDirectory() as directory:
            browser = Browser(Path(directory), rpc=rpc)
            opened = browser.open('https://example.test/')
            self.assertEqual(calls[0][0], 'list_pages')  # No spare blank tab here.
            self.assertIs(calls[1][1].get('background'), True)
            self.assertTrue(all(args.get('pageId') == 9 for _, args in calls[2:]))
            browser.read = lambda *args, **kwargs: {
                'url': 'https://example.test/', 'cards': [], 'placeholders': 0,
                'loading': True, 'empty': False, 'truncated': False, 'bottom': True,
                'scroll': {}, 'readyState': 'complete', 'next': 'unknown', 'visibility': 'hidden'}
            for _ in range(2):
                result = browser.cards(opened['session'], {'card': '.card'}, timeout=1)
                self.assertFalse(result['complete'])
                self.assertEqual(result['visibility'], 'hidden')
            selections = [args for name, args in calls if name == 'select_page']
            self.assertEqual(selections, [{'pageId': 9, 'bringToFront': False}] * 2)
            self.assertFalse(any(args.get('bringToFront') for _, args in calls))


if __name__ == '__main__':
    unittest.main()
