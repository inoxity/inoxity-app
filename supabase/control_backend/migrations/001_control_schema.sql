-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
-- Never apply this file to a Study Backend.
-- ================================================================
create extension if not exists pgcrypto;

create table public.study_backends (
  id uuid primary key default gen_random_uuid(),
  backend_slug text not null unique check (backend_slug ~ '^[a-z0-9][a-z0-9_-]{2,63}$'),
  environment text not null check (environment in ('Development','Staging','Production')),
  supabase_url text not null check (supabase_url ~ '^https://[^[:space:]]+$'),
  supabase_anon_key text not null check (length(trim(supabase_anon_key)) >= 20),
  descriptor_revision integer not null default 1 check (descriptor_revision > 0),
  diagnostic_name text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.studies (
  id uuid primary key default gen_random_uuid(),
  stable_study_id text not null unique check (stable_study_id ~ '^[A-Za-z0-9_-]+$'),
  study_code text not null unique check (study_code = upper(trim(study_code))),
  configuration_schema_version integer not null check (configuration_schema_version > 0),
  configuration_revision integer not null check (configuration_revision > 0),
  configuration_json jsonb not null,
  study_backend_id uuid not null references public.study_backends(id),
  is_active boolean not null default false,
  enrollment_opens_at timestamptz,
  enrollment_closes_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (enrollment_opens_at is null or enrollment_closes_at is null or enrollment_opens_at <= enrollment_closes_at)
);

comment on table public.study_backends is 'Public client descriptors only. Never store service-role keys.';
comment on table public.studies is 'Control-plane study metadata and immutable participant-app configuration.';
