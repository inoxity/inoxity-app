-- STUDY DATA BACKEND ONLY. Never apply to inoxity_backend (the Control Backend).
create table public.survey_events (
  id uuid primary key default gen_random_uuid(),
  client_event_id text not null unique,
  participant_id uuid not null references public.participants(id),
  enrollment_id uuid not null references public.study_enrollments(id),
  survey_id text not null,
  occurrence_id text not null,
  event_type text not null check (event_type in ('opened','completed')),
  event_timestamp timestamptz not null,
  scheduled_for timestamptz not null,
  opened_at timestamptz,
  completed_at timestamptz,
  -- IANA identifier (e.g. "America/Los_Angeles") for the zone this event was captured in — the
  -- timestamptz columns above are UTC-only and can't be converted back to local wall-clock time
  -- without it. Nullable: older app builds won't send it. Query local time later with
  -- event_timestamp AT TIME ZONE event_time_zone.
  event_time_zone text,
  configuration_schema_version integer not null check (configuration_schema_version > 0),
  configuration_revision integer not null check (configuration_revision > 0),
  event_source text not null check (event_source in ('presentation','completionCallback','restoration')),
  app_version text not null,
  received_at timestamptz not null default now(),
  unique(enrollment_id, occurrence_id, event_type),
  check (client_event_id = 'survey-event.' || occurrence_id || '.' || event_type),
  check (event_type <> 'opened' or opened_at = event_timestamp),
  check (event_type <> 'completed' or (completed_at = event_timestamp and opened_at is not null and opened_at <= completed_at))
);

alter table public.survey_events enable row level security;
revoke all on public.survey_events from anon, authenticated;
