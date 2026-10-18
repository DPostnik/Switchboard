#!/usr/bin/env python3
"""Exercise the Supabase migration in an isolated local PostgreSQL cluster (no app data)."""
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
bindir = Path(os.environ.get('SWITCHBOARD_POSTGRES_BIN', '/opt/homebrew/opt/postgresql@17/bin'))
if not (bindir/'initdb').exists():
    raise SystemExit('Set SWITCHBOARD_POSTGRES_BIN to a PostgreSQL bin directory.')
with tempfile.TemporaryDirectory(prefix='context-remote-db-', dir='/tmp') as directory:
    folder = Path(directory)
    def run(name, *args, **kwargs):
        result = subprocess.run([str(bindir/name), *map(str,args)], capture_output=True, text=True, **kwargs)
        if result.returncode: raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
        return result
    try: run('initdb', '-D', folder/'data', '-A', 'trust', '--no-locale', '--encoding=UTF8', env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    except subprocess.CalledProcessError as error: raise SystemExit(error.stderr)
    started = False
    try:
        run('pg_ctl', '-D', folder/'data', '-l', folder/'postgres.log', '-o', f"-k {folder} -h '' -p 55439", '-w', 'start')
        started = True
        def sql(text):
            return run('psql','-h',folder,'-p','55439','-d','postgres','-v','ON_ERROR_STOP=1','-At',input=text).stdout.strip()
        sql('''create role anon; create role authenticated;
            create schema auth; create table auth.users(id uuid primary key);
            create function auth.uid() returns uuid language sql stable as
            $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
            grant usage on schema auth to authenticated;
            grant execute on function auth.uid() to authenticated;
            insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');''')
        sql((root/'supabase/migrations/202609270001_remote.sql').read_text())
        # Only the Realtime transport is stubbed. PostgreSQL transactions, triggers,
        # security invoker/definer functions and RLS are exercised by the real engine.
        sql("""create schema realtime;
            create table realtime.messages(topic text, event text, extension text, payload jsonb, private boolean);
            alter table realtime.messages enable row level security;
            grant usage on schema realtime to authenticated;
            grant select, insert on realtime.messages to authenticated;
            create function realtime.topic() returns text language sql stable as
                $$ select current_setting('realtime.topic',true) $$;
            create function realtime.send(payload jsonb,event text,topic text,private boolean) returns void
                language sql security definer set search_path = '' as $$
                insert into realtime.messages values(topic,event,'broadcast',payload,private) $$;""")
        sql((root/'supabase/migrations/202609280001_realtime.sql').read_text())
        sql((root/'supabase/migrations/202609280002_revision_continuity.sql').read_text())
        sql((root/'supabase/migrations/202609280003_photos.sql').read_text())
        sql((root/'supabase/migrations/202609280004_photo_retention.sql').read_text())
        sql((root/'supabase/migrations/202609280006_chat_settings.sql').read_text())
        sql((root/'supabase/migrations/202610180001_remote_files.sql').read_text())
        assert sql("select public.valid_remote_photos(null), public.valid_remote_photos('[]'), public.valid_remote_photos('{}'), public.valid_remote_photos('[{\"id\":\"bad\",\"data\":\"/9j/AA==\"}]');") == 't|t|f|f'

        owner = "set role authenticated; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';"
        other = "set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';"
        device = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        command = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        assert sql(other + 'select count(*) from public.remote_devices;').endswith('0')
        insert = f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{command}','{device}','project','chat','send','hello');"
        def rejects(text):
            try: sql(text)
            except subprocess.CalledProcessError: return
            raise AssertionError('Expected database rejection')
        rejects(other + insert)
        rejects(owner + insert.replace("'project'", "'wrong-project'"))
        sql(owner + insert)
        rejects(owner + insert)
        rejects(owner + "update public.remote_commands set photos = '[]';")
        assert sql("select public.valid_remote_photos('[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"data\":\"/9j/AA==\"}]');") == 't'
        assert sql("select public.valid_remote_photos(jsonb_build_array(jsonb_build_object('id','11111111-1111-1111-1111-111111111111','data',encode(repeat('x',524289)::bytea,'base64'))));") == 'f'
        assert sql(owner + f"select status from public.claim_remote_command('{device}');").endswith('claimed')
        assert sql(owner + f"select count(*) from public.claim_remote_command('{device}');").endswith('0')
        rejects(owner + "update public.remote_commands set text = 'changed';")
        rejects(owner + "update public.remote_commands set status = 'pending';")
        assert sql(other + 'select count(*) from public.remote_commands;').endswith('0')
        sql(owner + "update public.remote_commands set status = 'uncertain';")
        rejects(owner + "update public.remote_commands set status = 'claimed';")
        sql(owner + 'delete from public.remote_devices;')
        assert sql(owner + 'select count(*) from public.remote_commands;').endswith('0')
        # Real PostgreSQL retention/permissions test; synthetic rows only.
        import uuid
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        photo = '[{"id":"11111111-1111-1111-1111-111111111111","data":"/9j/AA=="}]'
        ids = {}
        for status in ['pending','claimed','submitted','rejected','uncertain']:
            value = str(uuid.uuid4()); ids[status] = value
            sql(f"insert into public.remote_commands(id,owner,device,project,chat,kind,text,status,photos,photos_expire_at) values ('{value}','11111111-1111-1111-1111-111111111111','{device}','project','{value}','send','keep history','{status}','{photo}',now()-interval '1 second');")
        rejects(owner + 'select public.cleanup_remote_photos();')
        rejects('set role anon; select public.cleanup_remote_photos();')
        rejects(owner + f"update public.remote_commands set photos=null where id='{ids['pending']}';")
        rejects(owner + f"update public.remote_commands set photos=null where id='{ids['claimed']}';")
        rejects(owner + f"update public.remote_commands set photos=null,text='changed' where id='{ids['submitted']}';")
        sql(other + 'update public.remote_commands set photos=null;')
        assert sql('select public.cleanup_remote_photos();') == '3'
        assert sql('select public.cleanup_remote_photos();') == '0'
        assert sql("select count(*) from public.remote_commands where photos is not null;") == '2'
        assert sql("select count(*) from public.remote_commands where text='keep history';") == '5'
        sql(owner + f"update public.remote_commands set status='submitted' where id='{ids['claimed']}';")
        assert sql(f"select photos_expire_at >= now()+interval '59 minutes' from public.remote_commands where id='{ids['claimed']}';") == 't'
        rejects(owner + f"update public.remote_commands set photos=null where id='{ids['claimed']}';")
        rejects(owner + f"update public.remote_commands set photos_expire_at=now() where id='{ids['claimed']}';")
        assert sql('select public.cleanup_remote_photos();') == '0'
        sql(owner + 'delete from public.remote_devices;')
        # New-chat initial sends retain the v1 immutable envelope and stable app ID.
        # PostgreSQL normalizes UUID columns but leaves the text conversation key intact.
        import uuid
        initial = str(uuid.uuid4())
        approval_command = str(uuid.uuid4())
        approval_handle = 'ABCDEFAB-ABCD-ABCD-ABCD-ABCDEFABCDEF'
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        create = f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{initial}','{device}','project','mobile:{initial}','send','New chat');"
        sql(owner + create)
        rejects(owner + create)
        assert sql(owner + f"select chat from public.claim_remote_command('{device}');").endswith('mobile:' + initial)
        sql(owner + f"update public.remote_commands set status='submitted' where id='{initial}';")
        sql(owner + f"insert into public.remote_commands(id,device,project,chat,kind,approval) values ('{approval_command}','{device}','project','mobile:{initial}','allow','{approval_handle}');")
        assert sql(owner + f"select approval::text from public.claim_remote_command('{device}');").endswith(approval_handle.lower())
        assert sql(owner + f"select count(*) from public.claim_remote_command('{device}');").endswith('0')
        sql(owner + 'delete from public.remote_devices;')
        import json
        # Settings preserve owner/project isolation, command immutability and uncertain-work blocking.
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        created, configured, queued, stop = [str(uuid.uuid4()) for _ in range(4)]
        options = {'model': 'model-a', 'access': 'standard'}
        initial_options = json.dumps({'options': options})
        settings = json.dumps({'options': {'model':'model-b','access':'fullAccess'}, 'expected':options, 'expectedProjectAccess':'standard'})
        create = f"insert into public.remote_commands(id,device,project,chat,kind,text,settings) values ('{created}','{device}','project','mobile:{created}','create','Hello','{initial_options}');"
        rejects(other + create)
        rejects(owner + create.replace("'project'", "'private'"))
        rejects(owner + create.replace('standard', 'unknown'))
        sql(owner + create)
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('create')
        sql(owner + f"update public.remote_commands set status='submitted' where id='{created}';")
        configure = f"insert into public.remote_commands(id,device,project,chat,kind,settings) values ('{configured}','{device}','project','mobile:{created}','configure','{settings}');"
        sql(owner + configure)
        rejects(owner + f"update public.remote_commands set settings='{initial_options}' where id='{configured}';")
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('configure')
        sql(owner + f"update public.remote_commands set status='uncertain' where id='{configured}';")
        sql(owner + f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{queued}','{device}','project','mobile:{created}','send','Do not replay');")
        assert sql(owner + f"select count(*) from public.claim_remote_command('{device}');").endswith('0')
        sql(owner + f"insert into public.remote_commands(id,device,project,chat,kind,turn) values ('{stop}','{device}','project','mobile:{created}','stop','observed-turn');")
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('stop')
        rejects('set role anon; select public.remote_settings_version();')
        assert sql(owner + 'select public.remote_settings_version();').endswith('1')
        sql(owner + 'delete from public.remote_devices;')
        patch = f"select public.patch_remote_snapshot('{device}','Mac','[{{\"id\":\"project\",\"name\":\"Project\"}}]',array['a','b'],'[{{\"id\":\"a\",\"text\":\"first\"}},{{\"id\":\"b\",\"text\":\"second\"}}]');"
        sql(owner + patch)
        rev = int(sql(owner + 'select revision from public.remote_devices;').splitlines()[-1])
        def delta(since, who=owner):
            result = sql(who + f"select public.read_remote_changes('{device}',{since});").splitlines()[-1]
            return json.loads(result) if result.startswith('{') else None
        initial = delta(-1)
        assert len(initial['chats']) == 2 and initial['order'] == ['a','b']
        assert initial['device']['snapshot']['chats'] == []
        assert delta(-1, other) is None
        before = int(sql('select count(*) from realtime.messages;').splitlines()[-1])
        sql(owner + patch)
        assert int(sql('select count(*) from realtime.messages;').splitlines()[-1]) == before
        sql(owner + patch.replace('first','changed'))
        update = delta(rev)
        assert update['chats'] == [{'id':'a','text':'changed'}]
        changed_revision = update['device']['revision']
        assert changed_revision > rev
        sql(owner + f"select public.patch_remote_snapshot('{device}','Mac','[]',array['b'],'[]');")
        assert delta(changed_revision)['order'] == ['b']
        assert delta(changed_revision)['chats'] == []
        rejects(other + patch)
        rejects("set role anon; select public.remote_protocol_version();")
        # Signals contain only routing identifiers, never transcript/command text.
        signals = json.loads(sql("select jsonb_agg(payload) from realtime.messages;").splitlines()[-1])
        assert all(set(e) <= {'entity','device','id','status'} for e in signals)
        before = sql('select count(*) from realtime.messages;').splitlines()[-1]
        sql('begin;' + owner + patch + 'rollback;')
        assert sql('select count(*) from realtime.messages;').splitlines()[-1] == before
        owner_topic = "set realtime.topic = 'remote:11111111-1111-1111-1111-111111111111';"
        assert not sql(owner + owner_topic + 'select count(*) from realtime.messages;').endswith('0')
        assert sql(other + owner_topic + 'select count(*) from realtime.messages;').endswith('0')
        rejects(owner + owner_topic + "insert into realtime.messages(extension) values('broadcast');")
        sql(owner + owner_topic + "insert into realtime.messages(extension) values('presence');")
        rejects(other + owner_topic + "insert into realtime.messages(extension) values('presence');")
        last_revision = int(sql(owner + 'select revision from public.remote_devices;').splitlines()[-1])
        sql(owner + 'delete from public.remote_devices;')
        sql(owner + patch)
        assert delta(last_revision)['device']['revision'] > last_revision
        assert len(delta(last_revision)['chats']) == 2
        # File viewing: one owner-only answer per claimed file command, never edited, swept after 10 minutes.
        sql(owner + 'delete from public.remote_devices;')
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        request, sent = str(uuid.uuid4()), str(uuid.uuid4())
        ask = f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{request}','{device}','project','chat','file','docs/plan.md');"
        rejects(owner + ask.replace("'docs/plan.md'", "'   '"))
        rejects(owner + ask.replace("'docs/plan.md'", "E'a\\nb'"))
        rejects(owner + ask.replace("(id,device,project,chat,kind,text)", "(id,device,project,chat,kind,text,turn)").replace("'docs/plan.md')", "'docs/plan.md','turn')"))
        rejects(other + ask)
        sql(owner + ask)
        answer = f"insert into public.remote_files(id,payload) values ('{request}','{{\"kind\":\"text\",\"path\":\"docs/plan.md\",\"text\":\"hi\"}}');"
        rejects(owner + answer)
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('file')
        rejects(other + answer)
        rejects(owner + answer.replace("'{\"kind", "'[{\"kind").replace("}}');", "}}]');"))
        sql(owner + answer)
        rejects(owner + answer)
        rejects(owner + f"update public.remote_files set payload='{{}}' where id='{request}';")
        assert sql(other + 'select count(*) from public.remote_files;').endswith('0')
        assert json.loads(sql(owner + f"select payload from public.remote_files where id='{request}';").splitlines()[-1])['text'] == 'hi'
        sql(owner + f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{sent}','{device}','project','other','send','hello');")
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('send')
        rejects(owner + f"insert into public.remote_files(id,payload) values ('{sent}','{{}}');")
        sql(other + 'delete from public.remote_files;')
        assert sql('select count(*) from public.remote_files;') == '1'
        rejects(owner + 'select public.cleanup_remote_files();')
        rejects('set role anon; select public.cleanup_remote_files();')
        assert sql('select public.cleanup_remote_files();') == '0'
        sql(f"update public.remote_files set created = now() - interval '11 minutes' where id='{request}';")
        assert sql('select public.cleanup_remote_files();') == '1'
        later = str(uuid.uuid4())
        sql(owner + ask.replace(request, later))
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('file')
        sql(owner + answer.replace(request, later))
        sql(owner + f"delete from public.remote_files where id='{later}';")
        assert sql('select count(*) from public.remote_files;') == '0'
        assert sql(owner + 'select public.remote_files_version();').endswith('1')
        rejects('set role anon; select public.remote_files_version();')
        last = str(uuid.uuid4())
        sql(owner + ask.replace(request, last))
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('file')
        sql(owner + answer.replace(request, last))
        sql(owner + 'delete from public.remote_devices;')
        assert sql('select count(*) from public.remote_files;') == '0'
        print('PASS: file answers (owner-only, claimed file commands, immutable, swept after 10 minutes); chat settings validation, immutable choices and uncertain-work blocking; photo expiry, grace period, immutable history, retention permissions/idempotence; all data migrations, delete/recreate revision continuity, atomic event rollback, private channel RLS, compact signals, delta revisions/deletions, owner/project isolation, duplicate claims and no uncertain replay')
    finally:
        if started: run('pg_ctl','-D',folder/'data','-m','fast','-w','stop')
