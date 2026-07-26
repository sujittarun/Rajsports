-- ============================================================
-- RAJ SPORTS — remove every demo row, keep the real setup.
--
-- Run this ONCE at go-live, after Raj has seen the demo and before
-- the first real student is entered. It deletes only rows tagged
-- 'SAMPLE' by supabase/sample-data.sql — the five centres, thirteen
-- batches and five sports (his actual timetable) are NOT touched.
--
--   ./scripts/dry-run.sh supabase/clear-sample-data.sql   # see the counts
--   ./scripts/migrate.sh  supabase/clear-sample-data.sql   # do it
-- ============================================================

-- Children first: the FKs are ON DELETE CASCADE from members, but being
-- explicit keeps the counts below honest and the intent readable.
delete from reminder_events where tenant_id = 'raj'
  and member_id in (select id from members where tenant_id='raj' and notes = 'SAMPLE');

delete from member_timeline where tenant_id = 'raj'
  and member_id in (select id from members where tenant_id='raj' and notes = 'SAMPLE');

delete from payments   where tenant_id = 'raj' and note  = 'SAMPLE';
delete from payouts     where tenant_id = 'raj'
  and rule_id in (select id from payout_rules where tenant_id='raj' and note = 'SAMPLE');
delete from enrollments where tenant_id = 'raj' and notes = 'SAMPLE';
delete from members     where tenant_id = 'raj' and notes = 'SAMPLE';

delete from payout_rules where tenant_id = 'raj' and note  = 'SAMPLE';
delete from fee_rules    where tenant_id = 'raj' and note  = 'SAMPLE';
delete from coaches      where tenant_id = 'raj' and notes = 'SAMPLE';

-- The two demo enquiries on the review queue.
delete from applications where tenant_id = 'raj' and goal like 'SAMPLE%';

-- The audit log is deliberately NOT cleared: it is the record of what was
-- done to this tenant, including the demo. Clearing it would make the
-- first real month look like it had no history at all.

select 'SAMPLE DATA CLEARED' as result,
       (select count(*) from members      where tenant_id='raj') as students_left,
       (select count(*) from enrollments  where tenant_id='raj') as enrollments_left,
       (select count(*) from payments     where tenant_id='raj') as payments_left,
       (select count(*) from fee_rules    where tenant_id='raj') as fee_rules_left,
       (select count(*) from payout_rules where tenant_id='raj') as payout_rules_left,
       (select count(*) from centres      where tenant_id='raj') as centres_kept,
       (select count(*) from batches      where tenant_id='raj') as batches_kept,
       (select count(*) from sports       where tenant_id='raj') as sports_kept;
