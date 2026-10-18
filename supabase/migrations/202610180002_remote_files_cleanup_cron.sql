-- Supabase-hosted activation; run after remote_files. Named schedule is idempotent.
begin;
create extension if not exists pg_cron;
select cron.schedule('switchboard-file-cleanup', '*/5 * * * *',
                     'select public.cleanup_remote_files();');
commit;
