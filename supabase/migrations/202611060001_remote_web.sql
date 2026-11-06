-- Web client (docs/web-client-plan.md): full-text messages of web chats, restore and archive-search commands,
-- larger snapshots so web chats are listed beside the phone's 20. Apply after remote_interactions.
-- Additive: older phones ignore the new snapshot fields; older Macs reject the new kinds as unknown commands.
begin;
-- One row per web chat. Removing it removes its messages; scheduled cleanup drops chats idle for 15 days.
create table public.remote_web_chats (
    device uuid not null references public.remote_devices(id) on delete cascade,
    chat text not null check (length(chat) between 1 and 500),
    owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
    last_active timestamptz not null default now(),
    primary key (device, chat)
);
create index remote_web_chats_active on public.remote_web_chats(last_active);
create table public.remote_web_messages (
    device uuid not null,
    chat text not null,
    id text not null check (length(id) between 1 and 500),
    owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
    seq integer not null check (seq >= 0),
    role text not null check (role in ('user','assistant')),
    text text not null check (char_length(text) <= 100000),
    truncated boolean,
    updated timestamptz not null default now(),
    primary key (device, chat, id),
    foreign key (device, chat) references public.remote_web_chats(device, chat) on delete cascade
);
create index remote_web_messages_order on public.remote_web_messages(device, chat, seq);
alter table public.remote_web_chats enable row level security;
alter table public.remote_web_messages enable row level security;
-- Clients only read; the Mac writes through the functions below.
create policy remote_web_chats_read on public.remote_web_chats for select to authenticated using (owner = (select auth.uid()));
create policy remote_web_messages_read on public.remote_web_messages for select to authenticated using (owner = (select auth.uid()));
revoke all on public.remote_web_chats, public.remote_web_messages from anon, authenticated;
grant select on public.remote_web_chats, public.remote_web_messages to authenticated;

-- Mac: upserts a web chat and the given messages; with `keep`, removes the chat's other messages.
-- One Realtime invalidation per call. Only the owner of the device may write.
create function public.put_remote_web_chat(device_id uuid, chat_id text, active timestamptz, messages jsonb, keep text[] default null)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
    if uid is null or not exists(select 1 from public.remote_devices d where d.id = device_id and d.owner = uid)
       or length(chat_id) not between 1 and 500 or jsonb_typeof(messages) <> 'array' or jsonb_array_length(messages) > 500
       or (keep is not null and cardinality(keep) > 500) then
        raise exception 'invalid web chat';
    end if;
    insert into public.remote_web_chats(device, chat, owner, last_active) values (device_id, chat_id, uid, least(active, now()))
    on conflict (device, chat) do update set last_active = excluded.last_active
    where remote_web_chats.last_active is distinct from excluded.last_active;
    insert into public.remote_web_messages(device, chat, id, owner, seq, role, text, truncated)
    select device_id, chat_id, m->>'id', uid, (m->>'seq')::integer, m->>'role', m->>'text',
           case when (m->>'truncated')::boolean then true end
    from jsonb_array_elements(messages) m
    on conflict (device, chat, id) do update set seq = excluded.seq, role = excluded.role, text = excluded.text,
        truncated = excluded.truncated, updated = now()
    where (remote_web_messages.seq, remote_web_messages.role, remote_web_messages.text, remote_web_messages.truncated)
          is distinct from (excluded.seq, excluded.role, excluded.text, excluded.truncated);
    if keep is not null then
        delete from public.remote_web_messages where device = device_id and chat = chat_id and not (id = any(keep));
    end if;
    perform realtime.send(jsonb_build_object('entity','web','device',device_id,'chat',chat_id), 'changed', 'remote:' || uid::text, true);
end $$;
-- Mac: removes an expired, archived or deleted web chat.
create function public.drop_remote_web_chat(device_id uuid, chat_id text)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
    if uid is null then raise exception 'invalid web chat'; end if;
    delete from public.remote_web_chats where device = device_id and chat = chat_id and owner = uid;
    perform realtime.send(jsonb_build_object('entity','web','device',device_id,'chat',chat_id), 'changed', 'remote:' || uid::text, true);
end $$;
revoke all on function public.put_remote_web_chat(uuid,text,timestamptz,jsonb,text[]), public.drop_remote_web_chat(uuid,text) from public, anon;
grant execute on function public.put_remote_web_chat(uuid,text,timestamptz,jsonb,text[]), public.drop_remote_web_chat(uuid,text) to authenticated;

-- Invoker security: the maintenance role sweeps all owners; clients cannot invoke this function.
create function public.cleanup_remote_web() returns bigint
language plpgsql security invoker set search_path = '' as $$
declare cleaned bigint;
begin
    delete from public.remote_web_chats where last_active <= now() - interval '15 days';
    get diagnostics cleaned = row_count;
    return cleaned;
end $$;
revoke all on function public.cleanup_remote_web() from public, anon, authenticated;
comment on table public.remote_web_messages is 'Full text of web chats (latest 500 messages). Removed with the chat 15 days after its last activity.';

-- Snapshots list the phone's 20 chats plus web chats.
alter table public.remote_devices drop constraint remote_devices_snapshot_check;
alter table public.remote_devices add constraint remote_devices_snapshot_check check (octet_length(snapshot::text) <= 4194304);
create or replace function public.patch_remote_snapshot(device_id uuid, device_name text, project_list jsonb,
                                                        chat_order text[], changed_chats jsonb) returns void
language plpgsql security invoker set search_path = '' as $$
declare previous jsonb; document jsonb;
begin
    if auth.uid() is null or jsonb_array_length(changed_chats) > 60 or cardinality(chat_order) > 60 then
        raise exception 'invalid snapshot';
    end if;
    select snapshot into previous from public.remote_devices where id = device_id for update;
    select jsonb_build_object('version',1,'projects',project_list,'chats',coalesce(jsonb_agg(c.payload order by ids.ord),'[]'::jsonb))
    into document from unnest(chat_order) with ordinality ids(id,ord)
    cross join lateral (
        select payload from (
            select value as payload, 0 as priority from jsonb_array_elements(changed_chats) where value->>'id' = ids.id
            union all
            select value, 1 from jsonb_array_elements(coalesce(previous->'chats','[]'::jsonb)) where value->>'id' = ids.id
        ) matches order by priority limit 1
    ) c;
    insert into public.remote_devices(id,owner,name,projects,snapshot)
    values(device_id,auth.uid(),device_name,array(select value->>'id' from jsonb_array_elements(project_list)),document)
    on conflict(id) do update set name = excluded.name, projects = excluded.projects,
        snapshot = excluded.snapshot, seen = now();
end $$;

-- restore: brings an existing chat back to the web. search: starts an archive-search chat with a web ID.
alter table public.remote_commands drop constraint remote_commands_kind_check;
alter table public.remote_commands add constraint remote_commands_kind_check
    check (kind in ('send','stop','allow','deny','create','configure','file','answer','queue','interrupt','restore','search'));
alter table public.remote_commands drop constraint remote_settings_valid;
alter table public.remote_commands add constraint remote_settings_valid check (
    public.valid_remote_settings(settings, kind)
    and (kind not in ('create','configure') or (approval is null and turn is null))
    and (kind <> 'create' or (chat in ('mobile:' || id::text, 'web:' || id::text)
                              and (length(trim(text)) > 0 or coalesce(jsonb_array_length(photos),0) > 0)))
    and (kind <> 'configure' or (text = '' and photos is null))
);
alter table public.remote_commands add constraint remote_web_valid check (
    kind not in ('restore','search') or (approval is null and turn is null and photos is null and settings is null and answers is null
        and (kind <> 'restore' or text = '')
        and (kind <> 'search' or (chat = 'web:' || id::text and length(trim(text)) between 1 and 2000)))
);
-- An archive search starts a chat, so it waits in the per-chat order like create.
create or replace function public.claim_remote_command(device_id uuid) returns setof public.remote_commands
language sql security invoker set search_path = '' as $$
    update public.remote_commands set status = 'claimed'
    where id = (select id from public.remote_commands
                where device = device_id and owner = auth.uid() and status = 'pending'
                  and (kind not in ('send','create','configure','queue','interrupt','search') or not exists (
                      select 1 from public.remote_commands earlier
                      where earlier.device = remote_commands.device and earlier.chat = remote_commands.chat
                        and earlier.status in ('claimed', 'uncertain')
                  ))
                order by case when kind in ('send','create','configure','queue','interrupt','search') then 1 else 0 end, created, id
                for update skip locked limit 1)
    returning *;
$$;
create function public.remote_web_version() returns integer
language sql stable security invoker set search_path = '' as $$ select 1; $$;
revoke all on function public.remote_web_version() from public;
grant execute on function public.remote_web_version() to authenticated;
notify pgrst, 'reload schema';
commit;
