-- ARCHIVED HISTORICAL SQL — DO NOT APPLY
-- Original Phase 3B single-backend schema, preserved for reference only.
create extension if not exists pgcrypto;

create table public.studies (
  id uuid primary key default gen_random_uuid(),
  stable_study_id text not null unique,
  study_code text not null unique,
  configuration_schema_version integer not null,
  configuration_revision integer not null,
  configuration_json jsonb not null,
  is_active boolean not null default false,
  enrollment_opens_at timestamptz,
  enrollment_closes_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.participants (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  created_at timestamptz not null default now()
);

create table public.study_enrollments (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references public.participants(id),
  study_id uuid not null references public.studies(id),
  participant_identifier text not null,
  enrollment_attempt_id uuid not null unique,
  installation_id uuid not null,
  status text not null default 'active',
  configuration_schema_version integer not null,
  configuration_revision integer not null,
  enrolled_at timestamptz not null default now(),
  unique(participant_id, study_id)
);

create table public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  client_event_id uuid not null unique,
  participant_id uuid not null references public.participants(id),
  enrollment_id uuid references public.study_enrollments(id),
  stable_study_id text not null,
  withdrawal_choice text not null,
  requested_at timestamptz not null,
  created_at timestamptz not null default now()
);
