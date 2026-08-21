-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
-- Participant identifiers and participant records are prohibited here.
-- ================================================================
alter table public.study_backends enable row level security;
alter table public.studies enable row level security;
revoke all on public.study_backends, public.studies from anon, authenticated;

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
declare normalized text := upper(trim(requested_code)); study_row public.studies%rowtype; backend_row public.study_backends%rowtype;
begin
  if auth.uid() is null then raise exception 'unauthorized' using errcode = '42501'; end if;
  select * into study_row from public.studies s where s.study_code = normalized;
  if not found then raise exception 'study_not_found'; end if;
  if not study_row.is_active then raise exception 'study_inactive'; end if;
  if study_row.enrollment_opens_at is not null and now() < study_row.enrollment_opens_at then raise exception 'enrollment_not_open'; end if;
  if study_row.enrollment_closes_at is not null and now() > study_row.enrollment_closes_at then raise exception 'enrollment_closed'; end if;
  select * into backend_row from public.study_backends b where b.id = study_row.study_backend_id;
  if not found or not backend_row.is_active then raise exception 'study_backend_unavailable'; end if;
  return query select study_row.id, study_row.stable_study_id, study_row.study_code,
    study_row.configuration_schema_version, study_row.configuration_revision, study_row.configuration_json,
    backend_row.id, backend_row.supabase_url, backend_row.supabase_anon_key, backend_row.environment,
    backend_row.descriptor_revision, backend_row.diagnostic_name;
end $$;

revoke all on function public.resolve_study_bootstrap(text) from public;
grant execute on function public.resolve_study_bootstrap(text) to authenticated;
