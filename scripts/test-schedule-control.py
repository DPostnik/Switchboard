"""Client checks use an isolated mailbox, never the user's running app."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'Skills/schedule-control/scripts/schedule-control.py'
spec = importlib.util.spec_from_file_location('schedule_client', SOURCE)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ScheduleClientTests(unittest.TestCase):
    def test_edit_uses_observed_snapshot_and_literal_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            prompt = Path(tmp) / 'prompt.txt'
            prompt.write_text('Не отправлять заявки. $(do-not-run) `literal`\nNext line')
            job = {'id': 'B39B21BF-187C-4C45-8F94-F98F70F8643F', 'prompt': 'old', 'enabled': False}
            argv = ['client', 'update', '--job-id', job['id'], '--prompt-file', str(prompt), '--enable', '--confirm-source-disabled']
            with patch('sys.argv', argv), patch.object(client, 'send', side_effect=[{'jobs': [job]}, {'jobs': []}]) as send, contextlib.redirect_stdout(io.StringIO()):
                client.main()
            update = send.call_args_list[1].args[0]
            self.assertEqual(update['expected'], job)
            self.assertEqual(update['prompt'], prompt.read_text())
            self.assertTrue(update['enabled'] and update['confirmSourceDisabled'])

    def test_schedule_edit_keeps_omitted_part(self):
        job = {'id': 'B39B21BF-187C-4C45-8F94-F98F70F8643F', 'enabled': True,
               'schedule': {'rule': 'FREQ=HOURLY;INTERVAL=1', 'timeZone': 'Europe/Warsaw'}}
        args = ['client', 'update', '--job-id', job['id'], '--rule', 'FREQ=DAILY;BYHOUR=8,10;BYMINUTE=0']
        with patch('sys.argv', args), patch.object(client, 'send', side_effect=[{'jobs': [job]}, {'jobs': []}]) as send, contextlib.redirect_stdout(io.StringIO()):
            client.main()
        self.assertEqual(send.call_args_list[1].args[0], {'operation': 'update', 'expected': job,
                         'schedule': {'rule': 'FREQ=DAILY;BYHOUR=8,10;BYMINUTE=0', 'timeZone': 'Europe/Warsaw'}})
        once = dict(job, schedule={'rule': '', 'timeZone': 'Europe/Warsaw', 'once': 1})
        with patch('sys.argv', ['client', 'update', '--job-id', job['id'], '--time-zone', 'UTC']), \
                patch.object(client, 'send', side_effect=[{'jobs': [once]}]) as send, self.assertRaises(RuntimeError):
            client.main()
        self.assertEqual(send.call_count, 1)

    def test_external_policy_consent_is_explicit(self):
        job = {'id': 'B39B21BF-187C-4C45-8F94-F98F70F8643F', 'engine': 'claude', 'enabled': True}
        args = ['client', 'update', '--job-id', job['id'], '--accept-external-policy']
        with patch('sys.argv', args), patch.object(client, 'send', side_effect=[{'jobs': [job]}, {'jobs': []}]) as send, contextlib.redirect_stdout(io.StringIO()):
            client.main()
        self.assertEqual(send.call_args_list[1].args[0], {'operation': 'update', 'expected': job, 'acceptExternalPolicy': True})
        with patch('sys.argv', args + ['--revoke-external-policy']), patch.object(client, 'send') as send, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                client.main()
        send.assert_not_called()

    def test_model_pair_is_explicit_and_does_not_enable_job(self):
        job = {'id': 'B39B21BF-187C-4C45-8F94-F98F70F8643F', 'model': 'gpt-6-sol', 'effort': 'high', 'enabled': False}
        args = ['client', 'update', '--job-id', job['id'], '--model', 'gpt-6-astra', '--effort', 'medium']
        with patch('sys.argv', args), patch.object(client, 'send', side_effect=[{'jobs': [job]}, {'jobs': []}]) as send, contextlib.redirect_stdout(io.StringIO()):
            client.main()
        request = send.call_args_list[1].args[0]
        self.assertEqual(request, {'operation': 'update', 'expected': job, 'model': 'gpt-6-astra', 'effort': 'medium'})
        with patch('sys.argv', args[:-2]), patch.object(client, 'send') as send, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                client.main()
            send.assert_not_called()

    def test_import_is_disabled_and_uses_catalog_digest(self):
        project = 'B39B21BF-187C-4C45-8F94-F98F70F8643F'
        catalog = {'jobs': [], 'catalog': {'sources': [{'definition': {'id': 'routine'}, 'digest': 'snapshot'}]}}
        args = ['client', 'import', '--source-id', 'routine', '--project-id', project,
                '--time-zone', 'Europe/Warsaw', '--model', 'test-model', '--effort', 'medium', '--recurring']
        with patch('sys.argv', args), patch.object(client, 'send', side_effect=[catalog, {'jobs': []}]) as send, contextlib.redirect_stdout(io.StringIO()):
            client.main()
        self.assertEqual(send.call_args_list[0].args[0], {'operation': 'catalog'})
        request = send.call_args_list[1].args[0]
        self.assertEqual(request['operation'], 'import')
        self.assertEqual(request['importRequest']['sourceDigest'], 'snapshot')
        self.assertNotIn('enabled', request)
        catalog['jobs'] = [{'source': 'codex:routine'}]
        with patch('sys.argv', args), patch.object(client, 'send', return_value=catalog) as send:
            with self.assertRaisesRegex(RuntimeError, 'already imported'):
                client.main()
            self.assertEqual(send.call_count, 1)

    def test_create_sends_single_request_and_stays_paused_by_default(self):
        project = 'B39B21BF-187C-4C45-8F94-F98F70F8643F'
        with tempfile.TemporaryDirectory() as tmp:
            prompt = Path(tmp) / 'prompt.txt'
            prompt.write_text('Собери сводку. `literal` $(never-run)\n')
            args = ['client', 'create', '--name', 'Digest', '--project-id', project.lower(), '--prompt-file', str(prompt),
                    '--rule', 'FREQ=DAILY;BYHOUR=8;BYMINUTE=0', '--time-zone', 'Europe/Warsaw', '--model', 'test-model', '--effort', 'medium']
            with patch('sys.argv', args), patch.object(client, 'send', return_value={'jobs': []}) as send, contextlib.redirect_stdout(io.StringIO()):
                client.main()
            self.assertEqual(send.call_count, 1)
            request = send.call_args.args[0]
            self.assertEqual(request, {'operation': 'create', 'createRequest': {
                'name': 'Digest', 'prompt': prompt.read_text(), 'engine': 'codex', 'projectID': project,
                'schedule': {'rule': 'FREQ=DAILY;BYHOUR=8;BYMINUTE=0', 'timeZone': 'Europe/Warsaw'}, 'model': 'test-model', 'effort': 'medium'}})
            with patch('sys.argv', args + ['--enable', '--engine', 'claude']), patch.object(client, 'send', return_value={'jobs': []}) as send, contextlib.redirect_stdout(io.StringIO()):
                client.main()
            created = send.call_args.args[0]['createRequest']
            self.assertTrue(created['enabled'])
            self.assertEqual(created['engine'], 'claude')
            prompt.write_text('  \n')
            with patch('sys.argv', args), patch.object(client, 'send') as send, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    client.main()
            send.assert_not_called()

    def test_timeout_keeps_one_receipt_and_status_never_resends(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(client, 'ROOT', Path(tmp)), contextlib.redirect_stderr(io.StringIO()):
            with patch.object(client.time, 'monotonic', side_effect=[0, 41]):
                with self.assertRaisesRegex(RuntimeError, 'Do not repeat'):
                    client.send({'operation': 'list'})
            files = list(Path(tmp).iterdir())
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
            request = json.loads(files[0].read_text())
            output = io.StringIO()
            with patch('sys.argv', ['client', 'status', request['id']]), contextlib.redirect_stdout(output):
                client.main()
            self.assertEqual(json.loads(output.getvalue())['status'], 'pending-or-expired')
            self.assertEqual(list(Path(tmp).iterdir()), files)

    def test_oversize_request_never_enters_mailbox(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(client, 'ROOT', Path(tmp)):
            with self.assertRaisesRegex(ValueError, 'too large'):
                client.send({'operation': 'update', 'prompt': 'я' * 1_100_000})
            self.assertEqual(list(Path(tmp).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
