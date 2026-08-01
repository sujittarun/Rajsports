-- ============================================================
-- cron-raj-2 · the reminder jobs now authenticate themselves
-- scope: raj
--
-- The whatsapp-reminder function is deployed --no-verify-jwt, because
-- Meta must reach /webhook without a Supabase JWT. That left every
-- other route open to anyone who knew the URL: a POST to
-- /run?tenant=<any tenant> triggered a real send sweep to that
-- academy's parents, and `tenant` is a query parameter. Verified live
-- on 2026-08-01 — an unauthenticated GET answered `POST only`.
--
-- The function now requires x-am-secret. These jobs send it, read from
-- Vault at call time so the plaintext never sits in cron.job.command
-- (where the anon key currently does).
--
-- Order matters: this runs BEFORE the function is redeployed. An
-- extra header the old build ignores is harmless; the reverse would
-- have stopped Raj's reminders until the cron caught up.
-- ============================================================

select cron.unschedule(jobname)
  from cron.job
 where jobname in ('raj-fee-reminders-daily', 'raj-fee-reminders-retry');

-- ---------- the daily sweep, 15:00 IST ----------
select cron.schedule(
  'raj-fee-reminders-daily',
  '30 9 * * *',
  $job$
  select net.http_post(
    url     := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/whatsapp-reminder/run?tenant=raj',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-am-secret',
                 (select decrypted_secret from vault.decrypted_secrets where name = 'am_fn_secret')),
    body    := '{}'::jsonb
  );
  $job$
);

-- ---------- the retry worker, every 5 minutes ----------
select cron.schedule(
  'raj-fee-reminders-retry',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url     := 'https://ugsklcipzyiogxynshnh.supabase.co/functions/v1/whatsapp-reminder/retry?tenant=raj',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-am-secret',
                 (select decrypted_secret from vault.decrypted_secrets where name = 'am_fn_secret')),
    body    := '{}'::jsonb
  );
  $job$
);

-- The secret must exist, or these jobs would send a null header and the
-- reminders would fail silently at 15:00.
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'am_fn_secret') then
    raise exception 'vault secret am_fn_secret is missing — set it before scheduling';
  end if;
  if exists (select 1 from cron.job where jobname like 'raj-fee-reminders-%'
              and command like '%anon%') then
    raise exception 'a reminder job still carries the anon key';
  end if;
  raise notice 'raj reminder jobs now authenticate with x-am-secret from vault';
end $$;
