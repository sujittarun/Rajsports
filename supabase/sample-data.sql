-- ============================================================
-- RAJ SPORTS — sample data for the demo build.
--
-- Every row created here is tagged `notes = 'SAMPLE'` (members) or
-- `note = 'SAMPLE'` (rules/payments) so supabase/clear-sample-data.sql
-- can remove all of it in one command at go-live, without touching a
-- single real student.
--
-- Fees are PLACEHOLDERS — the client has not set prices yet. They exist
-- so the reminder amounts, the payouts split and the dashboards have
-- something real to compute from. Replace them in Setup → Fees.
-- ============================================================

-- ---------- rates (placeholder) ----------
insert into fee_rules (tenant_id, label, monthly_amount, admission_fee, note)
select 'raj', 'Default monthly fee', 1200, 500, 'SAMPLE'
where not exists (select 1 from fee_rules where tenant_id='raj' and note='SAMPLE' and label='Default monthly fee');

insert into fee_rules (tenant_id, label, sport, monthly_amount, plan_amounts, note)
select 'raj', 'Basketball', 'basketball', 1400, '{"3":3900,"6":7500}'::jsonb, 'SAMPLE'
where not exists (select 1 from fee_rules where tenant_id='raj' and note='SAMPLE' and label='Basketball');

insert into fee_rules (tenant_id, label, sport, monthly_amount, note)
select 'raj', 'Archery', 'archery', 1800, 'SAMPLE'
where not exists (select 1 from fee_rules where tenant_id='raj' and note='SAMPLE' and label='Archery');

insert into fee_rules (tenant_id, label, centre_id, sport, monthly_amount, note)
select 'raj', 'Basketball at BTV', c.id, 'basketball', 1600, 'SAMPLE'
from centres c where c.tenant_id='raj' and c.code='btv'
  and not exists (select 1 from fee_rules where tenant_id='raj' and note='SAMPLE' and label='Basketball at BTV');

-- ---------- a second coach, so the payout split is demonstrable ----------
insert into coaches (tenant_id, name, phone, role, notes)
select 'raj', 'Suresh Kumar', '9876543210', 'coach', 'SAMPLE'
where not exists (select 1 from coaches where tenant_id='raj' and notes='SAMPLE');

-- ---------- payout rules ----------
-- The school keeps 30% of what is collected at DPS…
insert into payout_rules (tenant_id, label, party, centre_id, basis, value, note)
select 'raj', 'DPS revenue share', 'centre', c.id, 'percent', 30, 'SAMPLE'
from centres c where c.tenant_id='raj' and c.code='dps-miyapur'
  and not exists (select 1 from payout_rules where tenant_id='raj' and note='SAMPLE' and label='DPS revenue share');

-- …and the PT master takes 50% of what is left after that.
insert into payout_rules (tenant_id, label, party, coach_id, centre_id, basis, value, applies_on, note)
select 'raj', 'Suresh · DPS split', 'coach', co.id, c.id, 'percent', 50, 'net_after_centre', 'SAMPLE'
from coaches co, centres c
where co.tenant_id='raj' and co.notes='SAMPLE' and c.tenant_id='raj' and c.code='dps-miyapur'
  and not exists (select 1 from payout_rules where tenant_id='raj' and note='SAMPLE' and label='Suresh · DPS split');

-- BTV pays a flat rent instead of a share — a different contract shape.
insert into payout_rules (tenant_id, label, party, centre_id, basis, value, note)
select 'raj', 'BTV court rent', 'centre', c.id, 'monthly_retainer', 8000, 'SAMPLE'
from centres c where c.tenant_id='raj' and c.code='btv'
  and not exists (select 1 from payout_rules where tenant_id='raj' and note='SAMPLE' and label='BTV court rent');

-- ---------- students ----------
-- Renewal dates are deliberately spread across the reminder ladder so
-- every state on the Reminders screen is visible: heads-up (−2), due
-- today (0), first chase (+5), daily chase (+7..14), and stopped (15+).
do $$
declare
  v_dps bigint; v_btv bigint; v_pus bigint; v_hil bigint; v_prc bigint;
  b_dps1 bigint; b_dps2 bigint; b_btv1 bigint; b_btv3 bigint;
  b_pus1 bigint; b_hil1 bigint; b_prc1 bigint;
  mid bigint; eid bigint;
  r record;
begin
  if exists (select 1 from members where tenant_id='raj' and notes='SAMPLE') then
    raise notice 'sample students already present — skipping';
    return;
  end if;

  select id into v_dps from centres where tenant_id='raj' and code='dps-miyapur';
  select id into v_btv from centres where tenant_id='raj' and code='btv';
  select id into v_pus from centres where tenant_id='raj' and code='pushpak';
  select id into v_hil from centres where tenant_id='raj' and code='hillcounty';
  select id into v_prc from centres where tenant_id='raj' and code='prc';
  select id into b_dps1 from batches where tenant_id='raj' and code='dps-b1';
  select id into b_dps2 from batches where tenant_id='raj' and code='dps-b2';
  select id into b_btv1 from batches where tenant_id='raj' and code='btv-b1';
  select id into b_btv3 from batches where tenant_id='raj' and code='btv-b3';
  select id into b_pus1 from batches where tenant_id='raj' and code='pushpak-b1';
  select id into b_hil1 from batches where tenant_id='raj' and code='hill-b1';
  select id into b_prc1 from batches where tenant_id='raj' and code='prc-b1';

  for r in
    select * from (values
      -- name,               parent,             phone,        centre, batch,  sport,        plan, joined_days_ago, renewal_offset, wa
      ('Aarav Reddy',        'Srinivas Reddy',   '9876500011', 'dps', 'dps1', 'cricket',      1,  95,   0,  'active'),
      ('Ishaan Verma',       'Rakesh Verma',     '9876500012', 'dps', 'dps1', 'basketball',   3, 180,  -2,  'active'),
      ('Diya Nair',          'Anitha Nair',      '9876500013', 'dps', 'dps2', 'tennis',       1,  62,   5,  'active'),
      ('Kabir Shetty',       'Manoj Shetty',     '9876500014', 'dps', 'dps2', 'archery',      1, 210,   9,  'active'),
      ('Ananya Rao',         'Padma Rao',        '9876500015', 'dps', 'dps1', 'football',     6, 300, -48,  'active'),
      ('Vihaan Gupta',       'Sanjay Gupta',     '9876500016', 'btv', 'btv1', 'basketball',   1,  40,   0,  'active'),
      ('Meher Fatima',       'Imran Ali',        '9876500017', 'btv', 'btv1', 'basketball',   3, 150, -25,  'active'),
      ('Rohan Iyer',         'Suresh Iyer',      '9876500018', 'btv', 'btv3', 'basketball',   1,  75,  12,  'active'),
      ('Sara Menon',         'Deepa Menon',      '9876500019', 'btv', 'btv3', 'basketball',   1,  55,  18,  'active'),
      ('Arjun Pillai',       'Ramesh Pillai',    '9876500020', 'pus', 'pus1', 'cricket',      1,  88,   5,  'active'),
      ('Nisha Bhat',         'Girish Bhat',      '9876500021', 'pus', 'pus1', 'basketball',   3, 120, -60,  'active'),
      ('Aditya Kulkarni',    'Vinod Kulkarni',   '9876500022', 'hil', 'hil1', 'tennis',       1,  30,  -2,  'active'),
      ('Tara Deshmukh',      'Shalini Deshmukh', '9876500023', 'hil', 'hil1', 'football',     1, 140,   7,  'active'),
      ('Yash Agarwal',       'Nitin Agarwal',    '9876500024', 'prc', 'prc1', 'cricket',      1,  66,   0,  'active'),
      ('Riya Chandran',      'Priya Chandran',   '9876500025', 'prc', 'prc1', 'basketball',   1, 175,  22,  'active'),
      ('Devansh Joshi',      'Alok Joshi',       '9876500026', 'prc', 'prc1', 'tennis',       6, 250, -95,  'active'),
      -- a wrong number: proves the engine stops instead of retrying forever
      ('Zara Khan',          'Faisal Khan',      '9876500027', 'dps', 'dps1', 'basketball',   1,  48,   6,  'wrong_number'),
      -- opted out of WhatsApp: manager must call
      ('Neel Saxena',        'Vikram Saxena',    '9876500028', 'btv', 'btv1', 'basketball',   1,  92,   8,  'opted_out')
    ) as t(nm, pn, ph, centre, batch, sport, plan, joined_ago, renew_off, wa)
  loop
    insert into members (tenant_id, name, phone, parent_name, parent_phone, program,
                         joined, status, whatsapp_status, notes)
    values ('raj', r.nm, r.ph, r.pn, r.ph, r.sport,
            ist_today() - r.joined_ago, 'active', r.wa, 'SAMPLE')
    returning id into mid;

    insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, plan_months,
                             joined_on, renewal_on, admission_paid, status, notes)
    values ('raj', mid,
            case r.centre when 'dps' then v_dps when 'btv' then v_btv
                          when 'pus' then v_pus when 'hil' then v_hil else v_prc end,
            case r.batch when 'dps1' then b_dps1 when 'dps2' then b_dps2
                         when 'btv1' then b_btv1 when 'btv3' then b_btv3
                         when 'pus1' then b_pus1 when 'hil1' then b_hil1 else b_prc1 end,
            r.sport, r.plan, ist_today() - r.joined_ago,
            ist_today() - r.renew_off,   -- +ve offset ⇒ overdue
            true, 'active', 'SAMPLE')
    returning id into eid;

    -- One historical payment each, so collections and payouts are non-zero.
    insert into payments (tenant_id, name, type, detail, amount, mode, on_date,
                          enrollment_id, member_id, centre_id, sport, months,
                          period_from, period_to, kind, status, note)
    select 'raj', r.nm, 'Coaching', r.sport,
           round((f->>'amount')::numeric)::int, 'UPI',
           greatest(ist_today() - r.joined_ago + 1, date_trunc('month', ist_today())::date),
           eid, mid,
           case r.centre when 'dps' then v_dps when 'btv' then v_btv
                         when 'pus' then v_pus when 'hil' then v_hil else v_prc end,
           r.sport, r.plan,
           ist_today() - r.joined_ago, ist_today() - r.renew_off, 'renewal', 'paid', 'SAMPLE'
    from (select enrollment_fee(eid) as f) x
    where (f->>'amount') is not null;
  end loop;

  -- Two parent applications waiting in the review queue.
  insert into applications (tenant_id, name, parent_name, parent_phone, phone,
                            centre_id, batch_id, sport, status, goal)
  values
    ('raj','Aryan Malhotra','Rohit Malhotra','9876500031','9876500031', v_btv, b_btv1, 'basketball','pending','SAMPLE — played at school level'),
    ('raj','Kiara Sethi','Neha Sethi','9876500032','9876500032', v_dps, b_dps1, 'archery','pending','SAMPLE — complete beginner');
end $$;

-- ---------- expand the roster to 100 realistic students ----------
-- The first block above keeps a small hand-written set whose dates exercise
-- exact reminder stages. This block fills the rest of the roster with
-- deterministic, fictional Hyderabad families. It is safe to rerun: phone
-- numbers are stable, and it stops as soon as 100 SAMPLE students exist.
do $$
declare
  first_names text[] := array[
    'Aadhya','Aarush','Advait','Ahana','Akshara','Anay','Anika','Arnav',
    'Avni','Dhruv','Eesha','Harsh','Ira','Ishita','Jai','Kavya','Krish',
    'Laksh','Mahi','Manas','Mira','Naksh','Navya','Nihal','Pari','Pranav',
    'Reyansh','Rhea','Ritvik','Saanvi','Samaira','Shaurya','Siya','Tanay',
    'Trisha','Varun','Ved','Veda','Vivaan','Yuvaan'
  ];
  last_names text[] := array[
    'Rao','Reddy','Sharma','Nair','Iyer','Patel','Mehta','Kapoor','Kulkarni',
    'Shetty','Menon','Gupta','Joshi','Khan','Pillai','Verma'
  ];
  parent_first_names text[] := array[
    'Anil','Anitha','Deepa','Farah','Girish','Kiran','Lakshmi','Manoj',
    'Meena','Neha','Prakash','Priya','Rahul','Ramesh','Sanjay','Sunita'
  ];
  schools text[] := array[
    'Delhi Public School Miyapur','Silver Oaks International School',
    'Sentia The Global School','Kennedy High Global School',
    'Vikas The Concept School','The Creek Planet School',
    'DAV Public School Kukatpally','Meridian School'
  ];
  localities text[] := array[
    'Miyapur','Nizampet','Bachupally','Kondapur','Kukatpally',
    'Pragathi Nagar','Hafeezpet','Chandanagar'
  ];
  mixed_sports text[] := array['archery','basketball','football','cricket','tennis'];
  plan_options int[] := array[1,1,1,3,3,6,12];
  renewal_offsets int[] := array[-45,-20,-2,0,5,7,10,14,18,30];
  sample_count int;
  seq int := 1;
  batch_count int;
  mid bigint;
  eid bigint;
  second_eid bigint;
  phone_text text;
  student_name text;
  parent_name_text text;
  chosen_sport text;
  member_status text;
  enrollment_status text;
  renewal_offset int;
  joined_days int;
  chosen_plan int;
  b record;
  b2 record;
begin
  select count(*) into sample_count
    from members where tenant_id='raj' and notes='SAMPLE';
  select count(*) into batch_count
    from batches where tenant_id='raj' and active;

  if batch_count = 0 then
    raise exception 'Cannot create sample students without active Raj Sports batches';
  end if;

  while sample_count < 100 loop
    phone_text := '9801' || lpad(seq::text, 6, '0');

    if exists (
      select 1 from members
       where tenant_id='raj' and (parent_phone=phone_text or phone=phone_text)
    ) then
      seq := seq + 1;
      continue;
    end if;

    select x.* into b
      from (
        select ba.id, ba.centre_id, ba.sport, ba.code,
               row_number() over (order by c.sort, ba.sort, ba.id) as rn
          from batches ba
          join centres c on c.id=ba.centre_id
         where ba.tenant_id='raj' and ba.active and c.active
      ) x
     where x.rn = ((seq - 1) % batch_count) + 1;

    student_name :=
      first_names[((seq - 1) % array_length(first_names, 1)) + 1] || ' ' ||
      last_names[(((seq - 1) / array_length(first_names, 1)) %
                  array_length(last_names, 1)) + 1];
    parent_name_text :=
      parent_first_names[((seq + 4) % array_length(parent_first_names, 1)) + 1] || ' ' ||
      last_names[(((seq - 1) / array_length(first_names, 1)) %
                  array_length(last_names, 1)) + 1];
    chosen_sport := coalesce(
      b.sport,
      mixed_sports[((seq - 1) % array_length(mixed_sports, 1)) + 1]
    );
    chosen_plan := plan_options[((seq - 1) % array_length(plan_options, 1)) + 1];
    renewal_offset :=
      renewal_offsets[((seq - 1) % array_length(renewal_offsets, 1)) + 1];
    joined_days := 35 + ((seq * 17) % 420);
    member_status := case when seq % 23 = 0 then 'discontinued' else 'active' end;
    enrollment_status := case when member_status = 'discontinued'
                              then 'discontinued'
                              when seq % 19 = 0 then 'paused'
                              else 'active' end;

    insert into members (
      tenant_id, name, phone, parent_name, parent_phone, alt_phone,
      program, joined, status, whatsapp_status, dob, gender, school,
      grade, address, notes, discontinued_on
    )
    values (
      'raj', student_name, phone_text, parent_name_text, phone_text,
      case when seq % 9 = 0
           then '9802' || lpad(seq::text, 6, '0') else null end,
      chosen_sport, ist_today() - joined_days, member_status,
      case when seq % 31 = 0 then 'wrong_number'
           when seq % 37 = 0 then 'opted_out'
           else 'active' end,
      make_date(2010 + (seq % 8), 1 + (seq % 12), 1 + (seq % 27)),
      case when seq % 2 = 0 then 'female' else 'male' end,
      schools[((seq - 1) % array_length(schools, 1)) + 1],
      ('Grade ' || (3 + (seq % 8)))::text,
      (10 + seq)::text || ', ' ||
        localities[((seq - 1) % array_length(localities, 1)) + 1] ||
        ', Hyderabad',
      'SAMPLE',
      case when member_status='discontinued' then ist_today() - (seq % 20) else null end
    )
    returning id into mid;

    insert into enrollments (
      tenant_id, member_id, centre_id, batch_id, sport, plan_months,
      custom_amount, joined_on, renewal_on, admission_paid, status,
      discontinued_on, notes
    )
    values (
      'raj', mid, b.centre_id, b.id, chosen_sport, chosen_plan,
      case when seq % 17 = 0 then 1500 + ((seq % 4) * 250) else null end,
      ist_today() - joined_days, ist_today() - renewal_offset,
      seq % 6 <> 0, enrollment_status,
      case when enrollment_status='discontinued' then ist_today() - (seq % 20) else null end,
      'SAMPLE'
    )
    returning id into eid;

    -- A historical payment gives Fees realistic volume across six months.
    insert into payments (
      tenant_id, name, type, detail, amount, mode, on_date,
      enrollment_id, member_id, centre_id, sport, months,
      period_from, period_to, kind, status, ref, note
    )
    select
      'raj', student_name, 'Coaching', chosen_sport,
      round((f->>'amount')::numeric)::int,
      (array['UPI','UPI','Cash','Bank'])[((seq - 1) % 4) + 1],
      least(
        ist_today(),
        (date_trunc('month', ist_today()) -
          make_interval(months => seq % 6) +
          make_interval(days => seq % 21))::date
      ),
      eid, mid, b.centre_id, chosen_sport, chosen_plan,
      ist_today() - joined_days, ist_today() - renewal_offset,
      case when seq % 13 = 0 then 'admission' else 'renewal' end,
      case when seq % 29 = 0 then 'pending_verification' else 'paid' end,
      case when seq % 4 = 0 then 'SAMPLE-' || lpad(seq::text, 4, '0') else null end,
      'SAMPLE'
    from (select enrollment_fee(eid) as f) x
    where (f->>'amount') is not null;

    -- Every tenth child has another enrollment, proving that billing stays
    -- attached to the enrollment instead of being collapsed onto the child.
    if seq % 10 = 0 then
      select x.* into b2
        from (
          select ba.id, ba.centre_id, ba.sport, ba.code,
                 row_number() over (order by c.sort, ba.sort, ba.id) as rn
            from batches ba
            join centres c on c.id=ba.centre_id
           where ba.tenant_id='raj' and ba.active and c.active
        ) x
       where x.rn = ((seq + 4) % batch_count) + 1;

      insert into enrollments (
        tenant_id, member_id, centre_id, batch_id, sport, plan_months,
        joined_on, renewal_on, admission_paid, status, notes
      )
      values (
        'raj', mid, b2.centre_id, b2.id,
        coalesce(
          b2.sport,
          mixed_sports[(seq % array_length(mixed_sports, 1)) + 1]
        ),
        1, ist_today() - greatest(30, joined_days / 2),
        ist_today() + 20 + (seq % 20), true, 'active', 'SAMPLE'
      )
      returning id into second_eid;
    end if;

    sample_count := sample_count + 1;
    seq := seq + 1;
  end loop;
end $$;

-- Generate this month's payout lines from the rules above.
select compute_payouts('raj', date_trunc('month', ist_today())::date);

select 'SAMPLE DATA LOADED' as result,
       (select count(*) from members     where tenant_id='raj' and notes='SAMPLE') as students,
       (select count(*) from enrollments where tenant_id='raj' and notes='SAMPLE') as enrollments,
       (select count(*) from payments    where tenant_id='raj' and note='SAMPLE')  as payments,
       (select count(*) from fee_rules   where tenant_id='raj' and note='SAMPLE')  as fee_rules,
       (select count(*) from payout_rules where tenant_id='raj' and note='SAMPLE') as payout_rules,
       (select count(*) from applications where tenant_id='raj' and status='pending') as pending_apps;
