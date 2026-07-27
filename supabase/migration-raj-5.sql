-- ============================================================
-- RAJ SPORTS: reminder recency and duplicate-send visibility
--
-- The one-per-enrollment-per-IST-day unique index remains the hard
-- duplicate guard. The queue now also returns the latest non-void event,
-- so every client can explain when that parent was last contacted.
-- ============================================================

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
  where base.days_since = -2
     or base.days_since = 0
     or base.days_since = 5
     or (base.days_since between 7 and 14)
     or base.days_since >= 15
  order by base.days_since desc, base.member_name
$$;

grant execute on function reminder_queue(text,date) to authenticated, service_role;
