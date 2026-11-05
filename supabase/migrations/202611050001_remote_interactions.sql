-- Phone answers to agent questions and tool forms, messages for a working chat (desktop queue and
-- "Interrupt and send"), and role and add-on choices in chat settings. Apply after remote_files.
-- Additive: older phones keep their commands; older Macs reject the new kinds as unknown commands.
begin;
-- Chat settings may name a role and add-ons. The Mac checks both against its catalog and the project's limits.
create or replace function public.valid_remote_options(value jsonb) returns boolean
language sql immutable set search_path = '' as $$
    select coalesce(jsonb_typeof(value) = 'object'
        and jsonb_typeof(value->'model') = 'string'
        and octet_length(value->>'model') between 1 and 200
        and (value - 'model' - 'access' - 'role' - 'addOns') = '{}'::jsonb
        and (not (value ? 'access') or value->'access' = 'null'::jsonb or value->>'access' in ('standard','fullAccess'))
        and (not (value ? 'role') or value->'role' = 'null'::jsonb
             or (jsonb_typeof(value->'role') = 'string' and octet_length(value->>'role') between 1 and 200))
        and (not (value ? 'addOns') or value->'addOns' = 'null'::jsonb
             or (jsonb_typeof(value->'addOns') = 'array' and jsonb_array_length(value->'addOns') <= 8
                 and not exists (select 1 from jsonb_array_elements(value->'addOns') item
                                 where jsonb_typeof(item) <> 'string' or octet_length(item #>> '{}') not between 1 and 64))), false);
$$;
-- Answers: question id -> answer text. Secrets are never answered from the phone (the Mac refuses them).
create function public.valid_remote_answers(value jsonb) returns boolean
language sql immutable set search_path = '' as $$
    select coalesce(jsonb_typeof(value) = 'object' and octet_length(value::text) <= 40000
        and (select count(*) from jsonb_each(value)) <= 8
        and not exists (select 1 from jsonb_each(value) entry
                        where octet_length(entry.key) = 0 or jsonb_typeof(entry.value) <> 'string'
                           or octet_length(entry.value #>> '{}') > 8000), false);
$$;
alter table public.remote_commands add column answers jsonb;
comment on column public.remote_commands.answers is 'Answers to one pending question or form (kind answer); immutable owner-scoped command data like text.';
alter table public.remote_commands drop constraint remote_commands_kind_check;
alter table public.remote_commands add constraint remote_commands_kind_check
    check (kind in ('send','stop','allow','deny','create','configure','file','answer','queue','interrupt'));
alter table public.remote_commands add constraint remote_answers_valid check (
    (kind = 'answer') = (answers is not null)
    and (kind <> 'answer' or (public.valid_remote_answers(answers) and approval is not null
                              and text = '' and turn is null and photos is null and settings is null))
);
-- queue: joins the chat's desktop queue. interrupt: stops the observed turn and sends next.
alter table public.remote_commands add constraint remote_working_send_valid check (
    kind not in ('queue','interrupt') or (approval is null and settings is null
        and (length(trim(text)) > 0 or coalesce(jsonb_array_length(photos), 0) > 0)
        and (kind <> 'interrupt' or (turn is not null and length(turn) between 1 and 500)))
);
alter table public.remote_commands drop constraint remote_photos_valid;
alter table public.remote_commands add constraint remote_photos_valid check (
    public.valid_remote_photos(photos) and (photos is null or kind in ('send','create','queue','interrupt'))
);
-- Every kind that brings a message to the agent waits behind a claimed or uncertain one in the same chat.
-- Control commands (stop, allow, deny, answer, file) are claimed first and are never blocked.
create or replace function public.claim_remote_command(device_id uuid) returns setof public.remote_commands
language sql security invoker set search_path = '' as $$
    update public.remote_commands set status = 'claimed'
    where id = (select id from public.remote_commands
                where device = device_id and owner = auth.uid() and status = 'pending'
                  and (kind not in ('send','create','configure','queue','interrupt') or not exists (
                      select 1 from public.remote_commands earlier
                      where earlier.device = remote_commands.device and earlier.chat = remote_commands.chat
                        and earlier.status in ('claimed', 'uncertain')
                  ))
                order by case when kind in ('send','create','configure','queue','interrupt') then 1 else 0 end, created, id
                for update skip locked limit 1)
    returning *;
$$;
create function public.remote_interactions_version() returns integer
language sql stable security invoker set search_path = '' as $$ select 1; $$;
revoke all on function public.remote_interactions_version() from public;
grant execute on function public.remote_interactions_version() to authenticated;
notify pgrst, 'reload schema';
commit;
