-- ============================================================
-- RAJ SPORTS: session attendance and attendance reporting
--
-- Generic tables and RPCs. Nothing here is Raj-specific except the
-- caller-supplied tenant id, so the next coaching tenant can reuse it.
-- Attendance belongs to an enrollment because one student can attend
-- two sports or batches independently.
-- ============================================================

-- Preserve what was scheduled when the register was taken. Batch timing
-- may change later, but a historical register must not silently change.
alter table sessions add column if not exists scheduled_start time;
alter table sessions add column if not exists scheduled_end time;
alter table sessions add column if not exists marked_at timestamptz;
alter table sessions add column if not exists marked_by text;
alter table sessions add column if not exists cancel_reason text;
alter table sessions add column if not exists updated_at timestamptz not null default now();

alter table sessions drop constraint if exists sessions_status_check;
alter table sessions add constraint sessions_status_check
  check (status in ('held','cancelled'));

create table if not exists attendance_records (
  id             bigint generated always as identity primary key,
  tenant_id      text not null references tenants(id) on delete cascade,
  session_id     bigint not null references sessions(id) on delete cascade,
  enrollment_id  bigint not null references enrollments(id),
  status         text not null
                   check (status in ('present','absent')),
  reason         text,
  note           text,
  marked_at      timestamptz not null default now(),
  marked_by      text,
  updated_at     timestamptz not null default now()
);

create unique index if not exists attendance_session_enrollment_uniq
  on attendance_records (session_id, enrollment_id);
create index if not exists attendance_tenant_session_idx
  on attendance_records (tenant_id, session_id);
create index if not exists attendance_enrollment_date_idx
  on attendance_records (enrollment_id, marked_at desc);

alter table attendance_records enable row level security;

drop policy if exists attendance_records_staff_r on attendance_records;
create policy attendance_records_staff_r on attendance_records for select
  using (
    (select auth_role()) = 'operator'
    or ((select auth_role()) = 'staff' and tenant_id = (select auth_tenant()))
  );

drop policy if exists attendance_records_staff_w on attendance_records;
create policy attendance_records_staff_w on attendance_records for insert
  with check (
    (select auth_role()) = 'operator'
    or ((select auth_role()) = 'staff' and tenant_id = (select auth_tenant()))
  );

drop policy if exists attendance_records_staff_u on attendance_records;
create policy attendance_records_staff_u on attendance_records for update
  using (
    (select auth_role()) = 'operator'
    or ((select auth_role()) = 'staff' and tenant_id = (select auth_tenant()))
  );

drop policy if exists attendance_records_staff_d on attendance_records;
create policy attendance_records_staff_d on attendance_records for delete
  using (
    (select auth_role()) = 'operator'
    or ((select auth_role()) = 'staff' and tenant_id = (select auth_tenant()))
  );

-- Existing sessions policies predate operator writes. Attendance is an
-- operational feature, so both tenant staff and an operator can correct it.
drop policy if exists sessions_staff_d on sessions;
create policy sessions_staff_d on sessions for delete
  using (
    (select auth_role()) = 'operator'
    or ((select auth_role()) = 'staff' and tenant_id = (select auth_tenant()))
  );

-- The roster includes today's active enrollments plus any enrollment that
-- already has a record in the historical session. That keeps old registers
-- editable even after a student later pauses or leaves.
create or replace function attendance_roster(
  p_tenant text,
  p_batch bigint,
  p_date date default null
) returns table (
  session_id bigint,
  session_status text,
  session_note text,
  session_marked_at timestamptz,
  session_marked_by text,
  enrollment_id bigint,
  member_id bigint,
  member_name text,
  parent_name text,
  phone text,
  sport text,
  attendance_id bigint,
  attendance_status text,
  reason text,
  attendance_note text
)
language plpgsql stable security definer set search_path = public as $$
declare
  d date := coalesce(p_date, ist_today());
begin
  perform assert_staff_or_service(p_tenant);
  if not exists (
    select 1 from batches b where b.id=p_batch and b.tenant_id=p_tenant
  ) then
    raise exception 'batch not found';
  end if;

  return query
  with target_session as (
    select s.*
      from sessions s
     where s.tenant_id=p_tenant and s.batch_id=p_batch and s.on_date=d
  ),
  roster_ids as (
    select e.id
      from enrollments e
      join members m on m.id=e.member_id
     where e.tenant_id=p_tenant
       and e.batch_id=p_batch
       and e.status='active'
       and m.status <> 'discontinued'
       and e.joined_on <= d
    union
    select ar.enrollment_id
      from attendance_records ar
      join target_session s on s.id=ar.session_id
  )
  select
    s.id, s.status, s.note, s.marked_at, s.marked_by,
    e.id, m.id, m.name, m.parent_name,
    coalesce(nullif(m.parent_phone,''), nullif(m.phone,'')),
    e.sport,
    ar.id, ar.status, ar.reason, ar.note
  from roster_ids r
  join enrollments e on e.id=r.id and e.tenant_id=p_tenant
  join members m on m.id=e.member_id
  left join target_session s on true
  left join attendance_records ar
    on ar.session_id=s.id and ar.enrollment_id=e.id
  order by m.name, e.id;
end $$;

-- A single transaction writes the session and its entire register.
-- Partial registers are refused because an unmarked student must never
-- quietly disappear from the attendance denominator.
create or replace function save_attendance_session(
  p_tenant text,
  p_batch bigint,
  p_date date,
  p_status text,
  p_rows jsonb default '[]'::jsonb,
  p_note text default null,
  p_cancel_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b batches;
  sid bigint;
  expected_count int;
  provided_count int;
  distinct_count int;
  bad_count int;
  actor text := coalesce(nullif(auth.jwt()->>'email',''), 'system');
  result jsonb;
begin
  perform assert_staff_or_service(p_tenant);
  if p_date is null then raise exception 'session date is required'; end if;
  if p_date > ist_today() then raise exception 'Attendance cannot be taken for a future date'; end if;
  if p_status not in ('held','cancelled') then raise exception 'invalid session status'; end if;

  select * into b from batches where id=p_batch and tenant_id=p_tenant;
  if not found then raise exception 'batch not found'; end if;

  insert into sessions (
    tenant_id, batch_id, on_date, coach_id, status, note,
    scheduled_start, scheduled_end, marked_at, marked_by,
    cancel_reason, updated_at
  ) values (
    p_tenant, b.id, p_date, b.coach_id, p_status, nullif(trim(p_note),''),
    b.start_time, b.end_time, now(), actor,
    case when p_status='cancelled' then nullif(trim(p_cancel_reason),'') else null end,
    now()
  )
  on conflict (tenant_id, batch_id, on_date) do update set
    coach_id=excluded.coach_id,
    status=excluded.status,
    note=excluded.note,
    scheduled_start=coalesce(sessions.scheduled_start, excluded.scheduled_start),
    scheduled_end=coalesce(sessions.scheduled_end, excluded.scheduled_end),
    marked_at=excluded.marked_at,
    marked_by=excluded.marked_by,
    cancel_reason=excluded.cancel_reason,
    updated_at=now()
  returning id into sid;

  if p_status='cancelled' then
    delete from attendance_records where tenant_id=p_tenant and session_id=sid;
    return jsonb_build_object(
      'session_id', sid, 'status', 'cancelled', 'saved_at', now(),
      'present', 0, 'absent', 0
    );
  end if;

  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception 'attendance rows must be an array';
  end if;

  select count(*), count(distinct (x->>'enrollment_id')::bigint)
    into provided_count, distinct_count
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x;
  if provided_count <> distinct_count then
    raise exception 'the same student appears more than once';
  end if;

  select count(*) into expected_count
  from (
    select e.id
      from enrollments e
      join members m on m.id=e.member_id
     where e.tenant_id=p_tenant and e.batch_id=p_batch
       and e.status='active' and m.status <> 'discontinued'
       and e.joined_on <= p_date
    union
    select ar.enrollment_id
      from attendance_records ar
     where ar.tenant_id=p_tenant and ar.session_id=sid
  ) expected;

  if expected_count = 0 then raise exception 'This batch has no students to mark'; end if;
  if provided_count <> expected_count then
    raise exception 'Mark every student before saving (% of % marked)',
      provided_count, expected_count;
  end if;

  select count(*) into bad_count
    from jsonb_array_elements(p_rows) x
    left join enrollments e
      on e.id=(x->>'enrollment_id')::bigint
     and e.tenant_id=p_tenant and e.batch_id=p_batch
   where e.id is null
      or coalesce(x->>'status','') not in ('present','absent');
  if bad_count > 0 then raise exception 'attendance contains an invalid student or status'; end if;

  delete from attendance_records ar
   where ar.tenant_id=p_tenant and ar.session_id=sid
     and not exists (
       select 1 from jsonb_array_elements(p_rows) x
        where (x->>'enrollment_id')::bigint=ar.enrollment_id
     );

  insert into attendance_records (
    tenant_id, session_id, enrollment_id, status,
    reason, note, marked_at, marked_by, updated_at
  )
  select
    p_tenant, sid, (x->>'enrollment_id')::bigint, x->>'status',
    nullif(trim(x->>'reason'),''),
    nullif(trim(x->>'note'),''),
    now(), actor, now()
  from jsonb_array_elements(p_rows) x
  on conflict (session_id, enrollment_id) do update set
    status=excluded.status,
    reason=excluded.reason,
    note=excluded.note,
    marked_at=excluded.marked_at,
    marked_by=excluded.marked_by,
    updated_at=now();

  select jsonb_build_object(
    'session_id', sid,
    'status', 'held',
    'saved_at', now(),
    'present', count(*) filter (where status='present'),
    'absent', count(*) filter (where status='absent')
  ) into result
  from attendance_records
  where tenant_id=p_tenant and session_id=sid;

  return result;
end $$;

create or replace function attendance_history(
  p_tenant text,
  p_from date,
  p_to date,
  p_centre bigint default null,
  p_batch bigint default null,
  p_member bigint default null,
  p_sport text default null
) returns table (
  session_id bigint,
  on_date date,
  batch_id bigint,
  batch_name text,
  centre_id bigint,
  centre_name text,
  session_status text,
  session_note text,
  cancel_reason text,
  marked_at timestamptz,
  marked_by text,
  total int,
  present int,
  absent int,
  attendance_rate numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform assert_staff_or_service(p_tenant);
  return query
  select
    s.id, s.on_date, b.id, b.name, c.id, coalesce(c.short_name,c.name),
    s.status, s.note, s.cancel_reason, s.marked_at, s.marked_by,
    count(ar.id)::int,
    count(ar.id) filter (where ar.status='present')::int,
    count(ar.id) filter (where ar.status='absent')::int,
    round(
      100.0 * count(ar.id) filter (where ar.status='present') /
      nullif(count(ar.id), 0),
      1
    )
  from sessions s
  join batches b on b.id=s.batch_id
  join centres c on c.id=b.centre_id
  left join attendance_records ar
    on ar.session_id=s.id
  left join enrollments e on e.id=ar.enrollment_id
  where s.tenant_id=p_tenant
    and s.on_date between p_from and p_to
    and (p_centre is null or b.centre_id=p_centre)
    and (p_batch is null or b.id=p_batch)
    and (p_member is null or e.member_id=p_member)
    and (p_sport is null or e.sport=p_sport)
  group by s.id, b.id, c.id
  order by s.on_date desc, b.start_time, b.sort, b.id;
end $$;

create or replace function attendance_absence_streak(p_statuses text[])
returns int language plpgsql immutable as $$
declare
  s text;
  n int := 0;
begin
  foreach s in array coalesce(p_statuses, '{}'::text[]) loop
    if s='absent' then n := n + 1; else exit; end if;
  end loop;
  return n;
end $$;

create or replace function attendance_dashboard(
  p_tenant text,
  p_from date,
  p_to date,
  p_centre bigint default null,
  p_batch bigint default null,
  p_member bigint default null,
  p_sport text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  result jsonb;
begin
  perform assert_staff_or_service(p_tenant);

  with scoped as (
    select
      ar.status, s.on_date,
      e.id as enrollment_id, e.member_id, m.name as member_name,
      b.id as batch_id, b.name as batch_name,
      c.id as centre_id, coalesce(c.short_name,c.name) as centre_name
    from attendance_records ar
    join sessions s on s.id=ar.session_id and s.status='held'
    join enrollments e on e.id=ar.enrollment_id
    join members m on m.id=e.member_id
    join batches b on b.id=s.batch_id
    join centres c on c.id=b.centre_id
    where ar.tenant_id=p_tenant
      and s.on_date between p_from and p_to
      and (p_centre is null or b.centre_id=p_centre)
      and (p_batch is null or b.id=p_batch)
      and (p_member is null or e.member_id=p_member)
      and (p_sport is null or e.sport=p_sport)
  ),
  summary as (
    select
      count(distinct (batch_id,on_date))::int as sessions,
      count(distinct member_id)::int as students,
      count(*) filter (where status='present')::int as present,
      count(*) filter (where status='absent')::int as absent,
      round(
        100.0 * count(*) filter (where status='present') /
        nullif(count(*), 0),
        1
      ) as rate
    from scoped
  ),
  per_student as (
    select
      enrollment_id, member_id, member_name, batch_id, batch_name,
      centre_id, centre_name,
      count(*)::int as sessions,
      count(*) filter (where status='present')::int as attended,
      count(*) filter (where status='absent')::int as absent,
      round(
        100.0 * count(*) filter (where status='present') /
        nullif(count(*), 0),
        1
      ) as rate,
      attendance_absence_streak(array_agg(status order by on_date desc)) as absence_streak,
      round(
        100.0 * count(*) filter (
          where status='present' and on_date > p_to-14
        ) / nullif(count(*) filter (
          where on_date > p_to-14
        ), 0),
        1
      ) as recent_rate,
      round(
        100.0 * count(*) filter (
          where status='present'
            and on_date between p_to-27 and p_to-14
        ) / nullif(count(*) filter (
          where on_date between p_to-27 and p_to-14
            and on_date between p_to-27 and p_to-14
        ), 0),
        1
      ) as previous_rate,
      max(on_date) as last_session_on
    from scoped
    group by enrollment_id, member_id, member_name, batch_id, batch_name,
             centre_id, centre_name
  ),
  trend as (
    select
      date_trunc('week', on_date)::date as week_start,
      round(
        100.0 * count(*) filter (where status='present') /
        nullif(count(*), 0),
        1
      ) as rate,
      count(*) filter (where status='absent')::int as absent
    from scoped
    group by date_trunc('week', on_date)
    order by week_start
  )
  select jsonb_build_object(
    'summary', coalesce((select to_jsonb(summary) from summary), '{}'::jsonb),
    'students', coalesce((
      select jsonb_agg(to_jsonb(per_student) order by
        absence_streak desc, rate asc nulls last, member_name)
      from per_student
    ), '[]'::jsonb),
    'trend', coalesce((
      select jsonb_agg(to_jsonb(trend) order by week_start) from trend
    ), '[]'::jsonb)
  ) into result;

  return result;
end $$;

grant execute on function attendance_roster(text,bigint,date) to authenticated;
grant execute on function save_attendance_session(text,bigint,date,text,jsonb,text,text) to authenticated;
grant execute on function attendance_history(text,date,date,bigint,bigint,bigint,text) to authenticated;
grant execute on function attendance_dashboard(text,date,date,bigint,bigint,bigint,text) to authenticated;
