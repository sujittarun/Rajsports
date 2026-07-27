-- ============================================================
-- RAJ SPORTS: instant attendance marking
--
-- One small RPC owns each Present / Absent tap. It is safe for the
-- web and Android clients to call independently and supports clearing
-- a mistaken tap by passing a null status.
-- ============================================================

create or replace function mark_attendance(
  p_tenant text,
  p_batch bigint,
  p_date date,
  p_enrollment bigint,
  p_status text default null,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b batches;
  sid bigint;
  actor text := coalesce(nullif(auth.jwt()->>'email',''), 'system');
  expected_count int;
  marked_count int;
  present_count int;
  absent_count int;
begin
  perform assert_staff_or_service(p_tenant);
  if p_date is null then raise exception 'session date is required'; end if;
  if p_date > ist_today() then
    raise exception 'Attendance cannot be taken for a future date';
  end if;
  if p_status is not null and p_status not in ('present','absent') then
    raise exception 'invalid attendance status';
  end if;

  select * into b
    from batches
   where id=p_batch and tenant_id=p_tenant;
  if not found then raise exception 'batch not found'; end if;

  if not exists (
    select 1
      from enrollments e
      join members m on m.id=e.member_id
     where e.id=p_enrollment
       and e.tenant_id=p_tenant
       and e.batch_id=p_batch
       and e.joined_on <= p_date
       and (
         (e.status='active' and m.status <> 'discontinued')
         or exists (
           select 1
             from attendance_records ar
             join sessions s on s.id=ar.session_id
            where ar.enrollment_id=e.id
              and s.tenant_id=p_tenant
              and s.batch_id=p_batch
              and s.on_date=p_date
         )
       )
  ) then
    raise exception 'student is not in this batch';
  end if;

  select id into sid
    from sessions
   where tenant_id=p_tenant and batch_id=p_batch and on_date=p_date;

  if p_status is null then
    if sid is not null then
      delete from attendance_records
       where tenant_id=p_tenant
         and session_id=sid
         and enrollment_id=p_enrollment;

      update sessions set
        marked_at=now(), marked_by=actor, updated_at=now()
       where id=sid;

      if not exists (select 1 from attendance_records where session_id=sid)
         and (select note is null from sessions where id=sid) then
        delete from sessions where id=sid;
        sid := null;
      end if;
    end if;
  else
    insert into sessions (
      tenant_id, batch_id, on_date, coach_id, status,
      scheduled_start, scheduled_end, marked_at, marked_by,
      cancel_reason, updated_at
    ) values (
      p_tenant, b.id, p_date, b.coach_id, 'held',
      b.start_time, b.end_time, now(), actor, null, now()
    )
    on conflict (tenant_id, batch_id, on_date) do update set
      status='held',
      coach_id=excluded.coach_id,
      scheduled_start=coalesce(sessions.scheduled_start, excluded.scheduled_start),
      scheduled_end=coalesce(sessions.scheduled_end, excluded.scheduled_end),
      marked_at=excluded.marked_at,
      marked_by=excluded.marked_by,
      cancel_reason=null,
      updated_at=now()
    returning id into sid;

    insert into attendance_records (
      tenant_id, session_id, enrollment_id, status,
      reason, marked_at, marked_by, updated_at
    ) values (
      p_tenant, sid, p_enrollment, p_status,
      case when p_status='absent' then nullif(trim(p_reason),'') else null end,
      now(), actor, now()
    )
    on conflict (session_id, enrollment_id) do update set
      status=excluded.status,
      reason=excluded.reason,
      marked_at=excluded.marked_at,
      marked_by=excluded.marked_by,
      updated_at=now();
  end if;

  select count(*) into expected_count
  from (
    select e.id
      from enrollments e
      join members m on m.id=e.member_id
     where e.tenant_id=p_tenant
       and e.batch_id=p_batch
       and e.status='active'
       and e.joined_on <= p_date
       and m.status <> 'discontinued'
    union
    select ar.enrollment_id
      from attendance_records ar
      join sessions s on s.id=ar.session_id
     where s.tenant_id=p_tenant
       and s.batch_id=p_batch
       and s.on_date=p_date
  ) roster;

  select
    count(*),
    count(*) filter (where status='present'),
    count(*) filter (where status='absent')
    into marked_count, present_count, absent_count
  from attendance_records
  where tenant_id=p_tenant and session_id=sid;

  return jsonb_build_object(
    'session_id', sid,
    'status', p_status,
    'saved_at', now(),
    'marked', coalesce(marked_count,0),
    'total', expected_count,
    'present', coalesce(present_count,0),
    'absent', coalesce(absent_count,0)
  );
end $$;

grant execute on function mark_attendance(text,bigint,date,bigint,text,text)
  to authenticated;
