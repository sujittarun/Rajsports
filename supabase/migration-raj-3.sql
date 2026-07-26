-- ============================================================
-- RAJ SPORTS — migration 3: hardening + observability
--
-- Raj will grow: a new sport, a new venue, a batch time that moves.
-- Every one of those is a routine edit in the app, so the DATABASE has
-- to be the thing that refuses a bad edit — not the UI, which is only
-- one of two clients (web and Android) and will not always be the newest.
--
-- Three groups of change:
--   A. INTEGRITY   — constraints and guards so no edit can orphan data,
--                    double-charge, or create two rules that fight.
--   B. CODES       — collision-safe slugs, so "Batch 3" added twice at
--                    two centres, or a re-added centre, never clashes.
--   C. OBSERVABILITY — an append-only audit_log of every config change,
--                    plus tenant_health() for the Academy Manager console.
--
-- Idempotent. Apply with scripts/migrate.sh.
-- ============================================================

-- ============================================================
-- A. INTEGRITY
-- ============================================================

-- ---------- batches: a timing must be a real timing ----------
alter table batches drop constraint if exists batches_time_order;
alter table batches add constraint batches_time_order
  check (end_time > start_time);

-- A CHECK cannot contain a subquery, so the "no repeated weekday" test
-- lives in an IMMUTABLE helper the constraint can call.
create or replace function distinct_count(p int[]) returns int
  language sql immutable as
$$ select count(distinct x)::int from unnest(coalesce(p, '{}')) x $$;

alter table batches drop constraint if exists batches_days_valid;
alter table batches add constraint batches_days_valid
  check (
    array_length(days, 1) between 1 and 7
    and days <@ array[1,2,3,4,5,6,7]
    and array_length(days, 1) = distinct_count(days)
  );

-- Two batches at one centre may overlap in time (Raj coaches five sports
-- in the same slot at DPS) — but two batches must not share a NAME there,
-- or the roster and the payout lines become ambiguous.
create unique index if not exists batches_centre_name_uniq
  on batches (tenant_id, centre_id, lower(name)) where active;

-- ---------- money can never be negative ----------
alter table fee_rules drop constraint if exists fee_rules_amounts_sane;
alter table fee_rules add constraint fee_rules_amounts_sane
  check (monthly_amount >= 0 and admission_fee >= 0);

alter table enrollments drop constraint if exists enrollments_custom_sane;
alter table enrollments add constraint enrollments_custom_sane
  check (custom_amount is null or custom_amount >= 0);

alter table payout_rules drop constraint if exists payout_rules_value_sane;
alter table payout_rules add constraint payout_rules_value_sane
  check (
    value >= 0
    and (basis <> 'percent' or value <= 100)
    and (min_guarantee is null or min_guarantee >= 0)
    and (max_cap is null or max_cap >= 0)
    and (min_guarantee is null or max_cap is null or max_cap >= min_guarantee)
    and (basis <> 'slab' or jsonb_array_length(slabs) > 0)
  );

-- ---------- exactly one rule may win ----------
-- Without this, a manager who adds "Basketball ₹1400" twice gets a fee
-- that depends on row order. The resolver would still be deterministic,
-- but the manager would have no way to see WHICH one applies.
create unique index if not exists fee_rules_scope_uniq
  on fee_rules (
    tenant_id,
    coalesce(centre_id, -1),
    coalesce(sport, ''),
    coalesce(batch_id, -1),
    coalesce(member_id, -1)
  ) where active;

-- Same for payouts: two active rules on one scope would pay a coach twice.
create unique index if not exists payout_rules_scope_uniq
  on payout_rules (
    tenant_id, party,
    coalesce(coach_id, -1),
    coalesce(centre_id, -1),
    coalesce(sport, ''),
    coalesce(batch_id, -1),
    coalesce(member_id, -1)
  ) where active;

-- One active enrollment per student per batch per sport. A student CAN
-- do two sports (two rows) — they cannot be billed twice for one.
create unique index if not exists enrollments_active_uniq
  on enrollments (tenant_id, member_id, batch_id, coalesce(sport, ''))
  where status = 'active';

-- ---------- deletes must not orphan ----------
-- A centre or batch that has ever had students is history, not a typo.
-- Deactivate it instead; the app offers exactly that.
create or replace function guard_centre_delete() returns trigger
  language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from enrollments where centre_id = old.id;
  if n > 0 then
    raise exception 'Centre "%" has % enrollment(s). Deactivate it instead of deleting.',
      old.name, n using errcode = 'restrict_violation';
  end if;
  return old;
end $$;
drop trigger if exists centres_delete_guard on centres;
create trigger centres_delete_guard before delete on centres
  for each row execute function guard_centre_delete();

create or replace function guard_batch_delete() returns trigger
  language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from enrollments where batch_id = old.id;
  if n > 0 then
    raise exception 'Batch "%" has % enrollment(s). Deactivate it instead of deleting.',
      old.name, n using errcode = 'restrict_violation';
  end if;
  return old;
end $$;
drop trigger if exists batches_delete_guard on batches;
create trigger batches_delete_guard before delete on batches
  for each row execute function guard_batch_delete();

-- `sport` is stored as text on batches/enrollments/fee_rules, so removing
-- a row from `sports` would leave those strings pointing at nothing.
create or replace function guard_sport_delete() returns trigger
  language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select (select count(*) from enrollments where tenant_id = old.tenant_id and sport = old.code)
       + (select count(*) from batches     where tenant_id = old.tenant_id and sport = old.code)
       + (select count(*) from fee_rules   where tenant_id = old.tenant_id and sport = old.code)
    into n;
  if n > 0 then
    raise exception 'Sport "%" is used by % record(s). Deactivate it instead of deleting.',
      old.name, n using errcode = 'restrict_violation';
  end if;
  return old;
end $$;
drop trigger if exists sports_delete_guard on sports;
create trigger sports_delete_guard before delete on sports
  for each row execute function guard_sport_delete();

-- A coach with payout history must not vanish from under the ledger.
create or replace function guard_coach_delete() returns trigger
  language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from payouts where coach_id = old.id;
  if n > 0 then
    raise exception 'Coach "%" has % payout line(s). Deactivate instead of deleting.',
      old.name, n using errcode = 'restrict_violation';
  end if;
  return old;
end $$;
drop trigger if exists coaches_delete_guard on coaches;
create trigger coaches_delete_guard before delete on coaches
  for each row execute function guard_coach_delete();

-- ---------- deactivating must not silently strand students ----------
-- Turning a batch off is allowed (a timing genuinely ends), but the
-- students on it are moved to "needs a batch" rather than left pointing
-- at a class that no longer runs.
create or replace function on_batch_deactivated() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active then
    update enrollments
       set batch_id = null,
           notes = coalesce(notes || ' · ', '') || 'batch "' || old.name || '" was closed',
           updated_at = now()
     where batch_id = old.id and status = 'active';
  end if;
  return new;
end $$;
drop trigger if exists batches_deactivate on batches;
create trigger batches_deactivate after update of active on batches
  for each row execute function on_batch_deactivated();

-- ---------- keep updated_at honest ----------
create or replace function touch_updated_at() returns trigger
  language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['members','enrollments','payouts','reminder_events'] loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I
                    for each row execute function touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- ============================================================
-- B. COLLISION-SAFE CODES
--    The app never invents a code again; it asks the database.
-- ============================================================
create or replace function slugify(p text) returns text
  language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g'))
$$;

-- Returns a unique code for a table, appending -2, -3 … on collision.
create or replace function next_code(p_tenant text, p_table text, p_base text)
  returns text
  language plpgsql stable security definer set search_path = public as $$
declare
  base text := nullif(slugify(p_base), '');
  cand text;
  n    int := 1;
  hit  int;
begin
  if base is null then base := 'item'; end if;
  base := left(base, 40);
  loop
    cand := case when n = 1 then base else base || '-' || n end;
    execute format('select count(*) from %I where tenant_id = $1 and code = $2', p_table)
      into hit using p_tenant, cand;
    exit when hit = 0;
    n := n + 1;
    if n > 200 then
      raise exception 'could not generate a unique code for "%"', p_base;
    end if;
  end loop;
  return cand;
end $$;

-- One RPC per thing the manager can add, so both clients (web + Android)
-- go through identical validation instead of each rolling its own.
create or replace function add_sport(p_tenant text, p_name text, p_icon text default null)
  returns sports
  language plpgsql security definer set search_path = public as $$
declare r sports;
begin
  perform assert_staff_or_service(p_tenant);
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the sport a name.'; end if;
  if exists (select 1 from sports where tenant_id = p_tenant and lower(name) = lower(trim(p_name))) then
    raise exception 'A sport called "%" already exists.', trim(p_name);
  end if;
  insert into sports (tenant_id, code, name, icon, sort)
  values (p_tenant, next_code(p_tenant, 'sports', p_name), trim(p_name), nullif(p_icon, ''),
          coalesce((select max(sort) + 1 from sports where tenant_id = p_tenant), 1))
  returning * into r;
  return r;
end $$;

create or replace function add_centre(
  p_tenant text, p_name text, p_short text default null,
  p_address text default null, p_contact text default null)
  returns centres
  language plpgsql security definer set search_path = public as $$
declare r centres;
begin
  perform assert_staff_or_service(p_tenant);
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the centre a name.'; end if;
  if exists (select 1 from centres where tenant_id = p_tenant and lower(name) = lower(trim(p_name))) then
    raise exception 'A centre called "%" already exists.', trim(p_name);
  end if;
  insert into centres (tenant_id, code, name, short_name, address, contact, sort)
  values (p_tenant, next_code(p_tenant, 'centres', p_name), trim(p_name),
          coalesce(nullif(trim(p_short), ''), trim(p_name)),
          nullif(p_address, ''), nullif(p_contact, ''),
          coalesce((select max(sort) + 1 from centres where tenant_id = p_tenant), 1))
  returning * into r;
  return r;
end $$;

create or replace function add_batch(
  p_tenant text, p_centre bigint, p_name text,
  p_days int[], p_start time, p_end time,
  p_sport text default null, p_coach bigint default null, p_capacity int default null)
  returns batches
  language plpgsql security definer set search_path = public as $$
declare r batches;
begin
  perform assert_staff_or_service(p_tenant);
  if not exists (select 1 from centres where id = p_centre and tenant_id = p_tenant) then
    raise exception 'That centre does not belong to this academy.';
  end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the batch a name.'; end if;
  if p_days is null or array_length(p_days, 1) is null then
    raise exception 'Pick at least one day.';
  end if;
  if p_end <= p_start then raise exception 'The end time must be after the start time.'; end if;
  if p_sport is not null and not exists (
       select 1 from sports where tenant_id = p_tenant and code = p_sport and active) then
    raise exception 'Unknown sport "%".', p_sport;
  end if;
  if exists (select 1 from batches
              where tenant_id = p_tenant and centre_id = p_centre
                and lower(name) = lower(trim(p_name)) and active) then
    raise exception 'This centre already has a batch called "%".', trim(p_name);
  end if;

  insert into batches (tenant_id, centre_id, code, name, sport, days,
                       start_time, end_time, coach_id, capacity, sort)
  values (p_tenant, p_centre,
          next_code(p_tenant, 'batches',
                    (select code from centres where id = p_centre) || '-' || p_name),
          trim(p_name), p_sport, p_days, p_start, p_end, p_coach, p_capacity,
          coalesce((select max(sort) + 1 from batches
                     where tenant_id = p_tenant and centre_id = p_centre), 1))
  returning * into r;
  return r;
end $$;

-- Changing a batch's timing is the single most common edit, so it gets
-- its own guarded path rather than a raw PATCH from the client.
create or replace function update_batch_timing(
  p_tenant text, p_batch bigint, p_days int[], p_start time, p_end time)
  returns batches
  language plpgsql security definer set search_path = public as $$
declare r batches; old_row batches;
begin
  perform assert_staff_or_service(p_tenant);
  select * into old_row from batches where id = p_batch and tenant_id = p_tenant;
  if not found then raise exception 'Batch not found.'; end if;
  if p_end <= p_start then raise exception 'The end time must be after the start time.'; end if;
  if p_days is null or array_length(p_days, 1) is null then
    raise exception 'Pick at least one day.';
  end if;

  update batches set days = p_days, start_time = p_start, end_time = p_end
   where id = p_batch returning * into r;

  -- Parents plan their week around this, so a timing change is worth a
  -- first-class audit entry rather than a generic row update.
  insert into audit_log (tenant_id, entity, entity_id, action, before, after, note)
  values (p_tenant, 'batch', p_batch, 'timing_changed',
          jsonb_build_object('days', old_row.days, 'start', old_row.start_time, 'end', old_row.end_time),
          jsonb_build_object('days', r.days, 'start', r.start_time, 'end', r.end_time),
          'Batch timing changed — tell the parents in this batch');
  return r;
end $$;

-- ============================================================
-- C. OBSERVABILITY
-- ============================================================

-- Append-only. Answers "who changed the fee, and when" months later.
create table if not exists audit_log (
  id         bigint generated always as identity primary key,
  tenant_id  text not null references tenants(id) on delete cascade,
  actor      text,                       -- auth email, or 'system'
  entity     text not null,              -- fee_rule | payout_rule | batch | centre | sport | coach | enrollment
  entity_id  bigint,
  action     text not null,              -- created | updated | deleted | timing_changed | deactivated
  before     jsonb,
  after      jsonb,
  note       text,
  at         timestamptz not null default now()
);
create index if not exists audit_log_tenant_at_idx on audit_log (tenant_id, at desc);
create index if not exists audit_log_entity_idx on audit_log (tenant_id, entity, entity_id);

create or replace function current_actor() returns text
  language sql stable as
$$ select coalesce(nullif(auth.jwt()->>'email', ''), 'system') $$;

-- One trigger body for every config table. Storing the whole row as
-- before/after keeps this generic — no column list to forget to update
-- when a table grows.
create or replace function audit_config_change() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  ent text := tg_argv[0];
  t   text;
  bid bigint;
begin
  if tg_op = 'DELETE' then
    t := old.tenant_id; bid := old.id;
    insert into audit_log (tenant_id, actor, entity, entity_id, action, before)
    values (t, current_actor(), ent, bid, 'deleted', to_jsonb(old));
    return old;
  elsif tg_op = 'UPDATE' then
    t := new.tenant_id; bid := new.id;
    -- ignore no-op writes so the log stays readable
    if to_jsonb(old) = to_jsonb(new) then return new; end if;
    insert into audit_log (tenant_id, actor, entity, entity_id, action, before, after)
    values (t, current_actor(), ent, bid,
            case when (to_jsonb(old)->>'active')::boolean is true
                  and (to_jsonb(new)->>'active')::boolean is false
                 then 'deactivated' else 'updated' end,
            to_jsonb(old), to_jsonb(new));
    return new;
  else
    t := new.tenant_id; bid := new.id;
    insert into audit_log (tenant_id, actor, entity, entity_id, action, after)
    values (t, current_actor(), ent, bid, 'created', to_jsonb(new));
    return new;
  end if;
end $$;

do $$
declare r record;
begin
  for r in select * from (values
      ('sports','sport'), ('centres','centre'), ('batches','batch'),
      ('coaches','coach'), ('fee_rules','fee_rule'), ('payout_rules','payout_rule'),
      ('enrollments','enrollment')
    ) as v(tbl, ent)
  loop
    execute format('drop trigger if exists %I on %I', r.tbl || '_audit', r.tbl);
    execute format('create trigger %I after insert or update or delete on %I
                    for each row execute function audit_config_change(%L)',
                   r.tbl || '_audit', r.tbl, r.ent);
  end loop;
end $$;

-- ---------- events: let the app report its own failures ----------
alter table events add column if not exists level text not null default 'info';
create index if not exists events_tenant_name_at_idx on events (tenant_id, name, at desc);
-- The Academy Manager console counts name='client_error'; make sure the
-- public apps are allowed to write one even when nobody is signed in.
drop policy if exists events_public_w on events;
create policy events_public_w on events for insert to anon with check (true);
grant insert on events to anon;

-- ---------- the health RPC the operator console reads ----------
-- Everything the Academy Manager needs to answer "is Raj Sports healthy?"
-- in ONE round trip: is the app being used, are reminders getting through,
-- is money moving, and is anything mis-configured.
create or replace function tenant_health(p_tenant text)
  returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare
  out_j jsonb;
  d30 date := ist_today() - 30;
  d7  date := ist_today() - 7;
begin
  if auth_role() <> 'operator'
     and not (auth_role() = 'staff' and auth_tenant() = p_tenant)
     and not is_service() then
    raise exception 'not authorised';
  end if;

  select jsonb_build_object(
    'tenant_id', p_tenant,
    'as_of', now(),

    'roster', jsonb_build_object(
      'active_students',   (select count(distinct member_id) from enrollments
                             where tenant_id = p_tenant and status = 'active'),
      'active_enrollments',(select count(*) from enrollments
                             where tenant_id = p_tenant and status = 'active'),
      'centres',           (select count(*) from centres where tenant_id = p_tenant and active),
      'batches',           (select count(*) from batches where tenant_id = p_tenant and active),
      'sports',            (select count(*) from sports  where tenant_id = p_tenant and active),
      'coaches',           (select count(*) from coaches where tenant_id = p_tenant and active)),

    'money', jsonb_build_object(
      'collected_30d', (select coalesce(sum(amount), 0) from payments
                         where tenant_id = p_tenant and status = 'paid' and on_date >= d30),
      'collected_mtd', (select coalesce(sum(amount), 0) from payments
                         where tenant_id = p_tenant and status = 'paid'
                           and on_date >= date_trunc('month', ist_today())::date),
      'unverified',    (select count(*) from payments
                         where tenant_id = p_tenant and status = 'pending_verification'),
      'overdue_students', (select count(*) from enrollments
                            where tenant_id = p_tenant and status = 'active'
                              and renewal_on < ist_today()),
      'payouts_pending',  (select coalesce(sum(amount), 0) from payouts
                            where tenant_id = p_tenant and status = 'pending')),

    -- The reminder engine is the client's headline concern, so its health
    -- is reported in the most literal terms available: what was attempted,
    -- what Meta confirmed, and what is stuck.
    'reminders', jsonb_build_object(
      'sent_7d',      (select count(*) from reminder_events
                        where tenant_id = p_tenant and ist_date >= d7),
      'sent_30d',     (select count(*) from reminder_events
                        where tenant_id = p_tenant and ist_date >= d30),
      'delivered_30d',(select count(*) from reminder_events
                        where tenant_id = p_tenant and ist_date >= d30
                          and status in ('delivered','read','resolved')),
      'failed_30d',   (select count(*) from reminder_events
                        where tenant_id = p_tenant and ist_date >= d30 and status = 'failed'),
      'retrying',     (select count(*) from reminder_events
                        where tenant_id = p_tenant and status = 'retry_scheduled'),
      'manual_share_30d', (select case when count(*) = 0 then null
                             else round(100.0 * count(*) filter (where sent_by = 'manual') / count(*)) end
                            from reminder_events where tenant_id = p_tenant and ist_date >= d30),
      'blocked_now',  (select coalesce(jsonb_object_agg(reason, n), '{}'::jsonb) from (
                        select blocked_reason as reason, count(*) n
                          from reminder_queue(p_tenant)
                         where blocked_reason is not null group by 1) b),
      'due_today',    (select count(*) from reminder_queue(p_tenant) where blocked_reason is null)),

    'usage', jsonb_build_object(
      'events_30d',     (select count(*) from events where tenant_id = p_tenant and at >= d30),
      'active_days_30d',(select count(distinct at::date) from events
                          where tenant_id = p_tenant and at >= d30),
      'last_event_at',  (select max(at) from events where tenant_id = p_tenant),
      'errors_30d',     (select count(*) from events
                          where tenant_id = p_tenant and name = 'client_error' and at >= d30),
      'config_changes_30d', (select count(*) from audit_log
                              where tenant_id = p_tenant and at >= d30)),

    -- Misconfiguration is the quiet failure mode: reminders that never
    -- fire because nobody set a price. Surface it as a first-class signal.
    'config', jsonb_build_object(
      'fee_rules',        (select count(*) from fee_rules where tenant_id = p_tenant and active),
      'has_default_fee',  (select exists (select 1 from fee_rules
                            where tenant_id = p_tenant and active and centre_id is null
                              and sport is null and batch_id is null and member_id is null)),
      'students_without_fee', (select count(*) from reminder_queue(p_tenant)
                                where blocked_reason = 'fee_not_set'),
      'students_without_phone', (select count(*) from reminder_queue(p_tenant)
                                  where blocked_reason = 'missing_phone'),
      'payout_rules',     (select count(*) from payout_rules where tenant_id = p_tenant and active),
      'whatsapp_mode',    (select config->'whatsapp'->>'mode' from tenants where id = p_tenant),
      'whatsapp_enabled', (select (config->'whatsapp'->>'enabled')::boolean from tenants where id = p_tenant),
      'booking_module',   (select (config->'modules'->>'booking')::boolean from tenants where id = p_tenant))
  ) into out_j;

  return out_j;
end $$;

-- ---------- RLS for the new table ----------
alter table audit_log enable row level security;
drop policy if exists audit_log_r on audit_log;
create policy audit_log_r on audit_log for select
  using (auth_role() = 'operator' or (auth_role() = 'staff' and tenant_id = auth_tenant()));
-- No insert/update/delete policy: only the SECURITY DEFINER triggers write
-- here, which is what makes the log trustworthy.

grant execute on function tenant_health(text)                       to authenticated;
grant execute on function add_sport(text,text,text)                 to authenticated;
grant execute on function add_centre(text,text,text,text,text)      to authenticated;
grant execute on function add_batch(text,bigint,text,int[],time,time,text,bigint,int) to authenticated;
grant execute on function update_batch_timing(text,bigint,int[],time,time) to authenticated;
grant execute on function next_code(text,text,text)                 to authenticated;
