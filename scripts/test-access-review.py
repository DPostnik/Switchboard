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
SERVER = Path(__file__).resolve().parents[1] / 'ChatDirectoryRuntime/server.py'
server_spec = importlib.util.spec_from_file_location('chat_directory_server', SERVER)
server = importlib.util.module_from_spec(server_spec)
server_spec.loader.exec_module(server)

PROJECT = '1F04568B-EF17-43A6-8E75-9FD26E81373E'
SCHEMA = ('CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, date REAL NOT NULL, chat TEXT, run TEXT, project TEXT, '
          'role TEXT NOT NULL, agent TEXT NOT NULL, tool TEXT NOT NULL, capability TEXT NOT NULL, target TEXT, decision TEXT NOT NULL, '
          'turn TEXT, audit INTEGER NOT NULL)')
LIFECYCLE = SCHEMA[:-1] + ', request_id TEXT, source TEXT, stage TEXT, outcome TEXT, rule_id TEXT, reason TEXT)'


class AccessReviewTests(unittest.TestCase):
    def run_script(self, rows, schema=SCHEMA, *arguments, extra=()):
        with tempfile.TemporaryDirectory() as tmp:
            ledger, metadata = Path(tmp) / 'ledger.sqlite', Path(tmp) / 'metadata.sqlite'
            with contextlib.closing(sqlite3.connect(ledger)) as connection, connection:
                connection.execute(schema)
                for row in rows:
                    connection.execute('INSERT INTO decisions (date, chat, project, role, agent, tool, capability, target, decision, audit) '
                                       'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', row)
                for statement in extra:
                    connection.execute(statement)
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
            text = output.getvalue()
            return json.loads(text) if '--format' not in arguments else text

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

    def test_reasons_are_counted_per_group_and_shown(self):
        rows = [self.row('C1', 'shell', 'swift build'), self.row('C2', 'shell', 'swift build --verbose'),
                self.row('C2', 'shell', 'swift build -c release', decision='denied')]
        # Lifecycle rows: requested with a reason; the old row without one stays legacy.
        reasons = ["UPDATE decisions SET request_id = 'r' || id, stage = 'requested', reason = 'backslash' WHERE id = 1",
                   "UPDATE decisions SET request_id = 'r' || id, stage = 'requested', reason = 'denyList' WHERE id = 3"]
        report = self.run_script(rows, LIFECYCLE, extra=reasons)
        group = next(g for g in report['groups'] if g['target'] == 'swift build')
        self.assertEqual(group['reasons'], {'backslash': 1, 'denyList': 1})
        markdown = self.run_script(rows, LIFECYCLE, '--format', 'md', extra=reasons)
        self.assertIn('reasons backslash 1, denyList 1', markdown)

    def test_old_ledger_without_reason_column_reads_without_reasons(self):
        report = self.run_script([self.row('C1', 'shell', 'swift build'), self.row('C2', 'shell', 'swift build -v')])
        self.assertEqual(report['groups'][0]['reasons'], {})

    def test_chat_lookup_counts_denied_commands_retried_in_the_same_turn(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / 'capability-ledger.sqlite'
            with contextlib.closing(sqlite3.connect(ledger)) as connection, connection:
                connection.execute(SCHEMA)
                for chat, turn, target, decision in [
                        ('C1', 't1', 'pgrep -f app', 'used'),          # the call itself, before the denial
                        ('C1', 't1', 'pgrep -f app', 'hookDenied'),
                        ('C1', 't1', 'pgrep -f app', 'asked'),         # retried, any decision
                        ('C1', 't1', 'sudo ls', 'denied'),            # never retried
                        ('C1', 't1', 'log show', 'denied'),
                        ('C1', 't2', 'log show', 'used'),             # another turn is not a retry
                        ('C2', 't1', 'sudo ls', 'used')]:              # another chat is not a retry
                    connection.execute('INSERT INTO decisions (date, chat, role, agent, tool, capability, target, decision, turn, audit) '
                                       "VALUES (?, ?, 'developer', 'claude', 'Bash', 'shell', ?, ?, ?, 0)", (time.time(), chat, target, decision, turn))
            before = ledger.read_bytes()
            self.assertEqual(server.denied_then_retried(tmp, 'C1'), {'denied': 3, 'retried': 1})
            self.assertEqual(server.denied_then_retried(tmp, 'C3'), {'denied': 0, 'retried': 0})
            # Old ledger without `reason`: refused requests still read, without the key.
            self.assertTrue(all('reason' not in row for row in server.refused_requests(tmp, 'C1')))
            self.assertEqual(ledger.read_bytes(), before)
            with contextlib.closing(sqlite3.connect(ledger)) as connection, connection:
                connection.execute('ALTER TABLE decisions ADD COLUMN reason TEXT')
                connection.execute("UPDATE decisions SET reason = 'denyList' WHERE target = 'sudo ls'")
            self.assertIn({'decision': 'denied', 'reason': 'denyList'},
                          [{k: row[k] for k in ('decision', 'reason') if k in row} for row in server.refused_requests(tmp, 'C1')])
            self.assertEqual(server.denied_then_retried(Path(tmp) / 'missing', 'C1'), None)

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
