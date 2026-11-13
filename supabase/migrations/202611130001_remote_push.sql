-- iPhone push notifications: one APNs device token per app installation, owner-only. Apply after remote_web_images.
-- Notification text is never stored here; the Mac reads these rows and sends through APNs itself.
begin;
create table public.remote_push_devices (
    id uuid primary key,                       -- app installation ID kept by the phone
    owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
    -- PostgreSQL regex bounds stop at 255, so the length is checked separately.
    token text not null check (token ~ '^[0-9a-f]+$' and length(token) between 64 and 400),
    environment text not null check (environment in ('development','production')),
    topic text not null check (topic ~ '^[A-Za-z0-9.-]{1,155}$'),
    locale text not null check (locale in ('ru','en')),
    updated timestamptz not null default now()
);
create index remote_push_devices_owner on public.remote_push_devices(owner, updated desc);
alter table public.remote_push_devices enable row level security;
create policy remote_push_devices_owner on public.remote_push_devices for all to authenticated
    using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
revoke all on public.remote_push_devices from anon;
grant select, insert, update, delete on public.remote_push_devices to authenticated;
comment on table public.remote_push_devices is 'APNs device tokens of the owner''s iPhone installations (at most 8 per owner). Identifiers only, no notification text.';
create function public.register_remote_push(device_id uuid, device_token text, apns_environment text,
                                            apns_topic text, language text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
    if auth.uid() is null then raise exception 'not authenticated'; end if;
    delete from public.remote_push_devices where owner = auth.uid() and token = device_token and id <> device_id;
    insert into public.remote_push_devices(id, owner, token, environment, topic, locale)
        values (device_id, auth.uid(), device_token, apns_environment, apns_topic, language)
    on conflict (id) do update set token = excluded.token, environment = excluded.environment,
        topic = excluded.topic, locale = excluded.locale, updated = now();
    delete from public.remote_push_devices where owner = auth.uid() and id in (
        select d.id from public.remote_push_devices d where d.owner = auth.uid()
        order by d.updated desc, d.id offset 8);
end $$;
revoke all on function public.register_remote_push(uuid, text, text, text, text) from public, anon;
grant execute on function public.register_remote_push(uuid, text, text, text, text) to authenticated;
create function public.remote_push_version() returns integer
language sql stable security invoker set search_path = '' as $$ select 1; $$;
revoke all on function public.remote_push_version() from public;
grant execute on function public.remote_push_version() to authenticated;
notify pgrst, 'reload schema';
commit;
