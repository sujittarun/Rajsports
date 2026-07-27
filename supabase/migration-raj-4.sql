-- ============================================================
-- RAJ SPORTS — migration 4: tenant-safe setup deletes
--
-- The setup UI can delete unused rates, sports, centres and batches.
-- The integrity triggers already refuse anything that is in use, but
-- lockdown was missing the RLS DELETE path, so PostgREST returned a
-- successful zero-row response and the UI incorrectly said "Deleted".
--
-- These policies remain generic for the shared Academy Manager schema:
-- staff can delete only rows belonging to their own tenant, while an
-- operator can manage any tenant. Existing FK and guard triggers still
-- decide whether the resolved row is safe to remove.
-- ============================================================

do $$
declare
  table_name text;
  policy_name text;
begin
  foreach table_name in array array[
    'sports', 'centres', 'batches', 'coaches', 'fee_rules', 'payout_rules'
  ] loop
    policy_name := table_name || '_staff_d';
    execute format('drop policy if exists %I on %I', policy_name, table_name);
    execute format(
      'create policy %I on %I for delete using (
         auth_role() = ''operator''
         or (auth_role() = ''staff'' and tenant_id = auth_tenant())
       )',
      policy_name, table_name
    );
  end loop;
end $$;
