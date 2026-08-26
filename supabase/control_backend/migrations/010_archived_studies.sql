-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- Adds a real archived state for studies, backing the dashboard's
-- "Archived Studies" stat card. Deliberately a separate archived_at
-- column rather than folding into is_active/config.status.state — a
-- study's activation state and its archived state are independent
-- questions (an archived study should never also be active, enforced
-- below, but "not active" already means Draft, which is a different
-- thing from "the researcher is done with this study").
--
-- No new RPC needed, unlike transfer_study_ownership/accept_study_invite
-- in 008_study_collaborators.sql — this column doesn't need a
-- cross-row invariant a security definer function has to protect.
-- studies' existing RLS UPDATE policy already covers whichever columns
-- are column-granted below (008_study_collaborators.sql revoked the
-- broad `update` grant from 005_dashboard_rls_and_grants.sql and replaced
-- it with an explicit column list, deliberately excluding owner_id); the
-- actual business rule ("deactivate before archiving") lives in
-- setStudyArchived() in inoxity-dashboard/src/lib/study-actions.ts,
-- matching how setStudyActive() already enforces its own preconditions
-- in application code rather than in the database.
-- ================================================================

alter table public.studies
  add column if not exists archived_at timestamptz;

-- Defense-in-depth only — setStudyArchived() is the primary enforcement
-- point (a friendly error message beats a raw constraint violation), but
-- this closes the gap for any other write path (SQL editor, a future
-- admin tool, etc.).
alter table public.studies
  add constraint studies_archived_requires_inactive
  check (archived_at is null or is_active = false);

create index if not exists studies_archived_at_idx
  on public.studies (archived_at)
  where archived_at is not null;

-- Additive — Postgres column grants accumulate, so this just adds
-- archived_at to 008's existing column list rather than repeating it.
grant update (archived_at) on public.studies to authenticated;
