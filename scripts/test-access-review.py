"""Access review script checks against throwaway databases, never the user's ledger."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / '.agents/skills/access-review/scripts/access_requests.py'
spec = importlib.util.spec_from_file_location('access_requests', SOURCE)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)

PROJECT = '1F04568B-EF17-43A6-8E75-9FD26E81373E'
SCHEMA = ('CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL NOT NULL, chat TEXT, run TEXT, project TEXT, '
          'role TEXT NOT NULL, agent TEXT NOT NULL, tool TEXT NOT NULL, capability TEXT NOT NULL, target TEXT, decision TEXT NOT NULL, '
          'turn TEXT, audit INTEGER NOT NULL)')


class AccessReviewTests(unittest.TestCase):
    def run_script(self, rows, schema=SCHEMA, *arguments):
        with tempfile.TemporaryDirectory() as tmp:
            ledger, metadata = Path(tmp) / 'ledger.sqlite', Path(tmp) / 'metadata.sqlite'
            with contextlib.closing(sqlite3.connect(ledger)) as connection, connection:
                connection.execute(schema)
                for row in rows:
                    connection.execute('INSERT INTO decisions (date, chat, project, role, agent, tool, capability, target, decision, audit) '
                                       'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', row)
            state = {'projects': [{'id': PROJECT, 'name': 'switchboard', 'path': '/work/app', 'accessPresets': ['github'],
                                   'sandboxCommands': ['zsh scripts/test.sh'], 'extraRoots': [{'path': '/work/notes', 'writable': False}]}],
                     'chats': [{'id': 'C1', 'title': 'First'}]}
            with contextlib.closing(sqlite3.connect(metadata)) as connection, connection:
                connection.execute('CREATE TABLE state (key TEXT PRIMARY KEY, value BLOB NOT NULL)')
                connection.execute("INSERT INTO state VALUES ('app', ?)", (json.dumps(state),))
            before = ledger.read_bytes()
            argv = ['access_requests', '--database', str(ledger), '--metadata', str(metadata), '--format', 'json', *arguments]
            output = io.StringIO()
            with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(output):
                review.main()
            self.assertEqual(ledger.read_bytes(), before)
            return json.loads(output.getvalue())

    def row(self, chat, capability, target, decision='asked', tool='Bash', age=60):
        return (time.time() - age, chat, PROJECT, 'developer', 'claude-code', tool, capability, target, decision, 0)

    def test_groups_by_folder_and_command_head_and_marks_open_rules(self):
        report = self.run_script([
            self.row('C1', 'read', '/tmp/probe-a/shot.png', tool='Read'),
            self.row('C2', 'read', '/private/tmp/x/y.png', tool='Read'),
            self.row('C3', 'read', '/tmp/probe-b/log.txt', tool='Read'),
            self.row('C1', 'shell', 'zsh scripts/test.sh --filter A > "$TMPDIR/t.log" 2>&1; code=$?; tail -5 "$TMPDIR/t.log"; exit $code', age=30),
            self.row('C2', 'shell', 'cd /work/app && zsh scripts/test.sh --filter B'),
            self.row('C1', 'shell', 'git push origin main', decision='used'),
            self.row('C1', 'read', '/work/notes/a.md', tool='Read', age=30 * 86400),
            self.row('C3', 'read', '/Users/x/Documents/test/a.png', tool='Read'),
        ])
        groups = {(g['capability'], g['target']): g for g in report['groups']}
        self.assertEqual(groups[('read', '/private/tmp')]['chats'], 3)
        test = groups[('shell', 'zsh scripts/test.sh')]
        self.assertEqual((test['requests'], test['chats']), (2, 2))
        self.assertIn('command zsh scripts/test.sh', test['alreadyOpenBy'])
        self.assertEqual(test['examples'][0]['chat'], 'switchboard-chat:C1')
        self.assertEqual(test['examples'][0]['title'], 'First')
        self.assertEqual(report['requests'], 6)
        self.assertEqual(report['oneOff']['switchboard']['groups'], 1)

    def test_missing_column_fails_with_a_clear_error(self):
        with self.assertRaises(SystemExit) as stop, contextlib.redirect_stderr(io.StringIO()):
            self.run_script([], SCHEMA.replace(', audit INTEGER NOT NULL', ''))
        self.assertIn("lacks columns ['audit']", str(stop.exception.code))

    def test_app_enums_and_presets_are_read_from_sources(self):
        self.assertIn('writeOutside', review.swift_cases(review.RECORD_SOURCE, 'Capability'))
        self.assertIn('hookAsked', review.swift_cases(review.RECORD_SOURCE, 'Decision'))
        self.assertIn('git push', review.presets()['github']['unsandboxed'])
        self.assertEqual(review.presets()['_base']['unsandboxed'], ['ps', 'sysctl -n'])

    def test_lifecycle_counts_one_presentation_across_run_finalization(self):
        base = dict(chat='C1', agent='codex', turn='t1', request_id='request-1', audit=0,
                    decision='asked', tool='mcpElicitation', run='active')
        rows = [{**base, 'stage': 'requested'},
                {**base, 'stage': 'presented', 'tool': 'interaction'},
                {**base, 'stage': 'responded', 'decision': 'answered'},
                {**base, 'stage': 'resolved', 'run': None}]
        entries = list(review.request_lifecycles(rows))
        self.assertEqual(len(entries), 1)
        representative, events, interrupted, legacy = entries[0]
        self.assertEqual(representative['tool'], 'mcpElicitation')
        self.assertEqual(len(events), 4)
        self.assertTrue(interrupted)
        self.assertFalse(legacy)

    def test_execution_response_and_audit_do_not_invent_user_interruptions(self):
        base = dict(chat='C1', agent='codex', turn='t1', request_id='request-1', audit=0,
                    decision='used', tool='browser_read', run=None)
        self.assertEqual(list(review.request_lifecycles([
            {**base, 'stage': 'started'}, {**base, 'stage': 'completed'}])), [])
        self.assertEqual(list(review.request_lifecycles([
            {**base, 'stage': 'responded', 'decision': 'answered'}])), [])
        entries = list(review.request_lifecycles([
            {**base, 'stage': 'requested', 'decision': 'asked', 'audit': 1},
            {**base, 'stage': 'presented', 'decision': 'asked', 'audit': 1}]))
        self.assertEqual(len(entries), 1)
        self.assertTrue(entries[0][2])


if __name__ == '__main__':
    unittest.main()
