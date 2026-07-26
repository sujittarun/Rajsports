-- ============================================================
-- Behaviour tests for migration-raj-3.sql (integrity + observability).
-- Run via scripts/test-migration-3.sh — migration + these tests in one
-- transaction, rolled back at the end.
--
-- Style: each guard is exercised by DOING the bad thing and asserting it
-- is refused. A constraint nobody has tried to violate is a guess.
-- ============================================================
do $$
declare
  c_new bigint; b_new bigint; s_new bigint; m_new bigint; e_new bigint;
  r_batch batches; r_sport sports; r_centre centres;
  c_dps bigint; n int; ok boolean; h jsonb; txt text;
begin
  select id into c_dps from centres where tenant_id='raj' and code='dps-miyapur';

  -- ============ A. INTEGRITY ============

  -- end time must be after start time
  ok := false;
  begin
    insert into batches (tenant_id, centre_id, code, name, days, start_time, end_time)
    values ('raj', c_dps, 'ZZTEST-bad-time', 'ZZTEST bad', array[1], '18:00', '17:00');
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: end<=start was accepted'; end if;

  -- a weekday may not repeat
  ok := false;
  begin
    insert into batches (tenant_id, centre_id, code, name, days, start_time, end_time)
    values ('raj', c_dps, 'ZZTEST-dup-day', 'ZZTEST dup', array[1,1,3], '17:00', '18:00');
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: repeated weekday was accepted'; end if;

  -- weekday 0 / 8 are not weekdays
  ok := false;
  begin
    insert into batches (tenant_id, centre_id, code, name, days, start_time, end_time)
    values ('raj', c_dps, 'ZZTEST-bad-day', 'ZZTEST bad day', array[0,9], '17:00', '18:00');
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: out-of-range weekday was accepted'; end if;
  raise notice 'OK  batch timings validate (order, duplicate days, range)';

  -- money cannot be negative, percent cannot exceed 100
  ok := false;
  begin insert into fee_rules (tenant_id, label, monthly_amount) values ('raj','ZZTEST', -5);
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: negative fee accepted'; end if;

  ok := false;
  begin
    insert into payout_rules (tenant_id, party, centre_id, basis, value)
    values ('raj','centre', c_dps, 'percent', 140);
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: 140%% payout accepted'; end if;

  -- a cap below the guarantee is a contract nobody can honour
  ok := false;
  begin
    insert into payout_rules (tenant_id, party, centre_id, basis, value, min_guarantee, max_cap)
    values ('raj','centre', c_dps, 'percent', 10, 9000, 5000);
  exception when check_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: max_cap below min_guarantee accepted'; end if;
  raise notice 'OK  money constraints (negative, >100%%, cap<floor)';

  -- two active rules on the SAME scope would make the winning fee ambiguous
  insert into fee_rules (tenant_id, label, sport, monthly_amount)
    values ('raj','ZZTEST hockey A','hockey-zztest', 1000);
  ok := false;
  begin
    insert into fee_rules (tenant_id, label, sport, monthly_amount)
      values ('raj','ZZTEST hockey B','hockey-zztest', 2000);
  exception when unique_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: duplicate active fee rule scope accepted'; end if;
  raise notice 'OK  only one active fee rule may own a scope';

  -- the same student cannot hold two active enrollments in one batch+sport
  insert into members (tenant_id, name, status) values ('raj','ZZTEST Student','active')
    returning id into m_new;
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, renewal_on)
    select 'raj', m_new, c_dps, b.id, 'cricket', ist_today()
      from batches b where b.tenant_id='raj' and b.code='dps-b1'
    returning id into e_new;
  ok := false;
  begin
    insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, renewal_on)
      select 'raj', m_new, c_dps, b.id, 'cricket', ist_today()
        from batches b where b.tenant_id='raj' and b.code='dps-b1';
  exception when unique_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: duplicate active enrollment accepted'; end if;

  -- but a SECOND sport in the same batch is legitimate
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, renewal_on)
    select 'raj', m_new, c_dps, b.id, 'tennis', ist_today()
      from batches b where b.tenant_id='raj' and b.code='dps-b1';
  raise notice 'OK  one enrollment per batch+sport, but two sports allowed';

  -- ============ deletes must not orphan ============
  ok := false;
  begin delete from centres where id = c_dps;
  exception when restrict_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: deleted a centre that has enrollments'; end if;

  ok := false;
  begin delete from sports where tenant_id='raj' and code='cricket';
  exception when restrict_violation then ok := true; end;
  if not ok then raise exception 'TEST FAIL: deleted a sport that is in use'; end if;
  raise notice 'OK  centres and sports in use cannot be deleted';

  -- an unused, newly added sport CAN be removed (no dead-ends for the manager)
  r_sport := add_sport('raj', 'ZZTEST Squash', '🎾');
  delete from sports where id = r_sport.id;
  raise notice 'OK  an unused sport can still be deleted';

  -- ============ deactivating a batch frees its students ============
  r_centre := add_centre('raj', 'ZZTEST Centre');
  r_batch  := add_batch('raj', r_centre.id, 'Evening', array[2,4], '18:00', '19:00', 'cricket');
  insert into members (tenant_id, name, status) values ('raj','ZZTEST Movable','active')
    returning id into m_new;
  insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport, renewal_on)
    values ('raj', m_new, r_centre.id, r_batch.id, 'cricket', ist_today());

  update batches set active = false where id = r_batch.id;
  select batch_id into e_new from enrollments where member_id = m_new;
  if e_new is not null then
    raise exception 'TEST FAIL: closing a batch left a student pointing at it';
  end if;
  select count(*) into n from enrollments
   where member_id = m_new and notes like '%was closed%';
  if n <> 1 then raise exception 'TEST FAIL: no note left explaining the move'; end if;
  raise notice 'OK  closing a batch detaches its students and records why';

  -- ============ B. COLLISION-SAFE CODES ============
  -- "Batch 1" already exists at DPS; adding one at a new centre must not clash
  r_batch := add_batch('raj', r_centre.id, 'Batch 1', array[1,3,5], '17:00', '18:00');
  if r_batch.code is null then raise exception 'TEST FAIL: no code generated'; end if;
  select count(*) into n from batches where tenant_id='raj' and code = r_batch.code;
  if n <> 1 then raise exception 'TEST FAIL: generated code is not unique'; end if;

  -- adding the same batch NAME at the same centre is refused with a readable message
  ok := false;
  begin r_batch := add_batch('raj', r_centre.id, 'Batch 1', array[2], '19:00', '20:00');
  exception when others then ok := true; txt := sqlerrm; end;
  if not ok then raise exception 'TEST FAIL: duplicate batch name at one centre accepted'; end if;
  if txt not like '%already has a batch%' then
    raise exception 'TEST FAIL: unhelpful error for duplicate batch: %', txt; end if;

  -- a duplicate centre name is refused too
  ok := false;
  begin r_centre := add_centre('raj', 'ZZTEST Centre');
  exception when others then ok := true; end;
  if not ok then raise exception 'TEST FAIL: duplicate centre name accepted'; end if;

  -- an unknown sport cannot be attached to a batch
  ok := false;
  begin
    r_batch := add_batch('raj', c_dps, 'ZZTEST Ghost', array[1], '10:00', '11:00', 'kabaddi-nope');
  exception when others then ok := true; end;
  if not ok then raise exception 'TEST FAIL: batch accepted an unknown sport'; end if;
  raise notice 'OK  add_sport / add_centre / add_batch validate and never collide';

  -- codes really do increment rather than fail
  r_sport := add_sport('raj', 'ZZTEST Kho Kho');
  if r_sport.code <> 'zztest-kho-kho' then
    raise exception 'TEST FAIL: unexpected slug %', r_sport.code; end if;
  raise notice 'OK  slugs are generated from the name';

  -- ============ timing change is audited ============
  select id into b_new from batches where tenant_id='raj' and code='dps-b1';
  perform update_batch_timing('raj', b_new, array[1,2,3,4,5], '15:30'::time, '17:00'::time);
  select count(*) into n from audit_log
   where tenant_id='raj' and entity='batch' and entity_id=b_new and action='timing_changed';
  if n <> 1 then raise exception 'TEST FAIL: timing change not audited'; end if;
  raise notice 'OK  a batch timing change writes a dedicated audit entry';

  -- ============ C. AUDIT LOG ============
  select count(*) into n from audit_log where tenant_id='raj';
  if n = 0 then raise exception 'TEST FAIL: audit log is empty after all these changes'; end if;

  -- a fee change records both sides, so "why did this student pay less" is answerable
  update fee_rules set monthly_amount = 1234
   where tenant_id='raj' and label='ZZTEST hockey A';
  select count(*) into n from audit_log
   where tenant_id='raj' and entity='fee_rule' and action='updated'
     and (before->>'monthly_amount')::numeric = 1000
     and (after->>'monthly_amount')::numeric = 1234;
  if n <> 1 then raise exception 'TEST FAIL: fee change did not record before/after'; end if;

  -- a no-op write must not pollute the log
  select count(*) into n from audit_log where tenant_id='raj';
  update fee_rules set monthly_amount = 1234
   where tenant_id='raj' and label='ZZTEST hockey A';
  select count(*) - n into n from audit_log where tenant_id='raj';
  if n <> 0 then raise exception 'TEST FAIL: a no-op update wrote an audit row'; end if;
  raise notice 'OK  audit log captures before/after and ignores no-op writes';

  -- ============ tenant_health ============
  h := tenant_health('raj');
  if h->'roster'->>'active_students' is null then
    raise exception 'TEST FAIL: health has no roster block'; end if;
  if h->'reminders'->>'due_today' is null then
    raise exception 'TEST FAIL: health has no reminder block'; end if;
  if (h->'config'->>'booking_module')::boolean is not false then
    raise exception 'TEST FAIL: health should report booking module OFF for raj'; end if;
  if h->'config'->>'students_without_fee' is null then
    raise exception 'TEST FAIL: health does not report misconfiguration'; end if;
  if h->'money'->>'collected_mtd' is null then
    raise exception 'TEST FAIL: health has no money block'; end if;
  raise notice 'OK  tenant_health returns roster, money, reminders, usage, config';

  raise notice '';
  raise notice '======== MIGRATION 3 TESTS PASSED ========';
end $$;

select 'MIGRATION 3 TESTS PASSED' as result,
       (select count(*) from audit_log where tenant_id='raj')       as audit_rows,
       (select tenant_health('raj')->'roster'->>'active_students')  as active_students,
       (select tenant_health('raj')->'reminders'->>'due_today')     as due_today,
       (select tenant_health('raj')->'config'->>'booking_module')   as booking_off;
