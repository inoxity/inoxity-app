-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- Minimizes what inoxity_backend stores about a study's own Supabase
-- project. Previously `study_backends` held every study's live
-- supabase_url/supabase_anon_key as its own readable table — and that
-- table's RLS policy (005_dashboard_rls_and_grants.sql) granted SELECT to
-- ANY authenticated researcher, not just the study's owner, so every
-- team's backend credentials were actually readable by every other team.
-- This migration folds those same three values into
-- `studies.configuration_json` itself, as a `dataBackend` object the
-- dashboard wizard already collects — nested inside the per-study JSON
-- blob rather than a dedicated table/columns, and now covered by the
-- existing `studies` RLS policy that scopes SELECT to
-- `auth.uid() = owner_id`, so only the owning researcher can see it.
--
-- After this migration, `studies` holds only what dashboard login/listing
-- needs (id, stable_study_id, study_code, configuration_*, owner_id,
-- is_active, enrollment window, timestamps) plus the jsonb config; nothing
-- in inoxity_backend is a dedicated table/column for another project's
-- Supabase credentials anymore. Any study that already had a linked
-- study_backends row has that same descriptor copied into
-- configuration_json.dataBackend first, so no existing link is lost.
-- ================================================================

-- Preserve any already-linked descriptor into configuration_json.dataBackend
-- BEFORE dropping study_backend_id/study_backends below, so an existing
-- production link isn't silently lost. Safe to run even if study_backends
-- doesn't exist yet or no study has one linked (affects 0 rows either way).
do $$ begin
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'study_backends')
     and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'studies' and column_name = 'study_backend_id')
  then
    update public.studies s
    set configuration_json = jsonb_set(
      s.configuration_json,
      '{dataBackend}',
      jsonb_build_object(
        'backendId', b.id,
        'supabaseUrl', b.supabase_url,
        'supabaseAnonKey', b.supabase_anon_key,
        'environment', b.environment
      ),
      true
    )
    from public.study_backends b
    where s.study_backend_id = b.id
      and (s.configuration_json -> 'dataBackend') is null;
  end if;
end $$;

drop policy if exists "Researchers can view study backends" on public.study_backends;
drop policy if exists "Researchers can register study backends" on public.study_backends;
revoke all on public.study_backends from authenticated;

alter table public.studies drop column if exists study_backend_id;
drop table if exists public.study_backends;

-- resolve_study_bootstrap keeps the exact same output shape the iOS app
-- already decodes (study_backend_url/anon_key/environment, backend_id,
-- descriptor_revision, backend_diagnostic_name) — only where those values
-- come from changes, from a join to `configuration_json->'dataBackend'`.
create or replace function public.resolve_study_bootstrap(requested_code text)
returns table (
  study_id uuid, stable_study_id text, study_code text,
  configuration_schema_version integer, configuration_revision integer,
  configuration_json jsonb, backend_id uuid,
  study_backend_url text, study_backend_anon_key text,
  study_backend_environment text, descriptor_revision integer,
  backend_diagnostic_name text
)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  normalized text := upper(trim(requested_code));
  study_row public.studies%rowtype;
  backend jsonb;
begin
  if auth.uid() is null then raise exception 'unauthorized' using errcode = '42501'; end if;
  select * into study_row from public.studies s where s.study_code = normalized;
  if not found then raise exception 'study_not_found'; end if;
  if not study_row.is_active then raise exception 'study_inactive'; end if;
  if study_row.enrollment_opens_at is not null and now() < study_row.enrollment_opens_at then raise exception 'enrollment_not_open'; end if;
  if study_row.enrollment_closes_at is not null and now() > study_row.enrollment_closes_at then raise exception 'enrollment_closed'; end if;

  backend := study_row.configuration_json -> 'dataBackend';
  if backend is null
     or backend ->> 'backendId' is null
     or backend ->> 'supabaseUrl' is null
     or backend ->> 'supabaseAnonKey' is null
  then
    raise exception 'study_backend_unavailable';
  end if;

  return query select study_row.id, study_row.stable_study_id, study_row.study_code,
    study_row.configuration_schema_version, study_row.configuration_revision, study_row.configuration_json,
    (backend ->> 'backendId')::uuid, backend ->> 'supabaseUrl', backend ->> 'supabaseAnonKey',
    coalesce(backend ->> 'environment', 'Production'),
    1, -- descriptor_revision: no rotation-tracking counter anymore now that this lives in configuration_json;
       -- bump configuration_revision (already tracked) instead if credentials ever need to be rotated.
    null::text; -- backend_diagnostic_name: dropped from the minimal schema; app treats it as optional.
end $$;

revoke all on function public.resolve_study_bootstrap(text) from public;
grant execute on function public.resolve_study_bootstrap(text) to authenticated;

comment on table public.studies is 'Control-plane study metadata, ownership, and immutable participant-app configuration. Per-study Supabase Study Backend credentials live inside configuration_json.dataBackend, not a separate table/column.';
