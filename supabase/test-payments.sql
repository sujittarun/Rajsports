-- ============================================================
-- This harness writes to SHARED tables. It refuses to run on
-- production, where a failed rollback is a data incident for
-- every academy — not just this one. (0040)
-- ============================================================
select assert_test_environment();

-- ============================================================
-- QA: the fee payment path, end to end.
--
-- Three surfaces have to agree about one payment:
--   1. the payments row      (Fees screen)
--   2. member_timeline       (student profile, History)
--   3. enrollments.renewal_on + the resolved fee (student profile, top)
--
-- Every assertion below is written from the manager's point of view:
-- "I took this money, what should the app now say?" Run with
-- scripts/test-payments.sh — migration + this file in one transaction,
-- rolled back at the end.
-- ============================================================
do $$
declare
  c_id bigint; b_id bigint;
  m1 bigint; e1 bigint;
  res jsonb; d date; n int; amt numeric; txt text; ok boolean;
  tl_title text; pay_amount int; pay_months int; pay_kind text;
  pay_from date; pay_to date;
  fails text[] := '{}';
begin
  select id into c_id from centres where tenant_id='raj' and code='dps-miyapur';
  select id into b_id from batches where tenant_id='raj' and code='dps-b1';

  -- A tenant default already exists, and only one active rule may own a
  -- scope, so pin the rate on the enrollment instead of adding a rule.
  insert into members (tenant_id, name, parent_phone, status)
    values ('raj','QATEST Payer','9876511111','active') returning id into m1;
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, joined_on, renewal_on)
    values ('raj', m1, c_id, b_id, 'cricket', 1, ist_today(), ist_today() + 30)
    returning id into e1;
  update enrollments set custom_amount = 1000 where id = e1;

  -- ============ 1. a plain one month renewal ============
  res := record_fee_payment('raj', e1, 1000, 1, 'UPI', 'renewal');
  select amount, months, kind, period_from, period_to
    into pay_amount, pay_months, pay_kind, pay_from, pay_to
    from payments where id = (res->>'payment_id')::bigint;
  select title, (meta->>'amount')::numeric into tl_title, amt
    from member_timeline where enrollment_id = e1 order by id desc limit 1;

  if pay_amount <> 1000 then fails := fails || format('TEST FAIL: payment amount %%', pay_amount); end if;
  -- The timeline must carry the SAME NUMBER as the payment row, and must
  -- not carry a pre-rendered money string: the client formats it, so all
  -- three screens read identically. This is the whole complaint.
  if amt is null then
    fails := fails || ARRAY['timeline has no meta.amount, so the client cannot render the figure itself'];
  elsif amt <> pay_amount then
    fails := fails || format('timeline amount %s does not equal the payment row %s', amt, pay_amount);
  end if;
  if tl_title like '%₹%' then
    fails := fails || format('timeline title "%s" bakes in a money string, so it cannot match client formatting', tl_title);
  end if;
  select renewal_on into d from enrollments where id = e1;
  if d <> (ist_today() + 30 + interval '1 month')::date then
    fails := fails || format('TEST FAIL: 1 month renewal did not roll, got %%', d); end if;
  raise notice 'OK  one month renewal: amount, roll and timeline agree';

  -- ============ 2. a three month renewal ============
  update enrollments set renewal_on = ist_today() where id = e1;
  res := record_fee_payment('raj', e1, 3000, 3, 'UPI', 'renewal');
  select renewal_on into d from enrollments where id = e1;
  if d <> (ist_today() + interval '3 months')::date then
    fails := fails || format('TEST FAIL: 3 month renewal rolled to %%', d); end if;
  select period_from, period_to into pay_from, pay_to
    from payments where id = (res->>'payment_id')::bigint;
  if pay_to <> d then
    fails := fails || format('TEST FAIL: payment period_to %% does not match renewal %%', pay_to, d); end if;
  raise notice 'OK  three month renewal: period_to matches the new renewal date';

  -- ============ 3. paying while overdue starts from today ============
  update enrollments set renewal_on = ist_today() - 20 where id = e1;
  res := record_fee_payment('raj', e1, 1000, 1, 'Cash', 'renewal');
  if (res->>'period_from')::date <> ist_today() then
    fails := fails || format('TEST FAIL: overdue payment back-dated to %%', res->>'period_from'); end if;
  select renewal_on into d from enrollments where id = e1;
  if d <= ist_today() then
    fails := fails || format('TEST FAIL: student still overdue after paying, renewal %%', d); end if;
  raise notice 'OK  paying late does not leave the student still overdue';

  -- ============ 4. paying early extends, never shortens ============
  update enrollments set renewal_on = ist_today() + 40 where id = e1;
  res := record_fee_payment('raj', e1, 1000, 1, 'UPI', 'renewal');
  select renewal_on into d from enrollments where id = e1;
  if d <> (ist_today() + 40 + interval '1 month')::date then
    fails := fails || format('TEST FAIL: early payment should extend from the existing date, got %%', d); end if;
  raise notice 'OK  paying early extends from the existing renewal date';

  -- ============ 5. THE REPORTED BUG ============
  -- A joining fee recorded for three months. The UI lets Type and Months
  -- be chosen independently, so this combination is reachable, and today
  -- it silently takes the money without moving the renewal date.
  update enrollments set renewal_on = ist_today() + 5 where id = e1;
  res := record_fee_payment('raj', e1, 3000, 3, 'UPI', 'admission');
  select renewal_on into d from enrollments where id = e1;
  select months, period_from, period_to into pay_months, pay_from, pay_to
    from payments where id = (res->>'payment_id')::bigint;

  if d <> (ist_today() + 5 + interval '3 months')::date then
    fails := fails || format('TEST FAIL (reported bug): joining fee covering %% months left renewal at %%, so the student paid for three months and is still due in five days', pay_months, d);
  end if;
  if pay_to = pay_from and pay_months > 1 then
    fails := fails || format('TEST FAIL: payment says %% months but covers a zero length period %% to %%', pay_months, pay_from, pay_to);
  end if;
  raise notice 'OK  a joining fee that covers months rolls the renewal too';

  -- ============ 6. a joining fee on its own ============
  update enrollments set renewal_on = ist_today() + 5, admission_paid = false where id = e1;
  res := record_fee_payment('raj', e1, 500, null, 'Cash', 'admission');
  select admission_paid into ok from enrollments where id = e1;
  if not ok then fails := fails || format('TEST FAIL: joining fee did not mark admission_paid'); end if;
  raise notice 'OK  a joining fee on its own marks admission paid';

  -- ============ 7. unverified money must not look collected ============
  update enrollments set renewal_on = ist_today() + 5 where id = e1;
  res := record_fee_payment('raj', e1, 1000, 1, 'UPI', 'renewal', null, 'UTR9', 'pending_verification');
  select renewal_on into d from enrollments where id = e1;
  if d <> (ist_today() + 5) then
    fails := fails || format('TEST FAIL: unverified payment moved the renewal to %%', d); end if;
  select title into tl_title from member_timeline where enrollment_id = e1 order by id desc limit 1;
  if tl_title not ilike '%pending%' and tl_title not ilike '%verif%' then
    fails := fails || format('TEST FAIL: unverified payment reads as received on the timeline: "%%"', tl_title);
  end if;
  raise notice 'OK  unverified money does not move the renewal or read as received';

  -- ============ 8. an unverified payment can be confirmed later ============
  -- Without this a manager who ticks the box has created a dead end.
  if not exists (select 1 from pg_proc where proname = 'confirm_payment') then
    fails := fails || ARRAY['no confirm_payment(): a payment saved as unverified can never be confirmed, so ticking that box strands the money'];
  else
  perform confirm_payment('raj', (res->>'payment_id')::bigint);
  select status into txt from payments where id = (res->>'payment_id')::bigint;
  if txt <> 'paid' then fails := fails || format('TEST FAIL: confirm left status %%', txt); end if;
  select renewal_on into d from enrollments where id = e1;
  if d <> (ist_today() + 5 + interval '1 month')::date then
    fails := fails || format('TEST FAIL: confirming did not roll the renewal, got %%', d); end if;
  raise notice 'OK  confirming an unverified payment rolls the renewal exactly once';

  -- confirming twice must not roll twice
  begin
    perform confirm_payment('raj', (res->>'payment_id')::bigint);
  exception when others then null; end;
  select renewal_on into d from enrollments where id = e1;
  if d <> (ist_today() + 5 + interval '1 month')::date then
    fails := fails || format('TEST FAIL: confirming twice rolled the renewal twice, got %%', d); end if;
  raise notice 'OK  confirming twice is harmless';
  end if;

  -- ============ 9. the server refuses nonsense ============
  ok := false;
  begin perform record_fee_payment('raj', e1, 0, 1, 'UPI', 'renewal');
  exception when others then ok := true; end;
  if not ok then fails := fails || format('TEST FAIL: a zero payment was accepted'); end if;

  ok := false;
  begin perform record_fee_payment('raj', e1, -500, 1, 'UPI', 'renewal');
  exception when others then ok := true; end;
  if not ok then fails := fails || format('TEST FAIL: a negative payment was accepted'); end if;

  ok := false;
  begin perform record_fee_payment('raj', e1, 1000, 5, 'UPI', 'renewal');
  exception when others then ok := true; end;
  if not ok then fails := fails || format('TEST FAIL: an unsupported plan length was accepted'); end if;
  raise notice 'OK  zero, negative and impossible plan lengths are refused';

  -- ============ 10. cross tenant ============
  ok := false;
  begin
    perform record_fee_payment('leo', e1, 1000, 1, 'UPI', 'renewal');
  exception when others then ok := true; end;
  if not ok then
    raise exception 'TEST FAIL: a payment was recorded against another academy''s enrollment';
  end if;
  raise notice 'OK  a payment cannot be recorded across tenants';

  -- ============ 11. the money adds up ============
  select coalesce(sum(amount),0) into amt from payments
   where enrollment_id = e1 and status = 'paid';
  select count(*) into n from member_timeline
   where enrollment_id = e1 and kind = 'payment';
  if n <> (select count(*) from payments where enrollment_id = e1 and status = 'paid') then
    fails := fails || format('TEST FAIL: %% paid payments but %% payment entries on the timeline',
      (select count(*) from payments where enrollment_id = e1 and status='paid'), n);
  end if;
  raise notice 'OK  every paid payment has exactly one timeline entry';

  if array_length(fails, 1) > 0 then
    raise exception E'\n\n% FAILURES\n  · %s\n',
      array_length(fails, 1), array_to_string(fails, E'\n  · ');
  end if;
end $$;

select 'PAYMENT TESTS PASSED' as result;
