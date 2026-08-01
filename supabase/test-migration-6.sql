-- ============================================================
-- This harness writes to SHARED tables. It refuses to run on
-- production, where a failed rollback is a data incident for
-- every academy — not just this one. (0040)
-- ============================================================
select assert_test_environment();

-- Attendance behavior tests. The runner wraps this file and migration 6
-- in one transaction, so every touched live row is restored on rollback.
do $$
declare
  bid bigint;
  sid bigint;
  roster_count int;
  record_count int;
  rows jsonb;
  result jsonb;
  dash jsonb;
  hist record;
  first_enrollment bigint;
begin
  select id into bid
    from batches where tenant_id='raj' and code='btv-b1';
  if bid is null then raise exception 'TEST FAIL: btv-b1 missing'; end if;

  delete from sessions
   where tenant_id='raj' and batch_id=bid and on_date=ist_today();

  select count(*) into roster_count
    from attendance_roster('raj', bid, ist_today());
  if roster_count < 2 then
    raise exception 'TEST FAIL: attendance roster needs at least 2 students, got %', roster_count;
  end if;

  select jsonb_agg(jsonb_build_object(
           'enrollment_id', enrollment_id,
           'status', case row_number
                       when 1 then 'absent'
                       else 'present'
                     end,
           'reason', case when row_number=1 then 'Family informed coach' else null end
         ) order by member_name)
    into rows
  from (
    select r.*, row_number() over (order by member_name) as row_number
      from attendance_roster('raj', bid, ist_today()) r
  ) marked;

  result := save_attendance_session(
    'raj', bid, ist_today(), 'held', rows, 'RAJTEST register', null
  );
  sid := (result->>'session_id')::bigint;

  if (result->>'absent')::int <> 1 then
    raise exception 'TEST FAIL: held summary wrong: %', result;
  end if;

  select count(*) into record_count
    from attendance_records where session_id=sid;
  if record_count <> roster_count then
    raise exception 'TEST FAIL: expected % records, got %', roster_count, record_count;
  end if;

  if (select count(*) from attendance_roster('raj',bid,ist_today())
        where attendance_status is not null) <> roster_count then
    raise exception 'TEST FAIL: saved statuses missing from roster';
  end if;

  select * into hist
    from attendance_history('raj',ist_today(),ist_today(),null,bid,null,null);
  if hist.session_status <> 'held' or hist.total <> roster_count
     or hist.absent <> 1 then
    raise exception 'TEST FAIL: history summary wrong';
  end if;

  dash := attendance_dashboard('raj',ist_today(),ist_today(),null,bid,null,null);
  if (dash->'summary'->>'sessions')::int <> 1
     or jsonb_array_length(dash->'students') <> roster_count then
    raise exception 'TEST FAIL: dashboard aggregation wrong: %', dash;
  end if;

  -- A partial register is rejected.
  begin
    perform save_attendance_session(
      'raj', bid, ist_today(), 'held',
      jsonb_build_array(rows->0), 'partial', null
    );
    raise exception 'TEST FAIL: partial register was accepted';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
  end;

  -- Editing is an upsert, never a second record for the same student.
  first_enrollment := (rows->0->>'enrollment_id')::bigint;
  rows := (
    select jsonb_agg(
      case when (x->>'enrollment_id')::bigint=first_enrollment
           then x || '{"status":"present","reason":null}'::jsonb
           else x end
    )
    from jsonb_array_elements(rows) x
  );
  perform save_attendance_session(
    'raj', bid, ist_today(), 'held', rows, 'corrected', null
  );
  if (select count(*) from attendance_records where session_id=sid) <> roster_count then
    raise exception 'TEST FAIL: correction duplicated attendance rows';
  end if;
  if (select status from attendance_records
       where session_id=sid and enrollment_id=first_enrollment) <> 'present' then
    raise exception 'TEST FAIL: correction did not update the record';
  end if;

  -- A cancelled class has no attendance denominator or child records.
  result := save_attendance_session(
    'raj', bid, ist_today(), 'cancelled', '[]'::jsonb,
    'Rain', 'Ground unavailable'
  );
  if result->>'status' <> 'cancelled'
     or (select count(*) from attendance_records where session_id=sid) <> 0 then
    raise exception 'TEST FAIL: cancellation did not clear attendance';
  end if;

  -- A future register is impossible.
  begin
    perform save_attendance_session(
      'raj', bid, ist_today()+1, 'held', rows, null, null
    );
    raise exception 'TEST FAIL: future attendance was accepted';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
  end;

  raise notice 'ATTENDANCE TESTS PASSED';
end $$;

select 'ATTENDANCE TESTS PASSED' as result,
       (select count(*) from batches where tenant_id='raj') as batches,
       (select count(*) from members where tenant_id='raj') as students;
