-- Bounded generated-image previews, under the same owner-only policy and retention as web messages.
-- Apply after remote_web. No local filesystem paths or public storage URLs are introduced.
begin;
alter table public.remote_web_messages add column images jsonb;
alter table public.remote_web_messages add column "imageError" boolean;
alter table public.remote_web_messages add constraint remote_web_images_bounded check (
    images is null or (jsonb_typeof(images) = 'array' and jsonb_array_length(images) <= 4
                      and octet_length(images::text) <= 530000)
);
create or replace function public.put_remote_web_chat(device_id uuid, chat_id text, active timestamptz, messages jsonb, keep text[] default null)
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
    insert into public.remote_web_messages(device, chat, id, owner, seq, role, text, truncated, images, "imageError")
    select device_id, chat_id, m->>'id', uid, (m->>'seq')::integer, m->>'role', m->>'text',
           case when (m->>'truncated')::boolean then true end,
           nullif(m->'images', 'null'::jsonb), case when (m->>'imageError')::boolean then true end
    from jsonb_array_elements(messages) m
    on conflict (device, chat, id) do update set seq = excluded.seq, role = excluded.role, text = excluded.text,
        truncated = excluded.truncated, images = excluded.images, "imageError" = excluded."imageError", updated = now()
    where (remote_web_messages.seq, remote_web_messages.role, remote_web_messages.text, remote_web_messages.truncated, remote_web_messages.images, remote_web_messages."imageError")
          is distinct from (excluded.seq, excluded.role, excluded.text, excluded.truncated, excluded.images, excluded."imageError");
    if keep is not null then
        delete from public.remote_web_messages where device = device_id and chat = chat_id and not (id = any(keep));
    end if;
    perform realtime.send(jsonb_build_object('entity','web','device',device_id,'chat',chat_id), 'changed', 'remote:' || uid::text, true);
end $$;

notify pgrst, 'reload schema';
commit;
