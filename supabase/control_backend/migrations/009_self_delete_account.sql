-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- Lets a signed-in researcher delete their own account from the
-- dashboard's Settings page, without the app ever holding a service_role
-- key (see the standing note in inoxity-dashboard/.env.example and
-- src/lib/study-actions.ts — "this app never needs service_role").
-- security definer functions run as the role that owns them (the
-- migration role, e.g. `postgres`), which — unlike `authenticated` — does
-- have DELETE privilege on auth.users in a standard Supabase project, the
-- same trust boundary handle_new_user() and find_profile_id_by_email()
-- already rely on to read/write auth.users (003_researcher_profiles.sql,
-- 008_study_collaborators.sql).
--
-- Deleting the auth.users row cascades to public.profiles (003's
-- `references auth.users(id) on delete cascade`) and to any
-- study_collaborators rows where they're the collaborator (008's
-- `references public.profiles(id) on delete cascade`) — but NOT to any
-- study they own, since studies.owner_id is `on delete restrict`
-- (004_dashboard_ownership.sql) precisely to stop an active study from
-- being silently orphaned. So this function checks that up front and
-- raises a friendly, specific error instead of a raw FK violation.
-- ================================================================
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if exists (select 1 from public.studies where owner_id = auth.uid()) then
    raise exception 'owns_studies';
  end if;

  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;
