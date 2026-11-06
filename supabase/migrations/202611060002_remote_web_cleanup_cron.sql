-- Supabase-hosted activation; run after remote_web. Named schedule is idempotent.
begin;
create extension if not exists pg_cron;
select cron.schedule('switchboard-web-cleanup', '17 * * * *',
                     'select public.cleanup_remote_web();');
commit;
