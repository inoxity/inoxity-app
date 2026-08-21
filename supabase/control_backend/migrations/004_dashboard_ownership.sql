-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
-- Adds researcher-ownership tracking now that researcher accounts
-- (public.profiles, see 003_researcher_profiles.sql) live in this same
-- project — owner_id is a real foreign key, and RLS in
-- 005_dashboard_rls_and_grants.sql enforces auth.uid() = owner_id.
--
-- Before running, confirm no existing studies rows have a null owner_id:
--   select count(*) from public.studies where owner_id is null;
-- (expected: 0 — this project's studies table should still be empty at
-- this point in the migration history).
--
-- on delete restrict (not cascade): profiles cascades from auth.users, but
-- deleting a researcher account while they still own studies should fail
-- loudly rather than silently deleting an active/participant-facing study.
-- ================================================================
alter table public.studies
  add column if not exists owner_id uuid;

alter table public.studies
  alter column owner_id set not null,
  add constraint studies_owner_id_fkey
    foreign key (owner_id) references public.profiles(id) on delete restrict;

create index if not exists studies_owner_id_idx on public.studies (owner_id);
