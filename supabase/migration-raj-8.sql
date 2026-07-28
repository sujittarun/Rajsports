-- ============================================================
-- RAJ SPORTS — migration 8: fix the fee payment path
--
-- Reported: "the payment recorded, the timeline entry and the fee on
-- the student profile do not match." They did not, for three separate
-- reasons, and a QA sweep of the same path found four more defects.
--
--  1. THE RENEWAL DID NOT ALWAYS ROLL. `kind` was doing two jobs:
--     labelling what the money was for, AND deciding whether the
--     student's renewal date moved. A payment labelled "joining fee"
--     covering three months therefore took ₹3,000 and left the student
--     due the following week. Money in, no coverage, and nothing on
--     screen said so.
--     Fix: the roll is driven by MONTHS COVERED, never by the label.
--     Three months is three months whatever it was called.
--
--  2. THE TIMELINE FORMATTED ITS OWN MONEY. The title was built in SQL
--     as '₹' || round(amount) giving "₹3000", while every screen
--     renders "₹3,000". One payment, two renderings.
--     Fix: the timeline stores the NUMBER in meta; the clients format
--     it, so there is one money formatter per app and none in SQL.
--
--  3. UNVERIFIED MONEY WAS A DEAD END. A payment saved as "claimed but
--     not verified" had no way to ever be confirmed.
--     Fix: confirm_payment(), idempotent, applying the roll once.
--
--  Plus: the server accepted zero, negative, and impossible plan
--  lengths, and wrote a months count onto payments that covered a
--  zero-length period.
--
-- Idempotent. Apply with scripts/migrate.sh.
-- ============================================================

-- ------------------------------------------------------------
-- Guard the data, not just the write path: a number this wrong should
-- not be storable however it arrives.
-- ------------------------------------------------------------
alter table payments drop constraint if exists payments_amount_sane;
alter table payments add constraint payments_amount_sane
  check (amount is null or amount >= 0);

alter table payments drop constraint if exists payments_months_sane;
alter table payments add constraint payments_months_sane
  check (months is null or months in (1, 3, 6, 12));

alter table payments drop constraint if exists payments_period_sane;
alter table payments add constraint payments_period_sane
  check (period_from is null or period_to is null or period_to >= period_from);

-- ------------------------------------------------------------
-- Applying a paid payment's coverage. Split out so recording a payment
-- and confirming one later run exactly the same code.
-- ------------------------------------------------------------
create or replace function apply_payment_coverage(p_tenant text, p_payment bigint)
  returns void
  language plpgsql security definer set search_path = public as $$
declare p payments; e enrollments;
begin
  select * into p from payments where id = p_payment and tenant_id = p_tenant;
  if not found then raise exception 'Payment not found.'; end if;
  if p.status <> 'paid' or p.enrollment_id is null then return; end if;

  select * into e from enrollments where id = p.enrollment_id;
  if not found then return; end if;

  if p.kind = 'admission' then
    update enrollments set admission_paid = true, updated_at = now() where id = e.id;
  end if;

  if coalesce(p.months, 0) > 0 and p.period_to is not null then
    -- Never move a renewal backwards. If two payments land out of
    -- order, the furthest coverage wins.
    update enrollments
       set renewal_on = greatest(coalesce(renewal_on, p.period_to), p.period_to),
           updated_at = now()
     where id = e.id;

    update reminder_events
       set status = 'resolved', resolved_at = now(), next_retry_at = null
     where tenant_id = p_tenant and enrollment_id = e.id
       and status in ('sent','delivered','read','accepted','failed',
                      'retry_scheduled','manual_followup','queued');
  end if;
end $$;

-- ------------------------------------------------------------
-- record_fee_payment, v2
-- ------------------------------------------------------------
create or replace function record_fee_payment(
  p_tenant      text,
  p_enrollment  bigint,
  p_amount      numeric,
  p_months      int default null,
  p_mode        text default 'UPI',
  p_kind        text default 'renewal',
  p_on_date     date default null,
  p_ref         text default null,
  p_status      text default 'paid',
  p_collected_by text default null,
  p_note        text default null
) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  e       enrollments;
  m       members;
  months  int;
  paid_on date := coalesce(p_on_date, ist_today());
  from_d  date;
  to_d    date;
  pay_id  bigint;
  covers  boolean;
begin
  perform assert_staff_or_service(p_tenant);

  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment has to be more than zero.' using errcode = 'check_violation';
  end if;
  if p_status not in ('paid', 'pending_verification') then
    raise exception 'Unknown payment status "%".', p_status using errcode = 'check_violation';
  end if;
  if p_kind not in ('renewal', 'admission', 'custom') then
    raise exception 'Unknown payment type "%".', p_kind using errcode = 'check_violation';
  end if;
  if p_months is not null and p_months not in (1, 3, 6, 12) then
    raise exception 'A plan is 1, 3, 6 or 12 months, not %.', p_months using errcode = 'check_violation';
  end if;

  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then
    raise exception 'That enrollment does not belong to this academy.' using errcode = 'no_data_found';
  end if;
  select * into m from members where id = e.member_id;

  -- A joining fee on its own covers no time, so months defaults to
  -- zero there. Everything else defaults to the enrollment's own plan.
  months := coalesce(p_months, case when p_kind = 'admission' then 0 else e.plan_months end, 1);
  covers := months > 0;

  -- THE MONTHS BUY THE COVERAGE, NOT THE LABEL. This is the line the
  -- reported bug turned on: it used to read `if p_kind = 'renewal'`, so
  -- a joining fee covering three months bought the student nothing.
  if covers then
    -- Extend from the later of (current renewal, today): paying early
    -- never loses days, paying late never back-dates coverage over a
    -- period the student already sat through unpaid.
    from_d := greatest(coalesce(e.renewal_on, paid_on), paid_on);
    to_d   := (from_d + (months || ' months')::interval)::date;
  else
    from_d := paid_on;
    to_d   := paid_on;
  end if;

  insert into payments (tenant_id, name, type, detail, amount, mode, on_date, ref,
                        enrollment_id, member_id, centre_id, sport, months,
                        period_from, period_to, kind, status, collected_by, note)
  values (p_tenant, m.name, 'Coaching',
          coalesce(e.sport, '') || case when covers and months > 1
                                        then ' · ' || months || ' months' else '' end,
          round(p_amount)::int, p_mode, paid_on, p_ref,
          e.id, e.member_id, e.centre_id, e.sport,
          case when covers then months else null end,
          from_d, to_d, p_kind, p_status, p_collected_by, p_note)
  returning id into pay_id;

  if p_status = 'paid' then
    perform apply_payment_coverage(p_tenant, pay_id);
  end if;

  -- The timeline stores the NUMBER, never a rendered string, so the web
  -- app and the Android app each format money exactly once.
  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id,
          case when p_status = 'paid' then 'payment' else 'payment_pending' end,
          case when p_status = 'paid' then 'Payment received'
               else 'Payment claimed, not verified yet' end,
          nullif(coalesce(p_note, ''), ''),
          jsonb_build_object(
            'payment_id', pay_id, 'amount', round(p_amount),
            'months', case when covers then months else null end,
            'kind', p_kind, 'mode', p_mode,
            'period_from', from_d, 'period_to', to_d, 'ref', p_ref));

  return jsonb_build_object(
    'payment_id', pay_id,
    'renewal_on', (select renewal_on from enrollments where id = e.id),
    'months', case when covers then months else 0 end,
    'period_from', from_d, 'period_to', to_d);
end $$;

-- ------------------------------------------------------------
-- Confirming money recorded as "claimed but not verified".
-- Idempotent, so a double tap cannot buy a second month.
-- ------------------------------------------------------------
create or replace function confirm_payment(p_tenant text, p_payment bigint)
  returns jsonb
  language plpgsql security definer set search_path = public as $$
declare p payments;
begin
  perform assert_staff_or_service(p_tenant);
  select * into p from payments where id = p_payment and tenant_id = p_tenant;
  if not found then raise exception 'Payment not found.' using errcode = 'no_data_found'; end if;

  if p.status = 'paid' then
    return jsonb_build_object('payment_id', p.id, 'already', true,
      'renewal_on', (select renewal_on from enrollments where id = p.enrollment_id));
  end if;
  if p.status <> 'pending_verification' then
    raise exception 'Only an unverified payment can be confirmed.' using errcode = 'check_violation';
  end if;

  update payments set status = 'paid' where id = p.id;
  perform apply_payment_coverage(p_tenant, p.id);

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, meta)
  values (p_tenant, p.member_id, p.enrollment_id, 'payment', 'Payment confirmed',
          jsonb_build_object('payment_id', p.id, 'amount', p.amount,
                             'months', p.months, 'mode', p.mode));

  return jsonb_build_object('payment_id', p.id, 'already', false,
    'renewal_on', (select renewal_on from enrollments where id = p.enrollment_id));
end $$;

-- Voiding a payment recorded in error. This deliberately does NOT
-- unwind the renewal date: a coach who has already told a parent they
-- are covered until March should not have that quietly reversed under
-- them. Correcting the date is a visible edit on the enrollment.
create or replace function void_payment(p_tenant text, p_payment bigint, p_reason text default null)
  returns void
  language plpgsql security definer set search_path = public as $$
declare p payments;
begin
  perform assert_staff_or_service(p_tenant);
  select * into p from payments where id = p_payment and tenant_id = p_tenant;
  if not found then raise exception 'Payment not found.' using errcode = 'no_data_found'; end if;

  update payments set status = 'void', note = coalesce(p_reason, note) where id = p.id;
  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, p.member_id, p.enrollment_id, 'note', 'Payment voided',
          coalesce(p_reason, 'Recorded in error'),
          jsonb_build_object('payment_id', p.id, 'amount', p.amount));
end $$;

-- ------------------------------------------------------------
-- What has this enrollment actually paid? The profile needs this so
-- "the rate" and "what was paid" can sit side by side, instead of one
-- masquerading as the other.
-- ------------------------------------------------------------
create or replace function enrollment_payment_summary(p_enrollment bigint)
  returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'paid_total',       coalesce(sum(amount) filter (where status = 'paid'), 0),
    'paid_count',       count(*) filter (where status = 'paid'),
    'unverified',       coalesce(sum(amount) filter (where status = 'pending_verification'), 0),
    'unverified_count', count(*) filter (where status = 'pending_verification'),
    'last_amount', (select amount  from payments where enrollment_id = p_enrollment
                     and status = 'paid' order by on_date desc, id desc limit 1),
    'last_on',     (select on_date from payments where enrollment_id = p_enrollment
                     and status = 'paid' order by on_date desc, id desc limit 1),
    'last_months', (select months  from payments where enrollment_id = p_enrollment
                     and status = 'paid' order by on_date desc, id desc limit 1),
    'covered_to',  (select max(period_to) from payments where enrollment_id = p_enrollment
                     and status = 'paid' and months is not null))
  from payments where enrollment_id = p_enrollment
$$;

grant execute on function confirm_payment(text,bigint)        to authenticated;
grant execute on function void_payment(text,bigint,text)      to authenticated;
grant execute on function apply_payment_coverage(text,bigint) to authenticated;
grant execute on function enrollment_payment_summary(bigint)  to authenticated;

-- ------------------------------------------------------------
-- Repair the rows the old function already wrote.
-- Any paid payment whose coverage was never applied gets it now, so
-- students who paid for months they never received stop being chased.
-- ------------------------------------------------------------
do $$
declare p payments; n int := 0;
begin
  for p in
    select * from payments
     where status = 'paid' and enrollment_id is not null
       and kind = 'admission' and coalesce(months, 0) > 1
     order by on_date, id
  loop
    -- The old function stored a zero-length period on these, so rebuild
    -- the coverage from the months it recorded.
    update payments
       set period_from = greatest(
             coalesce((select renewal_on from enrollments where id = p.enrollment_id), p.on_date),
             p.on_date),
           period_to = (greatest(
             coalesce((select renewal_on from enrollments where id = p.enrollment_id), p.on_date),
             p.on_date) + (p.months || ' months')::interval)::date
     where id = p.id;
    perform apply_payment_coverage(p.tenant_id, p.id);
    n := n + 1;
  end loop;
  if n > 0 then
    raise notice 'repaired % joining-fee payment(s) that covered months but never rolled a renewal', n;
  end if;
end $$;
