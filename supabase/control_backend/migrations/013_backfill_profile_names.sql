-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- handle_new_user() (003_researcher_profiles.sql) writes full_name = ''
-- whenever the auth.users row arrives without full_name in its signup
-- metadata, which left some researchers greeted as "Researcher" on the
-- dashboard until they re-saved their name in Settings.
--
-- One-time, idempotent backfill: only rows whose full_name is still
-- empty are touched, and only when the signup metadata actually has a
-- name to copy — a name someone has already set is never overwritten.
-- Safe to re-run; a second run updates zero rows.
-- ================================================================

update public.profiles p
set full_name = trim(u.raw_user_meta_data ->> 'full_name')
from auth.users u
where u.id = p.id
  and trim(p.full_name) = ''
  and coalesce(trim(u.raw_user_meta_data ->> 'full_name'), '') <> '';
