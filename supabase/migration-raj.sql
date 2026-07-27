-- ============================================================
-- RAJ SPORTS — tenant 'raj' on the Academy Manager platform DB
-- Project: ugsklcipzyiogxynshnh (org "Academy Manager")
--
-- Raj Sports is a coach-operator: he runs coaching batches at FIVE
-- centres he does not own (schools / clubs / communities), across
-- several sports. There is NO court booking here — CourtSync stays
-- OFF for this tenant (see the modules flag in tenants.config and the
-- guard at the bottom of this file).
--
-- What this migration adds to the shared platform (generic, so future
-- coaching-style academies reuse it — nothing is named 'raj_*'):
--   · centres / batches / coaches / sports  — the coaching structure
--   · enrollments                           — the BILLING UNIT
--   · fee_rules + resolve_fee()             — per-sport / per-centre /
--                                             per-batch / per-student rates
--   · payout_rules + payouts                — how a PT master or a
--                                             centre takes its cut
--   · sessions                              — for per-session payouts
--   · reminder_events / wa_flow_events /
--     wa_webhook_events / member_timeline   — the WhatsApp engine
--
-- Idempotent: safe to re-run. Applies via scripts/migrate.sh.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Helpers. The academy runs on IST; never let a UTC date shift
--    a renewal by a day.
-- ------------------------------------------------------------
create or replace function ist_today() returns date
  language sql stable as
$$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- The reminder cron and the payout job run as the service role, which
-- carries no JWT. assert_staff() would reject them once lockdown is on,
-- so give the definer-functions a service-role bypass.
create or replace function is_service() returns boolean
  language sql stable as
$$ select coalesce(current_setting('request.jwt.claims', true), '') = ''
       or coalesce(auth.jwt()->>'role', '') = 'service_role' $$;

create or replace function assert_staff_or_service(p_tenant text) returns void
  language plpgsql stable set search_path = public as $$
begin
  if is_service() then return; end if;
  perform assert_staff(p_tenant);
end $$;

-- ------------------------------------------------------------
-- 1. The tenant.
--    modules.booking = false is what keeps CourtSync out: the
--    CourtSync board and the sync workers skip any tenant whose
--    booking module is off, and no courts/rates are configured.
-- ------------------------------------------------------------
insert into tenants (id, name, config) values
  ('raj', 'Raj Sports',
   jsonb_build_object(
     'brand',    'Raj Sports',
     'city',     'Hyderabad',
     'kind',     'coaching',          -- coaching-only, not a venue
     'modules',  jsonb_build_object(
                   'booking',  false, -- NO court booking (CourtSync off)
                   'courts',   false,
                   'coaching', true,
                   'payouts',  true,
                   'whatsapp', true),
     'courts',   '{}'::jsonb,         -- deliberately empty
     'rates',    '{}'::jsonb,         -- deliberately empty
     'billing',  jsonb_build_object(
                   'payee',        'Raj Sports',
                   'upiIds',       '[]'::jsonb,
                   'currency',     'INR',
                   'gracePeriodDays', 5),
     'whatsapp', jsonb_build_object(
                   'enabled',      false,   -- flip on when the WABA is live
                   'mode',         'manual',-- manual | auto
                   'dryRun',       true,
                   'sendHourIST',  15,
                   'managerPhone', '',
                   'phoneNumberId','',
                   'wabaId',       '',
                   'templates',    jsonb_build_object(
                       'headsUp',   'utlity_fee_headsup',
                       'dueToday',  'utility_renewal_day',
                       'overdue',   'utility_for_fee_reminder'))
   ))
on conflict (id) do update set
  name = excluded.name,
  config = tenants.config || excluded.config;

insert into subscriptions (tenant_id, plan, mrr, status, started, renews_on, notes)
values ('raj', 'pilot', 0, 'pilot', ist_today(), ist_today() + 30,
        'Coaching-only client (no CourtSync). MRR placeholder — set on contract.')
on conflict (tenant_id) do nothing;

update subscriptions
   set tier = coalesce(tier, 'Tier 1'),
       player_cap = coalesce(player_cap, 50),
       msg_rate = coalesce(msg_rate, 0.35)
 where tenant_id = 'raj';

-- ============================================================
-- 2. COACHING STRUCTURE — centres, sports, batches, coaches
-- ============================================================

-- Sports are per tenant so staff can add one without a migration.
create table if not exists sports (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  code       text not null,                 -- 'basketball'
  name       text not null,                 -- 'Basketball'
  icon       text,                          -- emoji shown in UI
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists sports_tenant_code_uniq on sports (tenant_id, code);

-- A centre is a venue Raj coaches AT. He does not own it, which is
-- why centres can carry their own revenue share (see payout_rules).
create table if not exists centres (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  code       text not null,                 -- 'dps-miyapur'
  name       text not null,                 -- 'Delhi Public School Miyapur'
  short_name text,                          -- 'DPS Miyapur'
  address    text,
  contact    text,
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists centres_tenant_code_uniq on centres (tenant_id, code);

create table if not exists coaches (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  name       text not null,
  phone      text,
  role       text not null default 'coach', -- coach | head | assistant | owner
  active     boolean not null default true,
  notes      text,
  created_at timestamptz not null default now()
);
create index if not exists coaches_tenant_idx on coaches (tenant_id, active);

-- A batch is a recurring class: centre + days + time window.
-- `sport` may be null where a centre runs a mixed batch and the sport
-- is decided per student (that is the case at Raj's multi-sport centres).
create table if not exists batches (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  centre_id  bigint not null references centres(id) on delete cascade,
  code       text not null,                 -- 'dps-b1'
  name       text not null,                 -- 'Batch 1'
  sport      text,                          -- null = multi-sport batch
  days       int[] not null default '{}',   -- ISO weekday 1=Mon .. 7=Sun
  start_time time not null,
  end_time   time not null,
  coach_id   bigint references coaches(id) on delete set null,
  capacity   int,
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists batches_tenant_code_uniq on batches (tenant_id, code);
create index if not exists batches_centre_idx on batches (tenant_id, centre_id, active);

-- ============================================================
-- 3. ROSTER — members (the person) + enrollments (the billing unit)
--
-- `members` is the shared platform roster table; we only ADD nullable
-- columns so Leo/Machaxi/MatchPoint are untouched.
-- A student doing cricket AND basketball is ONE member with TWO
-- enrollments — each with its own fee, its own renewal date, and
-- its own coach cut. That is why enrollment, not member, is billed.
-- ============================================================
alter table members add column if not exists parent_name text;
alter table members add column if not exists parent_phone text;
alter table members add column if not exists alt_phone text;
alter table members add column if not exists dob date;
alter table members add column if not exists gender text;
alter table members add column if not exists school text;
alter table members add column if not exists grade text;
alter table members add column if not exists address text;
alter table members add column if not exists notes text;
-- WhatsApp deliverability state. 'active' | 'wrong_number' | 'opted_out'
alter table members add column if not exists whatsapp_status text not null default 'active';
alter table members add column if not exists discontinued_on date;
alter table members add column if not exists updated_at timestamptz not null default now();

create index if not exists members_tenant_wa_idx on members (tenant_id, whatsapp_status);

create table if not exists enrollments (
  id            bigint generated always as identity primary key,
  tenant_id     text not null references tenants(id) on delete cascade,
  member_id     bigint not null references members(id) on delete cascade,
  centre_id     bigint not null references centres(id),
  batch_id      bigint references batches(id) on delete set null,
  sport         text,
  -- Billing
  plan_months   int not null default 1 check (plan_months in (1,3,6,12)),
  -- custom_amount is the staff override — highest priority in the fee
  -- chain. Null means "use the fee rules".
  custom_amount numeric(10,2),
  admission_fee numeric(10,2),
  admission_paid boolean not null default false,
  joined_on     date not null default ist_today(),
  -- renewal_on is the date the NEXT payment is due. record_fee_payment()
  -- rolls it forward; the reminder engine reads it.
  renewal_on    date,
  status        text not null default 'active',  -- active | paused | discontinued
  discontinued_on date,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists enrollments_tenant_status_idx on enrollments (tenant_id, status);
create index if not exists enrollments_member_idx on enrollments (member_id);
create index if not exists enrollments_renewal_idx on enrollments (tenant_id, renewal_on)
  where status = 'active';
create index if not exists enrollments_batch_idx on enrollments (batch_id);

-- ============================================================
-- 4. MONEY IN — fee rules, resolution, payments
--
-- THE FEE CHAIN (most specific wins). Staff never has to fill in
-- every combination: set one tenant-wide default and override only
-- where reality differs.
--
--   60  enrollment.custom_amount      "this student pays ₹X"
--   50  rule on a member              "this family pays ₹X everywhere"
--   45  rule on a batch               "the 7 AM batch is ₹X"
--   40  rule on centre + sport        "basketball at BTV is ₹X"
--   30  rule on sport                 "basketball is ₹X anywhere"
--   20  rule on centre                "everything at PRC is ₹X"
--   10  rule with no scope            tenant default
-- ============================================================
create table if not exists fee_rules (
  id             bigint generated always as identity primary key,
  tenant_id      text not null references tenants(id) on delete cascade,
  label          text,
  -- scope columns; all null = tenant-wide default
  centre_id      bigint references centres(id) on delete cascade,
  sport          text,
  batch_id       bigint references batches(id) on delete cascade,
  member_id      bigint references members(id) on delete cascade,
  -- pricing
  monthly_amount numeric(10,2) not null,
  -- optional per-plan prices, e.g. {"1":1500,"3":4200,"6":8000}
  -- (lets staff give a discount on longer plans). Missing keys fall
  -- back to monthly_amount * months.
  plan_amounts   jsonb not null default '{}'::jsonb,
  admission_fee  numeric(10,2) not null default 0,
  effective_from date not null default ist_today(),
  effective_to   date,
  active         boolean not null default true,
  note           text,
  created_at     timestamptz not null default now()
);
create index if not exists fee_rules_tenant_idx on fee_rules (tenant_id, active);

-- Specificity score for a rule; higher wins.
create or replace function fee_rule_rank(r fee_rules) returns int
  language sql immutable as
$$ select case
     when r.member_id is not null                            then 50
     when r.batch_id  is not null                            then 45
     when r.centre_id is not null and r.sport is not null     then 40
     when r.sport     is not null                             then 30
     when r.centre_id is not null                             then 20
     else 10 end $$;

-- Resolve what an enrollment should pay for `p_months` months.
-- Returns {amount, monthly, source, rule_id, admission_fee}.
-- Used by the fees screen, the payment page, AND the reminder engine —
-- so a reminder always quotes the amount tied to that student.
create or replace function resolve_fee(
  p_tenant  text,
  p_member  bigint,
  p_centre  bigint,
  p_sport   text,
  p_batch   bigint,
  p_months  int default 1,
  p_custom  numeric default null
) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare
  r        fee_rules;
  months   int := greatest(coalesce(p_months, 1), 1);
  monthly  numeric;
  total    numeric;
  keyed    numeric;
begin
  -- 60 — the staff override on the enrollment beats every rule.
  if p_custom is not null then
    return jsonb_build_object(
      'amount', round(p_custom * months, 2),
      'monthly', p_custom,
      'source', 'custom',
      'rule_id', null,
      'admission_fee', 0);
  end if;

  select fr.* into r
    from fee_rules fr
   where fr.tenant_id = p_tenant
     and fr.active
     and fr.effective_from <= ist_today()
     and (fr.effective_to is null or fr.effective_to >= ist_today())
     and (fr.member_id is null or fr.member_id = p_member)
     and (fr.batch_id  is null or fr.batch_id  = p_batch)
     and (fr.centre_id is null or fr.centre_id = p_centre)
     and (fr.sport     is null or fr.sport     = p_sport)
   order by fee_rule_rank(fr) desc, fr.effective_from desc, fr.id desc
   limit 1;

  if not found then
    return jsonb_build_object(
      'amount', null, 'monthly', null, 'source', 'unset',
      'rule_id', null, 'admission_fee', 0);
  end if;

  monthly := r.monthly_amount;
  keyed   := nullif(r.plan_amounts ->> months::text, '')::numeric;
  total   := coalesce(keyed, monthly * months);

  return jsonb_build_object(
    'amount',        round(total, 2),
    'monthly',       monthly,
    'source',        case
                       when r.member_id is not null then 'member'
                       when r.batch_id  is not null then 'batch'
                       when r.centre_id is not null and r.sport is not null then 'centre_sport'
                       when r.sport     is not null then 'sport'
                       when r.centre_id is not null then 'centre'
                       else 'default' end,
    'rule_id',       r.id,
    'label',         r.label,
    'admission_fee', r.admission_fee);
end $$;

-- Convenience: resolve straight from an enrollment id.
create or replace function enrollment_fee(p_enrollment bigint, p_months int default null)
  returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare e enrollments;
begin
  select * into e from enrollments where id = p_enrollment;
  if not found then return jsonb_build_object('amount', null, 'source', 'missing'); end if;
  return resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport, e.batch_id,
                     coalesce(p_months, e.plan_months), e.custom_amount);
end $$;

-- payments: add the coaching-fee columns (nullable → other tenants unaffected)
alter table payments add column if not exists enrollment_id bigint references enrollments(id) on delete set null;
alter table payments add column if not exists member_id     bigint references members(id) on delete set null;
alter table payments add column if not exists centre_id     bigint references centres(id);
alter table payments add column if not exists sport         text;
alter table payments add column if not exists months        int;
alter table payments add column if not exists period_from   date;
alter table payments add column if not exists period_to     date;
alter table payments add column if not exists kind          text;   -- admission | renewal | custom
alter table payments add column if not exists status        text not null default 'paid';
                                                            -- paid | pending_verification | void
alter table payments add column if not exists collected_by  text;
alter table payments add column if not exists note          text;
create index if not exists payments_enrollment_idx on payments (enrollment_id, on_date desc);
create index if not exists payments_member_idx on payments (member_id, on_date desc);

-- ============================================================
-- 5. MONEY OUT — how a PT master (or a centre) takes a cut
--
-- Raj coaches AT other people's centres, and other PT masters coach
-- for Raj. Both sides take a cut, and real contracts take many shapes,
-- so the rule is a (party × basis) pair rather than a single percent:
--
--   basis = 'percent'            % of what was collected
--   basis = 'flat_per_student'   ₹X per active student per month
--   basis = 'monthly_retainer'   fixed ₹X per month, headcount-blind
--   basis = 'per_session'        ₹X per session actually held
--   basis = 'flat_per_payment'   ₹X per payment collected
--   basis = 'slab'               banded by headcount, e.g.
--                                [{"upto":20,"percent":40},
--                                 {"upto":null,"percent":50}]
--
-- applies_on = 'gross'            the whole collection
-- applies_on = 'net_after_centre' what's left after the CENTRE's cut
--                                 (the usual shape: school takes 30%,
--                                  the PT master splits the remainder)
--
-- min_guarantee / max_cap wrap it, so "₹8,000 minimum or 40%,
-- whichever is higher, capped at ₹25,000" is expressible.
-- ============================================================
create table if not exists payout_rules (
  id             bigint generated always as identity primary key,
  tenant_id      text not null references tenants(id) on delete cascade,
  label          text,
  party          text not null check (party in ('coach','centre')),
  coach_id       bigint references coaches(id) on delete cascade,
  -- scope: any combination; null = applies to all
  centre_id      bigint references centres(id) on delete cascade,
  sport          text,
  batch_id       bigint references batches(id) on delete cascade,
  member_id      bigint references members(id) on delete cascade,
  basis          text not null check (basis in
                   ('percent','flat_per_student','monthly_retainer',
                    'per_session','flat_per_payment','slab')),
  value          numeric(12,2) not null default 0,
  slabs          jsonb not null default '[]'::jsonb,
  applies_on     text not null default 'gross'
                   check (applies_on in ('gross','net_after_centre')),
  min_guarantee  numeric(12,2),
  max_cap        numeric(12,2),
  effective_from date not null default ist_today(),
  effective_to   date,
  active         boolean not null default true,
  note           text,
  created_at     timestamptz not null default now()
);
create index if not exists payout_rules_tenant_idx on payout_rules (tenant_id, party, active);
-- A coach rule must name the coach; a centre rule must name the centre.
alter table payout_rules drop constraint if exists payout_rules_party_scope;
alter table payout_rules add constraint payout_rules_party_scope check (
  (party = 'coach'  and coach_id  is not null) or
  (party = 'centre' and centre_id is not null));

-- The generated ledger: one row per party per month.
create table if not exists payouts (
  id             bigint generated always as identity primary key,
  tenant_id      text not null references tenants(id) on delete cascade,
  period_month   date not null,                    -- first day of the month
  party          text not null check (party in ('coach','centre')),
  coach_id       bigint references coaches(id) on delete set null,
  centre_id      bigint references centres(id) on delete set null,
  rule_id        bigint references payout_rules(id) on delete set null,
  amount         numeric(12,2) not null default 0,
  basis_snapshot jsonb not null default '{}'::jsonb, -- how it was computed
  status         text not null default 'pending',    -- pending | paid | void
  paid_on        date,
  note           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists payouts_period_rule_uniq
  on payouts (tenant_id, period_month, rule_id)
  where rule_id is not null and status <> 'void';
create index if not exists payouts_tenant_period_idx on payouts (tenant_id, period_month desc);

-- Sessions actually held — the denominator for per_session payouts and
-- the audit trail for "did the batch run this month".
create table if not exists sessions (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  batch_id   bigint not null references batches(id) on delete cascade,
  on_date    date not null,
  coach_id   bigint references coaches(id) on delete set null,
  status     text not null default 'held',   -- held | cancelled
  note       text,
  created_at timestamptz not null default now()
);
create unique index if not exists sessions_batch_date_uniq on sessions (tenant_id, batch_id, on_date);
create index if not exists sessions_tenant_date_idx on sessions (tenant_id, on_date);

-- Collections for a month, restricted to a rule's scope.
create or replace function payout_scope_collected(
  p_tenant text, p_month date, r payout_rules
) returns numeric
  language sql stable security definer set search_path = public as $$
  select coalesce(sum(p.amount), 0)::numeric
    from payments p
    left join enrollments e on e.id = p.enrollment_id
   where p.tenant_id = p_tenant
     and p.status = 'paid'
     and p.on_date >= p_month
     and p.on_date <  (p_month + interval '1 month')::date
     and (r.centre_id is null or p.centre_id = r.centre_id)
     and (r.sport     is null or p.sport     = r.sport)
     and (r.batch_id  is null or e.batch_id  = r.batch_id)
     and (r.member_id is null or p.member_id = r.member_id)
$$;

create or replace function payout_scope_headcount(
  p_tenant text, p_month date, r payout_rules
) returns int
  language sql stable security definer set search_path = public as $$
  select count(*)::int
    from enrollments e
   where e.tenant_id = p_tenant
     and e.status = 'active'
     and e.joined_on < (p_month + interval '1 month')::date
     and (r.centre_id is null or e.centre_id = r.centre_id)
     and (r.sport     is null or e.sport     = r.sport)
     and (r.batch_id  is null or e.batch_id  = r.batch_id)
     and (r.member_id is null or e.member_id = r.member_id)
$$;

create or replace function payout_scope_sessions(
  p_tenant text, p_month date, r payout_rules
) returns int
  language sql stable security definer set search_path = public as $$
  select count(*)::int
    from sessions s
    join batches b on b.id = s.batch_id
   where s.tenant_id = p_tenant
     and s.status = 'held'
     and s.on_date >= p_month
     and s.on_date <  (p_month + interval '1 month')::date
     and (r.centre_id is null or b.centre_id = r.centre_id)
     and (r.sport     is null or b.sport     = r.sport)
     and (r.batch_id  is null or s.batch_id  = r.batch_id)
     and (r.coach_id  is null or coalesce(s.coach_id, b.coach_id) = r.coach_id)
$$;

-- Pick the slab whose ceiling covers the headcount.
create or replace function payout_slab_value(p_slabs jsonb, p_count int)
  returns jsonb
  language sql immutable as $$
  select s from jsonb_array_elements(p_slabs) s
   where (s->>'upto') is null or (s->>'upto')::int >= p_count
   order by coalesce((s->>'upto')::int, 2147483647)
   limit 1
$$;

-- Compute (and store) every payout line for a month.
-- Centre rules run FIRST so coach rules with applies_on='net_after_centre'
-- have a net to work from. Re-running replaces unpaid lines only —
-- a line already marked paid is never silently rewritten.
create or replace function compute_payouts(p_tenant text, p_month date)
  returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  m           date := date_trunc('month', p_month)::date;
  r           payout_rules;
  collected   numeric;
  headcount   int;
  sess        int;
  amt         numeric;
  slab        jsonb;
  centre_cut  numeric := 0;
  net_by_centre jsonb := '{}'::jsonb;
  base        numeric;
  lines       jsonb := '[]'::jsonb;
  snap        jsonb;
begin
  perform assert_staff_or_service(p_tenant);

  -- ---- pass 1: centres ----
  for r in
    select * from payout_rules
     where tenant_id = p_tenant and party = 'centre' and active
       and effective_from <= (m + interval '1 month' - interval '1 day')::date
       and (effective_to is null or effective_to >= m)
     order by id
  loop
    collected := payout_scope_collected(p_tenant, m, r);
    headcount := payout_scope_headcount(p_tenant, m, r);
    sess      := payout_scope_sessions(p_tenant, m, r);

    amt := case r.basis
             when 'percent'           then collected * r.value / 100.0
             when 'flat_per_student'  then headcount * r.value
             when 'monthly_retainer'  then r.value
             when 'per_session'       then sess * r.value
             when 'flat_per_payment'  then r.value * (
                   select count(*) from payments p
                    where p.tenant_id = p_tenant and p.status='paid'
                      and p.on_date >= m and p.on_date < (m + interval '1 month')::date
                      and (r.centre_id is null or p.centre_id = r.centre_id))
             when 'slab' then (
                   select case
                     when (payout_slab_value(r.slabs, headcount)->>'percent') is not null
                       then collected * (payout_slab_value(r.slabs, headcount)->>'percent')::numeric / 100.0
                     else coalesce((payout_slab_value(r.slabs, headcount)->>'amount')::numeric, 0)
                   end)
             else 0 end;

    if r.min_guarantee is not null then amt := greatest(amt, r.min_guarantee); end if;
    if r.max_cap       is not null then amt := least(amt, r.max_cap); end if;
    amt := round(coalesce(amt, 0), 2);

    snap := jsonb_build_object('basis', r.basis, 'value', r.value,
              'collected', collected, 'headcount', headcount, 'sessions', sess,
              'applies_on', 'gross', 'month', m);

    insert into payouts (tenant_id, period_month, party, centre_id, rule_id, amount, basis_snapshot)
    values (p_tenant, m, 'centre', r.centre_id, r.id, amt, snap)
    on conflict (tenant_id, period_month, rule_id) where rule_id is not null and status <> 'void'
    do update set amount = excluded.amount,
                  basis_snapshot = excluded.basis_snapshot,
                  updated_at = now()
    where payouts.status = 'pending';

    -- remember the centre's cut so coach rules can net it off
    net_by_centre := net_by_centre || jsonb_build_object(
      coalesce(r.centre_id::text, 'all'),
      coalesce((net_by_centre->>coalesce(r.centre_id::text,'all'))::numeric, 0) + amt);

    lines := lines || jsonb_build_array(jsonb_build_object(
      'party','centre','centre_id',r.centre_id,'rule_id',r.id,'amount',amt,'snapshot',snap));
  end loop;

  -- ---- pass 2: coaches ----
  for r in
    select * from payout_rules
     where tenant_id = p_tenant and party = 'coach' and active
       and effective_from <= (m + interval '1 month' - interval '1 day')::date
       and (effective_to is null or effective_to >= m)
     order by id
  loop
    collected := payout_scope_collected(p_tenant, m, r);
    headcount := payout_scope_headcount(p_tenant, m, r);
    sess      := payout_scope_sessions(p_tenant, m, r);

    centre_cut := coalesce((net_by_centre->>coalesce(r.centre_id::text,'all'))::numeric, 0);
    base := case when r.applies_on = 'net_after_centre'
                 then greatest(collected - centre_cut, 0)
                 else collected end;

    amt := case r.basis
             when 'percent'           then base * r.value / 100.0
             when 'flat_per_student'  then headcount * r.value
             when 'monthly_retainer'  then r.value
             when 'per_session'       then sess * r.value
             when 'flat_per_payment'  then r.value * (
                   select count(*) from payments p
                    where p.tenant_id = p_tenant and p.status='paid'
                      and p.on_date >= m and p.on_date < (m + interval '1 month')::date
                      and (r.centre_id is null or p.centre_id = r.centre_id))
             when 'slab' then (
                   select case
                     when (payout_slab_value(r.slabs, headcount)->>'percent') is not null
                       then base * (payout_slab_value(r.slabs, headcount)->>'percent')::numeric / 100.0
                     else coalesce((payout_slab_value(r.slabs, headcount)->>'amount')::numeric, 0)
                   end)
             else 0 end;

    if r.min_guarantee is not null then amt := greatest(amt, r.min_guarantee); end if;
    if r.max_cap       is not null then amt := least(amt, r.max_cap); end if;
    amt := round(coalesce(amt, 0), 2);

    snap := jsonb_build_object('basis', r.basis, 'value', r.value,
              'collected', collected, 'base', base, 'centre_cut', centre_cut,
              'headcount', headcount, 'sessions', sess,
              'applies_on', r.applies_on, 'month', m);

    insert into payouts (tenant_id, period_month, party, coach_id, centre_id, rule_id, amount, basis_snapshot)
    values (p_tenant, m, 'coach', r.coach_id, r.centre_id, r.id, amt, snap)
    on conflict (tenant_id, period_month, rule_id) where rule_id is not null and status <> 'void'
    do update set amount = excluded.amount,
                  basis_snapshot = excluded.basis_snapshot,
                  updated_at = now()
    where payouts.status = 'pending';

    lines := lines || jsonb_build_array(jsonb_build_object(
      'party','coach','coach_id',r.coach_id,'rule_id',r.id,'amount',amt,'snapshot',snap));
  end loop;

  return jsonb_build_object('month', m, 'lines', lines);
end $$;

-- ============================================================
-- 6. RECORDING A PAYMENT — the one write path for fees.
--    Rolls the renewal date forward, writes the timeline, and
--    (for a renewal) closes any open reminder for that enrollment.
-- ============================================================
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
  e         enrollments;
  m         members;
  months    int;
  paid_on   date := coalesce(p_on_date, ist_today());
  from_d    date;
  to_d      date;
  pay_id    bigint;
begin
  perform assert_staff_or_service(p_tenant);

  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then raise exception 'enrollment not found'; end if;
  select * into m from members where id = e.member_id;

  months := coalesce(p_months, e.plan_months, 1);

  -- A renewal extends from the later of (current renewal date, today) so
  -- paying early never loses days and paying late never back-dates.
  if p_kind = 'renewal' then
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
          coalesce(e.sport, '') || case when months > 1 then ' · ' || months || ' months' else '' end,
          round(p_amount)::int, p_mode, paid_on, p_ref,
          e.id, e.member_id, e.centre_id, e.sport, months,
          from_d, to_d, p_kind, p_status, p_collected_by, p_note)
  returning id into pay_id;

  -- Only a confirmed payment moves the renewal date. A payment sitting at
  -- pending_verification must NOT make a student look paid.
  if p_status = 'paid' then
    if p_kind = 'renewal' then
      update enrollments
         set renewal_on = to_d, updated_at = now()
       where id = e.id;
      update reminder_events
         set status = 'resolved', resolved_at = now(), next_retry_at = null
       where tenant_id = p_tenant and enrollment_id = e.id
         and status in ('sent','delivered','read','accepted','failed',
                        'retry_scheduled','manual_followup','queued');
    elsif p_kind = 'admission' then
      update enrollments set admission_paid = true, updated_at = now() where id = e.id;
    end if;
  end if;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body, meta)
  values (p_tenant, e.member_id, e.id,
          case when p_status = 'paid' then 'payment' else 'payment_pending' end,
          case when p_status = 'paid'
               then 'Payment received · ₹' || round(p_amount)::text
               else 'Payment pending verification · ₹' || round(p_amount)::text end,
          coalesce(p_note, initcap(p_kind) || ' · ' || p_mode),
          jsonb_build_object('payment_id', pay_id, 'months', months,
                             'period_from', from_d, 'period_to', to_d, 'ref', p_ref));

  return jsonb_build_object('payment_id', pay_id, 'renewal_on',
                            (select renewal_on from enrollments where id = e.id),
                            'period_from', from_d, 'period_to', to_d);
end $$;

-- ============================================================
-- 7. WHATSAPP ENGINE (tenant-scoped port of the Gen Alpha engine)
-- ============================================================

-- Append-only history shown on the student profile.
create table if not exists member_timeline (
  id            bigint generated always as identity primary key,
  tenant_id     text not null references tenants(id) on delete cascade,
  member_id     bigint not null references members(id) on delete cascade,
  enrollment_id bigint references enrollments(id) on delete set null,
  kind          text not null,        -- payment | reminder | admission | note | system
  title         text not null,
  body          text,
  meta          jsonb not null default '{}'::jsonb,
  at            timestamptz not null default now()
);
create index if not exists member_timeline_member_idx on member_timeline (member_id, at desc);

-- One CURRENT-STATE row per reminder run per enrollment.
create table if not exists reminder_events (
  id             bigint generated always as identity primary key,
  tenant_id      text not null references tenants(id) on delete cascade,
  member_id      bigint not null references members(id) on delete cascade,
  enrollment_id  bigint references enrollments(id) on delete cascade,
  reminder_type  text not null default 'renewal',   -- renewal | admission_fee
  stage          text not null,                     -- heads_up | due | overdue
  channel        text not null default 'whatsapp',
  -- queued → (manual mode) awaiting a tap, or (auto) about to send
  -- accepted → sent → delivered → read       | failed → retry_scheduled
  -- manual_followup = stop auto, human must act
  status         text not null default 'queued',
  due_date       date,
  overdue_days   int not null default 0,
  amount         numeric(10,2),
  months         int,
  to_phone       text,
  template       text,
  message_body   text,
  message_id     text,
  error_code     text,
  error_message  text,
  retry_count    int not null default 0,
  next_retry_at  timestamptz,
  followup_reason text,      -- wrong_phone_number | whatsapp_opted_out |
                             -- overdue_15_days | retry_exhausted |
                             -- delivery_failure | missing_phone
  sent_by        text not null default 'system',   -- system | manual
  dry_run        boolean not null default true,
  resolved_at    timestamptz,
  -- The IST calendar day this reminder belongs to. Stored, not computed,
  -- because `created_at at time zone 'Asia/Kolkata'` is STABLE and cannot
  -- be indexed — and the one-per-day rule has to be an index to hold.
  ist_date       date not null default ist_today(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
alter table reminder_events add column if not exists ist_date date not null default ist_today();
create index if not exists reminder_events_tenant_idx on reminder_events (tenant_id, created_at desc);
create index if not exists reminder_events_enrollment_idx on reminder_events (enrollment_id, created_at desc);
create index if not exists reminder_events_retry_idx on reminder_events (tenant_id, next_retry_at)
  where status = 'retry_scheduled';
-- Never send the same student two reminders on the same IST day.
create unique index if not exists reminder_events_one_per_day
  on reminder_events (tenant_id, enrollment_id, ist_date)
  where status <> 'void';

-- Append-only audit stream (never updated, only inserted).
create table if not exists wa_flow_events (
  id           bigint generated always as identity primary key,
  tenant_id    text not null references tenants(id) on delete cascade,
  member_id    bigint references members(id) on delete cascade,
  reminder_id  bigint references reminder_events(id) on delete cascade,
  step         text not null,     -- reminder_created | sent | delivered | read |
                                  -- failed | retry_scheduled | manual_sent |
                                  -- parent_replied | payment_claimed | resolved
  detail       text,
  meta         jsonb not null default '{}'::jsonb,
  at           timestamptz not null default now()
);
create index if not exists wa_flow_events_reminder_idx on wa_flow_events (reminder_id, at);
create index if not exists wa_flow_events_tenant_idx on wa_flow_events (tenant_id, at desc);

-- Raw inbound webhook payloads, for diagnosing delivery problems.
create table if not exists wa_webhook_events (
  id         bigint generated always as identity primary key,
  tenant_id  text,
  message_id text,
  kind       text,
  payload    jsonb not null default '{}'::jsonb,
  at         timestamptz not null default now()
);
create index if not exists wa_webhook_events_msg_idx on wa_webhook_events (message_id);

-- ------------------------------------------------------------
-- THE QUEUE. One function answers "who needs a reminder today and
-- for how much" — the cron uses it to send, and the staff screen
-- uses the SAME function to show the manual click-to-send list.
-- Both surfaces therefore always agree.
--
-- Schedule (matches the proven Gen Alpha ladder):
--   -2 days  heads_up      soft nudge before the renewal date
--    0 days  due           due today
--   +5 days  overdue       first chase
--   +7..+14  overdue       daily
--   +15 and beyond         STOP — manual follow-up only
-- ------------------------------------------------------------
drop function if exists reminder_queue(text, date);
create function reminder_queue(p_tenant text, p_on date default null)
  returns table (
    enrollment_id bigint,
    member_id     bigint,
    member_name   text,
    parent_name   text,
    phone         text,
    centre        text,
    batch         text,
    sport         text,
    due_date      date,
    days_since    int,
    stage         text,
    amount        numeric,
    months        int,
    fee_source    text,
    whatsapp_status text,
    blocked_reason text,
    already_sent  boolean,
    last_sent_at  timestamptz,
    last_sent_status text,
    last_sent_channel text
  )
  language sql stable security definer set search_path = public as $$
  with today as (select coalesce(p_on, ist_today()) as d),
  base as (
    select e.id as enrollment_id, e.member_id, m.name as member_name,
           m.parent_name,
           coalesce(nullif(m.parent_phone,''), nullif(m.phone,'')) as phone,
           c.short_name as centre, b.name as batch, e.sport,
           e.renewal_on as due_date,
           ((select d from today) - e.renewal_on) as days_since,
           e.plan_months as months,
           m.whatsapp_status,
           resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport, e.batch_id,
                       e.plan_months, e.custom_amount) as fee
      from enrollments e
      join members m on m.id = e.member_id
      join centres c on c.id = e.centre_id
      left join batches b on b.id = e.batch_id
     where e.tenant_id = p_tenant
       and e.status = 'active'
       and m.status <> 'discontinued'
       and e.renewal_on is not null
  )
  select
    base.enrollment_id, base.member_id, base.member_name, base.parent_name,
    base.phone, base.centre, base.batch, base.sport, base.due_date, base.days_since,
    case
      when base.days_since = -2 then 'heads_up'
      when base.days_since = 0  then 'due'
      else 'overdue'
    end as stage,
    (base.fee->>'amount')::numeric as amount,
    base.months,
    base.fee->>'source' as fee_source,
    base.whatsapp_status,
    case
      when base.phone is null or length(regexp_replace(base.phone,'\D','','g')) < 10
        then 'missing_phone'
      when base.whatsapp_status = 'wrong_number' then 'wrong_phone_number'
      when base.whatsapp_status = 'opted_out'    then 'whatsapp_opted_out'
      when base.days_since >= 15                 then 'overdue_15_days'
      when (base.fee->>'amount') is null         then 'fee_not_set'
      else null
    end as blocked_reason,
    coalesce(last_reminder.ist_date = (select d from today), false) as already_sent,
    last_reminder.created_at as last_sent_at,
    last_reminder.status as last_sent_status,
    last_reminder.channel as last_sent_channel
  from base
  left join lateral (
    select r.created_at, r.status, r.channel, r.ist_date
      from reminder_events r
     where r.tenant_id = p_tenant
       and r.enrollment_id = base.enrollment_id
       and r.status <> 'void'
     order by r.created_at desc
     limit 1
  ) last_reminder on true
  where base.days_since = -2          -- heads-up
     or base.days_since = 0           -- due today
     or base.days_since = 5           -- first chase
     or (base.days_since between 7 and 14)  -- daily chase
     or base.days_since >= 15         -- surfaced, but blocked → manual only
  order by base.days_since desc, base.member_name
$$;

-- Mark a reminder the manager sent by hand (wa.me tap or a phone call).
create or replace function log_manual_reminder(
  p_tenant     text,
  p_enrollment bigint,
  p_stage      text,
  p_amount     numeric,
  p_phone      text,
  p_body       text default null,
  p_channel    text default 'whatsapp',   -- whatsapp | call
  p_by         text default 'staff'
) returns bigint
  language plpgsql security definer set search_path = public as $$
declare
  e   enrollments;
  rid bigint;
begin
  perform assert_staff_or_service(p_tenant);
  select * into e from enrollments where id = p_enrollment and tenant_id = p_tenant;
  if not found then raise exception 'enrollment not found'; end if;

  insert into reminder_events (tenant_id, member_id, enrollment_id, stage, channel,
                               status, due_date, overdue_days, amount, months,
                               to_phone, message_body, sent_by, dry_run)
  values (p_tenant, e.member_id, e.id, p_stage, p_channel,
          case when p_channel = 'call' then 'called' else 'manual_sent' end,
          e.renewal_on, greatest(ist_today() - coalesce(e.renewal_on, ist_today()), 0),
          p_amount, e.plan_months, p_phone, p_body, 'manual', false)
  returning id into rid;

  insert into wa_flow_events (tenant_id, member_id, reminder_id, step, detail)
  values (p_tenant, e.member_id, rid,
          case when p_channel = 'call' then 'called' else 'manual_sent' end,
          coalesce(p_body, 'Sent by staff'));

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, e.member_id, e.id, 'reminder',
          case when p_channel = 'call' then 'Parent called by staff'
               else 'Reminder sent by staff on WhatsApp' end,
          p_body);
  return rid;
end $$;

-- ============================================================
-- 8. ADMISSIONS — extend the shared applications table
-- ============================================================
alter table applications add column if not exists centre_id    bigint references centres(id);
alter table applications add column if not exists batch_id     bigint references batches(id);
alter table applications add column if not exists sport        text;
alter table applications add column if not exists parent_name  text;
alter table applications add column if not exists parent_phone text;
alter table applications add column if not exists dob          date;
alter table applications add column if not exists gender       text;
alter table applications add column if not exists school       text;
alter table applications add column if not exists status       text not null default 'pending';
                                                               -- pending | approved | rejected
alter table applications add column if not exists reviewed_at  timestamptz;
alter table applications add column if not exists reviewed_by  text;
alter table applications add column if not exists member_id    bigint references members(id) on delete set null;
create index if not exists applications_status_idx on applications (tenant_id, status, created_at desc);

-- Approve an application → create the member + the enrollment.
create or replace function approve_application(
  p_tenant text, p_application bigint, p_by text default 'staff'
) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  a    applications;
  mid  bigint;
  eid  bigint;
  fee  jsonb;
begin
  perform assert_staff_or_service(p_tenant);
  select * into a from applications where id = p_application and tenant_id = p_tenant;
  if not found then raise exception 'application not found'; end if;
  if a.status = 'approved' then
    return jsonb_build_object('member_id', a.member_id, 'already', true);
  end if;

  insert into members (tenant_id, name, phone, parent_name, parent_phone, dob,
                       gender, school, program, joined, status)
  values (p_tenant, a.name, coalesce(a.parent_phone, a.phone), a.parent_name,
          coalesce(a.parent_phone, a.phone), a.dob, a.gender, a.school,
          a.sport, ist_today(), 'active')
  returning id into mid;

  fee := resolve_fee(p_tenant, mid, a.centre_id, a.sport, a.batch_id, 1, null);

  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                           plan_months, admission_fee, joined_on, renewal_on, status)
  values (p_tenant, mid, a.centre_id, a.batch_id, a.sport, 1,
          coalesce((fee->>'admission_fee')::numeric, 0), ist_today(),
          (ist_today() + interval '1 month')::date, 'active')
  returning id into eid;

  update applications
     set status = 'approved', reviewed_at = now(), reviewed_by = p_by, member_id = mid
   where id = a.id;

  insert into member_timeline (tenant_id, member_id, enrollment_id, kind, title, body)
  values (p_tenant, mid, eid, 'admission', 'Admission approved',
          'Enrolled at centre #' || a.centre_id || coalesce(' · ' || a.sport, ''));

  return jsonb_build_object('member_id', mid, 'enrollment_id', eid,
                            'fee', fee, 'already', false);
end $$;

-- ============================================================
-- 9. RLS — staff of the tenant, or the operator. No anon access to
--    roster/fee/payout data. The public admission form writes through
--    the existing anon insert policy on `applications` only.
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['sports','centres','coaches','batches','enrollments',
                           'fee_rules','payout_rules','payouts','sessions',
                           'member_timeline','reminder_events','wa_flow_events']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_staff_r', t);
    execute format($p$create policy %I on %I for select
      using (auth_role() = 'operator'
             or (auth_role() = 'staff' and tenant_id = auth_tenant())
             or not is_locked())$p$, t || '_staff_r', t);
    execute format('drop policy if exists %I on %I', t || '_staff_w', t);
    execute format($p$create policy %I on %I for insert
      with check ((auth_role() = 'staff' and tenant_id = auth_tenant())
                  or not is_locked())$p$, t || '_staff_w', t);
    execute format('drop policy if exists %I on %I', t || '_staff_u', t);
    execute format($p$create policy %I on %I for update
      using ((auth_role() = 'staff' and tenant_id = auth_tenant())
             or not is_locked())$p$, t || '_staff_u', t);
  end loop;
end $$;

alter table wa_webhook_events enable row level security;  -- service role only

grant execute on function resolve_fee(text,bigint,bigint,text,bigint,int,numeric) to authenticated, anon;
grant execute on function enrollment_fee(bigint,int)        to authenticated;
grant execute on function reminder_queue(text,date)         to authenticated;
grant execute on function record_fee_payment(text,bigint,numeric,int,text,text,date,text,text,text,text) to authenticated;
grant execute on function log_manual_reminder(text,bigint,text,numeric,text,text,text,text) to authenticated;
grant execute on function compute_payouts(text,date)        to authenticated;
grant execute on function approve_application(text,bigint,text) to authenticated;
grant execute on function ist_today()                       to authenticated, anon;

-- ============================================================
-- 10. SEED — Raj Sports' real centres and batches.
--
--     Sports are recorded only where the client stated them
--     (DPS Miyapur: all five; BTV: basketball). Pushpak, Hill County
--     and PRC batches are left sport-neutral until confirmed, so the
--     sport is chosen per student at enrollment.
--
--     days[] is ISO weekday: 1=Mon … 7=Sun.
-- ============================================================
insert into sports (tenant_id, code, name, icon, sort) values
  ('raj','archery',   'Archery',    '🏹', 1),
  ('raj','basketball','Basketball', '🏀', 2),
  ('raj','football',  'Football',   '⚽️', 3),
  ('raj','cricket',   'Cricket',    '🏏', 4),
  ('raj','tennis',    'Tennis',     '🎾', 5)
on conflict (tenant_id, code) do nothing;

insert into centres (tenant_id, code, name, short_name, sort) values
  ('raj','dps-miyapur','Delhi Public School Miyapur','DPS Miyapur', 1),
  ('raj','btv',        'BTV',                        'BTV',         2),
  ('raj','pushpak',    'Pushpak',                    'Pushpak',     3),
  ('raj','hillcounty', 'Hill County',                'Hill County', 4),
  ('raj','prc',        'PRC',                        'PRC',         5)
on conflict (tenant_id, code) do nothing;

insert into batches (tenant_id, centre_id, code, name, sport, days, start_time, end_time, sort)
select 'raj', c.id, v.code, v.name, v.sport, v.days, v.st::time, v.et::time, v.sort
from (values
  -- DPS Miyapur — Mon–Fri, two batches, all five sports
  ('dps-miyapur','dps-b1','Batch 1', null, array[1,2,3,4,5], '15:00','16:30', 1),
  ('dps-miyapur','dps-b2','Batch 2', null, array[1,2,3,4,5], '16:30','18:00', 2),
  -- BTV — basketball only, five batches
  ('btv','btv-b1','Batch 1','basketball', array[1,3,5], '18:00','19:00', 1),
  ('btv','btv-b2','Batch 2','basketball', array[1,3,5], '19:00','20:00', 2),
  ('btv','btv-b3','Batch 3','basketball', array[2,4,6], '17:00','18:00', 3),
  ('btv','btv-b4','Batch 4','basketball', array[2,4,6], '18:00','19:00', 4),
  ('btv','btv-b5','Batch 5','basketball', array[2,4,6], '19:00','20:00', 5),
  -- Pushpak — Mon/Wed/Fri
  ('pushpak','pushpak-b1','Batch 1', null, array[1,3,5], '17:00','18:00', 1),
  ('pushpak','pushpak-b2','Batch 2', null, array[1,3,5], '18:00','19:00', 2),
  -- Hill County — Tue/Thu/Sat
  ('hillcounty','hill-b1','Batch 1', null, array[2,4,6], '17:00','18:00', 1),
  ('hillcounty','hill-b2','Batch 2', null, array[2,4,6], '18:00','19:00', 2),
  -- PRC — Mon–Fri
  ('prc','prc-b1','Batch 1', null, array[1,2,3,4,5], '17:00','18:00', 1),
  ('prc','prc-b2','Batch 2', null, array[1,2,3,4,5], '18:00','19:00', 2)
) as v(centre, code, name, sport, days, st, et, sort)
join centres c on c.tenant_id = 'raj' and c.code = v.centre
on conflict (tenant_id, code) do nothing;

-- The owner-coach.
insert into coaches (tenant_id, name, role)
select 'raj', 'Raj', 'owner'
where not exists (select 1 from coaches where tenant_id = 'raj' and role = 'owner');

-- ============================================================
-- 11. COURTSYNC GUARD — this tenant must never grow booking data.
--     Cheap insurance: a trigger, not just a config flag, because a
--     stray insert from a shared code path would otherwise be silent.
-- ============================================================
create or replace function block_booking_for_coaching_tenant()
  returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select (config->'modules'->>'booking')::boolean
                 from tenants where id = new.tenant_id), true) = false then
    raise exception 'tenant % has court booking disabled (coaching-only)', new.tenant_id;
  end if;
  return new;
end $$;

drop trigger if exists bookings_module_guard on bookings;
create trigger bookings_module_guard
  before insert on bookings
  for each row execute function block_booking_for_coaching_tenant();

drop trigger if exists integrations_module_guard on integrations;
create trigger integrations_module_guard
  before insert on integrations
  for each row execute function block_booking_for_coaching_tenant();

-- Nothing booking-shaped should exist for 'raj'. Fail loudly if it does.
do $$
begin
  if exists (select 1 from bookings where tenant_id = 'raj')
     or exists (select 1 from integrations where tenant_id = 'raj') then
    raise exception 'raj has booking/CourtSync rows — expected none';
  end if;
end $$;
