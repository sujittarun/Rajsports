-- Instant attendance behavior tests. The runner wraps this in a
-- transaction, so live data is restored on rollback.
do $$
declare
  bid bigint;
  first_enrollment bigint;
  second_enrollment bigint;
  result jsonb;
begin
  select id into bid
    from batches where tenant_id='raj' and code='btv-b1';

  delete from sessions
   where tenant_id='raj' and batch_id=bid and on_date=ist_today();

  select enrollment_id into first_enrollment
    from attendance_roster('raj',bid,ist_today())
   order by enrollment_id limit 1;
  select enrollment_id into second_enrollment
    from attendance_roster('raj',bid,ist_today())
   order by enrollment_id offset 1 limit 1;

  result := mark_attendance(
    'raj',bid,ist_today(),first_enrollment,'present',null
  );
  if (result->>'present')::int <> 1 or (result->>'marked')::int <> 1 then
    raise exception 'TEST FAIL: present tap was not saved: %', result;
  end if;

  result := mark_attendance(
    'raj',bid,ist_today(),first_enrollment,'absent','Family informed coach'
  );
  if (result->>'present')::int <> 0 or (result->>'absent')::int <> 1 then
    raise exception 'TEST FAIL: changing a tap did not update: %', result;
  end if;
  if (select count(*) from attendance_records
       where enrollment_id=first_enrollment
         and session_id=(result->>'session_id')::bigint) <> 1 then
    raise exception 'TEST FAIL: changing a tap duplicated the row';
  end if;

  result := mark_attendance(
    'raj',bid,ist_today(),second_enrollment,'present',null
  );
  if (result->>'marked')::int <> 2 then
    raise exception 'TEST FAIL: second tap was not saved: %', result;
  end if;

  result := mark_attendance(
    'raj',bid,ist_today(),first_enrollment,null,null
  );
  if (result->>'marked')::int <> 1 or (result->>'present')::int <> 1 then
    raise exception 'TEST FAIL: unclick did not clear the mark: %', result;
  end if;

  result := mark_attendance(
    'raj',bid,ist_today(),second_enrollment,null,null
  );
  if result->>'session_id' is not null then
    raise exception 'TEST FAIL: empty auto-created session was not removed: %', result;
  end if;

  begin
    perform mark_attendance(
      'raj',bid,ist_today()+1,first_enrollment,'present',null
    );
    raise exception 'TEST FAIL: future tap was accepted';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
  end;

  raise notice 'INSTANT ATTENDANCE TESTS PASSED';
end $$;

select 'INSTANT ATTENDANCE TESTS PASSED' as result;
