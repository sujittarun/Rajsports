-- ============================================================
-- RAJ SPORTS — migration 2: public read for the timetable
--
-- The landing page has to show centres, batches and sports to a parent
-- who is not signed in. These three tables hold no personal data — they
-- are exactly what the academy advertises — so anon may read the ACTIVE
-- rows. Everything with money or people in it (enrollments, fee_rules,
-- payout_rules, members, reminder_events) stays staff-only.
--
-- Idempotent. Apply with scripts/migrate.sh.
-- ============================================================

do $$
declare t text;
begin
  foreach t in array array['centres','batches','sports'] loop
    execute format('drop policy if exists %I on %I', t || '_public_r', t);
    execute format($p$create policy %I on %I for select to anon
      using (active)$p$, t || '_public_r', t);
  end loop;
end $$;

-- The public enrolment form posts here as anon. lockdown.sql narrowed
-- this table, so re-assert the insert-only path the form needs: anon may
-- WRITE an application but never read one back.
drop policy if exists applications_public_w on applications;
create policy applications_public_w on applications
  for insert to anon
  with check (
    tenant_id = 'raj'
    and coalesce(status, 'pending') = 'pending'
    and member_id is null            -- an application can't claim a roster row
    and reviewed_at is null
  );

-- Anon needs the timetable read to resolve names, and nothing else.
grant select on centres, batches, sports to anon;
grant insert on applications to anon;

-- Verify the intent rather than trusting the policy text: as anon,
-- the timetable is visible and the roster is not.
do $$
declare n int;
begin
  set local role anon;
  select count(*) into n from centres where tenant_id = 'raj';
  if n = 0 then raise exception 'anon still cannot read centres'; end if;

  select count(*) into n from members where tenant_id = 'raj';
  if n > 0 then raise exception 'anon can read members — that must never happen'; end if;

  select count(*) into n from enrollments where tenant_id = 'raj';
  if n > 0 then raise exception 'anon can read enrollments — that must never happen'; end if;

  select count(*) into n from fee_rules where tenant_id = 'raj';
  if n > 0 then raise exception 'anon can read fee_rules — that must never happen'; end if;

  reset role;
end $$;
