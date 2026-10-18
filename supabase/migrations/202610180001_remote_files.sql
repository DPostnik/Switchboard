-- Read-only file viewing from the phone. Apply after chat_settings.
-- The phone queues a 'file' command with the path in `text`; the Mac answers once
-- into a short-lived owner-only row that the phone deletes after reading.
begin;
alter table public.remote_commands drop constraint remote_commands_kind_check;
alter table public.remote_commands add constraint remote_commands_kind_check
    check (kind in ('send','stop','allow','deny','create','configure','file'));
alter table public.remote_commands add constraint remote_file_valid check (
    kind <> 'file' or (length(trim(text)) between 1 and 4096 and position(E'\n' in text) = 0
                       and photos is null and settings is null and approval is null and turn is null)
);
create table public.remote_files (
    id uuid primary key references public.remote_commands(id) on delete cascade,
    owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
    payload jsonb not null check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 4194304),
    created timestamptz not null default now()
);
create index remote_files_created on public.remote_files(created);
alter table public.remote_files enable row level security;
-- Only the owner's claimed file command can receive one answer; answers are never edited.
create policy remote_files_insert on public.remote_files for insert to authenticated with check (
    owner = (select auth.uid())
    and exists(select 1 from public.remote_commands c
               where c.id = remote_files.id and c.owner = (select auth.uid()) and c.kind = 'file' and c.status = 'claimed')
);
create policy remote_files_read on public.remote_files for select to authenticated using (owner = (select auth.uid()));
create policy remote_files_delete on public.remote_files for delete to authenticated using (owner = (select auth.uid()));
revoke all on public.remote_files from anon;
grant select, insert, delete on public.remote_files to authenticated;
-- Invoker security: the maintenance role sweeps all owners; clients cannot invoke this function.
create function public.cleanup_remote_files() returns bigint
language plpgsql security invoker set search_path = '' as $$
declare cleaned bigint;
begin
    delete from public.remote_files where created <= now() - interval '10 minutes';
    get diagnostics cleaned = row_count;
    return cleaned;
end $$;
revoke all on function public.cleanup_remote_files() from public, anon, authenticated;
create function public.remote_files_version() returns integer
language sql stable security invoker set search_path = '' as $$ select 1; $$;
revoke all on function public.remote_files_version() from public;
grant execute on function public.remote_files_version() to authenticated;
comment on table public.remote_files is 'Temporary file contents for the phone. Deleted by the phone after reading and by scheduled cleanup after 10 minutes.';
notify pgrst, 'reload schema';
commit;
