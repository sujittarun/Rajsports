-- ============================================================
-- Functional tests for migration-raj.sql.
-- Run with scripts/test-migration.sh — it concatenates the migration
-- and this file inside one transaction and rolls the whole thing back,
-- so it proves behaviour against the live schema without persisting.
-- Any failed assertion raises and aborts.
-- ============================================================
do $$
declare
  c_dps    bigint; c_btv bigint;
  b_dps1   bigint; b_btv1 bigint;
  m_a      bigint; m_b bigint; m_c bigint;
  e_a      bigint; e_b bigint; e_c bigint;
  v_coach  bigint;
  fee      jsonb;
  res      jsonb;
  stg      text;
  reason   text;
  d        date;
  n        int;
  amt      numeric;
  ok       boolean;
  sent_at  timestamptz;
  channel  text;
begin
  -- Keep the test deterministic when the requested SAMPLE roster is loaded.
  -- The outer transaction restores every live row below on rollback.
  delete from payouts where tenant_id='raj';
  delete from reminder_events where tenant_id='raj';
  delete from payments where tenant_id='raj';
  delete from attendance_records where tenant_id='raj';
  delete from sessions where tenant_id='raj';
  delete from enrollments where tenant_id='raj';
  delete from members where tenant_id='raj';
  delete from payout_rules where tenant_id='raj';
  delete from fee_rules where tenant_id='raj';

  select id into c_dps from centres where tenant_id='raj' and code='dps-miyapur';
  select id into c_btv from centres where tenant_id='raj' and code='btv';
  select id into b_dps1 from batches where tenant_id='raj' and code='dps-b1';
  select id into b_btv1 from batches where tenant_id='raj' and code='btv-b1';

  if c_dps is null or c_btv is null or b_dps1 is null or b_btv1 is null then
    raise exception 'TEST FAIL: seed centres/batches missing';
  end if;

  select count(*) into n from batches where tenant_id='raj';
  if n <> 13 then raise exception 'TEST FAIL: expected 13 batches, got %', n; end if;
  raise notice 'OK  seed — 5 centres, 13 batches, 5 sports';

  -- ---------- members + enrollments ----------
  insert into members (tenant_id, name, parent_name, parent_phone, status)
    values ('raj','RAJTEST Aarav','RAJTEST Parent A','9876500001','active') returning id into m_a;
  insert into members (tenant_id, name, parent_name, parent_phone, status)
    values ('raj','RAJTEST Bhavya','RAJTEST Parent B','9876500002','active') returning id into m_b;
  insert into members (tenant_id, name, parent_name, parent_phone, status, whatsapp_status)
    values ('raj','RAJTEST Chetan','RAJTEST Parent C','9876500003','active','wrong_number') returning id into m_c;

  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, plan_months, joined_on, renewal_on)
    values ('raj', m_a, c_dps, b_dps1, 'cricket', 1, ist_today()-60, ist_today()) returning id into e_a;
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, plan_months, joined_on, renewal_on)
    values ('raj', m_b, c_btv, b_btv1, 'basketball', 3, ist_today()-90, ist_today()-8) returning id into e_b;
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, plan_months, joined_on, renewal_on, custom_amount)
    values ('raj', m_c, c_dps, b_dps1, 'tennis', 1, ist_today()-30, ist_today()-5, 999) returning id into e_c;

  -- ---------- THE FEE CHAIN ----------
  -- unset first
  fee := enrollment_fee(e_a);
  if fee->>'source' <> 'unset' then raise exception 'TEST FAIL: expected unset, got %', fee; end if;

  -- tenant default 1000
  insert into fee_rules (tenant_id, label, monthly_amount, admission_fee)
    values ('raj','Default', 1000, 500);
  fee := enrollment_fee(e_a);
  if (fee->>'amount')::numeric <> 1000 or fee->>'source' <> 'default' then
    raise exception 'TEST FAIL: default rule — %', fee; end if;

  -- centre override 1200 (PRC-style "everything here is X")
  insert into fee_rules (tenant_id, label, centre_id, monthly_amount)
    values ('raj','DPS rate', c_dps, 1200);
  fee := enrollment_fee(e_a);
  if (fee->>'amount')::numeric <> 1200 or fee->>'source' <> 'centre' then
    raise exception 'TEST FAIL: centre rule — %', fee; end if;

  -- sport override 1500 beats centre
  insert into fee_rules (tenant_id, label, sport, monthly_amount)
    values ('raj','Cricket rate','cricket', 1500);
  fee := enrollment_fee(e_a);
  if (fee->>'amount')::numeric <> 1500 or fee->>'source' <> 'sport' then
    raise exception 'TEST FAIL: sport rule — %', fee; end if;

  -- centre+sport beats both
  insert into fee_rules (tenant_id, label, centre_id, sport, monthly_amount)
    values ('raj','Cricket @ DPS', c_dps, 'cricket', 1800);
  fee := enrollment_fee(e_a);
  if (fee->>'amount')::numeric <> 1800 or fee->>'source' <> 'centre_sport' then
    raise exception 'TEST FAIL: centre_sport rule — %', fee; end if;

  -- batch beats centre+sport
  insert into fee_rules (tenant_id, label, batch_id, monthly_amount)
    values ('raj','DPS Batch 1', b_dps1, 2000);
  fee := enrollment_fee(e_a);
  if (fee->>'amount')::numeric <> 2000 or fee->>'source' <> 'batch' then
    raise exception 'TEST FAIL: batch rule — %', fee; end if;

  -- member beats batch
  insert into fee_rules (tenant_id, label, member_id, monthly_amount)
    values ('raj','Sibling discount', m_a, 900);
  fee := enrollment_fee(e_a);
  if (fee->>'amount')::numeric <> 900 or fee->>'source' <> 'member' then
    raise exception 'TEST FAIL: member rule — %', fee; end if;

  -- enrollment custom_amount beats everything
  fee := enrollment_fee(e_c);
  if (fee->>'amount')::numeric <> 999 or fee->>'source' <> 'custom' then
    raise exception 'TEST FAIL: custom override — %', fee; end if;
  raise notice 'OK  fee chain — custom > member > batch > centre_sport > sport > centre > default';

  -- plan pricing: 3 months of basketball, with a discount on the 3-month plan
  insert into fee_rules (tenant_id, label, sport, monthly_amount, plan_amounts)
    values ('raj','Basketball','basketball', 1200, '{"3": 3000, "6": 5500}'::jsonb);
  fee := enrollment_fee(e_b);           -- e_b is a 3-month plan
  if (fee->>'amount')::numeric <> 3000 then
    raise exception 'TEST FAIL: 3-month plan price — %', fee; end if;
  fee := enrollment_fee(e_b, 2);        -- no keyed price → monthly × 2
  if (fee->>'amount')::numeric <> 2400 then
    raise exception 'TEST FAIL: fallback multiply — %', fee; end if;
  raise notice 'OK  plan pricing — keyed plan_amounts, fallback to monthly × months';

  -- ---------- REMINDER QUEUE ----------
  select count(*) into n from reminder_queue('raj');
  if n < 3 then raise exception 'TEST FAIL: queue should hold 3 test students, got %', n; end if;

  -- Aarav is due TODAY, amount must be his resolved fee (900), not a default
  select q.stage, q.amount into stg, amt from reminder_queue('raj') q where q.enrollment_id = e_a;
  if stg <> 'due' then raise exception 'TEST FAIL: expected stage due, got %', stg; end if;
  if amt <> 900 then raise exception 'TEST FAIL: reminder amount should be 900, got %', amt; end if;

  -- the -2 day heads-up and the day-2 gap: day 2 is deliberately NOT a send day
  select count(*) into n from reminder_queue('raj', ist_today() + 2) q where q.enrollment_id = e_a;
  if n <> 0 then raise exception 'TEST FAIL: day-2 overdue must not be a send day'; end if;
  select q.stage into stg from reminder_queue('raj', ist_today() - 2) q where q.enrollment_id = e_a;
  if stg <> 'heads_up' then raise exception 'TEST FAIL: 2 days before should be heads_up, got %', stg; end if;

  -- Bhavya is 8 days overdue → overdue stage, not blocked
  select q.blocked_reason is null into ok from reminder_queue('raj') q where q.enrollment_id = e_b;
  if not ok then raise exception 'TEST FAIL: 8-day overdue should not be blocked'; end if;

  -- Chetan has a wrong number → must be blocked before any send
  select q.blocked_reason into reason from reminder_queue('raj') q where q.enrollment_id = e_c;
  if reason is distinct from 'wrong_phone_number' then
    raise exception 'TEST FAIL: wrong_number must block, got %', reason; end if;

  -- and 15+ days overdue stops the automation entirely
  update enrollments set renewal_on = ist_today() - 20 where id = e_b;
  select q.blocked_reason into reason from reminder_queue('raj') q where q.enrollment_id = e_b;
  if reason is distinct from 'overdue_15_days' then
    raise exception 'TEST FAIL: 15+ days must stop automation, got %', reason; end if;
  update enrollments set renewal_on = ist_today() - 8 where id = e_b;
  raise notice 'OK  reminder queue — stages, dynamic amounts, wrong-number blocking';

  -- ---------- PAYMENT ROLLS THE RENEWAL ----------
  res := record_fee_payment('raj', e_a, 900, 1, 'UPI', 'renewal');
  if (res->>'renewal_on')::date <> (ist_today() + interval '1 month')::date then
    raise exception 'TEST FAIL: renewal should roll 1 month, got %', res; end if;

  -- paying while already 8 days overdue must extend from TODAY, not from the
  -- old (past) renewal date — otherwise the student stays overdue after paying
  res := record_fee_payment('raj', e_b, 3000, 3, 'Cash', 'renewal');
  if (res->>'period_from')::date <> ist_today() then
    raise exception 'TEST FAIL: overdue renewal must start today, got %', res; end if;
  if (res->>'renewal_on')::date <> (ist_today() + interval '3 months')::date then
    raise exception 'TEST FAIL: 3-month roll wrong, got %', res; end if;

  -- a pending-verification payment must NOT move the renewal date
  res := record_fee_payment('raj', e_c, 999, 1, 'UPI', 'renewal', null, 'UTR123', 'pending_verification');
  select e.renewal_on into d from enrollments e where e.id = e_c;
  if d <> (ist_today() - 5) then
    raise exception 'TEST FAIL: pending payment must not roll renewal, got %', d; end if;
  raise notice 'OK  payments — roll forward, never back-date, pending stays unpaid';

  -- paying clears the open reminder
  insert into reminder_events (tenant_id, member_id, enrollment_id, stage, status, ist_date)
    values ('raj', m_a, e_a, 'due', 'delivered', ist_today() - 1);
  perform record_fee_payment('raj', e_a, 900, 1, 'UPI', 'renewal');
  select count(*) into n from reminder_events
    where enrollment_id = e_a and status = 'resolved';
  if n < 1 then raise exception 'TEST FAIL: payment should resolve open reminders'; end if;
  raise notice 'OK  payment resolves the open reminder';

  -- ---------- PAYOUTS: how the PT master and the centre get paid ----------
  insert into coaches (tenant_id, name, role) values ('raj','RAJTEST PT Master','coach')
    returning id into v_coach;

  -- The school takes 30% of what is collected at DPS...
  insert into payout_rules (tenant_id, label, party, centre_id, basis, value)
    values ('raj','DPS revenue share','centre', c_dps, 'percent', 30);
  -- ...and the PT master takes 50% of WHAT IS LEFT.
  insert into payout_rules (tenant_id, label, party, coach_id, centre_id, basis, value, applies_on)
    values ('raj','PT master split','coach', v_coach, c_dps, 'percent', 50, 'net_after_centre');

  perform compute_payouts('raj', ist_today());

  select p.amount into amt from payouts p
   where p.tenant_id='raj' and p.party='centre' and p.centre_id = c_dps
     and p.period_month = date_trunc('month', ist_today())::date;
  -- Aarav paid 900 twice at DPS this month = 1800 collected; 30% = 540
  if amt <> 540 then raise exception 'TEST FAIL: centre 30%% of 1800 should be 540, got %', amt; end if;

  select p.amount into amt from payouts p
   where p.tenant_id='raj' and p.party='coach' and p.coach_id = v_coach
     and p.period_month = date_trunc('month', ist_today())::date;
  -- 50% of (1800 - 540) = 630
  if amt <> 630 then raise exception 'TEST FAIL: coach 50%% of net 1260 should be 630, got %', amt; end if;
  raise notice 'OK  payouts — centre 30%% of gross, PT master 50%% of the net remainder';

  -- flat-per-student with a minimum guarantee
  insert into payout_rules (tenant_id, label, party, coach_id, centre_id, basis, value, min_guarantee)
    values ('raj','Per-head w/ floor','coach', v_coach, c_btv, 'flat_per_student', 100, 5000);
  perform compute_payouts('raj', ist_today());
  select p.amount into amt from payouts p
    join payout_rules r on r.id = p.rule_id
   where p.tenant_id='raj' and r.label='Per-head w/ floor';
  if amt <> 5000 then raise exception 'TEST FAIL: min_guarantee floor should apply, got %', amt; end if;

  -- slab: 40% up to 20 students, 50% beyond
  update payout_rules set active=false
   where tenant_id='raj' and label='PT master split';
  insert into payout_rules (tenant_id, label, party, coach_id, centre_id, basis, value, slabs)
    values ('raj','Slab split','coach', v_coach, c_dps, 'slab', 0,
            '[{"upto":20,"percent":40},{"upto":null,"percent":50}]'::jsonb);
  perform compute_payouts('raj', ist_today());
  select p.amount into amt from payouts p
    join payout_rules r on r.id = p.rule_id where r.label='Slab split';
  -- 2 students at DPS → first band → 40% of 1800 gross = 720
  if amt <> 720 then raise exception 'TEST FAIL: slab band should give 720, got %', amt; end if;
  raise notice 'OK  payouts — flat_per_student + min_guarantee, headcount slabs';

  -- a payout already marked paid must never be silently rewritten
  update payouts p set status='paid', amount=1 where p.party='centre' and p.centre_id=c_dps;
  perform compute_payouts('raj', ist_today());
  select p.amount into amt from payouts p
   where p.party='centre' and p.centre_id=c_dps and p.status='paid';
  if amt <> 1 then raise exception 'TEST FAIL: paid payout was overwritten (got %)', amt; end if;
  raise notice 'OK  payouts — a paid line is immutable on recompute';

  -- ---------- MANUAL SEND ----------
  update enrollments set renewal_on=ist_today()-8 where id=e_b;
  perform log_manual_reminder('raj', e_b, 'overdue', 3000, '9876500002', 'Sent by hand', 'whatsapp');
  select count(*) into n from reminder_events where enrollment_id=e_b and sent_by='manual';
  if n <> 1 then raise exception 'TEST FAIL: manual reminder not logged'; end if;
  select count(*) into n from member_timeline where member_id=m_b and kind='reminder';
  if n <> 1 then raise exception 'TEST FAIL: manual reminder missing from timeline'; end if;
  select q.already_sent, q.last_sent_at, q.last_sent_channel
    into ok, sent_at, channel
    from reminder_queue('raj') q where q.enrollment_id=e_b;
  if not ok or sent_at is null or channel <> 'whatsapp' then
    raise exception 'TEST FAIL: queue missing latest reminder state';
  end if;
  raise notice 'OK  manual send — logged once with latest contact time in the queue';

  -- ---------- COURTSYNC IS OFF ----------
  begin
    insert into bookings (id, tenant_id, name, date, hour, amount)
      values ('RAJTEST-B1','raj','RAJTEST', ist_today(), 10, 500);
    raise exception 'TEST FAIL: booking insert for raj should have been blocked';
  exception when others then
    if sqlerrm like '%booking disabled%' then
      raise notice 'OK  CourtSync — booking insert for raj is blocked';
    else raise; end if;
  end;

  -- ...but a booking tenant is untouched by the guard
  insert into bookings (id, tenant_id, name, date, hour, amount)
    values ('RAJTEST-LEO','leo','RAJTEST leo', ist_today()+400, 10, 500);
  delete from bookings where id = 'RAJTEST-LEO';
  raise notice 'OK  CourtSync — Leo/Machaxi bookings still insert normally';

  -- ---------- ADMISSION ----------
  insert into applications (tenant_id, name, parent_name, parent_phone, centre_id, batch_id, sport)
    values ('raj','RAJTEST Applicant','RAJTEST P','9876500009', c_btv, b_btv1, 'basketball');
  res := approve_application('raj', (select id from applications
           where tenant_id='raj' and name='RAJTEST Applicant'), 'test');
  if (res->>'enrollment_id') is null then
    raise exception 'TEST FAIL: approval did not create an enrollment'; end if;
  select count(*) into n from enrollments where id = (res->>'enrollment_id')::bigint;
  if n <> 1 then raise exception 'TEST FAIL: enrollment missing after approval'; end if;
  raise notice 'OK  admission — approve creates member + enrollment + timeline';

  raise notice '';
  raise notice '======== ALL TESTS PASSED ========';
end $$;

-- Return positive evidence to the caller: the API surfaces the result of
-- the last statement, so the harness can print what was actually exercised.
select 'ALL TESTS PASSED'                                     as result,
       (select count(*) from centres     where tenant_id='raj') as centres,
       (select count(*) from batches     where tenant_id='raj') as batches,
       (select count(*) from sports      where tenant_id='raj') as sports,
       (select count(*) from fee_rules   where tenant_id='raj') as fee_rules,
       (select count(*) from enrollments where tenant_id='raj') as enrollments,
       (select count(*) from payouts     where tenant_id='raj') as payout_lines,
       (select count(*) from reminder_events where tenant_id='raj') as reminders;
