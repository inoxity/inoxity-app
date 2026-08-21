-- ================================================================
-- STUDY DATA BACKEND ONLY — apply to one independent Study Backend.
-- Never apply this file to inoxity_backend or a different Study Backend.
-- ================================================================
create extension if not exists pgcrypto;
create table public.study_backend_metadata (
  singleton boolean primary key default true check (singleton),
  backend_instance_id uuid not null unique,
  stable_study_id text not null,
  expected_study_code text not null check (expected_study_code = upper(trim(expected_study_code))),
  supported_configuration_schema_version integer not null check (supported_configuration_schema_version > 0),
  is_active boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.participants (
  id uuid primary key default gen_random_uuid(), auth_user_id uuid not null unique,
  -- HH:mm local time-of-day strings, mirroring the pre-dashboard app's participants
  -- table — set via the update_sleep_schedule RPC (002) whenever the participant
  -- sets/edits their wake/bed time in the app, so researchers have server-side
  -- visibility into it without needing device access.
  wake_time text check (wake_time is null or wake_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  bed_time text check (bed_time is null or bed_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  created_at timestamptz not null default now()
);
create table public.study_enrollments (
  id uuid primary key default gen_random_uuid(), participant_id uuid not null references public.participants(id),
  participant_identifier text not null, enrollment_attempt_id uuid not null unique, installation_id uuid not null,
  status text not null default 'active' check (status in ('active','withdrawn')),
  configuration_schema_version integer not null, configuration_revision integer not null,
  enrolled_at timestamptz not null default now(), unique(participant_id)
);
create table public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(), client_event_id uuid not null unique,
  participant_id uuid not null references public.participants(id),
  enrollment_id uuid references public.study_enrollments(id),
  withdrawal_choice text not null check (withdrawal_choice in ('keepExistingData','deleteExistingData')),
  requested_at timestamptz not null, created_at timestamptz not null default now(), processed_at timestamptz
);
