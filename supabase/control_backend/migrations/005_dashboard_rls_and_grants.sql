-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
-- 002_control_rls_and_rpcs.sql revoked ALL table privileges on
-- study_backends/studies from anon and authenticated so that participants
-- (who are also `authenticated` — Supabase has no separate Postgres role
-- per app-user-type) can reach this data ONLY through
-- resolve_study_bootstrap(), a security definer RPC that bypasses RLS.
--
-- Researchers now need direct table access from the dashboard, so this
-- file re-grants the minimum table privileges the dashboard actually uses,
-- then narrows that access back down with RLS so a participant's
-- `authenticated` session — despite now having the same table-level grant
-- — still can't see or touch anyone's studies or study_backends rows:
--   * studies: scoped to auth.uid() = owner_id (participants own 0 rows).
--   * study_backends: has no per-row owner (it's shared/reusable
--     infrastructure metadata across studies/researchers), so it's scoped
--     instead by auth.jwt()->>'is_anonymous' — real researcher sessions
--     only, never anonymous participant sessions. This matters because
--     study_backends.supabase_anon_key is sensitive: without this, any
--     authenticated participant could read every team's study backend's
--     anon key directly off the table, which is exactly what
--     resolve_study_bootstrap() exists to prevent.
-- ================================================================

-- studies -----------------------------------------------------------
grant select, insert, update on public.studies to authenticated;

create policy "Researchers can view their own studies"
  on public.studies
  for select
  to authenticated
  using (
    auth.uid() = owner_id
    and (auth.jwt() ->> 'is_anonymous')::boolean is not true
  );

create policy "Researchers can insert their own studies"
  on public.studies
  for insert
  to authenticated
  with check (
    auth.uid() = owner_id
    and (auth.jwt() ->> 'is_anonymous')::boolean is not true
  );

create policy "Researchers can update their own studies"
  on public.studies
  for update
  to authenticated
  using (
    auth.uid() = owner_id
    and (auth.jwt() ->> 'is_anonymous')::boolean is not true
  )
  with check (
    auth.uid() = owner_id
    and (auth.jwt() ->> 'is_anonymous')::boolean is not true
  );

-- study_backends ------------------------------------------------------
grant select, insert on public.study_backends to authenticated;

create policy "Researchers can view study backends"
  on public.study_backends
  for select
  to authenticated
  using ((auth.jwt() ->> 'is_anonymous')::boolean is not true);

create policy "Researchers can register study backends"
  on public.study_backends
  for insert
  to authenticated
  with check ((auth.jwt() ->> 'is_anonymous')::boolean is not true);
