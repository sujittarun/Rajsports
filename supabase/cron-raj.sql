-- ============================================================
-- RAJ SPORTS — scheduled jobs for the reminder engine.
--
-- Both jobs are SAFE TO LEAVE RUNNING before the WhatsApp Business
-- number exists: the function reads tenants.config.whatsapp and, while
-- mode = 'manual', it reports and returns without sending or writing
-- anything. Turning sending on is a config flip, not a redeploy and not
-- a cron change.
--
-- Times are UTC (pg_cron runs in UTC): 09:30 UTC = 15:00 IST, which is
-- the hour the Gen Alpha academy settled on — late enough that parents
-- are reachable, early enough to still pay the same day.
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Idempotent: drop before recreating so re-running is safe.
select cron.unschedule(jobid) from cron.job where jobname in
  ('raj-fee-reminders-daily', 'raj-fee-reminders-retry');

-- ---------- the daily sweep, 15:00 IST ----------
select cron.schedule(
  'raj-fee-reminders-daily',
  '30 9 * * *',
  $job$
  select net.http_post(
    url     := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/whatsapp-reminder/run?tenant=raj',
    -- the anon key is public by design; the function itself is deployed
    -- --no-verify-jwt and authorises via the service role internally
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVnc2tsY2lwenlpb2d4eW5zaG5oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4OTUyMzksImV4cCI6MjA5ODQ3MTIzOX0.w7xkjdTkYN2qA0oxMKLUNtua0ScKVHKQzfEyIayh9eo'),
    body    := '{}'::jsonb
  );
  $job$
);

-- ---------- the retry worker, every 5 minutes ----------
-- Only Meta's 131049 (healthy-ecosystem throttle) is retried, at 5/30/60
-- minutes. Anything else is a human problem, not a timing problem.
select cron.schedule(
  'raj-fee-reminders-retry',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url     := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/whatsapp-reminder/retry?tenant=raj',
    -- the anon key is public by design; the function itself is deployed
    -- --no-verify-jwt and authorises via the service role internally
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVnc2tsY2lwenlpb2d4eW5zaG5oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4OTUyMzksImV4cCI6MjA5ODQ3MTIzOX0.w7xkjdTkYN2qA0oxMKLUNtua0ScKVHKQzfEyIayh9eo'),
    body    := '{}'::jsonb
  );
  $job$
);

select jobname, schedule, active from cron.job where jobname like 'raj-%' order by jobname;
