-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
-- Makes study_backend_id optional on public.studies.
--
-- Why: each research team must provision and own its own Study Backend
-- project — the platform never gets a shared default, since that would
-- mean the platform operator has visibility into every team's participant
-- data by default, contradicting the "no participant data in Control"
-- design (see 002_control_rls_and_rpcs.sql's header). A researcher may not
-- have their own project ready yet when they start creating a study, so a
-- draft must be saveable with study_backend_id left null. Application code
-- (the dashboard's setStudyActive action) enforces that a study cannot be
-- activated (is_active = true) without a real study_backend_id set —
-- Postgres itself doesn't need to enforce that cross-column rule.
-- ================================================================
alter table public.studies
  alter column study_backend_id drop not null;
