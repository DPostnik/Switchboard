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
        # Without a valid locale in the environment the macOS postmaster refuses to start ("became multithreaded").
        run('pg_ctl', '-D', folder/'data', '-l', folder/'postgres.log', '-o', f"-k {folder} -h '' -p 55439", '-w', 'start',
            env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
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
        # Before the interactions migration a role (published in chat settings since roles) cannot reach the queue.
        assert sql("""select public.valid_remote_options('{"model":"m","role":"reader"}');""") == 'f'
        sql((root/'supabase/migrations/202611050001_remote_interactions.sql').read_text())
        sql((root/'supabase/migrations/202611060001_remote_web.sql').read_text())
        sql((root/'supabase/migrations/202611100001_remote_web_images.sql').read_text())
        sql((root/'supabase/migrations/202611130001_remote_push.sql').read_text())
        assert sql("""select public.valid_remote_options('{"model":"m","role":"reader","addOns":["mail","userChrome"]}'),
            public.valid_remote_options('{"model":"m","access":null,"role":null,"addOns":null}'),
            public.valid_remote_options('{"model":"m","role":""}'), public.valid_remote_options('{"model":"m","role":5}'),
            public.valid_remote_options('{"model":"m","addOns":[1]}'), public.valid_remote_options('{"model":"m","addOns":"mail"}'),
            public.valid_remote_options('{"model":"m","addOns":["a","b","c","d","e","f","g","h","i"]}'),
            public.valid_remote_options('{"model":"m","extra":true}');""") == 't|t|f|f|f|f|f|f'
        assert sql("""select public.valid_remote_answers('{"q":"a"}'), public.valid_remote_answers('{}'),
            public.valid_remote_answers('{"q":1}'), public.valid_remote_answers('[]'), public.valid_remote_answers('{"":"a"}'),
            public.valid_remote_answers(jsonb_build_object('q', repeat('x', 8001))),
            public.valid_remote_answers('{"1":"a","2":"a","3":"a","4":"a","5":"a","6":"a","7":"a","8":"a","9":"a"}');""") == 't|t|f|f|f|f|f'
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
        # Interactions: answers, queued and interrupt-and-send messages, role and add-on settings.
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        handle = str(uuid.uuid4())
        def command_row(kind, chat='work', text='', approval=None, turn=None, answers=None, photos=None, settings=None, project='project'):
            value = str(uuid.uuid4())
            columns, values = ['id','device','project','chat','kind','text'], [value, device, project, chat, kind, text]
            for name, item in [('approval', approval), ('turn', turn), ('answers', answers), ('photos', photos), ('settings', settings)]:
                if item is not None: columns.append(name); values.append(item)
            literal = ','.join("'" + str(item).replace("'", "''") + "'" for item in values)
            return value, f"insert into public.remote_commands({','.join(columns)}) values ({literal});"
        answers = json.dumps({'Which?': 'Option A', 'Name': 'Свободный ответ / free text'}, ensure_ascii=False)
        for _, bad in [command_row('answer', answers=answers), command_row('answer', approval=handle),
                       command_row('answer', approval=handle, answers='{"q":1}'), command_row('answer', approval=handle, answers=answers, text='x'),
                       command_row('answer', approval=handle, answers=answers, turn='t'), command_row('send', text='hi', answers=answers),
                       command_row('queue'), command_row('queue', text='hi', approval=handle), command_row('interrupt', text='hi'),
                       command_row('queue', text='hi', settings=json.dumps({'options': {'model': 'm'}})), command_row('stop', answers=answers),
                       command_row('queue', text='hi', project='private'), command_row('interrupt', text='hi', turn='')]:
            rejects(owner + bad)
        rejects(other + command_row('queue', text='hi')[1])
        # An uncertain message blocks every later message of the chat; answers are still claimed, and first.
        sent, insert_sent = command_row('send', text='first')
        sql(owner + insert_sent)
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('send')
        sql(owner + f"update public.remote_commands set status='uncertain' where id='{sent}';")
        queued, insert_queued = command_row('queue', text='after the turn', photos=photo)
        interrupt, insert_interrupt = command_row('interrupt', text='instead', turn='observed-turn')
        answer, insert_answer = command_row('answer', approval=handle.upper(), answers=answers)
        for statement in [insert_queued, insert_interrupt, insert_answer]: sql(owner + statement)
        rejects(owner + insert_answer)
        rejects(owner + f"update public.remote_commands set answers='{{}}' where id='{answer}';")
        claimed = sql(owner + f"select kind || ':' || approval::text from public.claim_remote_command('{device}');").splitlines()[-1]
        assert claimed == 'answer:' + handle.lower()
        assert sql(owner + f"select answers->>'Name' from public.remote_commands where id='{answer}';").endswith('Свободный ответ / free text')
        assert sql(owner + f"select count(*) from public.claim_remote_command('{device}');").endswith('0')
        # Another chat is not blocked; queue and interrupt keep their creation order there.
        other_queued, insert_other_queued = command_row('queue', chat='other-chat', text='later')
        other_interrupt, insert_other_interrupt = command_row('interrupt', chat='other-chat', text='now', turn='t-2')
        sql(owner + insert_other_queued); sql(owner + insert_other_interrupt)
        assert sql(owner + f"select id::text from public.claim_remote_command('{device}');").endswith(other_queued)
        sql(owner + f"update public.remote_commands set status='submitted' where id='{other_queued}';")
        assert sql(owner + f"select turn from public.claim_remote_command('{device}');").endswith('t-2')
        rejects(owner + f"update public.remote_commands set turn='newer' where id='{other_interrupt}';")
        # Role and add-ons in configure; the expected settings carry the role the Mac published.
        configured_role = json.dumps({'options': {'model': 'm', 'role': 'reader', 'addOns': ['mail']},
                                      'expected': {'model': 'm', 'role': 'editor', 'addOns': []}, 'expectedProjectAccess': 'standard'})
        sql(owner + command_row('configure', chat='settings-chat', settings=configured_role)[1])
        rejects(owner + command_row('configure', chat='settings-chat', settings=configured_role.replace('"mail"', '7'))[1])
        assert sql(owner + 'select public.remote_interactions_version();').endswith('1')
        rejects('set role anon; select public.remote_interactions_version();')
        assert sql(other + 'select count(*) from public.remote_commands;').endswith('0')
        sql(owner + 'delete from public.remote_devices;')
        assert sql('select count(*) from public.remote_commands;') == '0'
        # Web chats: full text written only through the Mac's functions, bigger snapshots, restore/search commands, cleanup.
        sql(owner + f"insert into public.remote_devices(id,name,projects,snapshot) values ('{device}','Mac',array['project'],'{{}}');")
        def put(chat, messages, keep='null'):
            text = json.dumps(messages, ensure_ascii=False).replace("'", "''")
            return f"select public.put_remote_web_chat('{device}','{chat}',now(),'{text}'::jsonb,{keep});"
        sql(owner + put('web:a', [{'id': 'm1', 'seq': 0, 'role': 'user', 'text': 'Привет / Hello'},
                                  {'id': 'm2', 'seq': 1, 'role': 'assistant', 'text': 'я' * 100000, 'truncated': True}]))
        assert sql(owner + "select count(*), bool_or(truncated) from public.remote_web_messages where chat='web:a';").endswith('2|t')
        rejects(owner + put('web:a', [{'id': 'm3', 'seq': 2, 'role': 'assistant', 'text': 'x' * 100001}]))
        rejects(owner + put('web:a', [{'id': 'm3', 'seq': 2, 'role': 'tool', 'text': 'x'}]))
        signals = int(sql("select count(*) from realtime.messages where payload->>'entity' = 'web';"))
        sql(owner + put('web:a', [{'id': 'm3', 'seq': 2, 'role': 'assistant', 'text': 'next'}], "array['m2','m3']"))
        assert sql(owner + "select string_agg(id, ',' order by seq) from public.remote_web_messages;").endswith('m2,m3')
        assert int(sql("select count(*) from realtime.messages where payload->>'entity' = 'web';")) == signals + 1
        preview = {'id': 'generated.png', 'name': 'preview.jpg', 'mimeType': 'image/jpeg', 'data': '/9j/AA=='}
        image_message = {'id': 'm3', 'seq': 2, 'role': 'assistant', 'text': 'next', 'images': [preview], 'imageError': True}
        sql(owner + put('web:a', [image_message]))
        assert sql(owner + '''select images->0->>'data', "imageError" from public.remote_web_messages where id='m3';''').endswith('/9j/AA==|t')
        rejects(owner + put('web:a', [{**image_message, 'images': [preview] * 5}]))
        rejects(owner + put('web:a', [{**image_message, 'images': [{**preview, 'data': 'A' * 530000}]}]))
        rejects(other + put('web:a', [image_message]))
        assert sql(other + 'select count(images) from public.remote_web_messages;').endswith('0')
        # A normal update removes stale previews and errors instead of retaining the old payload.
        sql(owner + put('web:a', [{'id': 'm3', 'seq': 2, 'role': 'assistant', 'text': 'next'}]))
        assert sql(owner + '''select images is null, "imageError" is null from public.remote_web_messages where id='m3';''').endswith('t|t')
        rejects(other + put('web:b', []))
        assert sql(other + 'select count(*) from public.remote_web_messages;').endswith('0')
        rejects(owner + f"insert into public.remote_web_chats(device,chat) values ('{device}','web:direct');")
        rejects(owner + "update public.remote_web_messages set text='edited';")
        ids = [f'chat-{n}' for n in range(30)]
        order = 'array[' + ','.join(f"'{n}'" for n in ids) + ']'
        changed = json.dumps([{'id': n, 'title': n} for n in ids])
        projects = json.dumps([{'id': 'project', 'name': 'Project'}])
        sql(owner + f"select public.patch_remote_snapshot('{device}','Mac','{projects}'::jsonb,{order},'{changed}'::jsonb);")
        assert sql(owner + f"select jsonb_array_length(snapshot->'chats') from public.remote_devices where id='{device}';").endswith('30')
        web_search = str(uuid.uuid4())
        sql(owner + f"insert into public.remote_commands(id,device,project,chat,kind,text) values ('{web_search}','{device}','project','web:{web_search}','search','анкета');")
        web_create = str(uuid.uuid4())
        sql(owner + f"""insert into public.remote_commands(id,device,project,chat,kind,text,settings) values ('{web_create}','{device}','project','web:{web_create}','create','hi','{{"options":{{"model":"m"}}}}');""")
        for _, bad in [command_row('search', chat='web:other', text='x'), command_row('restore', chat='old', text='x'),
                       command_row('restore', chat='old', turn='t'), command_row('restore', chat='old', settings=json.dumps({'options': {'model': 'm'}}))]:
            rejects(owner + bad)
        sql(owner + command_row('restore', chat='old')[1])
        assert sql(owner + f"select kind from public.claim_remote_command('{device}');").endswith('restore')
        sql("update public.remote_web_chats set last_active = now() - interval '16 days';")
        rejects(owner + 'select public.cleanup_remote_web();')
        assert sql('select public.cleanup_remote_web();') == '1'
        assert sql('select count(*) from public.remote_web_messages;') == '0'
        assert sql(owner + 'select public.remote_web_version();').endswith('1')
        sql(owner + 'delete from public.remote_devices;')
        # Push devices: owner-only rows, validated values, one row per token, at most 8 installations, cascade on Auth delete.
        def register(who, installation, token, environment='development', topic='com.contextdesk.mobile', language='ru'):
            return sql(who + f"select public.register_remote_push('{installation}','{token}','{environment}','{topic}','{language}');")
        token_a, token_b = 'a' * 64, '0123456789abcdef' * 10
        phone_a, phone_b = str(uuid.uuid4()), str(uuid.uuid4())
        register(owner, phone_a, token_a)
        assert sql(owner + f"select token, environment, topic, locale from public.remote_push_devices where id='{phone_a}';").endswith(f'{token_a}|development|com.contextdesk.mobile|ru')
        assert sql(other + 'select count(*) from public.remote_push_devices;').endswith('0')
        sql(other + "update public.remote_push_devices set locale = 'en';")
        sql(other + 'delete from public.remote_push_devices;')
        assert sql(owner + f"select locale, count(*) from public.remote_push_devices group by locale;").endswith('ru|1')
        rejects(other + f"insert into public.remote_push_devices(id,owner,token,environment,topic,locale) values ('{uuid.uuid4()}','11111111-1111-1111-1111-111111111111','{token_a}','development','t','en');")
        rejects('set role anon; select count(*) from public.remote_push_devices;')
        rejects(f"set role anon; select public.register_remote_push('{uuid.uuid4()}','{token_a}','development','com.contextdesk.mobile','ru');")
        rejects('set role anon; select public.remote_push_version();')
        rejects("set role authenticated; set request.jwt.claim.sub = ''; " + f"select public.register_remote_push('{uuid.uuid4()}','{token_a}','development','t','ru');")
        for bad in [dict(token='A' * 64), dict(token='a' * 63), dict(token='a' * 401), dict(token='g' * 64), dict(token=''),
                    dict(environment='sandbox'), dict(environment=''), dict(topic='com/evil'), dict(topic=''), dict(topic='a' * 156),
                    dict(language='de'), dict(language='')]:
            rejects(owner + f"select public.register_remote_push('{uuid.uuid4()}','{bad.get('token', token_b)}','{bad.get('environment', 'production')}','{bad.get('topic', 'com.contextdesk.mobile')}','{bad.get('language', 'en')}');")
        assert sql(owner + 'select count(*) from public.remote_push_devices;').endswith('1')
        first = sql(owner + f"select updated from public.remote_push_devices where id='{phone_a}';").splitlines()[-1]
        register(owner, phone_a, token_a, language='en')
        assert sql(owner + f"select updated > '{first}'::timestamptz, locale from public.remote_push_devices where id='{phone_a}';").endswith('t|en')
        # A reinstall registers the same token under a new installation ID: the token moves, one row remains.
        register(owner, phone_b, token_a)
        assert sql(owner + "select string_agg(id::text, ',') from public.remote_push_devices;").endswith(phone_b)
        # Another owner cannot take over an installation ID through the upsert.
        rejects(other + f"select public.register_remote_push('{phone_b}','{token_b}','development','com.contextdesk.mobile','en');")
        assert sql(owner + f"select token from public.remote_push_devices where id='{phone_b}';").endswith(token_a)
        # A ninth installation removes the least recently registered one.
        phones = [phone_b] + [str(uuid.uuid4()) for _ in range(8)]
        for index, phone in enumerate(phones[1:]): register(owner, phone, format(index + 1, 'x') * 64)
        remaining = sql(owner + 'select id::text from public.remote_push_devices order by updated;').splitlines()[-8:]
        assert sql(owner + 'select count(*) from public.remote_push_devices;').endswith('8') and phone_b not in remaining
        assert set(remaining) == set(phones[1:])
        sql(owner + f"delete from public.remote_push_devices where id='{phones[1]}' and token='{'1' * 64}' and updated < now() - interval '1 hour';")
        assert sql(owner + 'select count(*) from public.remote_push_devices;').endswith('8')
        sql(owner + f"delete from public.remote_push_devices where id='{phones[1]}' and token='{'1' * 64}' and updated < now() + interval '1 hour';")
        assert sql(owner + 'select count(*) from public.remote_push_devices;').endswith('7')
        assert sql(owner + 'select public.remote_push_version();').endswith('1')
        sql("insert into auth.users values ('33333333-3333-3333-3333-333333333333');")
        third = "set role authenticated; set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';"
        register(third, str(uuid.uuid4()), 'c' * 64)
        assert sql("select count(*) from public.remote_push_devices where owner = '33333333-3333-3333-3333-333333333333';") == '1'
        sql("delete from auth.users where id = '33333333-3333-3333-3333-333333333333';")
        assert sql("select count(*) from public.remote_push_devices where owner = '33333333-3333-3333-3333-333333333333';") == '0'
        assert sql('select count(*) from public.remote_push_devices;') == '7'
        print('PASS: push devices (owner-only read/update/delete, anonymous denied, token/environment/topic/locale validation, re-registration refreshes, token moves to the newest installation, upsert cannot take another owner\'s ID, 8 installations per owner, guarded delete, version gate, Auth user cascade)')
        print('PASS: web chats (writes only through the Mac functions, owner isolation, 100,000-character limit, keep list, one signal per call, 60-chat snapshots, restore/search validation, 15-day cleanup)')
        print('PASS: interactions (answers bound to a request handle, queue/interrupt validation, uncertain-message blocking with answers still claimed, role/add-on settings, version gate); file answers (owner-only, claimed file commands, immutable, swept after 10 minutes); chat settings validation, immutable choices and uncertain-work blocking; photo expiry, grace period, immutable history, retention permissions/idempotence; all data migrations, delete/recreate revision continuity, atomic event rollback, private channel RLS, compact signals, delta revisions/deletions, owner/project isolation, duplicate claims and no uncertain replay')
    finally:
        if started: run('pg_ctl','-D',folder/'data','-m','fast','-w','stop')
